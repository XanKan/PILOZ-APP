begin;

-- A document template can select one of the versioned CGV sets without
-- duplicating its text.  The id is stored in the already versioned
-- issuer_profile JSON so every template version keeps its own choice.
create or replace function public._piloz_template_sales_terms_id(
  target_company_id uuid,
  target_template_id uuid
) returns uuid
language sql stable security definer set search_path=public,pg_temp as $$
  select terms.id
  from public.document_templates template
  join public.document_template_versions version
    on version.template_id=template.id and version.version=template.current_version
  join public.sales_terms terms
    on terms.id=case
      when coalesce(version.issuer_profile->>'sales_terms_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then (version.issuer_profile->>'sales_terms_id')::uuid
      else null
    end
  where template.id=target_template_id
    and template.company_id=target_company_id
    and version.company_id=target_company_id
    and terms.company_id=target_company_id
    and terms.status='active'
  limit 1
$$;

create or replace function public.resolve_document_sales_terms(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents;terms_id uuid;version_id uuid;family text;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  family:=case when doc.document_type='quote' then 'quote'
    when doc.document_type in('invoice','deposit_invoice','balance_invoice','progress_invoice','proforma_invoice') then 'invoice'
    when doc.document_type='credit_note' then 'credit_note'
    else doc.document_type end;
  terms_id:=coalesce(doc.selected_sales_terms_id,public._piloz_template_sales_terms_id(doc.company_id,doc.template_id));
  if terms_id is null then
    select assignment.sales_terms_id into terms_id from public.sales_terms_assignments assignment
    where assignment.company_id=doc.company_id and assignment.active
      and (assignment.client_id=doc.client_id or assignment.client_id is null)
      and assignment.document_type=family
    order by (assignment.client_id is not null) desc,assignment.priority desc,assignment.created_at desc limit 1;
  end if;
  if terms_id is null then return null; end if;
  select version.id into version_id from public.sales_terms terms
  join public.sales_terms_versions version on version.sales_terms_id=terms.id and version.version=terms.current_version
  where terms.id=terms_id and terms.company_id=doc.company_id and terms.status='active';
  return version_id;
end $$;

create or replace function public._snapshot_document_sales_terms(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents;version_row public.sales_terms_versions;version_id uuid;terms_id uuid;family text;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or doc.finalized_at is null then return null;end if;
  select snapshot.sales_terms_version_id into version_id from public.document_sales_terms_snapshots snapshot where snapshot.document_id=doc.id;
  if version_id is not null then return version_id;end if;
  family:=case when doc.document_type='quote' then 'quote' when doc.document_type='credit_note' then 'credit_note' else 'invoice' end;
  terms_id:=coalesce(doc.selected_sales_terms_id,public._piloz_template_sales_terms_id(doc.company_id,doc.template_id));
  if terms_id is null then
    select assignment.sales_terms_id into terms_id
    from public.sales_terms_assignments assignment
    where assignment.company_id=doc.company_id and assignment.active
      and assignment.document_type=family
      and (assignment.client_id=doc.client_id or assignment.client_id is null)
    order by (assignment.client_id is not null) desc,assignment.priority desc,assignment.created_at desc
    limit 1;
  end if;
  if terms_id is null then return null;end if;
  select version.* into version_row
  from public.sales_terms terms
  join public.sales_terms_versions version on version.sales_terms_id=terms.id and version.version=terms.current_version
  where terms.id=terms_id and terms.company_id=doc.company_id and terms.status='active';
  if version_row.id is null then return null;end if;
  insert into public.document_sales_terms_snapshots(document_id,company_id,sales_terms_id,sales_terms_version_id,version,source_type,body,pdf_storage_path,pdf_sha256,mime_type,file_size_bytes,snapshotted_by)
  values(doc.id,doc.company_id,version_row.sales_terms_id,version_row.id,version_row.version,version_row.source_type,version_row.body,version_row.pdf_storage_path,version_row.pdf_sha256,version_row.mime_type,version_row.file_size_bytes,coalesce(doc.finalized_by,doc.created_by));
  return version_row.id;
end $$;

revoke all on function public._piloz_template_sales_terms_id(uuid,uuid) from public,anon,authenticated;
revoke all on function public._snapshot_document_sales_terms(uuid) from public,anon,authenticated;
revoke all on function public.resolve_document_sales_terms(uuid) from public,anon;
grant execute on function public.resolve_document_sales_terms(uuid) to authenticated;

commit;
