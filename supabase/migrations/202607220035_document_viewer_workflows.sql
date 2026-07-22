begin;

-- Les mutations légales passent par des fonctions SECURITY DEFINER. Les
-- protections historiques restent strictes pour les écritures directes mais
-- laissent ces RPC atomiques nettoyer un ancien devis déjà snapshoté.
create or replace function public.protect_validated_document()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if current_user in('postgres','service_role','supabase_admin') then return new; end if;
  if old.validated_at is not null and
    (to_jsonb(new)-array['status','archived_at','updated_at']::text[]) is distinct from
    (to_jsonb(old)-array['status','archived_at','updated_at']::text[])
  then raise exception 'validated_document_is_locked' using errcode='55000'; end if;
  return new;
end
$$;

create or replace function public.protect_validated_document_line()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare target_id uuid;
begin
  if current_user in('postgres','service_role','supabase_admin') then return case when tg_op='DELETE' then old else new end; end if;
  target_id:=case when tg_op='DELETE' then old.document_id else new.document_id end;
  if exists(select 1 from public.documents where id=target_id and validated_at is not null)
  then raise exception 'validated_document_lines_are_locked' using errcode='55000'; end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
revoke all on function public.protect_validated_document() from public,anon,authenticated;
revoke all on function public.protect_validated_document_line() from public,anon,authenticated;

-- Statuts métier des devis : seuls les trois choix manuels sont acceptés.
-- Les états "facturé" et "expiré" restent calculés à partir des liens et dates.
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
      select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
      where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
        and target.status not in('cancelled','archived')
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

-- Suppression commerciale atomique et auditée. Les factures finalisées ainsi
-- que les devis ayant produit un document de facturation sont protégés.
create or replace function public.delete_commercial_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; has_downstream boolean; has_payments boolean;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type='quote' then
    select exists(
      select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
      where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
        and target.status not in('cancelled','archived')
    ) or exists(
      select 1 from public.documents target where target.source_document_id=doc.id
        and target.document_type in('invoice','deposit_invoice','balance_invoice') and target.status not in('cancelled','archived')
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

-- Annulation totale d'une facture : avoir finalisé, annulation de la source
-- et, au choix, nouveau brouillon identique dans une transaction unique.
create or replace function public.create_full_credit_note_v2(
  target_invoice_id uuid,credit_reason text,credit_date date,create_replacement boolean default false
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; credit_id uuid; replacement_id uuid; finalized_credit jsonb;
begin
  if nullif(trim(credit_reason),'') is null then raise exception 'credit_reason_required'; end if;
  if credit_date is null then raise exception 'credit_date_required'; end if;
  select * into source from public.documents where id=target_invoice_id for update;
  if source.id is null or source.document_type not in('invoice','deposit_invoice','balance_invoice')
    or not public.is_company_member(source.company_id) then raise exception 'invoice_not_found' using errcode='P0002'; end if;
  if source.finalized_at is null and source.validated_at is null then raise exception 'invoice_must_be_finalized'; end if;
  if source.status in('cancelled','archived') then raise exception 'invoice_already_cancelled'; end if;

  credit_id:=public.create_credit_note(source.id,trim(credit_reason),null);
  update public.documents set issue_date=credit_date,due_date=credit_date,
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('credit_date',credit_date,'credit_reason',trim(credit_reason)),updated_at=now()
  where id=credit_id and status='draft';
  finalized_credit:=public.finalize_document(credit_id);

  update public.documents set status='cancelled',updated_at=now() where id=source.id;
  update public.document_links set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
    'reason',trim(credit_reason),'credit_date',credit_date,'cancellation_kind','full'
  ) where source_document_id=source.id and target_document_id=credit_id and link_type='credit_note';

  if create_replacement then
    insert into public.documents(
      company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
      payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
      opportunity_id,assigned_user_id,template_id,metadata,created_by
    ) values(
      source.company_id,'invoice',source.client_id,'draft',credit_date,null,source.subject,source.client_reference,
      source.currency,source.language,source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,
      source.discount_rate,source.id,coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
      source.template_id,coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object(
        'replacement_of',source.id,'created_from_cancellation',true,'credit_note_id',credit_id
      ),auth.uid()
    ) returning id into replacement_id;
    perform public._piloz_copy_document_lines(source.id,replacement_id);
    insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
    values(source.company_id,source.id,replacement_id,'related',jsonb_build_object('relation','replacement_invoice'),auth.uid()),
      (source.company_id,credit_id,replacement_id,'related',jsonb_build_object('relation','replacement_for_credit'),auth.uid());
  end if;

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(source.company_id,auth.uid(),'invoice.cancelled_with_credit','document',source.id,
    jsonb_build_object('status',source.status),jsonb_build_object('status','cancelled','credit_note_id',credit_id,
      'replacement_invoice_id',replacement_id,'reason',trim(credit_reason),'credit_date',credit_date),auth.uid());
  return jsonb_build_object('source_invoice_id',source.id,'credit_note_id',credit_id,
    'replacement_invoice_id',replacement_id,'credit_number',finalized_credit->>'number');
end
$$;

revoke all on function public.transition_document_status(uuid,text) from public,anon;
revoke all on function public.delete_commercial_document(uuid) from public,anon;
revoke all on function public.create_full_credit_note_v2(uuid,text,date,boolean) from public,anon;
grant execute on function public.transition_document_status(uuid,text) to authenticated;
grant execute on function public.delete_commercial_document(uuid) to authenticated;
grant execute on function public.create_full_credit_note_v2(uuid,text,date,boolean) to authenticated;

commit;
