begin;

-- L'accès à cette fonction reste exclusivement accordé à service_role.
-- Ne pas dépendre de request.jwt.claim.role : cette variable historique
-- n'est pas garantie par toutes les versions de PostgREST.
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
      schema_version='202607270096',updated_at=clock_timestamp()
    where company_id=archive_row.company_id;
    perform public._append_fiscal_event(
      archive_row.company_id,'archive_signed','fiscal_archive',archive_row.id,clock_timestamp(),
      jsonb_build_object('archive_id',archive_row.id,'archive_hash',archive_row.archive_hash,
        'provider',signature_row.provider,'key_id',signature_row.key_id,
        'algorithm',signature_row.algorithm,'signed_by',target_signed_by),
      'kms',jsonb_build_object('schema_version','202607270096')
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

commit;
