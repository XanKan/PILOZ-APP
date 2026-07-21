-- Supabase installe pgcrypto dans le schéma `extensions`. La fonction de
-- finalisation conserve un search_path verrouillé et qualifie donc digest.
begin;

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

revoke all on function public._piloz_create_document_snapshot(uuid) from public,anon,authenticated,service_role;
select pg_notify('pgrst','reload schema');
commit;
