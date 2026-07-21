-- Contrôles en lecture seule à exécuter après 202607210018_immediate_document_numbering.sql.
-- La requête doit retourner uniquement des lignes avec ok = true.

with checks(check_name,ok) as(values
  ('documents.draft_number_removed',not exists(select 1 from information_schema.columns where table_schema='public' and table_name='documents' and column_name='draft_number')),
  ('assign_document_draft_number_removed',to_regprocedure('public.assign_document_draft_number()') is null),
  ('ensure_document_draft_number_removed',to_regprocedure('public.ensure_document_draft_number(uuid)') is null),
  ('assign_document_number',to_regprocedure('public.assign_document_number()') is not null),
  ('documents_assign_document_number_trigger',exists(select 1 from pg_trigger where tgname='documents_assign_document_number' and tgrelid='public.documents'::regclass)),
  ('save_document_draft',to_regprocedure('public.save_document_draft(uuid,jsonb,jsonb)') is not null),
  ('finalize_document',to_regprocedure('public.finalize_document(uuid)') is not null),
  ('transition_document_status',to_regprocedure('public.transition_document_status(uuid,text)') is not null),
  ('convert_quote_to_invoice',to_regprocedure('public.convert_quote_to_invoice(uuid,text)') is not null),
  ('create_deposit_invoice',to_regprocedure('public.create_deposit_invoice(uuid,numeric,numeric)') is not null),
  ('create_progress_invoice',to_regprocedure('public.create_progress_invoice(uuid,jsonb)') is not null),
  ('create_balance_invoice',to_regprocedure('public.create_balance_invoice(uuid)') is not null),
  ('create_credit_note',to_regprocedure('public.create_credit_note(uuid,text,jsonb)') is not null),
  ('document_pipeline_view',to_regclass('public.document_pipeline_view') is not null),
  ('authenticated_finalize',has_function_privilege('authenticated','public.finalize_document(uuid)','execute')),
  ('anon_cannot_finalize',not has_function_privilege('anon','public.finalize_document(uuid)','execute'))
)
select check_name,ok from checks order by check_name;

-- Cette requête doit retourner zéro : tout devis, facture, acompte, solde,
-- avoir ou pro forma doit désormais avoir son numéro officiel dès sa création.
select 'draft_document_without_number' anomaly,count(*) anomaly_count
from public.documents
where document_type in('quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice') and number is null;
