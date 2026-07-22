begin;

-- Le devis reçoit son numéro commercial dès sa création. Les factures et
-- documents assimilés conservent uniquement leur identifiant de brouillon :
-- leur numéro légal est attribué atomiquement lors de la finalisation.
-- draft_number reste volontairement présent pour les brouillons historiques.

-- ---------------------------------------------------------------------------
-- 1. Numéro officiel attribué dès l'enregistrement initial, quel que soit le
--    chemin d'insertion (RPC atomique ou insertion REST directe de secours).
-- ---------------------------------------------------------------------------

create or replace function public.assign_document_number()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.number is null and new.document_type='quote' then
    new.number:=public._piloz_take_document_number(
      new.company_id,new.document_type,extract(year from coalesce(new.issue_date,current_date))::integer,false
    );
  end if;
  return new;
end
$$;
drop trigger if exists documents_assign_document_number on public.documents;
create trigger documents_assign_document_number before insert on public.documents
  for each row execute function public.assign_document_number();
revoke all on function public.assign_document_number() from public,anon,authenticated;

do $number_backfill$
declare doc record;
begin
  for doc in select id,company_id,document_type,issue_date from public.documents
    where number is null and document_type='quote' order by company_id,created_at,id
  loop
    update public.documents set number=public._piloz_take_document_number(
      doc.company_id,doc.document_type,extract(year from coalesce(doc.issue_date,current_date))::integer,false
    ) where id=doc.id;
  end loop;
end
$number_backfill$;

-- ---------------------------------------------------------------------------
-- 2. Le devis n'est plus jamais finalisé/verrouillé ; la facture le reste
-- ---------------------------------------------------------------------------

create or replace function public.finalize_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; result_snapshot_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    raise exception 'document_type_cannot_be_finalized';
  end if;
  if doc.finalized_at is not null then
    return jsonb_build_object('id',doc.id,'number',doc.number,
      'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',doc.snapshot_id,'pdf_status',doc.pdf_status);
  end if;
  if doc.status not in('draft','to_finalize') or doc.validated_at is not null then raise exception 'invalid_document_state'; end if;
  if doc.number is null then raise exception 'document_number_missing'; end if;
  if not public.is_company_onboarded(doc.company_id) then raise exception 'company_onboarding_required' using errcode='42501'; end if;
  if doc.client_id is null or not exists(select 1 from public.clients where id=doc.client_id and company_id=doc.company_id and active) then
    raise exception 'document_client_required';
  end if;
  if not exists(select 1 from public.document_lines where document_id=doc.id and line_type in('item','free_item','discount')
    and not optional and nullif(trim(coalesce(name,'')),'') is not null and quantity>0) then
    raise exception 'document_lines_required';
  end if;
  if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then raise exception 'document_total_must_be_positive'; end if;
  if doc.due_date is null then
    update public.documents set due_date=public.compute_document_due_date(doc.company_id,doc.payment_terms,doc.issue_date)
    where id=doc.id returning * into doc;
  end if;
  update public.documents set
    status='finalized',validated_at=now(),finalized_at=now(),
    finalized_by=auth.uid(),locked_at=now(),pdf_status='pending',updated_at=now()
  where id=doc.id returning * into doc;
  result_snapshot_id:=public._piloz_create_document_snapshot(doc.id);
  update public.documents set snapshot_id=result_snapshot_id,updated_at=now() where id=doc.id returning * into doc;
  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by)
  values(doc.company_id,doc.id,result_snapshot_id,'pending',coalesce(auth.uid(),doc.created_by))
  on conflict(snapshot_id) do nothing;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.finalized','document',doc.id,
    jsonb_build_object('number',doc.number,'document_type',doc.document_type,'snapshot_id',result_snapshot_id),auth.uid());
  return jsonb_build_object('id',doc.id,'number',doc.number,
    'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',result_snapshot_id,'pdf_status',doc.pdf_status);
end
$$;

