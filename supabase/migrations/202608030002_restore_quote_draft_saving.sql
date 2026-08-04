begin;

-- A quote created by save_document_draft must remain a draft until the user
-- explicitly validates it. Creating it directly as pending made the central
-- document-line permission trigger reject its first line as document_locked.
create or replace function public.save_document_draft(
  target_document_id uuid,target_document jsonb,target_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; target_company_id uuid; target_type text; line_data jsonb;
  saved_id uuid; line_position integer:=0; has_downstream_invoice boolean;
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
    if doc.document_type='quote' then
      select exists(
        select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
        where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
          and target.status not in('cancelled','archived')
      ) into has_downstream_invoice;
      if has_downstream_invoice then raise exception 'quote_locked_by_invoice'; end if;
    elsif doc.status<>'draft' or doc.validated_at is not null or doc.finalized_at is not null then
      raise exception 'document_is_locked';
    end if;
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
  if target_type='quote' then
    perform public._piloz_refresh_quote_snapshot(saved_id);
  end if;
  select * into doc from public.documents where id=saved_id;
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'updated_at',doc.updated_at);
end
$$;

revoke all on function public.save_document_draft(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.save_document_draft(uuid,jsonb,jsonb) to authenticated;

-- Quotes intentionally remain editable while pending (and until an active
-- downstream invoice exists). Invoices keep the strict draft-only rule.
create or replace function public.enforce_document_line_permission()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare
  document_row public.documents%rowtype; target_id uuid; permission_key text; has_downstream_invoice boolean:=false;
begin
  if auth.uid() is null then return case when tg_op='DELETE' then old else new end; end if;
  target_id:=case when tg_op='DELETE' then old.document_id else new.document_id end;
  select * into document_row from public.documents where id=target_id;
  if document_row.id is null then raise exception 'document_not_found' using errcode='23503'; end if;
  permission_key:=case when document_row.document_type='quote' then 'sales.quotes.update_draft'
    when document_row.document_type='credit_note' then 'sales.credit_notes.create'
    when document_row.document_type in('invoice','deposit_invoice','balance_invoice','proforma_invoice','recurring_invoice') then 'sales.invoices.update_draft'
    else 'application.read' end;
  if document_row.document_type='quote' then
    select exists(
      select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
      where link.source_document_id=document_row.id and link.link_type in('invoice','deposit','progress','balance')
        and target.status not in('cancelled','archived')
    ) into has_downstream_invoice;
    if document_row.status in('cancelled','archived') or has_downstream_invoice then
      raise exception 'document_locked' using errcode='42501';
    end if;
  elsif document_row.status<>'draft' or document_row.number is not null then
    raise exception 'document_locked' using errcode='42501';
  end if;
  if not public.has_company_permission(document_row.company_id,permission_key,'own',coalesce(document_row.assigned_user_id,document_row.created_by),document_row.team_id) then
    raise exception 'permission_denied:%',permission_key using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;

commit;
