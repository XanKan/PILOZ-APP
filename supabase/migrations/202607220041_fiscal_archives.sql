begin;

-- Phase 4 — archives fiscales exportables et vérifiables.
-- Le registre ne simule jamais de signature. En mode production, la création
-- est bloquée tant que le fournisseur de signature serveur n'est pas présent.

create table if not exists public.fiscal_archives(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  archive_number text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  format_name text not null default 'piloz-fiscal-archive',
  format_version text not null default '1.0',
  manifest jsonb not null,
  manifest_hash text not null,
  previous_archive_hash text,
  archive_hash text not null,
  signature text,
  signature_key_id text,
  integrity_status text not null default 'unsigned'
    check(integrity_status in('unsigned','signed','verification_error')),
  completeness_status text not null
    check(completeness_status in('complete','incomplete')),
  application_version text not null,
  schema_version text not null,
  canonicalization_version text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  unique(company_id,archive_number),
  unique(company_id,period_start,period_end),
  check(period_end>period_start)
);

create table if not exists public.fiscal_archive_items(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  archive_id uuid not null references public.fiscal_archives(id) on delete restrict,
  relative_path text not null,
  category text not null check(category in('structured_data','pdf','manifest','control_report')),
  media_type text not null,
  content_hash text not null,
  byte_size bigint,
  embedded_payload jsonb,
  storage_bucket text,
  storage_path text,
  content_status text not null check(content_status in('embedded','storage_reference','missing')),
  created_at timestamptz not null default now(),
  unique(archive_id,relative_path),
  check(
    (content_status='embedded' and embedded_payload is not null) or
    (content_status='storage_reference' and storage_path is not null) or
    content_status='missing'
  )
);