create or replace function public.transition_document_status(target_document_id uuid,target_status text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; allowed boolean:=false;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if target_status=doc.status then return jsonb_build_object('id',doc.id,'status',doc.status); end if;
  if doc.document_type='quote' then
    allowed:=target_status in('sent','pending','accepted','rejected','expired','invoiced','partially_invoiced','cancelled','archived');
  elsif doc.finalized_at is null then
    allowed:=doc.status='draft' and target_status in('to_finalize','cancelled','archived');
  elsif doc.document_type in('invoice','deposit_invoice','balance_invoice','credit_note') then
    allowed:=target_status in('finalized','sent','overdue','archived');
  end if;
  if not allowed then raise exception 'invalid_document_status_transition'; end if;
  update public.documents set status=target_status,
    sent_at=case when target_status='sent' then coalesce(sent_at,now()) else sent_at end,
    accepted_at=case when target_status='accepted' then coalesce(accepted_at,now()) else accepted_at end,
    rejected_at=case when target_status='rejected' then coalesce(rejected_at,now()) else rejected_at end,
    expired_at=case when target_status='expired' then coalesce(expired_at,now()) else expired_at end,
    archived_at=case when target_status='archived' then coalesce(archived_at,now()) else archived_at end,
    updated_at=now() where id=doc.id returning * into doc;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.status_changed','document',doc.id,
    jsonb_build_object('status',target_status),auth.uid());
  return jsonb_build_object('id',doc.id,'status',doc.status,'sent_at',doc.sent_at,
    'accepted_at',doc.accepted_at,'rejected_at',doc.rejected_at,'expired_at',doc.expired_at);
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Conversions : le devis n'a plus besoin d'être finalisé, seul son
--    numéro officiel (attribué dès sa création) est requis. Les documents
--    créés par conversion reçoivent eux aussi leur numéro immédiatement via
--    le trigger générique ci-dessus, sans changement de leurs insertions.
-- ---------------------------------------------------------------------------

create or replace function public.convert_quote_to_invoice(
  target_quote_id uuid,target_invoice_type text default 'invoice'
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; target_id uuid; link_kind text; existing_id uuid; target_due_date date;
begin
  if target_invoice_type not in('invoice','proforma_invoice') then
    raise exception 'use_specialized_invoice_creation_rpc';
  end if;
  select * into source from public.documents where id=target_quote_id for update;
  if source.id is null or source.document_type<>'quote' or not public.is_company_member(source.company_id) then
    raise exception 'quote_not_found' using errcode='P0002';
  end if;
  if source.number is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_number_required'; end if;
  link_kind:=case when target_invoice_type='proforma_invoice' then 'proforma' else 'invoice' end;
  select link.target_document_id into existing_id from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id and link.link_type=link_kind
    and target.status not in('cancelled','archived')
  order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;
  target_due_date:=public.compute_document_due_date(source.company_id,source.payment_terms,current_date);
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,metadata,pipeline_stage,created_by
  ) values(
    source.company_id,target_invoice_type,source.client_id,'draft',current_date,target_due_date,source.subject,
    source.client_reference,source.currency,source.language,source.payment_terms,source.payment_method,
    source.internal_notes,source.public_notes,source.discount_rate,source.id,coalesce(source.root_document_id,source.id),
    source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    source.metadata||jsonb_build_object('conversion','full','source_quote_id',source.id),
    'invoicing',auth.uid()
  ) returning id into target_id;
  perform public._piloz_copy_document_lines(source.id,target_id);
  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,link_kind,jsonb_build_object('source_total_incl_tax',source.total_incl_tax),auth.uid())
  on conflict(source_document_id,target_document_id,link_type) do nothing;
  if target_invoice_type='invoice' then
    update public.documents set status='invoiced',pipeline_stage='invoicing',updated_at=now() where id=source.id;
  end if;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(source.company_id,auth.uid(),'quote.converted','document',source.id,
    jsonb_build_object('target_document_id',target_id,'target_type',target_invoice_type),auth.uid());
  return target_id;
end
$$;

