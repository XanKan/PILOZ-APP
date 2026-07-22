begin;

-- Dès qu'un document comptable a été produit depuis un devis, son état
-- "Facturé" reste automatique et ses choix manuels ne sont plus modifiables.
create or replace function public.transition_document_status(target_document_id uuid,target_status text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; allowed boolean:=false; has_downstream_invoice boolean; old_status text;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if target_status=doc.status then return jsonb_build_object('id',doc.id,'status',doc.status); end if;
  old_status:=doc.status;
  if doc.document_type='quote' then
    select exists(
      select 1 from public.document_links link
      where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
    ) or exists(
      select 1 from public.documents target
      where target.source_document_id=doc.id and target.document_type in('invoice','deposit_invoice','balance_invoice')
    ) into has_downstream_invoice;
    if has_downstream_invoice then raise exception 'quote_locked_by_invoice'; end if;
    allowed:=target_status in('pending','accepted','rejected');
  elsif doc.finalized_at is null then
    allowed:=doc.status='draft' and target_status in('to_finalize','cancelled','archived');
  elsif doc.document_type in('invoice','deposit_invoice','balance_invoice','credit_note') then
    allowed:=target_status in('finalized','sent','overdue','archived');
  end if;
  if not allowed then raise exception 'invalid_document_status_transition'; end if;
  update public.documents set status=target_status,
    sent_at=case when target_status='sent' then coalesce(sent_at,now()) else sent_at end,
    accepted_at=case when target_status='accepted' then coalesce(accepted_at,now()) when target_status='pending' then null else accepted_at end,
    rejected_at=case when target_status='rejected' then coalesce(rejected_at,now()) when target_status='pending' then null else rejected_at end,
    updated_at=now()
  where id=doc.id returning * into doc;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.status_changed','document',doc.id,
    jsonb_build_object('status',old_status),jsonb_build_object('status',target_status),auth.uid());
  return jsonb_build_object('id',doc.id,'status',doc.status,'sent_at',doc.sent_at,
    'accepted_at',doc.accepted_at,'rejected_at',doc.rejected_at);
end
$$;

revoke all on function public.transition_document_status(uuid,text) from public,anon;
grant execute on function public.transition_document_status(uuid,text) to authenticated;

commit;
