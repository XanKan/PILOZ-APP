begin;

-- Signatures KMS additives et immuables. La signature est séparée de
-- fiscal_archives afin de ne jamais rouvrir une archive fiscale figée.
create table if not exists public.fiscal_archive_signatures(
  archive_id uuid primary key references public.fiscal_archives(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete restrict,
  digest_sha256 text not null check(digest_sha256 ~ '^[0-9a-f]{64}$'),
  provider text not null check(provider in('aws-kms')),
  key_id text not null check(length(trim(key_id)) between 3 and 2048),
  algorithm text not null check(algorithm in('RSASSA_PSS_SHA_256','ECDSA_SHA_256')),
  signature_base64 text not null check(length(signature_base64) between 40 and 16384),
  verification_status text not null default 'valid' check(verification_status='valid'),
  signed_by uuid not null,
  signed_at timestamptz not null default clock_timestamp(),
  verified_at timestamptz not null default clock_timestamp(),
  metadata jsonb not null default '{}'::jsonb,
  unique(company_id,archive_id)
);

create index if not exists fiscal_archive_signatures_company_idx
  on public.fiscal_archive_signatures(company_id,signed_at desc);

alter table public.fiscal_archive_signatures enable row level security;
drop policy if exists fiscal_archive_signatures_select on public.fiscal_archive_signatures;
create policy fiscal_archive_signatures_select on public.fiscal_archive_signatures
for select to authenticated using(public.is_company_member(company_id));

revoke all on public.fiscal_archive_signatures from public,anon,authenticated;
grant select on public.fiscal_archive_signatures to authenticated;

drop trigger if exists fiscal_archive_signatures_immutable on public.fiscal_archive_signatures;
create trigger fiscal_archive_signatures_immutable before update or delete on public.fiscal_archive_signatures
for each row execute function public.protect_immutable_fiscal_row();

-- Appel exclusivement serveur après Sign puis Verify auprès du KMS.
create or replace function public.register_fiscal_archive_signature(
  target_archive_id uuid,
  target_digest_sha256 text,
  target_provider text,
  target_key_id text,
  target_algorithm text,
  target_signature_base64 text,
  target_signed_by uuid,
  target_metadata jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  archive_row public.fiscal_archives%rowtype;
  signature_row public.fiscal_archive_signatures%rowtype;
  inserted_count integer:=0;
begin
  if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;
  select * into archive_row from public.fiscal_archives where id=target_archive_id;
  if archive_row.id is null then raise exception 'archive_not_found' using errcode='P0002'; end if;
  if lower(trim(coalesce(target_digest_sha256,'')))<>archive_row.archive_hash
    or lower(trim(coalesce(target_digest_sha256,'')))!~'^[0-9a-f]{64}$' then
    raise exception 'archive_digest_mismatch' using errcode='22000';
  end if;
  if target_provider<>'aws-kms'
    or target_algorithm not in('RSASSA_PSS_SHA_256','ECDSA_SHA_256')
    or nullif(trim(target_key_id),'') is null
    or nullif(trim(target_signature_base64),'') is null then
    raise exception 'invalid_kms_signature_metadata' using errcode='22000';
  end if;
  if not exists(
    select 1 from public.company_members member
    where member.company_id=archive_row.company_id and member.user_id=target_signed_by
      and member.role in('owner','admin')
  ) then raise exception 'signer_not_authorized' using errcode='42501'; end if;

  insert into public.fiscal_archive_signatures(
    archive_id,company_id,digest_sha256,provider,key_id,algorithm,signature_base64,
    verification_status,signed_by,metadata
  ) values(
    archive_row.id,archive_row.company_id,lower(target_digest_sha256),target_provider,
    trim(target_key_id),target_algorithm,trim(target_signature_base64),'valid',target_signed_by,
    coalesce(target_metadata,'{}'::jsonb)
  ) on conflict(archive_id) do nothing;
  get diagnostics inserted_count=row_count;

  select * into signature_row from public.fiscal_archive_signatures where archive_id=archive_row.id;
  if signature_row.digest_sha256<>lower(target_digest_sha256)
    or signature_row.provider<>target_provider
    or signature_row.key_id<>trim(target_key_id)
    or signature_row.algorithm<>target_algorithm
    or signature_row.signature_base64<>trim(target_signature_base64) then
    raise exception 'archive_already_signed_differently' using errcode='23505';
  end if;

  if inserted_count>0 then
    update public.company_fiscal_configurations
    set signing_status='configured',kms_key_id=signature_row.key_id,
      prerequisites=jsonb_set(coalesce(prerequisites,'{}'::jsonb),'{kms}',jsonb_build_object(
        'provider',signature_row.provider,'key_id',signature_row.key_id,
        'algorithm',signature_row.algorithm,'validated_at',signature_row.verified_at),true),
      updated_at=clock_timestamp()
    where company_id=archive_row.company_id;
    perform public._append_fiscal_event(
      archive_row.company_id,'archive_signed','fiscal_archive',archive_row.id,clock_timestamp(),
      jsonb_build_object('archive_id',archive_row.id,'archive_hash',archive_row.archive_hash,
        'provider',signature_row.provider,'key_id',signature_row.key_id,
        'algorithm',signature_row.algorithm,'signed_by',target_signed_by),
      'kms',jsonb_build_object('schema_version','202607270095')
    );
  end if;

  return jsonb_build_object(
    'archive_id',signature_row.archive_id,'status',signature_row.verification_status,
    'provider',signature_row.provider,'key_id',signature_row.key_id,
    'algorithm',signature_row.algorithm,'signed_at',signature_row.signed_at,
    'created',inserted_count>0
  );
end
$$;
revoke all on function public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)
  from public,anon,authenticated;
grant execute on function public.register_fiscal_archive_signature(uuid,text,text,text,text,text,uuid,jsonb)
  to service_role;

-- Le contrôle SQL vérifie l'intégrité de l'archive. La validité cryptographique
-- de la signature est contrôlée par AWS KMS dans l'Edge Function d'export.
create or replace function public.verify_fiscal_archive_record(target_archive_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare
  archive_row public.fiscal_archives%rowtype;
  item_row public.fiscal_archive_items%rowtype;
  signature_row public.fiscal_archive_signatures%rowtype;
  expected_manifest text;
  expected_archive text;
  expected_item text;
  anomalies jsonb:='[]'::jsonb;
  checked integer:=0;
begin
  select * into archive_row from public.fiscal_archives where id=target_archive_id;
  if archive_row.id is null or not public.is_company_member(archive_row.company_id) then
    raise exception 'archive_not_found' using errcode='P0002';
  end if;
  select * into signature_row from public.fiscal_archive_signatures where archive_id=archive_row.id;
  expected_manifest:=encode(extensions.digest(convert_to(archive_row.manifest::text,'UTF8'),'sha256'),'hex');
  if expected_manifest<>archive_row.manifest_hash then
    anomalies:=anomalies||jsonb_build_array(jsonb_build_object('code','manifest_hash_mismatch'));
  end if;
  expected_archive:=encode(extensions.digest(convert_to(public._fiscal_archive_material(
    archive_row.archive_number,archive_row.period_start,archive_row.period_end,archive_row.manifest_hash,
    archive_row.previous_archive_hash,archive_row.application_version,archive_row.schema_version,
    archive_row.canonicalization_version),'UTF8'),'sha256'),'hex');
  if expected_archive<>archive_row.archive_hash then
    anomalies:=anomalies||jsonb_build_array(jsonb_build_object('code','archive_hash_mismatch'));
  end if;
  if signature_row.archive_id is not null and signature_row.digest_sha256<>archive_row.archive_hash then
    anomalies:=anomalies||jsonb_build_array(jsonb_build_object('code','signature_digest_mismatch'));
  end if;
  for item_row in select * from public.fiscal_archive_items where archive_id=target_archive_id order by relative_path loop
    checked:=checked+1;
    if item_row.content_status='embedded' then
      expected_item:=encode(extensions.digest(convert_to(item_row.embedded_payload::text,'UTF8'),'sha256'),'hex');
      if expected_item<>item_row.content_hash then anomalies:=anomalies||jsonb_build_array(
        jsonb_build_object('code','item_hash_mismatch','path',item_row.relative_path)); end if;
    elsif item_row.content_status='missing' then
      anomalies:=anomalies||jsonb_build_array(jsonb_build_object('code','missing_item','path',item_row.relative_path));
    end if;
  end loop;
  return jsonb_build_object('valid',jsonb_array_length(anomalies)=0,'archive_id',archive_row.id,
    'archive_number',archive_row.archive_number,'checked_items',checked,'anomalies',anomalies,
    'signature_status',case when signature_row.archive_id is null then 'not_configured' else 'verification_requires_kms' end,
    'signature_provider',signature_row.provider,'signature_key_id',signature_row.key_id,
    'verified_at',clock_timestamp());
end
$$;
revoke all on function public.verify_fiscal_archive_record(uuid) from public,anon;
grant execute on function public.verify_fiscal_archive_record(uuid) to authenticated;

-- Une archive de production n'est autorisée qu'après validation effective
-- d'une première signature KMS. Elle est ensuite signée au premier export.
create or replace function public.create_fiscal_archive(
  target_company_id uuid,target_period_start timestamptz,target_period_end timestamptz,
  target_allow_incomplete boolean default false
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  config public.company_fiscal_configurations%rowtype; archive_id uuid:=gen_random_uuid(); archive_number_value text;
  previous_hash text; structured_payload jsonb; structured_hash text; pdf_items jsonb:='[]'::jsonb;
  item_descriptors jsonb; manifest_value jsonb; manifest_digest text; archive_digest text;
  missing_pdf_count integer:=0; chain_report jsonb; event_id uuid; item jsonb; signature_status_value text;
begin
  if target_period_start is null or target_period_end is null or target_period_end<=target_period_start
    or target_period_end>clock_timestamp() then raise exception 'invalid_archive_period'; end if;
  if not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if exists(select 1 from public.fiscal_archives where company_id=target_company_id
    and period_start=target_period_start and period_end=target_period_end) then raise exception 'archive_period_already_exists'; end if;

  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  if coalesce(config.mode,'off')='production'
    and (config.signing_status<>'configured' or nullif(trim(config.kms_key_id),'') is null) then
    raise exception 'archive_signing_provider_required'
      using hint='Configurer et valider AWS KMS avant une archive de production.';
  end if;
  signature_status_value:=case when config.signing_status='configured' and nullif(trim(config.kms_key_id),'') is not null
    then 'pending_kms' else 'not_configured' end;
  chain_report:=public.verify_fiscal_event_chain(target_company_id);
  if not coalesce((chain_report->>'valid')::boolean,false) then raise exception 'fiscal_event_chain_invalid'; end if;

  select count(*) into missing_pdf_count
  from public.documents d left join public.document_snapshots s on s.id=d.snapshot_id and s.company_id=d.company_id
  where d.company_id=target_company_id and d.finalized_at>=target_period_start and d.finalized_at<target_period_end
    and d.document_type in('invoice','deposit_invoice','progress_invoice','balance_invoice','credit_note')
    and (s.id is null or s.pdf_status<>'ready' or s.pdf_storage_path is null or s.pdf_sha256 is null);
  if missing_pdf_count>0 and not target_allow_incomplete then raise exception 'archive_contains_missing_final_pdf'; end if;

  structured_payload:=jsonb_build_object(
    'format','piloz-fiscal-records','format_version','1.0','archive_id',archive_id,
    'company_id',target_company_id,'period_start',target_period_start,'period_end',target_period_end,
    'captured_at',clock_timestamp(),
    'fiscal_configuration',coalesce((select to_jsonb(c)-array['kms_key_id']::text[]
      from public.company_fiscal_configurations c where c.company_id=target_company_id),'{}'::jsonb),
    'documents',coalesce((select jsonb_agg(jsonb_build_object(
      'document_id',d.id,'document_number',d.number,'document_type',d.document_type,'status',d.status,
      'finalized_at',d.finalized_at,'snapshot_id',d.snapshot_id,'fiscal_security_status',d.fiscal_security_status,
      'versions',jsonb_build_object('application',d.application_version,'git_commit',d.git_commit,
        'schema',d.database_schema_version,'calculation',d.calculation_version,'pdf',d.pdf_generator_version,
        'electronic_format',d.electronic_format_version,'fiscal_policy',d.fiscal_policy_version),
      'snapshot_hash',s.payload_hash,'snapshot',s.public_payload,'pdf_path',s.pdf_storage_path,'pdf_sha256',s.pdf_sha256
    ) order by d.finalized_at,d.id)
      from public.documents d left join public.document_snapshots s on s.id=d.snapshot_id and s.company_id=d.company_id
      where d.company_id=target_company_id and d.finalized_at>=target_period_start and d.finalized_at<target_period_end
        and d.document_type in('invoice','deposit_invoice','progress_invoice','balance_invoice','credit_note')),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.paid_at,p.id) from public.payments p
      where p.company_id=target_company_id and p.paid_at>=target_period_start and p.paid_at<target_period_end),'[]'::jsonb),
    'closures',coalesce((select jsonb_agg(to_jsonb(c) order by c.period_end,c.id) from public.fiscal_closures c
      where c.company_id=target_company_id and c.created_at>=target_period_start and c.created_at<target_period_end),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('verification_material',public._fiscal_event_material(
      e.sequence_number,e.event_type,e.entity_type,e.entity_id,e.occurred_at,e.effective_at,e.previous_hash,
      e.payload_hash,e.application_version,e.schema_version,e.canonicalization_version)) order by e.sequence_number) from public.fiscal_events e
      where e.company_id=target_company_id and e.occurred_at>=target_period_start and e.occurred_at<target_period_end),'[]'::jsonb),
    'relevant_roles',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',m.role,'permissions',m.permissions)
      order by m.user_id) from public.company_members m where m.company_id=target_company_id),'[]'::jsonb),
    'chain_control',chain_report
  );
  structured_hash:=encode(extensions.digest(convert_to(structured_payload::text,'UTF8'),'sha256'),'hex');

  select coalesce(jsonb_agg(jsonb_build_object(
    'relative_path','documents/'||coalesce(regexp_replace(d.number,'[^A-Za-z0-9._-]','','g'),d.id::text)||'.pdf',
    'category','pdf','media_type','application/pdf','content_hash',coalesce(s.pdf_sha256,''),
    'byte_size',null,'storage_bucket','company-files','storage_path',s.pdf_storage_path,
    'canonicalization','raw-bytes',
    'content_status',case when s.pdf_status='ready' and s.pdf_storage_path is not null and s.pdf_sha256 is not null
      then 'storage_reference' else 'missing' end
  ) order by d.finalized_at,d.id),'[]'::jsonb) into pdf_items
  from public.documents d left join public.document_snapshots s on s.id=d.snapshot_id and s.company_id=d.company_id
  where d.company_id=target_company_id and d.finalized_at>=target_period_start and d.finalized_at<target_period_end
    and d.document_type in('invoice','deposit_invoice','progress_invoice','balance_invoice','credit_note');

  item_descriptors:=jsonb_build_array(jsonb_build_object(
    'relative_path','data/fiscal-records.json','category','structured_data','media_type','application/json',
    'content_hash',structured_hash,'byte_size',octet_length(convert_to(structured_payload::text,'UTF8')),
    'content_status','embedded','canonicalization','postgres-jsonb-text-v1'))||pdf_items;
  archive_number_value:=public._piloz_take_document_number(target_company_id,'archive',
    extract(year from target_period_end at time zone 'UTC')::integer,false);
  select archive_hash into previous_hash from public.fiscal_archives where company_id=target_company_id
    order by created_at desc,id desc limit 1;
  manifest_value:=jsonb_build_object(
    'format','piloz-fiscal-archive','format_version','1.0','archive_id',archive_id,
    'archive_number',archive_number_value,'company_id',target_company_id,'period_start',target_period_start,
    'period_end',target_period_end,'created_at',clock_timestamp(),'items',item_descriptors,
    'previous_archive_hash',previous_hash,'signature_status',signature_status_value,
    'completeness_status',case when missing_pdf_count=0 then 'complete' else 'incomplete' end,
    'missing_pdf_count',missing_pdf_count,'canonicalization_version',coalesce(config.canonicalization_version,'jsonb-text-v1'),
    'application_version','0.9.0-compliance.49','schema_version','202607270095'
  );
  manifest_digest:=encode(extensions.digest(convert_to(manifest_value::text,'UTF8'),'sha256'),'hex');
  archive_digest:=encode(extensions.digest(convert_to(public._fiscal_archive_material(
    archive_number_value,target_period_start,target_period_end,manifest_digest,previous_hash,
    '0.9.0-compliance.49','202607270095',
    coalesce(config.canonicalization_version,'jsonb-text-v1')),'UTF8'),'sha256'),'hex');

  insert into public.fiscal_archives(
    id,company_id,archive_number,period_start,period_end,manifest,manifest_hash,previous_archive_hash,
    archive_hash,signature,signature_key_id,integrity_status,completeness_status,application_version,
    schema_version,canonicalization_version,created_by,metadata
  ) values(
    archive_id,target_company_id,archive_number_value,target_period_start,target_period_end,manifest_value,
    manifest_digest,previous_hash,archive_digest,null,null,'unsigned',
    case when missing_pdf_count=0 then 'complete' else 'incomplete' end,
    '0.9.0-compliance.49','202607270095',
    coalesce(config.canonicalization_version,'jsonb-text-v1'),auth.uid(),jsonb_build_object(
      'external_validation_required',true,
      'signature_provider',case when signature_status_value='pending_kms' then 'aws-kms' else 'not_configured' end,
      'chain_report',chain_report));

  insert into public.fiscal_archive_items(
    company_id,archive_id,relative_path,category,media_type,content_hash,byte_size,embedded_payload,content_status
  ) values(target_company_id,archive_id,'data/fiscal-records.json','structured_data','application/json',structured_hash,
    octet_length(convert_to(structured_payload::text,'UTF8')),structured_payload,'embedded');
  for item in select value from jsonb_array_elements(pdf_items) loop
    insert into public.fiscal_archive_items(
      company_id,archive_id,relative_path,category,media_type,content_hash,byte_size,storage_bucket,storage_path,content_status
    ) values(target_company_id,archive_id,item->>'relative_path','pdf','application/pdf',item->>'content_hash',null,
      item->>'storage_bucket',item->>'storage_path',item->>'content_status');
  end loop;
  event_id:=public._append_fiscal_event(target_company_id,'archive_created','fiscal_archive',archive_id,target_period_end,
    jsonb_build_object('archive_number',archive_number_value,'manifest_hash',manifest_digest,'archive_hash',archive_digest,
      'completeness_status',case when missing_pdf_count=0 then 'complete' else 'incomplete' end,
      'signature_status',signature_status_value),'rpc',jsonb_build_object('schema_version','202607270095'));
  return archive_id;
end
$$;
revoke all on function public.create_fiscal_archive(uuid,timestamptz,timestamptz,boolean) from public,anon;
grant execute on function public.create_fiscal_archive(uuid,timestamptz,timestamptz,boolean) to authenticated;

alter table public.company_fiscal_configurations alter column schema_version set default '202607270095';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.49',schema_version='202607270095',updated_at=clock_timestamp()
where application_version is distinct from '0.9.0-compliance.49'
   or schema_version is distinct from '202607270095';

commit;
