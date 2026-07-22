begin;

-- Simplifie le cycle de vie des devis : plus de brouillon. L'enregistrement
-- d'un devis le finalise immédiatement (verrouillage du contenu, snapshot,
-- PDF), avec un statut initial "en attente" (pending). Tant qu'aucune
-- facture n'en découle, le statut peut être basculé manuellement entre
-- "accepté" et "refusé" (ou archivé). Dès qu'une facture, un acompte, une
-- facture de situation ou un solde est créé à partir du devis, celui-ci
-- passe automatiquement à "accepté" et son statut se verrouille
-- définitivement (transition_document_status refuse alors tout changement).

create or replace function public.finalize_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; result_snapshot_id uuid; final_status text;
begin
 select * into doc from public.documents where id=target_document_id for update;
 if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
 if doc.document_type not in('quote','invoice','deposit_invoice','balance_invoice','credit_note') then
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
 if doc.document_type<>'quote' and doc.due_date is null then
   update public.documents set due_date=public.compute_document_due_date(doc.company_id,doc.payment_terms,doc.issue_date)
   where id=doc.id returning * into doc;
 end if;
 final_status:=case when doc.document_type='quote' then 'pending' else 'finalized' end;
 update public.documents set
   status=final_status,validated_at=now(),finalized_at=now(),
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
declare doc public.documents%rowtype; allowed boolean:=false; has_downstream_invoice boolean;
begin
 select * into doc from public.documents where id=target_document_id for update;
 if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
 if target_status=doc.status then return jsonb_build_object('id',doc.id,'status',doc.status); end if;
 if doc.document_type='quote' then
   select exists(
     select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
     where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
       and target.status not in('cancelled','archived')
   ) into has_downstream_invoice;
   if has_downstream_invoice then raise exception 'quote_locked_by_invoice'; end if;
   allowed:=doc.finalized_at is not null and target_status in('accepted','rejected','archived');
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

-- Les 4 conversions devis -> facture forcent désormais le devis source en
-- statut "accepté" (au lieu de "invoiced"/"partially_invoiced", valeurs
-- retirées du nouveau modèle simplifié).

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
    update public.documents set status='accepted',accepted_at=coalesce(accepted_at,now()),pipeline_stage='invoicing',updated_at=now() where id=source.id;
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
  update public.documents set status='accepted',accepted_at=coalesce(accepted_at,now()),pipeline_stage='invoicing',updated_at=now() where id=source.id;
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
  update public.documents set status='accepted',accepted_at=coalesce(accepted_at,now()),pipeline_stage='invoicing',updated_at=now() where id=source.id;
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
  update public.documents set status='accepted',accepted_at=coalesce(accepted_at,now()),pipeline_stage='invoicing',updated_at=now() where id=source.id;
  return target_id;
end
$$;

commit;
