-- Contrôle post-déploiement en lecture seule. Le résultat doit avoir ok=true.
with controls as(
  select 'latest_migration' control,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'missing') value,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'')='202607220047' ok
  union all
  select 'payment_reversal_rpc',coalesce(to_regprocedure('public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz)')::text,'missing'),
    to_regprocedure('public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz)') is not null
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
  select 'fiscal_events_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.fiscal_events'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.fiscal_events'::regclass),false)
  union all
  select 'anonymous_scheduled_job_blocked',has_function_privilege('anon','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')::text,
    not has_function_privilege('anon','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')
  union all
  select 'browser_scheduled_job_blocked',has_function_privilege('authenticated','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')::text,
    not has_function_privilege('authenticated','public.run_due_fiscal_maintenance(timestamptz)','EXECUTE')
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
  'schema_version','202607220047',
  'checked_at',clock_timestamp(),
  'controls',jsonb_agg(jsonb_build_object('name',control,'value',value,'ok',ok) order by control)
) production_check from controls;
