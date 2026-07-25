begin;

-- Tout nouveau devis commence comme un vrai brouillon. Son numéro commercial
-- n'est attribué qu'au moment où il est validé avec un client.
create or replace function public.force_new_quote_to_draft()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.document_type='quote' then
    new.status:='draft';
    new.number:=null;
  end if;
  return new;
end
$$;

revoke all on function public.force_new_quote_to_draft() from public,anon,authenticated;
drop trigger if exists documents_00_force_new_quote_to_draft on public.documents;
create trigger documents_00_force_new_quote_to_draft
before insert on public.documents
for each row execute function public.force_new_quote_to_draft();

-- Le trigger historique reste un filet de securite pour les imports, mais il
-- ne numerote plus les brouillons.
create or replace function public.assign_document_number()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.number is null and new.document_type='quote' and new.status<>'draft' then
    new.number:=public._piloz_take_document_number(
      new.company_id,new.document_type,
      extract(year from coalesce(new.issue_date,current_date))::integer,false
    );
  end if;
  return new;
end
$$;

revoke all on function public.assign_document_number() from public,anon,authenticated;

-- La validation d'un devis devient une vraie transition metier : client,
-- lignes, total, date de validite et entreprise complete sont controles avant
-- l'attribution du numero. Un brouillon incomplet reste enregistrable.
create or replace function public.transition_document_status(target_document_id uuid,target_status text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  doc public.documents%rowtype;
  allowed boolean:=false;
  has_downstream_invoice boolean:=false;
  old_status text;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then
    raise exception 'document_not_found' using errcode='P0002';
  end if;
  old_status:=doc.status;

  if doc.document_type='quote' then
    select exists(
      select 1 from public.document_links link
      where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
    ) or exists(
      select 1 from public.documents target
      where target.source_document_id=doc.id
        and target.document_type in('invoice','deposit_invoice','balance_invoice','proforma_invoice')
    ) into has_downstream_invoice;
    if has_downstream_invoice then raise exception 'quote_locked_by_invoice'; end if;

    if target_status in('pending','sent','accepted','rejected') then
      if doc.status='draft' and target_status<>'pending' then
        raise exception 'quote_must_be_validated';
      end if;
      if doc.status='draft' and not public.has_company_permission(doc.company_id,'finalize_quote') then
        raise exception 'missing_permission:finalize_quote' using errcode='42501';
      end if;
      if not public.is_company_onboarded(doc.company_id) then
        raise exception 'company_onboarding_required' using errcode='42501';
      end if;
      if doc.client_id is null or not exists(
        select 1 from public.clients client
        where client.id=doc.client_id and client.company_id=doc.company_id and client.active
      ) then
        raise exception 'document_client_required';
      end if;
      if doc.validity_date is null then raise exception 'quote_validity_date_required'; end if;
      if not exists(
        select 1 from public.document_lines line
        where line.document_id=doc.id
          and line.line_type in('item','free_item','discount')
          and not line.optional
          and nullif(trim(coalesce(line.name,'')),'') is not null
          and line.quantity>0
      ) then
        raise exception 'document_lines_required';
      end if;
      if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then
        raise exception 'document_total_must_be_positive';
      end if;
      if doc.number is null then
        update public.documents set number=public._piloz_take_document_number(
          doc.company_id,'quote',extract(year from coalesce(doc.issue_date,current_date))::integer,false
        ),updated_at=now() where id=doc.id returning * into doc;
      end if;
    end if;

    allowed:=case
      when doc.status='draft' then target_status in('pending','archived')
      else target_status in('pending','sent','accepted','rejected','expired','archived')
    end;
    if not allowed then raise exception 'invalid_document_status_transition'; end if;

    if target_status=doc.status then
      return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status);
    end if;
  elsif doc.finalized_at is null then
    allowed:=doc.status='draft' and target_status in('to_finalize','cancelled','archived');
  elsif doc.document_type in('invoice','deposit_invoice','balance_invoice','credit_note') then
    allowed:=target_status in('finalized','sent','overdue','archived');
  end if;

  if not allowed then raise exception 'invalid_document_status_transition'; end if;
  update public.documents set
    status=target_status,
    sent_at=case when target_status='sent' then coalesce(sent_at,now()) else sent_at end,
    accepted_at=case when target_status='accepted' then coalesce(accepted_at,now()) when target_status='pending' then null else accepted_at end,
    rejected_at=case when target_status='rejected' then coalesce(rejected_at,now()) when target_status='pending' then null else rejected_at end,
    expired_at=case when target_status='expired' then coalesce(expired_at,now()) else expired_at end,
    archived_at=case when target_status='archived' then coalesce(archived_at,now()) else archived_at end,
    updated_at=now()
  where id=doc.id returning * into doc;

  if doc.document_type='quote' then perform public._piloz_refresh_quote_snapshot(doc.id); end if;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.status_changed','document',doc.id,
    jsonb_build_object('status',old_status),
    jsonb_build_object('status',target_status,'number',doc.number),auth.uid());
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'sent_at',doc.sent_at,
    'accepted_at',doc.accepted_at,'rejected_at',doc.rejected_at,'expired_at',doc.expired_at);
end
$$;

revoke all on function public.transition_document_status(uuid,text) from public,anon;
grant execute on function public.transition_document_status(uuid,text) to authenticated;

-- Une fois sorti du brouillon, un devis doit conserver son client. Ce garde
-- couvre aussi les mises a jour REST/RPC qui contourneraient l'interface.
create or replace function public.guard_operational_document_client()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.document_type='quote' and new.status<>'draft' and new.client_id is null then
    raise exception 'document_client_required';
  end if;
  if new.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
    and new.finalized_at is not null and new.client_id is null then
    raise exception 'document_client_required';
  end if;
  return new;
end
$$;

revoke all on function public.guard_operational_document_client() from public,anon,authenticated;
drop trigger if exists documents_guard_operational_client on public.documents;
create trigger documents_guard_operational_client
before update on public.documents
for each row execute function public.guard_operational_document_client();

-- Dernier filet serveur : aucune facture ne peut etre produite depuis un
-- devis encore brouillon, meme en appelant directement un RPC ou l'API REST.
create or replace function public.guard_invoice_created_from_quote()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare source public.documents%rowtype;
begin
  if new.source_document_id is null
    or new.document_type not in('invoice','deposit_invoice','balance_invoice','proforma_invoice') then
    return new;
  end if;
  select * into source from public.documents where id=new.source_document_id;
  if source.id is not null and source.document_type='quote'
    and (source.status='draft' or source.number is null or source.client_id is null) then
    raise exception 'quote_must_be_validated';
  end if;
  return new;
end
$$;

revoke all on function public.guard_invoice_created_from_quote() from public,anon,authenticated;
drop trigger if exists documents_guard_invoice_created_from_quote on public.documents;
create trigger documents_guard_invoice_created_from_quote
before insert on public.documents
for each row execute function public.guard_invoice_created_from_quote();

commit;
