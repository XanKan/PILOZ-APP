-- Contrôles en lecture seule à exécuter après 202607210014_document_lifecycle.sql.
-- La requête doit retourner uniquement des lignes avec ok = true.

with checks(check_name,ok) as(values
  ('documents.draft_number',exists(select 1 from information_schema.columns where table_schema='public' and table_name='documents' and column_name='draft_number')),
  ('documents.pipeline_stage',exists(select 1 from information_schema.columns where table_schema='public' and table_name='documents' and column_name='pipeline_stage')),
  ('documents.finalized_at',exists(select 1 from information_schema.columns where table_schema='public' and table_name='documents' and column_name='finalized_at')),
  ('document_snapshots',to_regclass('public.document_snapshots') is not null),
  ('document_pdf_jobs',to_regclass('public.document_pdf_jobs') is not null),
  ('document_links',to_regclass('public.document_links') is not null),
  ('document_comments',to_regclass('public.document_comments') is not null),
  ('payment_methods',to_regclass('public.payment_methods') is not null),
  ('payment_terms',to_regclass('public.payment_terms') is not null),
  ('pipeline_items',to_regclass('public.pipeline_items') is not null),
  ('document_pipeline_view',to_regclass('public.document_pipeline_view') is not null),
  ('save_document_draft',to_regprocedure('public.save_document_draft(uuid,jsonb,jsonb)') is not null),
  ('finalize_document',to_regprocedure('public.finalize_document(uuid)') is not null),
  ('transition_document_status',to_regprocedure('public.transition_document_status(uuid,text)') is not null),
  ('convert_quote_to_invoice',to_regprocedure('public.convert_quote_to_invoice(uuid,text)') is not null),
  ('create_deposit_invoice',to_regprocedure('public.create_deposit_invoice(uuid,numeric,numeric)') is not null),
  ('create_progress_invoice',to_regprocedure('public.create_progress_invoice(uuid,jsonb)') is not null),
  ('create_balance_invoice',to_regprocedure('public.create_balance_invoice(uuid)') is not null),
  ('create_credit_note',to_regprocedure('public.create_credit_note(uuid,text,jsonb)') is not null),
  ('record_document_payment_v2',to_regprocedure('public.record_document_payment_v2(uuid,numeric,text,text,timestamp with time zone,text)') is not null),
  ('save_document_comment',to_regprocedure('public.save_document_comment(uuid,text,uuid[])') is not null),
  ('update_document_comment',to_regprocedure('public.update_document_comment(uuid,text,uuid[])') is not null),
  ('delete_document_comment',to_regprocedure('public.delete_document_comment(uuid)') is not null),
  ('snapshots_rls',(select relrowsecurity from pg_class where oid='public.document_snapshots'::regclass)),
  ('links_rls',(select relrowsecurity from pg_class where oid='public.document_links'::regclass)),
  ('comments_rls',(select relrowsecurity from pg_class where oid='public.document_comments'::regclass)),
  ('payment_methods_rls',(select relrowsecurity from pg_class where oid='public.payment_methods'::regclass)),
  ('payment_terms_rls',(select relrowsecurity from pg_class where oid='public.payment_terms'::regclass)),
  ('authenticated_finalize',has_function_privilege('authenticated','public.finalize_document(uuid)','execute')),
  ('anon_cannot_finalize',not has_function_privilege('anon','public.finalize_document(uuid)','execute')),
  ('authenticated_cannot_write_sequence',not has_table_privilege('authenticated','public.document_sequences','insert')),
  ('authenticated_cannot_insert_payment',not has_table_privilege('authenticated','public.payments','insert')),
  ('document_line_tenant_fk',exists(select 1 from pg_constraint where conname='document_lines_document_company_fk')),
  ('payment_tenant_fk',exists(select 1 from pg_constraint where conname='payments_document_company_fk'))
)
select check_name,ok from checks order by check_name;

-- Ces cinq requêtes doivent chacune retourner zéro.
select 'cross_company_document_lines' anomaly,count(*) anomaly_count
from public.document_lines line join public.documents document on document.id=line.document_id
where line.company_id<>document.company_id
union all
select 'cross_company_payments',count(*)
from public.payments payment join public.documents document on document.id=payment.document_id
where payment.company_id<>document.company_id
union all
select 'finalized_without_number',count(*) from public.documents
where finalized_at is not null and number is null
union all
select 'finalized_without_lock',count(*) from public.documents
where finalized_at is not null and locked_at is null
union all
select 'ready_pdf_without_path',count(*) from public.documents
where pdf_status='ready' and final_pdf_path is null;
