-- Interdit toute nouvelle situation lorsque l'avancement cumule de la
-- situation finalisee atteint deja 100 %. La verification serveur complete
-- le verrouillage d'interface et protege aussi les appels RPC directs.

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
  current_progress numeric;
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

  select case
    when coalesce(sum(progress.weight),0)>0 then
      sum(progress.weight*progress.percent/100)/sum(progress.weight)*100
    else avg(progress.percent)
  end into current_progress
  from (
    select
      greatest(0,least(100,coalesce(line.cumulative_progress_percent,0)))::numeric percent,
      abs(
        coalesce(nullif(line.line_metadata->>'original_quantity','')::numeric,line.quantity,0)
        * coalesce(nullif(line.line_metadata->>'original_unit_price','')::numeric,line.unit_price,0)
        * (1-greatest(0,least(100,coalesce(line.discount_rate,0)))/100)
      )::numeric weight
    from public.document_lines line
    where line.document_id=current_situation.id
      and line.line_type in('item','free_item','discount')
      and not coalesce(line.optional,false)
  ) progress;

  if coalesce(current_progress,0)>=99.999 then
    raise exception 'progress_already_complete';
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
  'Cree le brouillon de situation suivant tant que l avancement cumule reste inferieur a 100 pour cent.';

revoke all on function public.create_next_progress_invoice_draft(uuid) from public,anon;
grant execute on function public.create_next_progress_invoice_draft(uuid) to authenticated;

commit;
