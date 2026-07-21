-- Génération des PDF finaux : instantané exact, bail atomique et stockage immuable.
-- Migration additive et idempotente. Aucun document ni fichier existant n'est supprimé.
begin;

alter table public.document_pdf_jobs
  add column if not exists claim_token uuid,
  add column if not exists claimed_by uuid,
  add column if not exists lease_expires_at timestamptz;

create index if not exists document_pdf_jobs_claim_idx
  on public.document_pdf_jobs(status,available_at,lease_expires_at)
  where status in('pending','failed','processing');

do $pdf_claim_constraint$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='document_pdf_jobs_claim_state_check'
      and conrelid='public.document_pdf_jobs'::regclass
  ) then
    alter table public.document_pdf_jobs add constraint document_pdf_jobs_claim_state_check check(
      (status='processing' and claim_token is not null and claimed_by is not null and lease_expires_at is not null)
      or (status<>'processing' and claim_token is null and lease_expires_at is null)
    ) not valid;
  end if;
end
$pdf_claim_constraint$;

-- Le logo public utilisé par un nouveau document finalisé est figé dans son
-- instantané. Les instantanés historiques restent strictement inchangés.
create or replace function public._piloz_create_document_snapshot(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype; issuer jsonb; document_settings jsonb; customer jsonb; company_logo jsonb;
  public_lines jsonb; internal_lines jsonb; template_payload jsonb;
  public_snapshot jsonb; internal_snapshot jsonb; snapshot_hash text;
  next_version integer; result_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.finalized_at is null then raise exception 'document_not_finalized'; end if;
  select to_jsonb(s) into issuer from public.company_settings s where s.company_id=doc.company_id;
  select to_jsonb(s) into document_settings from public.company_document_settings s where s.company_id=doc.company_id;
  select to_jsonb(c) into customer from public.clients c where c.id=doc.client_id and c.company_id=doc.company_id;
  select jsonb_build_object(
    'storage_path',logo.storage_path,'mime_type',logo.mime_type,'size_bytes',logo.size_bytes,
    'width',logo.width,'height',logo.height,'variant',logo.variant
  ) into company_logo
  from public.company_logos logo
  where logo.company_id=doc.company_id and logo.variant='light' and logo.is_active
  order by logo.created_at desc limit 1;
  select coalesce(jsonb_agg(
    to_jsonb(l)-array['unit_cost_snapshot','line_metadata','created_by','created_at','updated_at']::text[] order by l.position
  ),'[]'::jsonb),coalesce(jsonb_agg(to_jsonb(l) order by l.position),'[]'::jsonb)
  into public_lines,internal_lines from public.document_lines l where l.document_id=doc.id;
  select jsonb_build_object('template',to_jsonb(t),'version',to_jsonb(tv)) into template_payload
  from public.document_templates t
  left join public.document_template_versions tv on tv.template_id=t.id and tv.version=t.current_version
  where t.id=doc.template_id and t.company_id=doc.company_id;

  public_snapshot:=jsonb_build_object(
    'schema_version',2,'captured_at',now(),
    'document',to_jsonb(doc)-array['total_cost','internal_notes','final_pdf_path','final_pdf_sha256']::text[],
    'lines',public_lines,'issuer',coalesce(issuer,'{}'::jsonb),
    'document_settings',coalesce(document_settings,'{}'::jsonb)-'mandate_reference',
    'client',coalesce(customer,'{}'::jsonb),'logo',coalesce(company_logo,'{}'::jsonb),
    'template',coalesce(template_payload,'{}'::jsonb)
  );
  internal_snapshot:=jsonb_build_object(
    'schema_version',2,'captured_at',now(),'document',to_jsonb(doc),'lines',internal_lines,
    'issuer',coalesce(issuer,'{}'::jsonb),'document_settings',coalesce(document_settings,'{}'::jsonb),
    'client',coalesce(customer,'{}'::jsonb),'logo',coalesce(company_logo,'{}'::jsonb),
    'template',coalesce(template_payload,'{}'::jsonb)
  );
  snapshot_hash:=encode(extensions.digest(convert_to(public_snapshot::text,'UTF8'),'sha256'),'hex');
  select coalesce(max(snapshot_version),0)+1 into next_version
  from public.document_snapshots where document_id=doc.id;
  insert into public.document_snapshots(
    company_id,document_id,snapshot_version,snapshot_kind,public_payload,internal_payload,
    payload_hash,pdf_status,created_by
  ) values(
    doc.company_id,doc.id,next_version,'finalization',public_snapshot,internal_snapshot,
    snapshot_hash,'pending',coalesce(auth.uid(),doc.created_by)
  ) returning id into result_id;
  return result_id;
end
$$;

-- Le client authentifié ne peut obtenir qu'un bail court pour l'instantané
-- actuellement attaché au document. Le jeton n'est jamais exposé par SELECT.
create or replace function public.claim_document_pdf_job(
  target_document_id uuid,target_lease_seconds integer default 300
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  actor_id uuid:=auth.uid(); doc public.documents%rowtype; snapshot public.document_snapshots%rowtype;
  job public.document_pdf_jobs%rowtype; new_token uuid:=gen_random_uuid();
  lease_seconds integer:=least(900,greatest(60,coalesce(target_lease_seconds,300)));
  active_until timestamptz;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then
    raise exception 'document_not_found' using errcode='P0002';
  end if;
  if doc.finalized_at is null or doc.snapshot_id is null then raise exception 'document_not_finalized' using errcode='55000'; end if;
  select * into snapshot from public.document_snapshots
  where id=doc.snapshot_id and company_id=doc.company_id and document_id=doc.id for update;
  if snapshot.id is null then raise exception 'document_snapshot_mismatch' using errcode='55000'; end if;

  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by)
  values(doc.company_id,doc.id,snapshot.id,'pending',actor_id) on conflict(snapshot_id) do nothing;
  select * into job from public.document_pdf_jobs
  where snapshot_id=snapshot.id and company_id=doc.company_id and document_id=doc.id for update;
  if job.id is null then raise exception 'pdf_job_snapshot_mismatch' using errcode='55000'; end if;

  if job.status='completed' then
    if doc.pdf_status='ready' and snapshot.pdf_status='ready' and doc.final_pdf_path is not null
       and doc.final_pdf_path=snapshot.pdf_storage_path then
      return jsonb_build_object('claimed',false,'ready',true,'status','completed',
        'job_id',job.id,'snapshot_id',snapshot.id,'path',snapshot.pdf_storage_path,'sha256',snapshot.pdf_sha256);
    end if;
    raise exception 'pdf_job_state_inconsistent' using errcode='55000';
  end if;

  active_until:=coalesce(job.lease_expires_at,job.started_at+make_interval(secs=>lease_seconds),'-infinity'::timestamptz);
  if job.status='processing' and active_until>now() then
    return jsonb_build_object('claimed',false,'ready',false,'status','processing',
      'job_id',job.id,'snapshot_id',snapshot.id,'retry_at',active_until);
  end if;
  if job.status in('pending','failed') and job.available_at>now() then
    return jsonb_build_object('claimed',false,'ready',false,'status',job.status,
      'job_id',job.id,'snapshot_id',snapshot.id,'retry_at',job.available_at);
  end if;

  update public.document_pdf_jobs set status='processing',attempts=attempts+1,
    last_error_code=null,started_at=now(),completed_at=null,available_at=now(),
    claim_token=new_token,claimed_by=actor_id,
    lease_expires_at=now()+make_interval(secs=>lease_seconds),updated_at=now()
  where id=job.id returning * into job;
  update public.document_snapshots set pdf_status='pending',pdf_storage_path=null,
    pdf_sha256=null,pdf_generated_at=null where id=snapshot.id;
  update public.documents set pdf_status='pending',final_pdf_path=null,
    final_pdf_sha256=null,final_pdf_generated_at=null,updated_at=now() where id=doc.id;

  return jsonb_build_object('claimed',true,'ready',false,'status','processing',
    'job_id',job.id,'claim_token',new_token,'snapshot_id',snapshot.id,
    'document_id',doc.id,'company_id',doc.company_id,'lease_expires_at',job.lease_expires_at,
    'payload_hash',snapshot.payload_hash,'public_payload',snapshot.public_payload);
end
$$;

-- Seule l'Edge Function (service_role) peut terminer un bail. Le chemin est
-- déterministe, l'objet doit déjà exister dans le bucket privé et le SHA est figé.
create or replace function public.complete_document_pdf_job(
  target_job_id uuid,target_claim_token uuid,target_storage_path text,target_sha256 text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  job public.document_pdf_jobs%rowtype; doc public.documents%rowtype;
  snapshot public.document_snapshots%rowtype; expected_path text;
  normalized_hash text:=lower(trim(coalesce(target_sha256,'')));
begin
  select * into job from public.document_pdf_jobs where id=target_job_id for update;
  if job.id is null then raise exception 'pdf_job_not_found' using errcode='P0002'; end if;
  select * into doc from public.documents
  where id=job.document_id and company_id=job.company_id and snapshot_id=job.snapshot_id
    and finalized_at is not null for update;
  select * into snapshot from public.document_snapshots
  where id=job.snapshot_id and company_id=job.company_id and document_id=job.document_id for update;
  if doc.id is null or snapshot.id is null then raise exception 'pdf_job_snapshot_mismatch' using errcode='55000'; end if;
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
  job public.document_pdf_jobs%rowtype; doc public.documents%rowtype; snapshot public.document_snapshots%rowtype;
  retry_seconds integer:=least(3600,greatest(30,coalesce(target_retry_after_seconds,60)));
  retry_at timestamptz;
  safe_error text:=left(regexp_replace(lower(coalesce(nullif(trim(target_error_code),''),'pdf_generation_failed')),
    '[^a-z0-9_.:-]+','_','g'),120);
begin
  select * into job from public.document_pdf_jobs where id=target_job_id for update;
  if job.id is null then raise exception 'pdf_job_not_found' using errcode='P0002'; end if;
  if job.status='failed' and job.claim_token is null then
    return jsonb_build_object('failed',true,'idempotent',true,'job_id',job.id,
      'attempts',job.attempts,'retry_at',job.available_at);
  end if;
  if job.status<>'processing' or job.claim_token is distinct from target_claim_token or job.claimed_by is null then
    raise exception 'invalid_pdf_job_claim' using errcode='42501';
  end if;
  select * into doc from public.documents
  where id=job.document_id and company_id=job.company_id and snapshot_id=job.snapshot_id
    and finalized_at is not null for update;
  select * into snapshot from public.document_snapshots
  where id=job.snapshot_id and company_id=job.company_id and document_id=job.document_id for update;
  if doc.id is null or snapshot.id is null then raise exception 'pdf_job_snapshot_mismatch' using errcode='55000'; end if;
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

-- Le jeton de bail ne doit jamais être lisible directement.
revoke select on public.document_pdf_jobs from authenticated;
revoke insert,update,delete on public.document_pdf_jobs from anon,authenticated;
grant select(id,company_id,document_id,snapshot_id,status,attempts,last_error_code,
  available_at,started_at,completed_at,created_by,created_at,updated_at,claimed_by,lease_expires_at)
  on public.document_pdf_jobs to authenticated;

revoke all on function public._piloz_create_document_snapshot(uuid) from public,anon,authenticated,service_role;
revoke all on function public.claim_document_pdf_job(uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.complete_document_pdf_job(uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.fail_document_pdf_job(uuid,uuid,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.claim_document_pdf_job(uuid,integer) to authenticated;
grant execute on function public.complete_document_pdf_job(uuid,uuid,text,text) to service_role;
grant execute on function public.fail_document_pdf_job(uuid,uuid,text,integer) to service_role;

-- L'ancien attachement sans bail contournerait le verrou atomique.
revoke all on function public.attach_document_final_pdf(uuid,text,text) from public,anon,authenticated,service_role;
select pg_notify('pgrst','reload schema');
commit;