create table if not exists public.fiscal_archive_exports(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  archive_id uuid not null references public.fiscal_archives(id) on delete restrict,
  export_format text not null check(export_format in('json_bundle','directory')),
  destination_kind text not null default 'download',
  exported_by uuid,
  exported_at timestamptz not null default now(),
  package_hash text,
  verification_status text not null default 'not_verified'
    check(verification_status in('not_verified','valid','invalid','unsigned')),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists fiscal_archives_company_period_idx
  on public.fiscal_archives(company_id,period_start,period_end);
create index if not exists fiscal_archive_items_archive_idx
  on public.fiscal_archive_items(company_id,archive_id,relative_path);
create index if not exists fiscal_archive_exports_archive_idx
  on public.fiscal_archive_exports(company_id,archive_id,exported_at);

alter table public.fiscal_archives enable row level security;
alter table public.fiscal_archive_items enable row level security;
alter table public.fiscal_archive_exports enable row level security;
drop policy if exists fiscal_archives_select on public.fiscal_archives;
create policy fiscal_archives_select on public.fiscal_archives for select to authenticated
using(public.is_company_member(company_id));
drop policy if exists fiscal_archive_items_select on public.fiscal_archive_items;
create policy fiscal_archive_items_select on public.fiscal_archive_items for select to authenticated
using(public.is_company_member(company_id));
drop policy if exists fiscal_archive_exports_select on public.fiscal_archive_exports;
create policy fiscal_archive_exports_select on public.fiscal_archive_exports for select to authenticated
using(public.is_company_member(company_id));

revoke all on public.fiscal_archives,public.fiscal_archive_items,public.fiscal_archive_exports from anon,authenticated;
grant select on public.fiscal_archives,public.fiscal_archive_items,public.fiscal_archive_exports to authenticated;

drop trigger if exists fiscal_archives_immutable on public.fiscal_archives;
create trigger fiscal_archives_immutable before update or delete on public.fiscal_archives
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists fiscal_archive_items_immutable on public.fiscal_archive_items;
create trigger fiscal_archive_items_immutable before update or delete on public.fiscal_archive_items
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists fiscal_archive_exports_immutable on public.fiscal_archive_exports;
create trigger fiscal_archive_exports_immutable before update or delete on public.fiscal_archive_exports
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public._fiscal_archive_material(
  target_archive_number text,target_period_start timestamptz,target_period_end timestamptz,
  target_manifest_hash text,target_previous_hash text,target_application_version text,
  target_schema_version text,target_canonicalization_version text
) returns text language sql immutable set search_path=public,pg_temp as $$
  select concat_ws('|',target_archive_number,
    to_char(target_period_start at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    to_char(target_period_end at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    target_manifest_hash,coalesce(target_previous_hash,''),target_application_version,
    target_schema_version,target_canonicalization_version)
$$;
revoke all on function public._fiscal_archive_material(text,timestamptz,timestamptz,text,text,text,text,text)
from public,anon,authenticated;

create or replace function public.create_fiscal_archive(
  target_company_id uuid,target_period_start timestamptz,target_period_end timestamptz,
  target_allow_incomplete boolean default false
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  config public.company_fiscal_configurations%rowtype; archive_id uuid:=gen_random_uuid(); archive_number_value text;
  previous_hash text; structured_payload jsonb; structured_hash text; pdf_items jsonb:='[]'::jsonb;
  item_descriptors jsonb; manifest_value jsonb; manifest_digest text; archive_digest text;
  missing_pdf_count integer:=0; chain_report jsonb; event_id uuid; item jsonb;
begin
  if target_period_start is null or target_period_end is null or target_period_end<=target_period_start
    or target_period_end>clock_timestamp() then raise exception 'invalid_archive_period'; end if;
  if not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if exists(select 1 from public.fiscal_archives where company_id=target_company_id
    and period_start=target_period_start and period_end=target_period_end) then raise exception 'archive_period_already_exists'; end if;

  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  if coalesce(config.mode,'off')='production' then
    raise exception 'archive_signing_provider_required' using hint='Configurer et valider un KMS avant une archive de production.';
  end if;
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
    'previous_archive_hash',previous_hash,'signature_status','not_configured',
    'completeness_status',case when missing_pdf_count=0 then 'complete' else 'incomplete' end,
    'missing_pdf_count',missing_pdf_count,'canonicalization_version',coalesce(config.canonicalization_version,'jsonb-text-v1'),
    'application_version',coalesce(config.application_version,'2026.07-compliance'),
    'schema_version','202607220041'
  );
  manifest_digest:=encode(extensions.digest(convert_to(manifest_value::text,'UTF8'),'sha256'),'hex');
  archive_digest:=encode(extensions.digest(convert_to(public._fiscal_archive_material(
    archive_number_value,target_period_start,target_period_end,manifest_digest,previous_hash,
    coalesce(config.application_version,'2026.07-compliance'),'202607220041',
    coalesce(config.canonicalization_version,'jsonb-text-v1')),'UTF8'),'sha256'),'hex');

  insert into public.fiscal_archives(
    id,company_id,archive_number,period_start,period_end,manifest,manifest_hash,previous_archive_hash,
    archive_hash,signature,signature_key_id,integrity_status,completeness_status,application_version,
    schema_version,canonicalization_version,created_by,metadata
  ) values(
    archive_id,target_company_id,archive_number_value,target_period_start,target_period_end,manifest_value,
    manifest_digest,previous_hash,archive_digest,null,null,'unsigned',
    case when missing_pdf_count=0 then 'complete' else 'incomplete' end,
    coalesce(config.application_version,'2026.07-compliance'),'202607220041',
    coalesce(config.canonicalization_version,'jsonb-text-v1'),auth.uid(),jsonb_build_object(
      'external_validation_required',true,'signature_provider','not_configured','chain_report',chain_report));

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
      'signature_status','not_configured'),'rpc','{}'::jsonb);
  return archive_id;
end
$$;
revoke all on function public.create_fiscal_archive(uuid,timestamptz,timestamptz,boolean) from public,anon;
grant execute on function public.create_fiscal_archive(uuid,timestamptz,timestamptz,boolean) to authenticated;

create or replace function public.verify_fiscal_archive_record(target_archive_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare
  archive_row public.fiscal_archives%rowtype; item_row public.fiscal_archive_items%rowtype;
  expected_manifest text; expected_archive text; expected_item text; anomalies jsonb:='[]'::jsonb; checked integer:=0;
begin
  select * into archive_row from public.fiscal_archives where id=target_archive_id;
  if archive_row.id is null or not public.is_company_member(archive_row.company_id) then
    raise exception 'archive_not_found' using errcode='P0002';
  end if;
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
    'signature_status',case when archive_row.signature is null then 'not_configured' else 'verification_requires_kms' end,
    'verified_at',clock_timestamp());
end
$$;
revoke all on function public.verify_fiscal_archive_record(uuid) from public,anon;
grant execute on function public.verify_fiscal_archive_record(uuid) to authenticated;

create or replace function public.register_fiscal_archive_export(
  target_archive_id uuid,target_export_format text,target_package_hash text default null,
  target_verification_status text default 'not_verified'
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare archive_row public.fiscal_archives%rowtype; export_id uuid:=gen_random_uuid();
begin
  select * into archive_row from public.fiscal_archives where id=target_archive_id;
  if archive_row.id is null or not public.has_company_role(archive_row.company_id,array['owner','admin']) then
    raise exception 'archive_not_found' using errcode='P0002'; end if;
  if target_export_format not in('json_bundle','directory') or target_verification_status not in('not_verified','valid','invalid','unsigned')
    then raise exception 'invalid_archive_export'; end if;
  insert into public.fiscal_archive_exports(
    id,company_id,archive_id,export_format,exported_by,package_hash,verification_status
  ) values(export_id,archive_row.company_id,archive_row.id,target_export_format,auth.uid(),
    nullif(trim(target_package_hash),''),target_verification_status);
  perform public._append_fiscal_event(archive_row.company_id,'archive_exported','fiscal_archive',archive_row.id,clock_timestamp(),
    jsonb_build_object('archive_id',archive_row.id,'archive_number',archive_row.archive_number,
      'export_id',export_id,'export_format',target_export_format,'package_hash',nullif(trim(target_package_hash),''),
      'verification_status',target_verification_status),'rpc','{}'::jsonb);
  return export_id;
end
$$;
revoke all on function public.register_fiscal_archive_export(uuid,text,text,text) from public,anon;
grant execute on function public.register_fiscal_archive_export(uuid,text,text,text) to authenticated;

commit;
