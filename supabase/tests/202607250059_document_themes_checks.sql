-- Contrôles structurels en lecture seule après la migration 202607250059.
select * from (values
  ('theme_assignments',to_regclass('public.document_theme_assignments') is not null),
  ('theme_assets',to_regclass('public.document_theme_assets') is not null),
  ('theme_links',to_regclass('public.document_theme_links') is not null),
  ('theme_footer_logos',to_regclass('public.document_theme_footer_logos') is not null),
  ('theme_usage',to_regclass('public.document_theme_usage') is not null),
  ('theme_preferences',to_regclass('public.document_theme_user_preferences') is not null),
  ('assignments_rls',(select relrowsecurity from pg_class where oid='public.document_theme_assignments'::regclass)),
  ('assets_rls',(select relrowsecurity from pg_class where oid='public.document_theme_assets'::regclass)),
  ('links_rls',(select relrowsecurity from pg_class where oid='public.document_theme_links'::regclass)),
  ('usage_rls',(select relrowsecurity from pg_class where oid='public.document_theme_usage'::regclass)),
  ('theme_create_rpc',to_regprocedure('public.create_document_theme(uuid,uuid)') is not null),
  ('theme_save_rpc',to_regprocedure('public.save_document_theme(uuid,text,jsonb,jsonb)') is not null),
  ('theme_assign_rpc',to_regprocedure('public.assign_document_theme(uuid,text)') is not null),
  ('anon_cannot_save_theme',not has_function_privilege('anon','public.save_document_theme(uuid,text,jsonb,jsonb)','execute')),
  ('document_theme_columns',(select count(*)=3 from information_schema.columns where table_schema='public' and table_name='documents' and column_name in('theme_id','theme_version','theme_snapshot'))),
  ('configuration_columns',(select count(*)=4 from information_schema.columns where table_schema='public' and table_name='document_template_versions' and column_name in('configuration_json','renderer_version','configuration_checksum','parent_version_id')))
) checks(control_name,passed);

select 'finalized_documents_with_mutable_theme_reference' control_name,count(*) anomaly_count
from public.documents document
where document.finalized_at is not null and document.theme_id is not null
  and (document.theme_version is null or document.theme_snapshot is null);

select 'theme_usage_without_version' control_name,count(*) anomaly_count
from public.document_theme_usage usage
left join public.document_template_versions version
  on version.template_id=usage.theme_id and version.version=usage.theme_version
where version.id is null;
