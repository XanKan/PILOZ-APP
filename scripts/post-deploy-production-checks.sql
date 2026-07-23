-- Contrôle post-déploiement en lecture seule. Le résultat doit avoir ok=true.
with controls as(
  select 'latest_migration' control,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'missing') value,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'')='202607230052' ok
  union all
  select 'payment_reversal_rpc',coalesce(to_regprocedure('public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz)')::text,'missing'),
    to_regprocedure('public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz)') is not null
  union all
  select 'multi_invoice_payment_rpc',coalesce(to_regprocedure('public.record_multi_invoice_payment(jsonb,numeric,text,timestamptz,date,text,text,text,text,jsonb,text,boolean,uuid)')::text,'missing'),
    to_regprocedure('public.record_multi_invoice_payment(jsonb,numeric,text,timestamptz,date,text,text,text,text,jsonb,text,boolean,uuid)') is not null
  union all
  select 'manual_invoice_email_rpc',coalesce(to_regprocedure('public.record_manual_document_email(uuid,text[],text[],text,text,text,text)')::text,'missing'),
    to_regprocedure('public.record_manual_document_email(uuid,text[],text[],text,text,text,text)') is not null
  union all
  select 'payment_receipt_reversal_rpc',coalesce(to_regprocedure('public.reverse_payment_receipt(uuid,text,text,timestamptz)')::text,'missing'),
    to_regprocedure('public.reverse_payment_receipt(uuid,text,text,timestamptz)') is not null
  union all
  select 'privacy_export_rpc',coalesce(to_regprocedure('public.generate_data_subject_export(uuid)')::text,'missing'),
    to_regprocedure('public.generate_data_subject_export(uuid)') is not null
  union all
  select 'scheduled_maintenance_rpc',coalesce(to_regprocedure('public.run_due_fiscal_maintenance(timestamptz)')::text,'missing'),
    to_regprocedure('public.run_due_fiscal_maintenance(timestamptz)') is not null
  union all
  select 'payment_ledger_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.payments'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.payments'::regclass),false)
  union all
  select 'payment_receipts_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.payment_receipts'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.payment_receipts'::regclass),false)
  union all
  select 'payment_receipt_base_table_blocked',has_table_privilege('authenticated','public.payment_receipts','SELECT')::text,
    not has_table_privilege('authenticated','public.payment_receipts','SELECT')
  union all
  select 'payment_receipt_safe_view_available',has_table_privilege('authenticated','public.payment_receipt_read_model','SELECT')::text,
    has_table_privilege('authenticated','public.payment_receipt_read_model','SELECT')
  union all
  select 'payment_allocations_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.payment_allocations'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.payment_allocations'::regclass),false)
  union all
  select 'email_deliveries_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.document_email_deliveries'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.document_email_deliveries'::regclass),false)
  union all
  select 'email_delivery_counter_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.document_email_deliveries'::regclass
    and tgname='document_email_deliveries_apply_counter'
    and not tgisinternal
  union all
  select 'fiscal_events_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.fiscal_events'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.fiscal_events'::regclass),false)
  union all
  select 'client_addresses_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.client_addresses'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.client_addresses'::regclass),false)
  union all
  select 'client_directory_rpc',coalesce(to_regprocedure('public.get_client_directory_v2(uuid,text,jsonb,text,text,integer,integer)')::text,'missing'),
    to_regprocedure('public.get_client_directory_v2(uuid,text,jsonb,text,text,integer,integer)') is not null
  union all
  select 'client_snapshot_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.document_snapshots'::regclass
    and tgname='document_snapshots_client_context'
    and not tgisinternal
  union all
  select 'anonymous_scheduled_job_blocked',has_function_privilege('anon','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')::text,
    not has_function_privilege('anon','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')
  union all
  select 'browser_scheduled_job_blocked',has_function_privilege('authenticated','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')::text,
    not has_function_privilege('authenticated','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')
  union all
  select 'invoice_chronology_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_enforce_issue_date_chronology'
    and not tgisinternal
  union all
  select 'production_without_kms',count(*)::text,count(*)=0
  from public.company_fiscal_configurations
  where mode='production' and activation_status='production_active'
    and (signing_status<>'configured' or kms_key_id is null)
  union all
  select 'over_reversed_payments',count(*)::text,count(*)=0 from(
    select original.id from public.payments original
    left join public.payments reversal on reversal.reverses_payment_id=original.id and reversal.status='confirmed'
    where original.entry_type in('payment','overpayment')
    group by original.id,original.amount
    having coalesce(-sum(reversal.amount),0)>original.amount+0.005
  ) anomaly
)
select jsonb_build_object(
  'ok',bool_and(ok),
  'schema_version','202607230052',
  'checked_at',clock_timestamp(),
  'controls',jsonb_agg(jsonb_build_object('name',control,'value',value,'ok',ok) order by control)
) production_check from controls;
