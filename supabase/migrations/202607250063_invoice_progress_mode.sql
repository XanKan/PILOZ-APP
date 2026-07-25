-- Une conversion devis -> facture cree toujours une facture classique brouillon.
-- L'utilisateur peut ensuite activer ou desactiver le mode "facture de situation"
-- depuis l'editeur. La transformation reste atomique et limitee a son entreprise.

begin;

create or replace function public.set_invoice_progress_mode(
  target_invoice_id uuid,
  target_enabled boolean
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  target public.documents%rowtype;
  source public.documents%rowtype;
  situation_number integer:=0;
  previous_situation_id uuid;
  existing_progress_id uuid;
begin
  select * into target from public.documents where id=target_invoice_id for update;
  if target.id is null or target.document_type<>'invoice' or not public.is_company_member(target.company_id) then
    raise exception 'invoice_not_found' using errcode='P0002';
  end if;
  if target.status<>'draft' or target.number is not null or target.validated_at is not null
    or target.finalized_at is not null or target.locked_at is not null then
    raise exception 'only_editable_invoice_draft_can_change_progress_mode';
  end if;

  select * into source
  from public.documents
  where id=target.source_document_id and company_id=target.company_id and document_type='quote';
  if source.id is null then raise exception 'source_quote_not_found' using errcode='P0002'; end if;

  if target_enabled then
    if coalesce(target.metadata->>'document_kind','')='progress_invoice' then
      return jsonb_build_object('id',target.id,'enabled',true,
        'situation_number',coalesce(nullif(target.metadata->>'situation_number','')::integer,1));
    end if;

    select link.target_document_id into existing_progress_id
    from public.document_links link
    join public.documents document on document.id=link.target_document_id
    where link.company_id=target.company_id and link.source_document_id=source.id
      and link.link_type='progress' and document.status='draft' and document.id<>target.id
    order by document.created_at desc limit 1;
    if existing_progress_id is not null then raise exception 'progress_draft_already_exists'; end if;

    select coalesce(max(case when coalesce(document.metadata->>'situation_number','')~'^[0-9]+$'
      then (document.metadata->>'situation_number')::integer else 0 end),0)+1
    into situation_number
    from public.document_links link
    join public.documents document on document.id=link.target_document_id
    where link.company_id=target.company_id and link.source_document_id=source.id
      and link.link_type='progress' and document.status not in('cancelled','archived') and document.id<>target.id;

    select document.id into previous_situation_id
    from public.document_links link
    join public.documents document on document.id=link.target_document_id
    where link.company_id=target.company_id and link.source_document_id=source.id
      and link.link_type='progress' and document.status not in('cancelled','archived') and document.id<>target.id
    order by coalesce(nullif(document.metadata->>'situation_number','')::integer,0) desc,document.created_at desc
    limit 1;

    update public.document_lines line
    set quantity=0,
        cumulative_progress_percent=previous.progress_percent,
        line_metadata=coalesce(line.line_metadata,'{}'::jsonb)||jsonb_build_object(
          'original_quantity',source_line.quantity,
          'original_unit_price',source_line.unit_price,
          'previous_progress_percent',previous.progress_percent,
          'progress_delta_percent',0,
          'progress_placeholder',true,
          'source_quote_id',source.id,
          'situation_number',situation_number
        )
    from public.document_lines source_line
    cross join lateral(
      select coalesce(max(previous_line.cumulative_progress_percent),0) progress_percent
      from public.document_links previous_link
      join public.documents previous_document on previous_document.id=previous_link.target_document_id
        and previous_document.status not in('cancelled','archived') and previous_document.id<>target.id
      join public.document_lines previous_line on previous_line.document_id=previous_document.id
        and previous_line.source_line_id=source_line.id
      where previous_link.company_id=target.company_id and previous_link.source_document_id=source.id
        and previous_link.link_type='progress'
    ) previous
    where line.document_id=target.id and line.source_line_id=source_line.id
      and source_line.document_id=source.id and line.line_type in('item','free_item','discount') and not line.optional;

    update public.documents
    set subject='Situation N'||chr(176)||situation_number||case
          when nullif(trim(coalesce(source.subject,'')),'') is not null then ' - '||source.subject else '' end,
        metadata=(coalesce(metadata,'{}'::jsonb)-'conversion'-'document_kind'-'situation_number'-'previous_situation_id')
          ||jsonb_build_object('conversion','progress','document_kind','progress_invoice',
            'source_quote_id',source.id,'situation_number',situation_number,
            'previous_situation_id',previous_situation_id),
        updated_at=now()
    where id=target.id;

    update public.document_links
    set link_type='progress',metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'situation_number',situation_number,'previous_situation_id',previous_situation_id)
    where company_id=target.company_id and source_document_id=source.id
      and target_document_id=target.id and link_type='invoice';
    if not found then
      insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
      values(target.company_id,source.id,target.id,'progress',jsonb_build_object(
        'situation_number',situation_number,'previous_situation_id',previous_situation_id),auth.uid())
      on conflict(source_document_id,target_document_id,link_type) do update
      set metadata=excluded.metadata;
    end if;
  else
    if coalesce(target.metadata->>'document_kind','')<>'progress_invoice' then
      return jsonb_build_object('id',target.id,'enabled',false,'situation_number',null);
    end if;

    update public.document_lines line
    set quantity=coalesce(nullif(line.line_metadata->>'original_quantity','')::numeric,source_line.quantity),
        cumulative_progress_percent=0,
        line_metadata=coalesce(line.line_metadata,'{}'::jsonb)
          -'original_quantity'-'original_unit_price'-'previous_progress_percent'
          -'progress_delta_percent'-'progress_placeholder'-'source_quote_id'-'situation_number'
    from public.document_lines source_line
    where line.document_id=target.id and line.source_line_id=source_line.id
      and source_line.document_id=source.id and line.line_type in('item','free_item','discount');

    update public.documents
    set subject=source.subject,
        metadata=(coalesce(metadata,'{}'::jsonb)-'conversion'-'document_kind'-'situation_number'-'previous_situation_id')
          ||jsonb_build_object('conversion','full','source_quote_id',source.id),
        updated_at=now()
    where id=target.id;

    update public.document_links
    set link_type='invoice',metadata=coalesce(metadata,'{}'::jsonb)
      -'situation_number'-'previous_situation_id'-'line_progress'
    where company_id=target.company_id and source_document_id=source.id
      and target_document_id=target.id and link_type='progress';
    if not found then
      insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
      values(target.company_id,source.id,target.id,'invoice',jsonb_build_object('source_total_incl_tax',source.total_incl_tax),auth.uid())
      on conflict(source_document_id,target_document_id,link_type) do nothing;
    end if;
  end if;

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(target.company_id,auth.uid(),'document.progress_mode_changed','document',target.id,
    jsonb_build_object('enabled',target_enabled,'source_quote_id',source.id,
      'situation_number',case when target_enabled then situation_number else null end),auth.uid());

  return jsonb_build_object('id',target.id,'enabled',target_enabled,
    'situation_number',case when target_enabled then situation_number else null end);
end
$$;

comment on function public.set_invoice_progress_mode(uuid,boolean) is
  'Transforme atomiquement une facture classique brouillon issue d un devis en situation brouillon, ou inversement.';

revoke all on function public.set_invoice_progress_mode(uuid,boolean) from public,anon;
grant execute on function public.set_invoice_progress_mode(uuid,boolean) to authenticated;

commit;
