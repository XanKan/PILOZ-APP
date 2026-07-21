-- Contrôles en lecture seule à exécuter après 202607210015_document_pdf_jobs.sql.
with checks(check_name,ok) as(values
  ('claim_document_pdf_job',to_regprocedure('public.claim_document_pdf_job(uuid,integer)') is not null),
  ('complete_document_pdf_job',to_regprocedure('public.complete_document_pdf_job(uuid,uuid,text,text)') is not null),
  ('fail_document_pdf_job',to_regprocedure('public.fail_document_pdf_job(uuid,uuid,text,integer)') is not null),
  ('authenticated_can_claim',has_function_privilege('authenticated','public.claim_document_pdf_job(uuid,integer)','execute')),
  ('authenticated_cannot_complete',not has_function_privilege('authenticated','public.complete_document_pdf_job(uuid,uuid,text,text)','execute')),
  ('authenticated_cannot_fail',not has_function_privilege('authenticated','public.fail_document_pdf_job(uuid,uuid,text,integer)','execute')),
  ('service_can_complete',has_function_privilege('service_role','public.complete_document_pdf_job(uuid,uuid,text,text)','execute')),
  ('service_can_fail',has_function_privilege('service_role','public.fail_document_pdf_job(uuid,uuid,text,integer)','execute')),
  ('anon_cannot_claim',not has_function_privilege('anon','public.claim_document_pdf_job(uuid,integer)','execute')),
  ('legacy_attach_revoked',not has_function_privilege('authenticated','public.attach_document_final_pdf(uuid,text,text)','execute')),
  ('authenticated_cannot_insert_jobs',not has_table_privilege('authenticated','public.document_pdf_jobs','insert')),
  ('authenticated_cannot_update_jobs',not has_table_privilege('authenticated','public.document_pdf_jobs','update')),
  ('authenticated_cannot_delete_jobs',not has_table_privilege('authenticated','public.document_pdf_jobs','delete')),
  ('claim_token_is_private',not has_column_privilege('authenticated','public.document_pdf_jobs','claim_token','select')),
  ('final_pdf_insert_is_service_only',exists(
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname='company_files_insert' and coalesce(with_check,'') like '%documents%'
  )),
  ('final_pdf_update_is_service_only',exists(
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname='company_files_update' and coalesce(qual,'') like '%documents%'
  )),
  ('final_pdf_delete_is_service_only',exists(
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname='company_files_delete' and coalesce(qual,'') like '%documents%'
  )),
  ('historical_logos_are_immutable',exists(
    select 1 from pg_policies where schemaname='storage' and tablename='objects'
      and policyname='company_assets_delete' and coalesce(qual,'') like '%logos%'
  ))
)
select check_name,ok from checks order by check_name;

select 'completed_job_without_ready_snapshot' anomaly,count(*) anomaly_count
from public.document_pdf_jobs job
join public.document_snapshots snapshot on snapshot.id=job.snapshot_id
where job.status='completed' and (snapshot.pdf_status<>'ready' or snapshot.pdf_storage_path is null)
union all
select 'ready_document_without_matching_snapshot',count(*)
from public.documents document
left join public.document_snapshots snapshot on snapshot.id=document.snapshot_id and snapshot.document_id=document.id
where document.pdf_status='ready' and (
  snapshot.id is null or snapshot.pdf_status<>'ready' or snapshot.pdf_storage_path is distinct from document.final_pdf_path
);