create or replace function public.create_deposit_invoice(
  target_quote_id uuid,deposit_percent numeric default null,deposit_amount numeric default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  source public.documents%rowtype; target_id uuid; existing_id uuid; ratio numeric;
  requested_ttc numeric; already_invoiced numeric; remaining_ttc numeric; target_due_date date;
begin
  if (deposit_percent is null)=(deposit_amount is null) then raise exception 'provide_deposit_percent_or_amount'; end if;
  select * into source from public.documents where id=target_quote_id for update;
  if source.id is null or source.document_type<>'quote' or not public.is_company_member(source.company_id) then
    raise exception 'quote_not_found' using errcode='P0002';
  end if;
  if source.number is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_number_required'; end if;
  select link.target_document_id into existing_id from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id and link.link_type='deposit'
    and target.status='draft' order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;
  select coalesce(sum(target.total_incl_tax),0) into already_invoiced
  from public.document_links link join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id
    and link.link_type in('invoice','deposit','progress','balance') and target.status not in('cancelled','archived');
  remaining_ttc:=greatest(source.total_incl_tax-already_invoiced,0);
  if deposit_percent is not null then
    if deposit_percent<=0 or deposit_percent>100 then raise exception 'invalid_deposit_percent'; end if;
    requested_ttc:=round(source.total_incl_tax*deposit_percent/100,2);
  else
    if deposit_amount<=0 then raise exception 'invalid_deposit_amount'; end if;
    requested_ttc:=round(deposit_amount,2);
  end if;
  if requested_ttc>remaining_ttc+0.01 then raise exception 'deposit_exceeds_remaining_to_invoice'; end if;
  ratio:=requested_ttc/source.total_incl_tax;
  target_due_date:=public.compute_document_due_date(source.company_id,source.payment_terms,current_date);
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,deposit_rate,metadata,pipeline_stage,created_by
  ) values(
    source.company_id,'deposit_invoice',source.client_id,'draft',current_date,target_due_date,
    coalesce(source.subject,'Acompte'),source.client_reference,source.currency,source.language,
    source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,0,source.id,
    coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    round(ratio*100,2),source.metadata||jsonb_build_object('conversion','deposit','source_quote_id',source.id,
      'deposit_percent',round(ratio*100,2),'deposit_amount_ttc',requested_ttc),'invoicing',auth.uid()
  ) returning id into target_id;
  insert into public.document_lines(
    company_id,document_id,position,line_type,name,quantity,unit,unit_price,tax_rate,source_line_id,line_metadata,created_by
  )
  select source.company_id,target_id,row_number() over(order by grouped.tax_rate)::integer,'free_item',
    'Acompte de '||trim(to_char(round(ratio*100,2),'FM999990D00'))||' %',1,'forfait',
    round(grouped.total_ht*ratio*(1-source.discount_rate/100),2),grouped.tax_rate,null,
    jsonb_build_object('source_quote_id',source.id,'deposit_ratio',ratio),auth.uid()
  from(
    select tax_rate,sum(total_excl_tax) total_ht from public.document_lines
    where document_id=source.id and line_type in('item','free_item','discount') and not optional group by tax_rate
  )grouped;
  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,'deposit',jsonb_build_object('percent',round(ratio*100,2),'amount_ttc',requested_ttc),auth.uid());
  update public.documents set status=case when status='invoiced' then status else 'partially_invoiced' end,
    pipeline_stage='invoicing',updated_at=now() where id=source.id;
  return target_id;
end
$$;

create or replace function public.create_progress_invoice(target_quote_id uuid,line_progress jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  source public.documents%rowtype; target_id uuid; existing_id uuid; target_due_date date;
  progress_entry jsonb; source_line public.document_lines%rowtype; requested numeric; previous numeric; delta numeric;
  inserted_count integer:=0;
begin
  if line_progress is null or jsonb_typeof(line_progress)<>'array' or jsonb_array_length(line_progress)=0 then
    raise exception 'line_progress_required';
  end if;
  select * into source from public.documents where id=target_quote_id for update;
  if source.id is null or source.document_type<>'quote' or not public.is_company_member(source.company_id) then
    raise exception 'quote_not_found' using errcode='P0002';
  end if;
  if source.number is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_number_required'; end if;
  select link.target_document_id into existing_id from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.company_id=source.company_id and link.source_document_id=source.id and link.link_type='progress'
    and target.status='draft' order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;
  target_due_date:=public.compute_document_due_date(source.company_id,source.payment_terms,current_date);
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,metadata,pipeline_stage,created_by
  ) values(
    source.company_id,'invoice',source.client_id,'draft',current_date,target_due_date,
    coalesce(source.subject,'Facture de situation'),source.client_reference,source.currency,source.language,
    source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,source.discount_rate,source.id,
    coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    source.metadata||jsonb_build_object('conversion','progress','source_quote_id',source.id),'invoicing',auth.uid()
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
    delta:=requested-previous; inserted_count:=inserted_count+1;
    insert into public.document_lines(
      company_id,document_id,position,line_type,item_id,reference,name,description,quantity,unit,
      unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,source_line_id,
      cumulative_progress_percent,line_metadata,created_by
    ) values(
      source.company_id,target_id,inserted_count,source_line.line_type,source_line.item_id,source_line.reference,
      source_line.name,source_line.description,source_line.quantity*delta/100,source_line.unit,
      source_line.unit_cost_snapshot,source_line.unit_price,source_line.discount_rate,source_line.tax_rate,false,
      source_line.id,requested,jsonb_build_object('previous_progress_percent',previous,'progress_delta_percent',delta),auth.uid()
    );
  end loop;
  if inserted_count=0 then raise exception 'progress_invoice_empty'; end if;
  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,'progress',jsonb_build_object('line_progress',line_progress),auth.uid());
  update public.documents set status=case when status='invoiced' then status else 'partially_invoiced' end,
    pipeline_stage='invoicing',updated_at=now() where id=source.id;
  return target_id;
