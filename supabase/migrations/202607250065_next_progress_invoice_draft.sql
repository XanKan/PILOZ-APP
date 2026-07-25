-- Cree et ouvre le brouillon de situation suivant sans demander l'avancement
-- dans une fenetre intermediaire. Le brouillon reprend atomiquement le dernier
-- avancement cumule ; l'utilisateur l'ajuste ensuite dans l'editeur.

begin;

create or replace function public.create_next_progress_invoice_draft(
  target_progress_invoice_id uuid
) returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  current_situation public.documents%rowtype;
  source_quote public.documents%rowtype;
  existing_draft_id uuid;
  target_id uuid;
begin
  select * into current_situation
  from public.documents
  where id=target_progress_invoice_id
  for update;

  if current_situation.id is null
    or current_situation.document_type<>'invoice'
    or coalesce(current_situation.metadata->>'document_kind','')<>'progress_invoice'
    or not public.is_company_member(current_situation.company_id) then
    raise exception 'progress_invoice_not_found' using errcode='P0002';
  end if;

  if current_situation.finalized_at is null
    and current_situation.validated_at is null
    and current_situation.locked_at is null then
    raise exception 'progress_invoice_must_be_finalized';
  end if;

  select * into source_quote
  from public.documents
  where id=current_situation.source_document_id
    and company_id=current_situation.company_id
    and document_type='quote'
  for update;

  if source_quote.id is null then
    raise exception 'source_quote_not_found' using errcode='P0002';
  end if;

  if exists(
    select 1
    from public.document_links link
    join public.documents target on target.id=link.target_document_id
    where link.company_id=current_situation.company_id
      and link.source_document_id=source_quote.id
      and link.link_type='balance'
      and target.status not in('cancelled','archived')
  ) then
    raise exception 'balance_invoice_already_exists';
  end if;

  select target.id into existing_draft_id
  from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=current_situation.company_id
    and link.source_document_id=source_quote.id
    and link.link_type='progress'
    and target.status='draft'
  order by target.created_at desc
  limit 1;

  if existing_draft_id is not null then
    return existing_draft_id;
  end if;

  target_id:=public.convert_quote_to_invoice(source_quote.id,'invoice');
  perform public.set_invoice_progress_mode(target_id,true);

  insert into public.activity_logs(
    company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by
  ) values(
    current_situation.company_id,auth.uid(),'document.next_progress_draft_created',
    'document',target_id,jsonb_build_object(
      'previous_situation_id',current_situation.id,
      'source_quote_id',source_quote.id
    ),auth.uid()
  );

  return target_id;
end
$$;

comment on function public.create_next_progress_invoice_draft(uuid) is
  'Cree atomiquement le brouillon de situation suivant en reprenant le dernier avancement cumule.';

revoke all on function public.create_next_progress_invoice_draft(uuid) from public,anon;
grant execute on function public.create_next_progress_invoice_draft(uuid) to authenticated;

commit;
