-- Contrôle post-déploiement en lecture seule. Le résultat doit avoir ok=true.
with controls as(
  select 'latest_migration' control,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'missing') value,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'')='202607250064' ok
  union all
  select 'document_theme_assignments_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.document_theme_assignments'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.document_theme_assignments'::regclass),false)
  union all
  select 'document_theme_save_rpc',coalesce(to_regprocedure('public.save_document_theme(uuid,text,jsonb,jsonb)')::text,'missing'),
    to_regprocedure('public.save_document_theme(uuid,text,jsonb,jsonb)') is not null
  union all
  select 'document_theme_snapshot_columns',count(*)::text,count(*)=3
  from information_schema.columns where table_schema='public' and table_name='documents'
    and column_name in('theme_id','theme_version','theme_snapshot')
  union all
  select 'stripe_price_mapping_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.subscription_provider_prices'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.subscription_provider_prices'::regclass),false)
  union all
  select 'stripe_webhook_events_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.stripe_webhook_events'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.stripe_webhook_events'::regclass),false)
  union all
  select 'stripe_webhook_event_primary_key',count(*)::text,count(*)=1
  from pg_constraint
  where conrelid='public.stripe_webhook_events'::regclass and contype='p'
  union all
  select 'stripe_checkout_claims_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.stripe_checkout_claims'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.stripe_checkout_claims'::regclass),false)
  union all
  select 'browser_plan_change_blocked',has_function_privilege('authenticated','public.choose_plan(uuid,text,text)','EXECUTE')::text,
    not has_function_privilege('authenticated','public.choose_plan(uuid,text,text)','EXECUTE')
  union all
  select 'subscription_billing_profile',count(*)::text,count(*)=9
  from information_schema.columns
  where table_schema='public' and table_name='subscriptions'
    and column_name in('billing_name','billing_email','billing_address_line1','billing_address_line2','billing_postal_code','billing_city','billing_country','billing_tax_id','billing_profile_updated_at')
  union all
  select 'company_billing_invoice_policy',count(*)::text,count(*)=1
  from pg_policies
  where schemaname='public' and tablename='platform_billing_invoices' and policyname='platform_billing_invoices_company_select'
  union all
  select 'platform_admin_context_rpc',coalesce(to_regprocedure('public.platform_admin_context()')::text,'missing'),
    to_regprocedure('public.platform_admin_context()') is not null
  union all
  select 'platform_admin_audit_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.platform_admin_audit_events'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.platform_admin_audit_events'::regclass),false)
  union all
  select 'platform_admin_audit_immutable',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.platform_admin_audit_events'::regclass
    and tgname='platform_admin_audit_immutable'
    and not tgisinternal
  union all
  select 'platform_admin_mfa_required',count(*)::text,count(*)=0
  from public.platform_admins
  where not mfa_required
  union all
  select 'platform_support_session_rpc',coalesce(to_regprocedure('public.platform_admin_start_support_session(uuid,text,text)')::text,'missing'),
    to_regprocedure('public.platform_admin_start_support_session(uuid,text,text)') is not null
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
  select 'progress_draft_completion_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.document_links'::regclass
    and tgname='complete_progress_draft_lines_after_link'
    and not tgisinternal
  union all
  select 'progress_invoice_zero_line_validator',
    (position('invoice-validator-v2-progress-lines' in pg_get_functiondef(to_regprocedure('public.validate_invoice_for_finalization(uuid)')))>0)::text,
    position('invoice-validator-v2-progress-lines' in pg_get_functiondef(to_regprocedure('public.validate_invoice_for_finalization(uuid)')))>0
  union all
  select 'invoice_progress_mode_rpc',coalesce(to_regprocedure('public.set_invoice_progress_mode(uuid,boolean)')::text,'missing'),
    to_regprocedure('public.set_invoice_progress_mode(uuid,boolean)') is not null
  union all
  select 'quote_draft_guard_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_00_force_new_quote_to_draft'
    and not tgisinternal
  union all
  select 'quote_conversion_guard_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_guard_invoice_created_from_quote'
    and not tgisinternal
  union all
  select 'operational_document_client_guard_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_guard_operational_client'
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
  'schema_version','202607250064',
  'checked_at',clock_timestamp(),
  'controls',jsonb_agg(jsonb_build_object('name',control,'value',value,'ok',ok) order by control)
) production_check from controls;
