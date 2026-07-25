select * from (values
  ('quote_draft_trigger',exists(
    select 1 from pg_trigger where tgname='documents_00_force_new_quote_to_draft' and not tgisinternal
  )),
  ('conversion_guard_trigger',exists(
    select 1 from pg_trigger where tgname='documents_guard_invoice_created_from_quote' and not tgisinternal
  )),
  ('operational_client_guard_trigger',exists(
    select 1 from pg_trigger where tgname='documents_guard_operational_client' and not tgisinternal
  )),
  ('transition_rpc',to_regprocedure('public.transition_document_status(uuid,text)') is not null),
  ('authenticated_transition',has_function_privilege('authenticated','public.transition_document_status(uuid,text)','execute')),
  ('anon_cannot_transition',not has_function_privilege('anon','public.transition_document_status(uuid,text)','execute'))
) as checks(name,ok);
