-- Durcit l'intégrité des PDF finaux et uniformise l'ordre des verrous.
-- Migration additive : aucune donnée ni aucun objet Storage existant n'est supprimé.
begin;

-- Les pièces jointes ordinaires restent gérées par les membres autorisés, mais
-- le préfixe réservé aux PDF finaux n'est modifiable que par service_role, qui
-- contourne les politiques RLS depuis l'Edge Function.
drop policy if exists company_files_insert on storage.objects;
drop policy if exists company_files_update on storage.objects;
drop policy if exists company_files_delete on storage.objects;
create policy company_files_insert on storage.objects for insert to authenticated with check(
  bucket_id='company-files'
  and coalesce((storage.foldername(name))[2],'')<>'documents'
  and (
    public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
    or public.has_company_permission((storage.foldername(name))[1]::uuid,'adjust_stock')
  )
);
create policy company_files_update on storage.objects for update to authenticated using(
  bucket_id='company-files'
  and coalesce((storage.foldername(name))[2],'')<>'documents'
  and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
) with check(
  bucket_id='company-files'
  and coalesce((storage.foldername(name))[2],'')<>'documents'
  and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);
create policy company_files_delete on storage.objects for delete to authenticated using(
  bucket_id='company-files'
  and coalesce((storage.foldername(name))[2],'')<>'documents'
  and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);

-- Un logo remplacé est désactivé en base mais son objet historique reste
-- immuable afin qu'un instantané puisse encore produire exactement son PDF.
drop policy if exists company_assets_update on storage.objects;
drop policy if exists company_assets_delete on storage.objects;
create policy company_assets_update on storage.objects for update to authenticated using(
  bucket_id='company-assets'
  and coalesce((storage.foldername(name))[2],'')<>'logos'
  and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
) with check(
  bucket_id='company-assets'
  and coalesce((storage.foldername(name))[2],'')<>'logos'
  and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);
create policy company_assets_delete on storage.objects for delete to authenticated using(
  bucket_id='company-assets'
  and coalesce((storage.foldername(name))[2],'')<>'logos'
  and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);

