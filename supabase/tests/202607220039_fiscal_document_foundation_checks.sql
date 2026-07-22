-- Contrôles structurels en lecture seule après la migration 202607220039.
select * from (values
  ('company_fiscal_configurations',to_regclass('public.company_fiscal_configurations') is not null),
  ('document_number_allocations',to_regclass('public.document_number_allocations') is not null),
  ('number_allocations_rls',(select relrowsecurity from pg_class where oid='public.document_number_allocations'::regclass)),
  ('fiscal_configuration_rls',(select relrowsecurity from pg_class where oid='public.company_fiscal_configurations'::regclass)),
  ('central_validator',to_regprocedure('public.validate_invoice_for_finalization(uuid)') is not null),
  ('central_mentions',to_regprocedure('public.resolve_required_invoice_mentions(uuid)') is not null),
  ('central_calculation',to_regprocedure('public.recalculate_document_amounts_v1(uuid)') is not null),
  ('anon_cannot_finalize',not has_function_privilege('anon','public.finalize_document(uuid)','execute')),
  ('authenticated_cannot_insert_allocation',not has_table_privilege('authenticated','public.document_number_allocations','insert')),
  ('authenticated_cannot_update_allocation',not has_table_privilege('authenticated','public.document_number_allocations','update')),
  ('authenticated_cannot_write_fiscal_config',not has_table_privilege('authenticated','public.company_fiscal_configurations','update'))
) checks(control_name,passed);

select 'numbered_documents_without_future_allocation' control_name,count(*) anomaly_count
from public.documents document
where document.number is not null
  and document.created_at>=(select min(created_at) from public.company_fiscal_configurations)
  and not exists(select 1 from public.document_number_allocations allocation where allocation.document_id=document.id);