end
$$;

create or replace function public.create_balance_invoice(target_quote_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; target_id uuid; existing_id uuid; target_due_date date; remaining_ttc numeric;
begin
  select * into source from public.documents where id=target_quote_id for update;
  if source.id is null or source.document_type<>'quote' or not public.is_company_member(source.company_id) then
    raise exception 'quote_not_found' using errcode='P0002';
  end if;
  if source.number is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_number_required'; end if;
  select link.target_document_id into existing_id from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.source_document_id=source.id and link.link_type='balance' and target.status not in('cancelled','archived')
  order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;
  select source.total_incl_tax-coalesce(sum(target.total_incl_tax),0) into remaining_ttc
  from public.document_links link join public.documents target on target.id=link.target_document_id
  where link.source_document_id=source.id and link.link_type in('invoice','deposit','progress')
    and target.status not in('cancelled','archived');
  remaining_ttc:=coalesce(remaining_ttc,source.total_incl_tax);
  if remaining_ttc<=0.01 then raise exception 'nothing_left_to_invoice'; end if;
  target_due_date:=public.compute_document_due_date(source.company_id,source.payment_terms,current_date);
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,metadata,pipeline_stage,created_by
  ) values(
    source.company_id,'balance_invoice',source.client_id,'draft',current_date,target_due_date,
    coalesce(source.subject,'Facture de solde'),source.client_reference,source.currency,source.language,
    source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,0,source.id,
    coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    source.metadata||jsonb_build_object('conversion','balance','source_quote_id',source.id),'invoicing',auth.uid()
  ) returning id into target_id;
  insert into public.document_lines(company_id,document_id,position,line_type,name,quantity,unit,unit_price,tax_rate,line_metadata,created_by)
  select source.company_id,target_id,row_number() over(order by quote_group.tax_rate)::integer,'free_item',
    'Solde du devis '||source.number,1,'forfait',greatest(quote_group.quote_ht-coalesce(billed.billed_ht,0),0),
    quote_group.tax_rate,jsonb_build_object('source_quote_id',source.id,'balance',true),auth.uid()
  from(
    select tax_rate,sum(total_excl_tax)*(1-source.discount_rate/100) quote_ht from public.document_lines
    where document_id=source.id and line_type in('item','free_item','discount') and not optional group by tax_rate
  )quote_group
  left join lateral(
    select sum(target_line.total_excl_tax*(1-target.discount_rate/100)) billed_ht
    from public.document_links link join public.documents target on target.id=link.target_document_id
    join public.document_lines target_line on target_line.document_id=target.id
    where link.source_document_id=source.id and link.link_type in('invoice','deposit','progress')
      and target.status not in('cancelled','archived') and target_line.tax_rate=quote_group.tax_rate
  )billed on true
  where quote_group.quote_ht-coalesce(billed.billed_ht,0)>0.005;
  if not exists(select 1 from public.document_lines where document_id=target_id) then raise exception 'nothing_left_to_invoice'; end if;
  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,'balance',jsonb_build_object('remaining_ttc',remaining_ttc),auth.uid());
  update public.documents set status='invoiced',pipeline_stage='invoicing',updated_at=now() where id=source.id;
  return target_id;
end
$$;

