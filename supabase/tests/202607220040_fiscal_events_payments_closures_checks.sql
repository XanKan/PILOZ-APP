select * from (values
  ('fiscal_events',to_regclass('public.fiscal_events') is not null),
  ('fiscal_event_heads',to_regclass('public.fiscal_event_heads') is not null),
  ('fiscal_closures',to_regclass('public.fiscal_closures') is not null),
  ('fiscal_events_rls',(select relrowsecurity from pg_class where oid='public.fiscal_events'::regclass)),
  ('fiscal_closures_rls',(select relrowsecurity from pg_class where oid='public.fiscal_closures'::regclass)),
  ('chain_verifier',to_regprocedure('public.verify_fiscal_event_chain(uuid)') is not null),
  ('closure_generator',to_regprocedure('public.generate_fiscal_closure(uuid,text,timestamp with time zone,timestamp with time zone)') is not null),
  ('anon_cannot_verify',not has_function_privilege('anon','public.verify_fiscal_event_chain(uuid)','execute')),
  ('authenticated_cannot_insert_event',not has_table_privilege('authenticated','public.fiscal_events','insert')),
  ('authenticated_cannot_update_event',not has_table_privilege('authenticated','public.fiscal_events','update')),
  ('authenticated_cannot_delete_event',not has_table_privilege('authenticated','public.fiscal_events','delete')),
  ('authenticated_cannot_insert_closure',not has_table_privilege('authenticated','public.fiscal_closures','insert'))
) checks(control_name,passed);

select 'cross_company_fiscal_events',count(*) anomaly_count from public.fiscal_events event
left join public.companies company on company.id=event.company_id where company.id is null;
select 'broken_event_head',count(*) anomaly_count from public.fiscal_event_heads head
where head.last_sequence_number<>(select coalesce(max(sequence_number),0) from public.fiscal_events event where event.company_id=head.company_id)
   or head.last_event_hash is distinct from(select event_hash from public.fiscal_events event where event.company_id=head.company_id order by sequence_number desc limit 1);