-- Toutes les opérations concurrentes prennent désormais les verrous dans le
-- même ordre : document -> instantané -> tâche PDF.
create or replace function public.complete_document_pdf_job(
  target_job_id uuid,target_claim_token uuid,target_storage_path text,target_sha256 text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  job_hint public.document_pdf_jobs%rowtype; job public.document_pdf_jobs%rowtype;
  doc public.documents%rowtype; snapshot public.document_snapshots%rowtype; expected_path text;
  normalized_hash text:=lower(trim(coalesce(target_sha256,'')));
begin
  select * into job_hint from public.document_pdf_jobs where id=target_job_id;
  if job_hint.id is null then raise exception 'pdf_job_not_found' using errcode='P0002'; end if;
  select * into doc from public.documents
  where id=job_hint.document_id and company_id=job_hint.company_id
    and snapshot_id=job_hint.snapshot_id and finalized_at is not null for update;
  select * into snapshot from public.document_snapshots
  where id=job_hint.snapshot_id and company_id=job_hint.company_id
    and document_id=job_hint.document_id for update;
  select * into job from public.document_pdf_jobs where id=target_job_id for update;
  if doc.id is null or snapshot.id is null or job.id is null
     or job.company_id is distinct from job_hint.company_id
     or job.document_id is distinct from job_hint.document_id
     or job.snapshot_id is distinct from job_hint.snapshot_id then
    raise exception 'pdf_job_snapshot_mismatch' using errcode='55000';
  end if;

  expected_path:=job.company_id::text||'/documents/'||job.document_id::text||'/'||job.snapshot_id::text||'.pdf';
  if trim(coalesce(target_storage_path,''))<>expected_path then raise exception 'invalid_pdf_storage_path' using errcode='22023'; end if;
  if normalized_hash!~'^[0-9a-f]{64}$' then raise exception 'invalid_pdf_sha256' using errcode='22023'; end if;
  if job.status='completed' then
    if snapshot.pdf_storage_path=expected_path and snapshot.pdf_sha256=normalized_hash
       and doc.final_pdf_path=expected_path and doc.final_pdf_sha256=normalized_hash then
      return jsonb_build_object('completed',true,'idempotent',true,'job_id',job.id,
        'snapshot_id',snapshot.id,'path',expected_path,'sha256',normalized_hash);
    end if;
    raise exception 'pdf_completion_conflict' using errcode='55000';
  end if;
  if job.status<>'processing' or job.claim_token is distinct from target_claim_token or job.claimed_by is null then
    raise exception 'invalid_pdf_job_claim' using errcode='42501';
  end if;
  if not exists(select 1 from storage.objects where bucket_id='company-files' and name=expected_path) then
    raise exception 'pdf_storage_object_missing' using errcode='P0002';
  end if;

  update public.document_snapshots set pdf_storage_path=expected_path,pdf_sha256=normalized_hash,
    pdf_status='ready',pdf_generated_at=now()
  where id=job.snapshot_id and company_id=job.company_id and document_id=job.document_id;
  if not found then raise exception 'pdf_snapshot_update_failed' using errcode='55000'; end if;
  update public.documents set final_pdf_path=expected_path,final_pdf_sha256=normalized_hash,
    final_pdf_generated_at=now(),pdf_status='ready',updated_at=now()
  where id=job.document_id and company_id=job.company_id and snapshot_id=job.snapshot_id;
  if not found then raise exception 'pdf_document_update_failed' using errcode='55000'; end if;
  update public.document_pdf_jobs set status='completed',last_error_code=null,completed_at=now(),
    available_at=now(),claim_token=null,lease_expires_at=null,updated_at=now()
  where id=job.id and status='processing' and claim_token=target_claim_token;
  if not found then raise exception 'pdf_job_completion_race' using errcode='40001'; end if;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(job.company_id,job.claimed_by,'document.pdf.generated','document',job.document_id,
    jsonb_build_object('snapshot_id',snapshot.id,'sha256',normalized_hash),job.claimed_by);
  return jsonb_build_object('completed',true,'idempotent',false,'job_id',job.id,
    'snapshot_id',snapshot.id,'document_id',doc.id,'path',expected_path,'sha256',normalized_hash);
end
$$;

create or replace function public.fail_document_pdf_job(
  target_job_id uuid,target_claim_token uuid,target_error_code text,target_retry_after_seconds integer default 60
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  job_hint public.document_pdf_jobs%rowtype; job public.document_pdf_jobs%rowtype;
  doc public.documents%rowtype; snapshot public.document_snapshots%rowtype;
  retry_seconds integer:=least(3600,greatest(30,coalesce(target_retry_after_seconds,60)));
  retry_at timestamptz;
  safe_error text:=left(regexp_replace(lower(coalesce(nullif(trim(target_error_code),''),'pdf_generation_failed')),
    '[^a-z0-9_.:-]+','_','g'),120);
begin
  select * into job_hint from public.document_pdf_jobs where id=target_job_id;
  if job_hint.id is null then raise exception 'pdf_job_not_found' using errcode='P0002'; end if;
  select * into doc from public.documents
  where id=job_hint.document_id and company_id=job_hint.company_id
    and snapshot_id=job_hint.snapshot_id and finalized_at is not null for update;
  select * into snapshot from public.document_snapshots
  where id=job_hint.snapshot_id and company_id=job_hint.company_id
    and document_id=job_hint.document_id for update;
  select * into job from public.document_pdf_jobs where id=target_job_id for update;
  if doc.id is null or snapshot.id is null or job.id is null
     or job.company_id is distinct from job_hint.company_id
     or job.document_id is distinct from job_hint.document_id
     or job.snapshot_id is distinct from job_hint.snapshot_id then
    raise exception 'pdf_job_snapshot_mismatch' using errcode='55000';
  end if;
  if job.status='failed' and job.claim_token is null then
    return jsonb_build_object('failed',true,'idempotent',true,'job_id',job.id,
      'attempts',job.attempts,'retry_at',job.available_at);
  end if;
  if job.status<>'processing' or job.claim_token is distinct from target_claim_token or job.claimed_by is null then
    raise exception 'invalid_pdf_job_claim' using errcode='42501';
  end if;
  retry_at:=now()+make_interval(secs=>retry_seconds);
  update public.document_snapshots set pdf_status='error',pdf_storage_path=null,
    pdf_sha256=null,pdf_generated_at=null where id=job.snapshot_id and company_id=job.company_id;
  update public.documents set pdf_status='error',final_pdf_path=null,final_pdf_sha256=null,
    final_pdf_generated_at=null,updated_at=now() where id=job.document_id and company_id=job.company_id;
  update public.document_pdf_jobs set status='failed',last_error_code=safe_error,
    available_at=retry_at,completed_at=now(),claim_token=null,lease_expires_at=null,updated_at=now()
  where id=job.id and status='processing' and claim_token=target_claim_token;
  if not found then raise exception 'pdf_job_failure_race' using errcode='40001'; end if;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(job.company_id,job.claimed_by,'document.pdf.failed','document',job.document_id,
    jsonb_build_object('snapshot_id',snapshot.id,'error_code',safe_error,'attempt',job.attempts),job.claimed_by);
  return jsonb_build_object('failed',true,'idempotent',false,'job_id',job.id,
    'attempts',job.attempts,'error_code',safe_error,'retry_at',retry_at);
end
$$;

revoke all on function public.complete_document_pdf_job(uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.fail_document_pdf_job(uuid,uuid,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.complete_document_pdf_job(uuid,uuid,text,text) to service_role;
grant execute on function public.fail_document_pdf_job(uuid,uuid,text,integer) to service_role;
select pg_notify('pgrst','reload schema');
commit;