create or replace function public.create_credit_note(
  target_invoice_id uuid,credit_reason text,line_adjustments jsonb default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; target_id uuid; existing_id uuid; adjustment jsonb;
  source_line public.document_lines%rowtype; position_value integer:=0; already_credited numeric; available_credit numeric;
begin
  if nullif(trim(credit_reason),'') is null then raise exception 'credit_reason_required'; end if;
  select * into source from public.documents where id=target_invoice_id for update;
  if source.id is null or source.document_type not in('invoice','deposit_invoice','balance_invoice')
    or not public.is_company_member(source.company_id) then raise exception 'invoice_not_found' using errcode='P0002'; end if;
  if source.finalized_at is null and source.validated_at is null then raise exception 'invoice_must_be_finalized'; end if;
  select link.target_document_id into existing_id from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.source_document_id=source.id and link.link_type='credit_note' and target.status='draft'
  order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;
  select coalesce(sum(target.total_incl_tax),0) into already_credited
  from public.document_links link join public.documents target on target.id=link.target_document_id
  where link.source_document_id=source.id and link.link_type='credit_note' and target.status not in('cancelled','archived');
  available_credit:=greatest(source.total_incl_tax-already_credited,0);
  if available_credit<=0.01 then raise exception 'invoice_already_fully_credited'; end if;
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,metadata,created_by
  ) values(
    source.company_id,'credit_note',source.client_id,'draft',current_date,current_date,
    'Avoir — '||source.number,source.client_reference,source.currency,source.language,
    source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,source.discount_rate,source.id,
    coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    source.metadata||jsonb_build_object('conversion','credit_note','source_invoice_id',source.id,'credit_reason',trim(credit_reason)),auth.uid()
  ) returning id into target_id;
  if line_adjustments is null then
    perform public._piloz_copy_document_lines(source.id,target_id);
  else
    if jsonb_typeof(line_adjustments)<>'array' or jsonb_array_length(line_adjustments)=0 then raise exception 'line_adjustments_required'; end if;
    for adjustment in select value from jsonb_array_elements(line_adjustments) loop
      select * into source_line from public.document_lines
      where id=nullif(adjustment->>'line_id','')::uuid and document_id=source.id;
      if source_line.id is null or source_line.line_type not in('item','free_item','discount') then raise exception 'invalid_credit_line'; end if;
      position_value:=position_value+1;
      insert into public.document_lines(
        company_id,document_id,position,line_type,item_id,reference,name,description,quantity,unit,
        unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,source_line_id,line_metadata,created_by
      ) values(
        source.company_id,target_id,position_value,source_line.line_type,source_line.item_id,source_line.reference,
        source_line.name,source_line.description,
        least(coalesce(nullif(adjustment->>'quantity','')::numeric,source_line.quantity),source_line.quantity),source_line.unit,
        source_line.unit_cost_snapshot,coalesce(nullif(adjustment->>'unit_price','')::numeric,source_line.unit_price),
        source_line.discount_rate,source_line.tax_rate,false,source_line.id,
        jsonb_build_object('credit_reason',trim(credit_reason)),auth.uid()
      );
    end loop;
  end if;
  if (select total_incl_tax from public.documents where id=target_id)>available_credit+0.01 then raise exception 'credit_exceeds_invoice_balance'; end if;
  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,'credit_note',jsonb_build_object('reason',trim(credit_reason)),auth.uid());
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(source.company_id,auth.uid(),'credit_note.created','document',target_id,
    jsonb_build_object('source_invoice_id',source.id,'reason',trim(credit_reason)),auth.uid());
  return target_id;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. save_document_draft n'a plus besoin d'attribuer explicitement le numéro
--    (le trigger générique s'en charge désormais à l'insertion), la fonction
--    est donc republiée uniquement pour retirer draft_number de son retour.
-- ---------------------------------------------------------------------------

