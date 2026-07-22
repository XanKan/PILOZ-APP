-- Contrôles structurels en lecture seule après la migration 202607220045.
do $$
declare table_name text;
begin
  foreach table_name in array array[
    'company_compliance_evidence','compliance_anomalies','compliance_anomaly_resolutions',
    'compliance_integrity_checks','data_subject_requests','data_subject_request_items',
    'company_retention_rules','company_software_certifications'
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
  if to_regprocedure('public.has_company_permission(uuid,text)') is null then raise exception 'permission_helper_missing'; end if;
  if to_regprocedure('public.set_company_member_access(uuid,uuid,text,jsonb)') is null then raise exception 'member_access_rpc_missing'; end if;
  if to_regprocedure('public.run_company_integrity_check(uuid)') is null then raise exception 'integrity_check_rpc_missing'; end if;
  if to_regprocedure('public.evaluate_fiscal_activation(uuid,text)') is null then raise exception 'activation_evaluator_missing'; end if;
  if to_regprocedure('public.activate_fiscal_engine(uuid,text)') is null then raise exception 'activation_rpc_missing'; end if;
  if to_regprocedure('public.get_company_compliance_summary(uuid)') is null then raise exception 'compliance_summary_rpc_missing'; end if;
  if has_function_privilege('anon','public.activate_fiscal_engine(uuid,text)','EXECUTE') then raise exception 'anonymous_activation_detected'; end if;
  if has_function_privilege('anon','public.run_company_integrity_check(uuid)','EXECUTE') then raise exception 'anonymous_integrity_check_detected'; end if;
  if exists(select 1 from public.company_software_certifications) then raise exception 'unexpected_certification_seed'; end if;
end
$$;

select 'production_enabled_without_kms' control_name,count(*) anomaly_count
from public.company_fiscal_configurations
where mode='production' and activation_status='production_active'
  and (signing_status<>'configured' or kms_key_id is null)
union all
select 'verified_certificate_without_date',count(*)
from public.company_software_certifications where status='verified' and verified_at is null
union all
select 'verified_evidence_without_date',count(*)
from public.company_compliance_evidence where status='verified' and verified_at is null
union all
select 'cross_company_request_items',count(*)
from public.data_subject_request_items item
join public.data_subject_requests request on request.id=item.request_id
where item.company_id<>request.company_id;

