-- Contrôle post-déploiement en lecture seule. Le résultat doit avoir ok=true.
with controls as(
  select 'latest_migration' control,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'missing') value,
    coalesce((select max(version)::text from supabase_migrations.schema_migrations),'')='202607310125' ok
  union all
  select 'outbound_einvoice_trigger_removed',count(*)::text,count(*)=0
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_queue_superpdp_after_finalization'
    and not tgisinternal
  union all
  select 'outbound_einvoice_jobs_inactive',count(*)::text,count(*)=0
  from public.superpdp_jobs
  where job_type='send_document'
    and status in('pending','retry_scheduled','processing')
  union all
  select 'company_access_system_roles',count(*)::text,count(*)=0
  from public.companies company
  where (select count(distinct role.system_key) from public.company_roles role
         where role.company_id=company.id and role.is_system and role.active
           and role.system_key in('administrator','user','commercial','accountant'))<>4
  union all
  select 'company_access_resolver_rpc',coalesce(to_regprocedure('public.resolve_company_permissions(uuid,uuid)')::text,'missing'),
    to_regprocedure('public.resolve_company_permissions(uuid,uuid)') is not null
  union all
  select 'company_access_context_rpc',coalesce(to_regprocedure('public.get_company_access_context(uuid)')::text,'missing'),
    to_regprocedure('public.get_company_access_context(uuid)') is not null
  union all
  select 'company_access_users_rpc',coalesce(to_regprocedure('public.list_company_access_users(uuid,text,text,uuid,text,text,text,integer,integer)')::text,'missing'),
    to_regprocedure('public.list_company_access_users(uuid,text,text,uuid,text,text,text,integer,integer)') is not null
  union all
  select 'client_primary_contact_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.clients'::regclass
    and tgname='clients_create_primary_contact_trigger'
    and not tgisinternal
  union all
  select 'client_identity_primary_contact',count(*)::text,count(*)=0
  from public.clients client
  where nullif(trim(client.first_name),'') is not null
    and nullif(trim(client.last_name),'') is not null
    and not exists(
      select 1 from public.client_contacts contact
      where contact.client_id=client.id and contact.is_primary
    )
  union all
  select 'accounting_customer_mode_default',count(*)::text,count(*)=0
  from public.accounting_settings where customer_account_mode<>'individualized'
  union all
  select 'accounting_customer_reconciliation_rpc',
    coalesce(to_regprocedure('public.reconcile_unexported_customer_account_lines(uuid)')::text,'missing'),
    to_regprocedure('public.reconcile_unexported_customer_account_lines(uuid)') is not null
      and not has_function_privilege('anon','public.reconcile_unexported_customer_account_lines(uuid)','EXECUTE')
      and not has_function_privilege('authenticated','public.reconcile_unexported_customer_account_lines(uuid)','EXECUTE')
  union all
  select 'accounting_auxiliary_length_max_10',count(*)::text,count(*)=0
  from public.accounting_settings where auxiliary_length not between 1 and 10
  union all
  select 'accounting_individual_accounts_persisted',count(*)::text,count(*)=0
  from public.clients client
  left join public.client_accounting_profiles profile
    on profile.company_id=client.company_id and profile.client_id=client.id and profile.active
  where profile.individual_account_code is null
     or profile.individual_account_code!~'^411[A-Z0-9]+$'
  union all
  select 'accounting_unexported_customer_collective',count(*)::text,count(*)=0
  from public.accounting_entry_lines line
  join public.accounting_entries entry on entry.id=line.entry_id
  join public.accounting_settings settings on settings.company_id=entry.company_id
  join public.clients client on client.id=line.third_party_id and client.company_id=entry.company_id
  where settings.customer_account_mode='individualized'
    and (line.account_code in('411','411000') or line.auxiliary_code is not null or line.auxiliary_label is not null)
    and not exists(
      select 1 from public.accounting_export_batch_entries exported
      join public.accounting_export_batches batch on batch.id=exported.export_batch_id
      where exported.accounting_entry_id=entry.id and batch.status='validated'
    )
  union all
  select 'company_invitation_accept_rpc',coalesce(to_regprocedure('public.accept_company_invitation(uuid)')::text,'missing'),
    to_regprocedure('public.accept_company_invitation(uuid)') is not null
  union all
  select 'company_access_rls_tables',count(*)::text,count(*)=3
  from pg_class
  where oid in('public.company_roles'::regclass,'public.company_invitations'::regclass,'public.company_access_audit'::regclass)
    and relrowsecurity
  union all
  select 'company_access_server_guards',count(*)::text,count(*)=3
  from pg_trigger
  where (tgrelid,tgname) in(
    ('public.documents'::regclass,'documents_enforce_central_permission'),
    ('public.document_lines'::regclass,'document_lines_enforce_central_permission'),
    ('public.payments'::regclass,'payments_enforce_central_permission')
  ) and not tgisinternal
  union all
  select 'crm_pipelines_rls',coalesce((select relrowsecurity::text from pg_class where oid=to_regclass('public.crm_pipelines')),'missing'),
    coalesce((select relrowsecurity from pg_class where oid=to_regclass('public.crm_pipelines')),false)
  union all
  select 'crm_pipeline_workspace_rpc',coalesce(to_regprocedure('public.get_crm_pipeline_workspace(uuid,text,jsonb,integer,integer)')::text,'missing'),
    to_regprocedure('public.get_crm_pipeline_workspace(uuid,text,jsonb,integer,integer)') is not null
  union all
  select 'crm_dashboard_command_center_rpc',coalesce(to_regprocedure('public.get_dashboard_command_center(text,date,date,text)')::text,'missing'),
    to_regprocedure('public.get_dashboard_command_center(text,date,date,text)') is not null
  union all
  select 'crm_activity_reschedule_rpc',coalesce(to_regprocedure('public.reschedule_crm_activity(uuid,timestamptz,uuid)')::text,'missing'),
    to_regprocedure('public.reschedule_crm_activity(uuid,timestamptz,uuid)') is not null
  union all
  select 'crm_party_picker_rpc',coalesce(to_regprocedure('public.get_crm_party_picker(text,integer,text)')::text,'missing'),
    to_regprocedure('public.get_crm_party_picker(text,integer,text)') is not null
  union all
  select 'crm_opportunity_v2_rpc',coalesce(to_regprocedure('public.save_crm_opportunity_v2(uuid,jsonb)')::text,'missing'),
    to_regprocedure('public.save_crm_opportunity_v2(uuid,jsonb)') is not null
  union all
  select 'crm_document_amount_rpc',coalesce(to_regprocedure('public.recalculate_crm_opportunity_amount(uuid)')::text,'missing'),
    to_regprocedure('public.recalculate_crm_opportunity_amount(uuid)') is not null
  union all
  select 'crm_rework_columns',count(*)::text,count(*)=7
  from information_schema.columns
  where table_schema='public' and (
    (table_name='opportunities' and column_name in('estimated_amount','documentary_amount','amount_source','origin_prospect_id','tags'))
    or (table_name='documents' and column_name in('crm_relation_type','crm_replaced_by_id'))
  )
  union all
  select 'crm_default_pipeline_stages',count(*)::text,count(*)=0
  from public.crm_pipelines pipeline
  where pipeline.is_default and pipeline.status<>'archived' and coalesce((
    select array_agg(stage.slug order by stage.position,stage.id)
    from public.pipeline_stages stage where stage.pipeline_id=pipeline.id and stage.active
  ),'{}'::text[])<>array['new','to_qualify','qualified','meeting','need_identified','quote_preparation','quote_sent','won','lost']::text[]
  union all
  select 'crm_saved_view_rpc',coalesce(to_regprocedure('public.save_crm_view(uuid,text,text,jsonb,jsonb,jsonb,boolean,boolean)')::text,'missing'),
    to_regprocedure('public.save_crm_view(uuid,text,text,jsonb,jsonb,jsonb,boolean,boolean)') is not null
  union all
  select 'crm_mail_treatment_rpc',coalesce(to_regprocedure('public.update_crm_mail_link(uuid,jsonb)')::text,'missing'),
    to_regprocedure('public.update_crm_mail_link(uuid,jsonb)') is not null
  union all
  select 'crm_automation_retry_rpc',coalesce(to_regprocedure('public.retry_crm_automation_run(uuid)')::text,'missing'),
    to_regprocedure('public.retry_crm_automation_run(uuid)') is not null
      and not has_function_privilege('anon','public.retry_crm_automation_run(uuid)','EXECUTE')
  union all
  select 'crm_mail_metadata_columns',count(*)::text,count(*)=4
  from information_schema.columns where table_schema='public' and table_name='external_mail_links'
    and column_name in('sender','preview','treatment_status','assigned_user_id')
  union all
  select 'crm_granular_write_policy',count(*)::text,count(*)=1
  from pg_policies where schemaname='public' and tablename='crm_notes' and policyname='crm_notes_insert'
    and coalesce(with_check,'') like '%manage_opportunity%'
  union all
  select 'invoice_legal_validator',coalesce(to_regprocedure('public.validate_invoice_for_finalization(uuid)')::text,'missing'),
    to_regprocedure('public.validate_invoice_for_finalization(uuid)') is not null
      and position('invoice-validator-v3-fr-2026' in pg_get_functiondef(to_regprocedure('public.validate_invoice_for_finalization(uuid)')))>0
  union all
  select 'document_audit_trail_rpc',coalesce(to_regprocedure('public.get_document_audit_trail(uuid)')::text,'missing'),
    to_regprocedure('public.get_document_audit_trail(uuid)') is not null
  union all
  select 'invoice_legal_retention_columns',count(*)::text,count(*)=2
  from information_schema.columns where table_schema='public' and table_name='documents'
    and column_name in('legal_validation_report','legal_retention_until')
  union all
  select 'personal_data_breaches_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.personal_data_breaches'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.personal_data_breaches'::regclass),false)
  union all
  select 'data_processing_agreements_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.data_processing_agreements'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.data_processing_agreements'::regclass),false)
  union all
  select 'einvoice_readiness_rpc',coalesce(to_regprocedure('public.get_einvoice_readiness(uuid)')::text,'missing'),
    to_regprocedure('public.get_einvoice_readiness(uuid)') is not null
  union all
  select 'next_progress_draft_rpc',coalesce(to_regprocedure('public.create_next_progress_invoice_draft(uuid)')::text,'missing'),
    to_regprocedure('public.create_next_progress_invoice_draft(uuid)') is not null
  union all
  select 'deposit_deduction_rpc',coalesce(to_regprocedure('public._piloz_document_deposit_deduction(uuid,jsonb,numeric,numeric,numeric)')::text,'missing'),
    to_regprocedure('public._piloz_document_deposit_deduction(uuid,jsonb,numeric,numeric,numeric)') is not null
  union all
  select 'template_terms_column',count(*)::text,count(*)=1
  from information_schema.columns where table_schema='public' and table_name='document_template_versions'
    and column_name='terms_conditions'
  union all
  select 'deposit_calculation_version',
    (position('financial-v2-deposit-deduction' in pg_get_functiondef(to_regprocedure('public.finalize_document(uuid)')))>0)::text,
    position('financial-v2-deposit-deduction' in pg_get_functiondef(to_regprocedure('public.finalize_document(uuid)')))>0
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
    (position('progress_placeholder' in pg_get_functiondef(to_regprocedure('public.validate_invoice_for_finalization(uuid)')))>0)::text,
    position('progress_placeholder' in pg_get_functiondef(to_regprocedure('public.validate_invoice_for_finalization(uuid)')))>0
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
  select 'stripe_onboarding_grants_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.stripe_onboarding_grants'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.stripe_onboarding_grants'::regclass),false)
  union all
  select 'external_connections_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.external_connections'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.external_connections'::regclass),false)
  union all
  select 'oauth_secrets_blocked_from_browser',has_table_privilege('authenticated','public.external_connection_secrets','SELECT')::text,
    not has_table_privilege('authenticated','public.external_connection_secrets','SELECT')
  union all
  select 'sales_terms_snapshot_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_snapshot_sales_terms'
    and not tgisinternal
  union all
  select 'accounting_entries_rls',coalesce((select relrowsecurity::text from pg_class where oid='public.accounting_entries'::regclass),'missing'),
    coalesce((select relrowsecurity from pg_class where oid='public.accounting_entries'::regclass),false)
  union all
  select 'accounting_document_trigger',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.documents'::regclass
    and tgname='documents_generate_accounting'
    and not tgisinternal
  union all
  select 'accounting_export_rpc',coalesce(to_regprocedure('public.validate_accounting_export(uuid,text,date,date,text,boolean,boolean,text)')::text,'missing'),
    to_regprocedure('public.validate_accounting_export(uuid,text,date,date,text,boolean,boolean,text)') is not null
  union all
  select 'accounting_export_diagnostics_rpc',coalesce(to_regprocedure('public.diagnose_accounting_export(uuid,text,date,date)')::text,'missing'),
    to_regprocedure('public.diagnose_accounting_export(uuid,text,date,date)') is not null
  union all
  select 'accounting_export_backfill_rpc',coalesce(to_regprocedure('public.backfill_company_accounting_entries(uuid)')::text,'missing'),
    to_regprocedure('public.backfill_company_accounting_entries(uuid)') is not null
  union all
  select 'accounting_fiscal_maintenance_rpc',coalesce(to_regprocedure('public.run_accounting_fiscal_maintenance(timestamptz)')::text,'missing'),
    to_regprocedure('public.run_accounting_fiscal_maintenance(timestamptz)') is not null
      and not has_function_privilege('anon','public.run_accounting_fiscal_maintenance(timestamptz)','EXECUTE')
      and not has_function_privilege('authenticated','public.run_accounting_fiscal_maintenance(timestamptz)','EXECUTE')
  union all
  select 'accounting_close_fiscal_year_rpc',coalesce(to_regprocedure('public.close_accounting_fiscal_year(uuid)')::text,'missing'),
    to_regprocedure('public.close_accounting_fiscal_year(uuid)') is not null
  union all
  select 'proprietary_export_adapters_disabled',count(*)::text,count(*)=0
  from public.accounting_export_adapters
  where adapter_group='proprietary' and availability='available'
  union all
  select 'fiscal_archive_signatures_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.fiscal_archive_signatures')) signature_table
  union all
  select 'fiscal_archive_signature_rpc',
    coalesce(to_regprocedure('public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)')::text,'missing'),
    to_regprocedure('public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)') is not null
      and not has_function_privilege('anon','public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)','EXECUTE')
      and not has_function_privilege('authenticated','public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)','EXECUTE')
      and has_function_privilege('service_role','public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)','EXECUTE')
  union all
  select 'production_without_kms',count(*)::text,count(*)=0
  from public.company_fiscal_configurations
  where mode='production' and activation_status='production_active'
    and (signing_status<>'configured' or kms_key_id is null)
  union all
  select 'superpdp_sandbox_connector_rpc',
    coalesce(to_regprocedure('public.configure_superpdp_sandbox_connector(uuid,jsonb)')::text,'missing'),
    to_regprocedure('public.configure_superpdp_sandbox_connector(uuid,jsonb)') is not null
  union all
  select 'superpdp_sandbox_audit_rpc',
    coalesce(to_regprocedure('public.record_superpdp_sandbox_test_transmission(uuid,text,text)')::text,'missing'),
    to_regprocedure('public.record_superpdp_sandbox_test_transmission(uuid,text,text)') is not null
  union all
  select 'superpdp_production_authorizations_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.superpdp_company_authorizations')) authorization_table
  union all
  select 'superpdp_production_tokens_blocked_from_browser',
    has_table_privilege('authenticated','public.superpdp_company_authorizations','SELECT')::text,
    not has_table_privilege('authenticated','public.superpdp_company_authorizations','SELECT')
      and not has_table_privilege('anon','public.superpdp_company_authorizations','SELECT')
  union all
  select 'superpdp_oauth_states_blocked_from_browser',
    has_table_privilege('authenticated','public.superpdp_oauth_states','SELECT')::text,
    not has_table_privilege('authenticated','public.superpdp_oauth_states','SELECT')
      and not has_table_privilege('anon','public.superpdp_oauth_states','SELECT')
  union all
  select 'superpdp_production_jobs_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.superpdp_jobs')) jobs_table
  union all
  select 'superpdp_production_jobs_blocked_from_browser',
    has_table_privilege('authenticated','public.superpdp_jobs','SELECT')::text,
    not has_table_privilege('authenticated','public.superpdp_jobs','SELECT')
      and not has_table_privilege('anon','public.superpdp_jobs','SELECT')
  union all
  select 'superpdp_connection_status_rpc',coalesce(to_regprocedure('public.get_superpdp_connection_status(uuid)')::text,'missing'),
    to_regprocedure('public.get_superpdp_connection_status(uuid)') is not null
  union all
  select 'superpdp_worker_enqueue_rpc',coalesce(to_regprocedure('public.enqueue_superpdp_recurring_jobs(timestamp with time zone)')::text,'missing'),
    to_regprocedure('public.enqueue_superpdp_recurring_jobs(timestamp with time zone)') is not null
      and not has_function_privilege('anon','public.enqueue_superpdp_recurring_jobs(timestamp with time zone)','EXECUTE')
      and not has_function_privilege('authenticated','public.enqueue_superpdp_recurring_jobs(timestamp with time zone)','EXECUTE')
  union all
  select 'superpdp_finalization_queue_trigger',count(*)::text,count(*)=1
  from pg_trigger where tgrelid='public.documents'::regclass and tgname='documents_queue_superpdp_after_finalization' and not tgisinternal
  union all
  select 'superpdp_invoice_exchanges_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.superpdp_invoice_exchanges')) exchange_table
  union all
  select 'superpdp_invoice_events_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.superpdp_invoice_events')) event_table
  union all
  select 'superpdp_exchange_environment_valid',count(*)::text,count(*)=0
  from public.superpdp_invoice_exchanges where environment not in('sandbox','production')
  union all
  select 'knowledge_articles_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.knowledge_articles')) knowledge_table
  union all
  select 'support_tickets_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.support_tickets')) support_table
  union all
  select 'support_attachments_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.support_ticket_attachments')) support_attachment_table
  union all
  select 'knowledge_attachments_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.knowledge_article_attachments')) knowledge_attachment_table
  union all
  select 'pilo_documentation_search_rpc',
    coalesce(to_regprocedure('public.search_piloz_documentation(text,uuid,jsonb,integer)')::text,'missing'),
    to_regprocedure('public.search_piloz_documentation(text,uuid,jsonb,integer)') is not null
      and not has_function_privilege('anon','public.search_piloz_documentation(text,uuid,jsonb,integer)','EXECUTE')
      and has_function_privilege('authenticated','public.search_piloz_documentation(text,uuid,jsonb,integer)','EXECUTE')
  union all
  select 'support_ticket_creation_rpc',
    coalesce(to_regprocedure('public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text,jsonb,uuid)')::text,'missing'),
    to_regprocedure('public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text,jsonb,uuid)') is not null
      and not has_function_privilege('anon','public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text,jsonb,uuid)','EXECUTE')
      and has_function_privilege('authenticated','public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text,jsonb,uuid)','EXECUTE')
  union all
  select 'activities_workspace_rpc',
    coalesce(to_regprocedure('public.get_activity_workspace_v3(text,text,text,text[],uuid[],uuid,uuid,timestamp with time zone,timestamp with time zone,boolean,integer,integer)')::text,'missing'),
    to_regprocedure('public.get_activity_workspace_v3(text,text,text,text[],uuid[],uuid,uuid,timestamp with time zone,timestamp with time zone,boolean,integer,integer)') is not null
  union all
  select 'activities_detail_rpc',
    coalesce(to_regprocedure('public.get_activity_detail(uuid)')::text,'missing'),
    to_regprocedure('public.get_activity_detail(uuid)') is not null
  union all
  select 'activities_complete_rpc',
    coalesce(to_regprocedure('public.complete_activity_workspace(uuid,uuid,text,integer,jsonb)')::text,'missing'),
    to_regprocedure('public.complete_activity_workspace(uuid,uuid,text,integer,jsonb)') is not null
  union all
  select 'activities_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.activities')) activities_table
  union all
  select 'activity_events_rls',coalesce(relrowsecurity::text,'missing'),coalesce(relrowsecurity,false)
  from (select relrowsecurity from pg_class where oid=to_regclass('public.activity_events')) activity_events_table
  union all
  select 'activity_events_immutable_permissions',
    concat_ws(',',has_table_privilege('authenticated','public.activity_events','INSERT'),has_table_privilege('authenticated','public.activity_events','UPDATE'),has_table_privilege('authenticated','public.activity_events','DELETE')),
    not has_table_privilege('authenticated','public.activity_events','INSERT')
      and not has_table_privilege('authenticated','public.activity_events','UPDATE')
      and not has_table_privilege('authenticated','public.activity_events','DELETE')
  union all
  select 'activities_physical_delete_blocked',count(*)::text,count(*)=1
  from pg_trigger
  where tgrelid='public.activities'::regclass
    and tgname='activities_prevent_physical_delete'
    and not tgisinternal
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
  'schema_version','202607310125',
  'checked_at',clock_timestamp(),
  'controls',jsonb_agg(jsonb_build_object('name',control,'value',value,'ok',ok) order by control)
) production_check from controls;