create or replace function public.save_document_draft(
  target_document_id uuid,target_document jsonb,target_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; target_company_id uuid; target_type text; line_data jsonb;
  saved_id uuid; line_position integer:=0;
begin
  if target_document is null or jsonb_typeof(coalesce(target_lines,'[]'::jsonb))<>'array' then
    raise exception 'invalid_document_payload';
  end if;
  if target_document_id is null then
    target_company_id:=nullif(target_document->>'company_id','')::uuid;
    target_type:=coalesce(nullif(target_document->>'document_type',''),'quote');
    if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
    if target_type not in('quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice') then raise exception 'invalid_document_type'; end if;
    insert into public.documents(
      company_id,document_type,version,client_id,status,issue_date,due_date,validity_date,subject,client_reference,
      currency,language,payment_terms,payment_method,internal_notes,public_notes,discount_rate,
      source_document_id,root_document_id,version_reason,sale_type,opportunity_id,assigned_user_id,
      template_id,deposit_rate,pipeline_stage,metadata,created_by
    ) values(
      target_company_id,target_type,coalesce(nullif(target_document->>'version','')::integer,1),
      nullif(target_document->>'client_id','')::uuid,'draft',
      coalesce(nullif(target_document->>'issue_date','')::date,current_date),
      nullif(target_document->>'due_date','')::date,nullif(target_document->>'validity_date','')::date,
      nullif(target_document->>'subject',''),nullif(target_document->>'client_reference',''),
      coalesce(nullif(target_document->>'currency',''),'EUR'),
      coalesce(nullif(target_document->>'language',''),'fr'),nullif(target_document->>'payment_terms',''),
      nullif(target_document->>'payment_method',''),nullif(target_document->>'internal_notes',''),
      nullif(target_document->>'public_notes',''),coalesce(nullif(target_document->>'discount_rate','')::numeric,0),
      nullif(target_document->>'source_document_id','')::uuid,nullif(target_document->>'root_document_id','')::uuid,
      nullif(target_document->>'version_reason',''),nullif(target_document->>'sale_type',''),
      nullif(target_document->>'opportunity_id','')::uuid,nullif(target_document->>'assigned_user_id','')::uuid,
      nullif(target_document->>'template_id','')::uuid,coalesce(nullif(target_document->>'deposit_rate','')::numeric,0),
      coalesce(nullif(target_document->>'pipeline_stage',''),'draft'),
      case when nullif(target_document->>'pipeline_stage','') is null then coalesce(target_document->'metadata','{}'::jsonb)
        else jsonb_set(coalesce(target_document->'metadata','{}'::jsonb),'{pipeline_stage}',to_jsonb(target_document->>'pipeline_stage'),true) end,
      auth.uid()
    ) returning id into saved_id;
  else
    select * into doc from public.documents where id=target_document_id for update;
    if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
    if doc.status<>'draft' or doc.validated_at is not null or doc.finalized_at is not null then raise exception 'document_is_locked'; end if;
    target_company_id:=doc.company_id; target_type:=doc.document_type; saved_id:=doc.id;
    if nullif(target_document->>'document_type','') is not null and target_document->>'document_type'<>doc.document_type then
      raise exception 'document_type_is_immutable';
    end if;
    update public.documents set
      version=coalesce(nullif(target_document->>'version','')::integer,version),
      client_id=nullif(target_document->>'client_id','')::uuid,
      issue_date=coalesce(nullif(target_document->>'issue_date','')::date,issue_date),
      due_date=nullif(target_document->>'due_date','')::date,
      validity_date=nullif(target_document->>'validity_date','')::date,
      subject=nullif(target_document->>'subject',''),client_reference=nullif(target_document->>'client_reference',''),
      currency=coalesce(nullif(target_document->>'currency',''),currency),
      language=coalesce(nullif(target_document->>'language',''),language),payment_terms=nullif(target_document->>'payment_terms',''),
      payment_method=nullif(target_document->>'payment_method',''),internal_notes=nullif(target_document->>'internal_notes',''),
      public_notes=nullif(target_document->>'public_notes',''),discount_rate=coalesce(nullif(target_document->>'discount_rate','')::numeric,0),
      source_document_id=nullif(target_document->>'source_document_id','')::uuid,
      root_document_id=nullif(target_document->>'root_document_id','')::uuid,version_reason=nullif(target_document->>'version_reason',''),
      sale_type=nullif(target_document->>'sale_type',''),opportunity_id=nullif(target_document->>'opportunity_id','')::uuid,
      assigned_user_id=nullif(target_document->>'assigned_user_id','')::uuid,template_id=nullif(target_document->>'template_id','')::uuid,
      deposit_rate=coalesce(nullif(target_document->>'deposit_rate','')::numeric,0),
      pipeline_stage=coalesce(nullif(target_document->>'pipeline_stage',''),pipeline_stage),
      metadata=case when nullif(target_document->>'pipeline_stage','') is null then coalesce(target_document->'metadata','{}'::jsonb)
        else jsonb_set(coalesce(target_document->'metadata','{}'::jsonb),'{pipeline_stage}',to_jsonb(target_document->>'pipeline_stage'),true) end,
      updated_at=now()
    where id=saved_id;
    delete from public.document_lines where document_id=saved_id;
  end if;

  for line_data in select value from jsonb_array_elements(coalesce(target_lines,'[]'::jsonb)) loop
    line_position:=line_position+1;
    insert into public.document_lines(
      id,company_id,document_id,position,line_type,section_id,item_id,reference,name,description,
      quantity,unit,unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,
      source_line_id,cumulative_progress_percent,line_metadata,created_by
    ) values(
      coalesce(nullif(line_data->>'id','')::uuid,gen_random_uuid()),target_company_id,saved_id,
      coalesce(nullif(line_data->>'position','')::integer,line_position),coalesce(nullif(line_data->>'line_type',''),'item'),
      nullif(line_data->>'section_id','')::uuid,nullif(line_data->>'item_id','')::uuid,
      nullif(line_data->>'reference',''),nullif(line_data->>'name',''),nullif(line_data->>'description',''),
      coalesce(nullif(line_data->>'quantity','')::numeric,1),nullif(line_data->>'unit',''),
      coalesce(nullif(line_data->>'unit_cost_snapshot','')::numeric,0),coalesce(nullif(line_data->>'unit_price','')::numeric,0),
      coalesce(nullif(line_data->>'discount_rate','')::numeric,0),coalesce(nullif(line_data->>'tax_rate','')::numeric,0),
      coalesce((line_data->>'optional')::boolean,false),nullif(line_data->>'source_line_id','')::uuid,
      nullif(line_data->>'cumulative_progress_percent','')::numeric,coalesce(line_data->'line_metadata','{}'::jsonb),auth.uid()
    );
  end loop;
  select * into doc from public.documents where id=saved_id;
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'updated_at',doc.updated_at);
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Vue pipeline : la colonne draft_number disparaît, number suffit
-- ---------------------------------------------------------------------------

