-- Factures de situation cumulatives, sans limite de nombre.
-- Migration additive : les devis, factures et situations existants sont conserves.

create or replace function public.create_progress_invoice(target_quote_id uuid,line_progress jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  source public.documents%rowtype;
  target_id uuid;
  existing_id uuid;
  previous_situation_id uuid;
  target_due_date date;
  situation_number integer;
  progress_entry jsonb;
  source_line public.document_lines%rowtype;
  requested numeric;
  previous numeric;
  delta numeric;
  inserted_count integer:=0;
begin
  if line_progress is null or jsonb_typeof(line_progress)<>'array' or jsonb_array_length(line_progress)=0 then
    raise exception 'line_progress_required';
  end if;

  select * into source from public.documents where id=target_quote_id for update;
  if source.id is null or source.document_type<>'quote' or not public.is_company_member(source.company_id) then
    raise exception 'quote_not_found' using errcode='P0002';
  end if;
  if source.number is null or source.status in('rejected','expired','cancelled','archived') then
    raise exception 'quote_number_required';
  end if;

  -- Une situation brouillon existante est reutilisee afin d'eviter les doublons.
  select link.target_document_id into existing_id
  from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id
    and link.link_type='progress' and target.status='draft'
  order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;

  select coalesce(max(case
    when coalesce(target.metadata->>'situation_number','') ~ '^[0-9]+$'
      then (target.metadata->>'situation_number')::integer
    else 0 end),0)+1
  into situation_number
  from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id
    and link.link_type='progress' and target.status not in('cancelled','archived');

  select target.id into previous_situation_id
  from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id
    and link.link_type='progress' and target.status not in('cancelled','archived')
  order by coalesce(nullif(target.metadata->>'situation_number','')::integer,0) desc,target.created_at desc
  limit 1;

  target_due_date:=public.compute_document_due_date(source.company_id,source.payment_terms,current_date);
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,metadata,pipeline_stage,created_by
  ) values(
    source.company_id,'invoice',source.client_id,'draft',current_date,target_due_date,
    'Situation N'||chr(176)||situation_number||case when nullif(trim(coalesce(source.subject,'')),'') is not null then ' - '||source.subject else '' end,
    source.client_reference,source.currency,source.language,source.payment_terms,source.payment_method,
    source.internal_notes,source.public_notes,source.discount_rate,source.id,coalesce(source.root_document_id,source.id),
    source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object(
      'conversion','progress','document_kind','progress_invoice','source_quote_id',source.id,
      'situation_number',situation_number,'previous_situation_id',previous_situation_id
    ),'invoicing',auth.uid()
  ) returning id into target_id;

  for progress_entry in select value from jsonb_array_elements(line_progress) loop
    select * into source_line from public.document_lines
    where id=nullif(progress_entry->>'line_id','')::uuid and document_id=source.id for share;
    if source_line.id is null or source_line.line_type not in('item','free_item','discount') or source_line.optional then
      raise exception 'invalid_progress_line';
    end if;

    requested:=nullif(progress_entry->>'progress_percent','')::numeric;
    select coalesce(max(target_line.cumulative_progress_percent),0) into previous
    from public.document_links link
    join public.documents target on target.id=link.target_document_id and target.status not in('cancelled','archived')
    join public.document_lines target_line on target_line.document_id=target.id and target_line.source_line_id=source_line.id
    where link.source_document_id=source.id and link.link_type='progress';
    if requested is null or requested<=previous or requested>100 then raise exception 'invalid_progress_percent'; end if;

    delta:=requested-previous;
    inserted_count:=inserted_count+1;
    insert into public.document_lines(
      company_id,document_id,position,line_type,item_id,reference,name,description,quantity,unit,
      unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,source_line_id,
      cumulative_progress_percent,line_metadata,created_by
    ) values(
      source.company_id,target_id,source_line.position,source_line.line_type,source_line.item_id,source_line.reference,
      source_line.name,source_line.description,source_line.quantity*delta/100,source_line.unit,
      source_line.unit_cost_snapshot,source_line.unit_price,source_line.discount_rate,source_line.tax_rate,false,
      source_line.id,requested,jsonb_build_object(
        'previous_progress_percent',previous,'progress_delta_percent',delta,
        'original_quantity',source_line.quantity,'original_unit_price',source_line.unit_price,
        'source_quote_id',source.id,'situation_number',situation_number
      ),auth.uid()
    );
  end loop;
  if inserted_count=0 then raise exception 'progress_invoice_empty'; end if;

  -- Les titres, sections et sous-totaux sont recopies pour que l'editeur et le PDF
  -- conservent la structure du devis. Ils ne participent pas aux montants.
  insert into public.document_lines(
    company_id,document_id,position,line_type,section_id,reference,name,description,quantity,unit,
    unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,source_line_id,
    cumulative_progress_percent,line_metadata,created_by
  )
  select source.company_id,target_id,line.position,line.line_type,line.section_id,line.reference,line.name,line.description,
    0,line.unit,0,0,0,0,false,line.id,null,
    coalesce(line.line_metadata,'{}'::jsonb)||jsonb_build_object('source_quote_id',source.id,'situation_number',situation_number),auth.uid()
  from public.document_lines line
  where line.document_id=source.id and line.line_type in('title','subtitle','section','text','comment','subtotal','page_break')
  order by line.position;

  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,'progress',jsonb_build_object(
    'situation_number',situation_number,'previous_situation_id',previous_situation_id,'line_progress',line_progress
  ),auth.uid());

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(source.company_id,auth.uid(),'document.progress_invoice_created','document',target_id,jsonb_build_object(
    'source_quote_id',source.id,'situation_number',situation_number,'previous_situation_id',previous_situation_id
  ),auth.uid());

  update public.documents set status='accepted',accepted_at=coalesce(accepted_at,now()),pipeline_stage='invoicing',updated_at=now()
  where id=source.id;
  return target_id;
end
$$;

comment on function public.create_progress_invoice(uuid,jsonb) is
  'Cree la prochaine facture de situation cumulative d un devis. Numerotation N1, N2, ... sans limite fonctionnelle.';

revoke all on function public.create_progress_invoice(uuid,jsonb) from public,anon;
grant execute on function public.create_progress_invoice(uuid,jsonb) to authenticated;
