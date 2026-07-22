begin;

-- Un devis conserve son historique dès qu'un document de facturation a été
-- produit, y compris si ce document a ensuite été annulé ou archivé.
create or replace function public.delete_commercial_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; has_downstream boolean; has_payments boolean;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type='quote' then
    select exists(
      select 1 from public.document_links link
      where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
    ) or exists(
      select 1 from public.documents target where target.source_document_id=doc.id
        and target.document_type in('invoice','deposit_invoice','balance_invoice')
    ) into has_downstream;
    if has_downstream then raise exception 'quote_has_downstream_invoice'; end if;
  elsif doc.document_type in('invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice','recurring_invoice') then
    if doc.status<>'draft' or doc.finalized_at is not null or doc.validated_at is not null or doc.locked_at is not null then
      raise exception 'only_draft_invoice_can_be_deleted';
    end if;
    select exists(select 1 from public.payments where document_id=doc.id) into has_payments;
    if has_payments then raise exception 'invoice_has_payments'; end if;
  else
    raise exception 'unsupported_document_type';
  end if;

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.deleted','document',doc.id,
    jsonb_build_object('id',doc.id,'number',doc.number,'document_type',doc.document_type,'status',doc.status),
    jsonb_build_object('deleted',true),auth.uid());
  update public.documents set snapshot_id=null where id=doc.id;
  delete from public.document_pdf_jobs where document_id=doc.id;
  delete from public.document_snapshots where document_id=doc.id;
  delete from public.documents where id=doc.id;
  return jsonb_build_object('id',doc.id,'deleted',true,'document_type',doc.document_type);
end
$$;

revoke all on function public.delete_commercial_document(uuid) from public,anon;
grant execute on function public.delete_commercial_document(uuid) to authenticated;

commit;