drop view if exists public.document_pipeline_view;
create view public.document_pipeline_view with (security_invoker=true) as
select
  quote.company_id,quote.id quote_document_id,quote.number,quote.subject,
  quote.client_id,client.legal_name client_legal_name,client.first_name client_first_name,client.last_name client_last_name,
  quote.total_excl_tax,quote.total_incl_tax,quote.status,quote.pipeline_stage,
  quote.assigned_user_id,quote.validity_date,item.next_activity_at,
  coalesce(metrics.invoice_count,0) invoice_count,coalesce(metrics.total_invoiced,0) total_invoiced,
  coalesce(metrics.total_collected,0) total_collected,
  greatest(coalesce(metrics.total_invoiced,0)-coalesce(metrics.total_collected,0),0) remaining_to_collect,
  greatest(quote.total_incl_tax-coalesce(metrics.total_invoiced,0),0) remaining_to_invoice,
  coalesce(metrics.linked_documents,'[]'::jsonb) linked_documents
from public.documents quote
left join public.clients client on client.id=quote.client_id and client.company_id=quote.company_id
left join public.pipeline_items item on item.quote_document_id=quote.id and item.company_id=quote.company_id
left join lateral(
  select count(*) invoice_count,coalesce(sum(invoice.total_incl_tax),0) total_invoiced,
    coalesce(sum(payment_totals.paid),0) total_collected,
    jsonb_agg(jsonb_build_object('id',invoice.id,'type',invoice.document_type,'number',invoice.number,
      'status',invoice.status,'total_incl_tax',invoice.total_incl_tax)
      order by invoice.created_at) linked_documents
  from public.documents invoice
  left join lateral(select sum(payment.amount) paid from public.payments payment
    where payment.document_id=invoice.id and payment.status='confirmed')payment_totals on true
  where invoice.company_id=quote.company_id and invoice.source_document_id=quote.id
    and invoice.document_type in('invoice','deposit_invoice','balance_invoice')
    and invoice.status not in('cancelled','archived')
)metrics on true
where quote.document_type='quote' and quote.archived_at is null;

grant select on public.document_pipeline_view to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Compatibilité des brouillons historiques
-- ---------------------------------------------------------------------------

-- La colonne et son index sont conservés : aucune donnée existante n'est
-- supprimée par cette migration.

commit;
