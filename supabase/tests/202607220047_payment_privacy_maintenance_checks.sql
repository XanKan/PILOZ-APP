-- Read-only structural controls for migrations 202607220046 and 047.
do $$
declare table_name text;
begin
  foreach table_name in array array[
    'data_subject_request_events','data_subject_exports',
    'fiscal_automation_policies','fiscal_maintenance_runs'
  ] loop
    if to_regclass('public.'||table_name) is null then raise exception 'missing_table:%',table_name; end if;
    if not (select relrowsecurity from pg_class where oid=to_regclass('public.'||table_name)) then
      raise exception 'rls_disabled:%',table_name;
    end if;
    if has_table_privilege('authenticated','public.'||table_name,'INSERT')
      or has_table_privilege('authenticated','public.'||table_name,'UPDATE')
      or has_table_privilege('authenticated','public.'||table_name,'DELETE') then
      raise exception 'direct_authenticated_write_detected:%',table_name;
    end if;
  end loop;
  if to_regprocedure('public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz)') is null then
    raise exception 'payment_reversal_rpc_missing';
  end if;
  if to_regprocedure('public.record_document_receipt(uuid,numeric,text,text,timestamptz,text)') is null then
    raise exception 'receipt_rpc_missing';
  end if;
  if to_regprocedure('public.generate_data_subject_export(uuid)') is null then
    raise exception 'data_subject_export_rpc_missing';
  end if;
  if to_regprocedure('public.run_due_fiscal_maintenance(timestamptz)') is null then
    raise exception 'scheduled_maintenance_rpc_missing';
  end if;
  if has_function_privilege('anon','public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz)','EXECUTE') then
    raise exception 'anonymous_payment_reversal_detected';
  end if;
  if has_function_privilege('authenticated','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE') then
    raise exception 'browser_scheduled_maintenance_detected';
  end if;
end
$$;

select 'over_reversed_payments' control_name,count(*) anomaly_count
from(
  select original.id,original.amount,coalesce(-sum(reversal.amount),0) reversed
  from public.payments original
  left join public.payments reversal on reversal.reverses_payment_id=original.id and reversal.status='confirmed'
  where original.entry_type in('payment','overpayment')
  group by original.id,original.amount
) control where control.reversed>control.amount+0.005
union all
select 'cross_company_privacy_events',count(*)
from public.data_subject_request_events event
join public.data_subject_requests request on request.id=event.request_id
where event.company_id<>request.company_id
union all
select 'automatic_archives_enabled_without_provider',count(*)
from public.fiscal_automation_policies where archive_enabled;
