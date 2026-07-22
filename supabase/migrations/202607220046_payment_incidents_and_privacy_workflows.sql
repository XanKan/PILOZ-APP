begin;

-- Phase 9 - complete the append-only payment incident workflow and make
-- data-subject requests operational. This migration never deletes business
-- or personal data and does not enable any retention action automatically.

drop index if exists public.payments_single_full_reversal_idx;
create index if not exists payments_reversal_lookup_idx
  on public.payments(company_id,reverses_payment_id,created_at)
  where reverses_payment_id is not null;

create or replace function public.record_document_payment_reversal(
  target_payment_id uuid,
  target_entry_type text,
  target_amount numeric,
  target_reason text,
  target_effective_at timestamptz default now()
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  original public.payments%rowtype;
  config public.company_fiscal_configurations%rowtype;
  reversal_id uuid:=gen_random_uuid();
  already_reversed numeric:=0;
  remaining_reversible numeric:=0;
  reversal_amount numeric;
  event_id uuid;
  event_name text;
  payload jsonb;
  payload_digest text;
begin
  if target_entry_type not in('correction','refund','rejection','chargeback') then
    raise exception 'invalid_payment_reversal_type';
  end if;
  if nullif(trim(target_reason),'') is null then
    raise exception 'payment_reversal_reason_required';
  end if;

  select * into original from public.payments where id=target_payment_id for update;
  if original.id is null or original.status<>'confirmed'
    or original.entry_type not in('payment','overpayment') then
    raise exception 'invalid_payment_state';
  end if;
  if not public.has_company_permission(original.company_id,'record_payment') then
    raise exception 'missing_permission:record_payment' using errcode='42501';
  end if;

  select coalesce(-sum(amount),0) into already_reversed
  from public.payments
  where reverses_payment_id=original.id and status='confirmed'
    and entry_type in('correction','refund','rejection','chargeback');
  remaining_reversible:=round(greatest(original.amount-already_reversed,0),2);
  reversal_amount:=round(coalesce(target_amount,remaining_reversible),2);
  if reversal_amount<=0 then raise exception 'payment_already_fully_reversed'; end if;
  if reversal_amount>remaining_reversible+0.005 then
    raise exception 'payment_reversal_exceeds_remaining_amount';
  end if;

  select * into config from public.company_fiscal_configurations where company_id=original.company_id;
  event_name:=case target_entry_type
    when 'refund' then 'payment_refunded'
    when 'rejection' then 'payment_rejected'
    when 'chargeback' then 'payment_chargeback_recorded'
    else 'payment_corrected'
  end;
  payload:=jsonb_build_object(
    'reversal_id',reversal_id,'reverses_payment_id',original.id,
    'document_id',original.document_id,'entry_type',target_entry_type,
    'amount',-reversal_amount,'currency',original.currency,
    'effective_at',coalesce(target_effective_at,now()),'reason',trim(target_reason),
    'remaining_reversible_after',round(remaining_reversible-reversal_amount,2)
  );
  payload_digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  event_id:=public._append_fiscal_event(
    original.company_id,event_name,'payment',reversal_id,
    coalesce(target_effective_at,now()),payload,'rpc','{}'::jsonb
  );
  insert into public.payments(
    id,company_id,document_id,amount,currency,paid_at,payment_method,reference,
    status,comment,entry_type,reverses_payment_id,correction_reason,fiscal_event_id,
    payload_hash,application_version,schema_version,created_by
  ) values(
    reversal_id,original.company_id,original.document_id,-reversal_amount,original.currency,
    coalesce(target_effective_at,now()),original.payment_method,original.reference,'confirmed',
    initcap(target_entry_type)||' : '||trim(target_reason),target_entry_type,original.id,
    trim(target_reason),event_id,payload_digest,
    coalesce(config.application_version,'0.9.0-compliance.3'),'202607220046',auth.uid()
  );
  perform public._rebuild_document_payment_projection(original.document_id);
  return reversal_id;
end
$$;

create or replace function public.cancel_document_payment(target_payment_id uuid,cancellation_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
begin
  return public.record_document_payment_reversal(
    target_payment_id,'correction',null,cancellation_reason,clock_timestamp()
  );
end
$$;

create or replace function public.record_document_receipt(
  target_document_id uuid,
  received_amount numeric,
  payment_method text default null,
  payment_reference text default null,
  payment_date timestamptz default now(),
  payment_comment text default null
) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype;
  config public.company_fiscal_configurations%rowtype;
  paid numeric:=0;
  balance numeric:=0;
  allocated numeric:=0;
  excess numeric:=0;
  payment_id uuid;
  overpayment_id uuid;
  event_id uuid;
  payload jsonb;
  payload_digest text;
begin
  if received_amount is null or received_amount<=0 then raise exception 'invalid_payment_amount'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.document_type not in('invoice','deposit_invoice','balance_invoice')
    or doc.finalized_at is null or doc.status in('draft','cancelled','archived') then
    raise exception 'invalid_invoice_state';
  end if;
  if not public.has_company_permission(doc.company_id,'record_payment') then
    raise exception 'missing_permission:record_payment' using errcode='42501';
  end if;
  select coalesce(sum(amount),0) into paid from public.payments
  where document_id=doc.id and status='confirmed';
  balance:=round(greatest(doc.total_incl_tax-paid,0),2);
  allocated:=round(least(received_amount,balance),2);
  excess:=round(greatest(received_amount-allocated,0),2);
  if allocated>0 then
    payment_id:=public.record_document_payment_v2(
      doc.id,allocated,payment_method,payment_reference,payment_date,payment_comment
    );
  end if;
  if excess>0 then
    overpayment_id:=gen_random_uuid();
    select * into config from public.company_fiscal_configurations where company_id=doc.company_id;
    payload:=jsonb_build_object(
      'payment_id',overpayment_id,'document_id',doc.id,'document_number',doc.number,
      'client_id',doc.client_id,'entry_type','overpayment','amount',excess,
      'currency',doc.currency,'paid_at',coalesce(payment_date,now()),
      'payment_method',payment_method,'reference',payment_reference,
      'allocated_amount',allocated,'comment_present',nullif(trim(payment_comment),'') is not null
    );
    payload_digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
    event_id:=public._append_fiscal_event(
      doc.company_id,'payment_overpayment_recorded','payment',overpayment_id,
      coalesce(payment_date,now()),payload,'rpc','{}'::jsonb
    );
    insert into public.payments(
      id,company_id,document_id,amount,currency,paid_at,payment_method,reference,
      status,comment,entry_type,fiscal_event_id,payload_hash,application_version,
      schema_version,created_by
    ) values(
      overpayment_id,doc.company_id,doc.id,excess,doc.currency,coalesce(payment_date,now()),
      nullif(trim(payment_method),''),nullif(trim(payment_reference),''),'confirmed',
      nullif(trim(payment_comment),''),'overpayment',event_id,payload_digest,
      coalesce(config.application_version,'0.9.0-compliance.3'),'202607220046',auth.uid()
    );
    perform public._rebuild_document_payment_projection(doc.id);
  end if;
  return jsonb_build_object(
    'payment_id',payment_id,'overpayment_id',overpayment_id,
    'received_amount',round(received_amount,2),'allocated_amount',allocated,
    'overpayment_amount',excess,'currency',doc.currency
  );
end
$$;

revoke all on function public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz) from public,anon;
revoke all on function public.record_document_receipt(uuid,numeric,text,text,timestamptz,text) from public,anon;
revoke all on function public.cancel_document_payment(uuid,text) from public,anon;
grant execute on function public.record_document_payment_reversal(uuid,text,numeric,text,timestamptz) to authenticated;
grant execute on function public.record_document_receipt(uuid,numeric,text,text,timestamptz,text) to authenticated;
grant execute on function public.cancel_document_payment(uuid,text) to authenticated;

create table if not exists public.data_subject_request_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  request_id uuid not null references public.data_subject_requests(id) on delete restrict,
  event_type text not null check(event_type in(
    'created','identity_verified','status_changed','decision_recorded','export_generated','response_recorded'
  )),
  previous_status text,
  new_status text,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  actor_id uuid,
  occurred_at timestamptz not null default now()
);

create table if not exists public.data_subject_exports(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  request_id uuid not null references public.data_subject_requests(id) on delete restrict,
  format text not null default 'json' check(format in('json')),
  payload_sha256 text not null,
  record_count integer not null default 0 check(record_count>=0),
  generated_by uuid,
  generated_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '7 days',
  metadata jsonb not null default '{}'::jsonb
);

alter table public.data_subject_request_events enable row level security;
alter table public.data_subject_exports enable row level security;
drop policy if exists data_subject_request_events_select on public.data_subject_request_events;
create policy data_subject_request_events_select on public.data_subject_request_events for select to authenticated
using(public.has_company_permission(company_id,'personal_data_manage')
  or public.has_company_permission(company_id,'personal_data_audit'));
drop policy if exists data_subject_exports_select on public.data_subject_exports;
create policy data_subject_exports_select on public.data_subject_exports for select to authenticated
using(public.has_company_permission(company_id,'personal_data_manage'));
revoke all on public.data_subject_request_events,public.data_subject_exports from anon,authenticated;
grant select on public.data_subject_request_events,public.data_subject_exports to authenticated;
drop trigger if exists data_subject_request_events_immutable on public.data_subject_request_events;
create trigger data_subject_request_events_immutable before update or delete on public.data_subject_request_events
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists data_subject_exports_immutable on public.data_subject_exports;
create trigger data_subject_exports_immutable before update or delete on public.data_subject_exports
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.transition_data_subject_request(
  target_request_id uuid,
  target_status text,
  target_reason text default null,
  target_legal_basis text default null,
  target_response_summary text default null,
  target_identity_verified_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare request_row public.data_subject_requests%rowtype; closed_time timestamptz;
begin
  select * into request_row from public.data_subject_requests where id=target_request_id for update;
  if request_row.id is null then raise exception 'data_subject_request_not_found' using errcode='P0002'; end if;
  if not public.has_company_permission(request_row.company_id,'personal_data_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_status not in('received','identity_check','in_progress','partially_fulfilled','fulfilled','refused','cancelled') then
    raise exception 'invalid_data_subject_request_status';
  end if;
  if request_row.status in('fulfilled','refused','cancelled') then raise exception 'data_subject_request_is_closed'; end if;
  if not (
    (request_row.status='received' and target_status in('identity_check','in_progress','cancelled')) or
    (request_row.status='identity_check' and target_status in('in_progress','refused','cancelled')) or
    (request_row.status='in_progress' and target_status in('partially_fulfilled','fulfilled','refused','cancelled')) or
    (request_row.status='partially_fulfilled' and target_status in('in_progress','fulfilled','refused','cancelled'))
  ) then raise exception 'invalid_data_subject_request_transition'; end if;
  if target_status='refused' and (nullif(trim(target_reason),'') is null or nullif(trim(target_legal_basis),'') is null) then
    raise exception 'refusal_reason_and_legal_basis_required';
  end if;
  if target_status in('fulfilled','partially_fulfilled') and nullif(trim(target_response_summary),'') is null then
    raise exception 'response_summary_required';
  end if;
  closed_time:=case when target_status in('fulfilled','refused','cancelled') then clock_timestamp() else null end;
  update public.data_subject_requests set
    status=target_status,
    identity_verified_at=coalesce(target_identity_verified_at,identity_verified_at),
    legal_basis=coalesce(nullif(trim(target_legal_basis),''),legal_basis),
    response_summary=coalesce(nullif(trim(target_response_summary),''),response_summary),
    closed_at=closed_time
  where id=request_row.id;
  insert into public.data_subject_request_events(
    company_id,request_id,event_type,previous_status,new_status,reason,actor_id,metadata
  ) values(
    request_row.company_id,request_row.id,
    case when target_identity_verified_at is not null and request_row.identity_verified_at is null
      then 'identity_verified' else 'status_changed' end,
    request_row.status,target_status,nullif(trim(target_reason),''),auth.uid(),
    jsonb_build_object('legal_basis_recorded',nullif(trim(target_legal_basis),'') is not null,
      'response_recorded',nullif(trim(target_response_summary),'') is not null)
  );
  perform public._append_fiscal_event(
    request_row.company_id,'data_subject_request_status_changed','data_subject_request',request_row.id,
    clock_timestamp(),jsonb_build_object('previous_status',request_row.status,'new_status',target_status,
      'closed',closed_time is not null),'rpc','{}'::jsonb
  );
  return jsonb_build_object('id',request_row.id,'status',target_status,'closed_at',closed_time);
end
$$;

create or replace function public.record_data_subject_request_decision(
  target_request_id uuid,
  target_data_category text,
  target_decision text,
  target_decision_reason text,
  target_entity_type text default null,
  target_entity_id uuid default null,
  target_legal_hold boolean default false
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare request_row public.data_subject_requests%rowtype; result_id uuid:=gen_random_uuid(); evidence text;
begin
  select * into request_row from public.data_subject_requests where id=target_request_id for update;
  if request_row.id is null then raise exception 'data_subject_request_not_found' using errcode='P0002'; end if;
  if not public.has_company_permission(request_row.company_id,'personal_data_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_decision not in('export','rectify','delete','anonymize','retain','restrict','not_found') then
    raise exception 'invalid_data_subject_decision';
  end if;
  if nullif(trim(target_data_category),'') is null or nullif(trim(target_decision_reason),'') is null then
    raise exception 'decision_category_and_reason_required';
  end if;
  evidence:=encode(extensions.digest(convert_to(jsonb_build_object(
    'request_id',request_row.id,'data_category',trim(target_data_category),'decision',target_decision,
    'decision_reason',trim(target_decision_reason),'entity_type',target_entity_type,
    'entity_id',target_entity_id,'legal_hold',coalesce(target_legal_hold,false)
  )::text,'UTF8'),'sha256'),'hex');
  insert into public.data_subject_request_items(
    id,company_id,request_id,data_category,entity_type,entity_id,decision,decision_reason,
    legal_hold,processed_at,processed_by,evidence_hash
  ) values(
    result_id,request_row.company_id,request_row.id,trim(target_data_category),
    nullif(trim(target_entity_type),''),target_entity_id,target_decision,trim(target_decision_reason),
    coalesce(target_legal_hold,false),clock_timestamp(),auth.uid(),evidence
  );
  insert into public.data_subject_request_events(
    company_id,request_id,event_type,reason,actor_id,metadata
  ) values(
    request_row.company_id,request_row.id,'decision_recorded',trim(target_decision_reason),auth.uid(),
    jsonb_build_object('item_id',result_id,'data_category',trim(target_data_category),
      'decision',target_decision,'legal_hold',coalesce(target_legal_hold,false),'evidence_hash',evidence)
  );
  perform public._append_fiscal_event(
    request_row.company_id,'data_subject_decision_recorded','data_subject_request_item',result_id,
    clock_timestamp(),jsonb_build_object('request_id',request_row.id,'data_category',trim(target_data_category),
      'decision',target_decision,'legal_hold',coalesce(target_legal_hold,false),'evidence_hash',evidence),
    'rpc','{}'::jsonb
  );
  return result_id;
end
$$;

create or replace function public.generate_data_subject_export(target_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions,auth,pg_temp as $$
declare
  request_row public.data_subject_requests%rowtype;
  subject_uuid uuid;
  subject_client_id uuid;
  payload jsonb:='{}'::jsonb;
  result_id uuid:=gen_random_uuid();
  payload_digest text;
  result_count integer:=0;
begin
  select * into request_row from public.data_subject_requests where id=target_request_id for update;
  if request_row.id is null then raise exception 'data_subject_request_not_found' using errcode='P0002'; end if;
  if request_row.request_type not in('access','portability') then raise exception 'request_type_does_not_allow_export'; end if;
  if not public.has_company_permission(request_row.company_id,'personal_data_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if request_row.identity_verified_at is null then
    raise exception 'data_subject_identity_verification_required' using errcode='55000';
  end if;
  if request_row.status not in('in_progress','partially_fulfilled') then
    raise exception 'data_subject_request_not_exportable_in_current_status' using errcode='55000';
  end if;
  begin subject_uuid:=request_row.subject_reference::uuid; exception when invalid_text_representation then subject_uuid:=null; end;

  if request_row.subject_kind in('client','prospect') then
    select client.id into subject_client_id from public.clients client
    where client.company_id=request_row.company_id
      and (client.id=subject_uuid or lower(client.email)=lower(request_row.subject_reference))
      and (request_row.subject_kind<>'prospect' or client.relationship_type='prospect')
    order by case when client.id=subject_uuid then 0 else 1 end limit 1;
    payload:=jsonb_build_object(
      'subject',coalesce((select to_jsonb(client)-array['company_id','created_by']::text[]
        from public.clients client where client.id=subject_client_id),'{}'::jsonb),
      'contacts',coalesce((select jsonb_agg(to_jsonb(contact)-array['company_id','created_by']::text[] order by contact.created_at)
        from public.client_contacts contact where contact.company_id=request_row.company_id and contact.client_id=subject_client_id),'[]'::jsonb),
      'documents',coalesce((select jsonb_agg((to_jsonb(document)-array['company_id','internal_notes','created_by']::text[])
        order by document.created_at) from public.documents document
        where document.company_id=request_row.company_id and document.client_id=subject_client_id),'[]'::jsonb),
      'activities',coalesce((select jsonb_agg(to_jsonb(activity)-array['company_id','created_by','updated_by']::text[] order by activity.created_at)
        from public.activities activity where activity.company_id=request_row.company_id and activity.client_id=subject_client_id),'[]'::jsonb),
      'reminders',coalesce((select jsonb_agg(to_jsonb(reminder)-array['company_id','created_by']::text[] order by reminder.created_at)
        from public.reminders reminder where reminder.company_id=request_row.company_id and reminder.client_id=subject_client_id),'[]'::jsonb)
    );
  elsif request_row.subject_kind='supplier' then
    payload:=jsonb_build_object('subject',coalesce((select to_jsonb(supplier)-array['company_id','created_by']::text[]
      from public.suppliers supplier where supplier.company_id=request_row.company_id
        and (supplier.id=subject_uuid or lower(supplier.email)=lower(request_row.subject_reference)) limit 1),'{}'::jsonb));
  elsif request_row.subject_kind='contact' then
    payload:=jsonb_build_object('subject',coalesce((select to_jsonb(contact)-array['company_id','created_by']::text[]
      from public.client_contacts contact where contact.company_id=request_row.company_id
        and (contact.id=subject_uuid or lower(contact.email)=lower(request_row.subject_reference)) limit 1),'{}'::jsonb));
  elsif request_row.subject_kind='user' then
    payload:=jsonb_build_object('subject',coalesce((select to_jsonb(account)-array[
      'encrypted_password','confirmation_token','recovery_token','email_change_token_new','email_change_token_current',
      'phone_change_token','reauthentication_token','raw_app_meta_data'
    ]::text[] from auth.users account
      where account.id=subject_uuid or lower(account.email)=lower(request_row.subject_reference) limit 1),'{}'::jsonb));
  else
    payload:=jsonb_build_object('subject_kind',request_row.subject_kind,'result','manual_collection_required');
  end if;
  result_count:=case when payload->'subject' is null or payload->'subject'='{}'::jsonb then 0 else 1 end
    +coalesce(jsonb_array_length(coalesce(payload->'contacts','[]'::jsonb)),0)
    +coalesce(jsonb_array_length(coalesce(payload->'documents','[]'::jsonb)),0)
    +coalesce(jsonb_array_length(coalesce(payload->'activities','[]'::jsonb)),0)
    +coalesce(jsonb_array_length(coalesce(payload->'reminders','[]'::jsonb)),0);
  payload:=jsonb_build_object(
    'format','piloz-data-subject-export','version','1.0','request_id',request_row.id,
    'generated_at',clock_timestamp(),'subject_kind',request_row.subject_kind,'data',payload
  );
  payload_digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  insert into public.data_subject_exports(
    id,company_id,request_id,payload_sha256,record_count,generated_by,metadata
  ) values(
    result_id,request_row.company_id,request_row.id,payload_digest,result_count,auth.uid(),
    jsonb_build_object('payload_not_persisted',true,'delivery_requires_identity_control',true)
  );
  insert into public.data_subject_request_events(
    company_id,request_id,event_type,actor_id,metadata
  ) values(
    request_row.company_id,request_row.id,'export_generated',auth.uid(),
    jsonb_build_object('export_id',result_id,'payload_sha256',payload_digest,'record_count',result_count)
  );
  perform public._append_fiscal_event(
    request_row.company_id,'data_subject_export_generated','data_subject_export',result_id,
    clock_timestamp(),jsonb_build_object('request_id',request_row.id,'payload_sha256',payload_digest,
      'record_count',result_count,'payload_persisted',false),'rpc','{}'::jsonb
  );
  return jsonb_build_object('export_id',result_id,'payload_sha256',payload_digest,
    'record_count',result_count,'expires_at',clock_timestamp()+interval '7 days','payload',payload);
end
$$;

create or replace function public.preview_company_retention_actions(target_company_id uuid,target_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if not public.has_company_permission(target_company_id,'personal_data_manage')
    and not public.has_company_permission(target_company_id,'personal_data_audit') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'rule_id',rule.id,'data_category',rule.data_category,'retention_months',rule.retention_months,
    'trigger_event',rule.trigger_event,'legal_basis',rule.legal_basis,
    'configured_action',rule.action_after_expiry,'validated',rule.validated_at is not null,
    'cutoff_at',case when rule.retention_months is null then null else target_at-make_interval(months=>rule.retention_months) end,
    'estimated_candidates',case
      when rule.retention_months is null then null
      when rule.data_category='prospects' then (select count(*) from public.clients client
        where client.company_id=target_company_id and client.relationship_type='prospect'
          and client.updated_at<target_at-make_interval(months=>rule.retention_months))
      when rule.data_category='draft_documents' then (select count(*) from public.documents document
        where document.company_id=target_company_id and document.finalized_at is null
          and document.updated_at<target_at-make_interval(months=>rule.retention_months))
      when rule.data_category='notifications' then (select count(*) from public.notifications notification
        where notification.company_id=target_company_id
          and notification.created_at<target_at-make_interval(months=>rule.retention_months))
      else null end,
    'automatic_action_allowed',false,
    'blocker','Revue juridique/DPO et contrÃ´le des obligations de conservation requis avant toute action.'
  ) order by rule.data_category),'[]'::jsonb) into result
  from public.company_retention_rules rule where rule.company_id=target_company_id;
  return jsonb_build_object('company_id',target_company_id,'previewed_at',target_at,
    'destructive_action_executed',false,'rules',result);
end
$$;

create or replace function public.set_company_retention_rule(
  target_company_id uuid,
  target_data_category text,
  target_retention_months integer,
  target_trigger_event text,
  target_legal_basis text,
  target_action_after_expiry text,
  target_validated_by text default null,
  target_validated_at timestamptz default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result_id uuid;
begin
  if not public.has_company_permission(target_company_id,'personal_data_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if nullif(trim(target_data_category),'') is null or nullif(trim(target_trigger_event),'') is null
    or nullif(trim(target_legal_basis),'') is null then raise exception 'retention_rule_fields_required'; end if;
  if target_retention_months is not null and target_retention_months<=0 then
    raise exception 'invalid_retention_period';
  end if;
  if target_action_after_expiry not in('review','delete','anonymize','archive','legal_hold') then
    raise exception 'invalid_retention_action';
  end if;
  insert into public.company_retention_rules(
    company_id,data_category,retention_months,trigger_event,legal_basis,action_after_expiry,
    validated_by,validated_at,created_by
  ) values(
    target_company_id,trim(target_data_category),target_retention_months,trim(target_trigger_event),
    trim(target_legal_basis),target_action_after_expiry,nullif(trim(target_validated_by),''),
    target_validated_at,auth.uid()
  ) on conflict(company_id,data_category) do update set
    retention_months=excluded.retention_months,trigger_event=excluded.trigger_event,
    legal_basis=excluded.legal_basis,action_after_expiry=excluded.action_after_expiry,
    validated_by=excluded.validated_by,validated_at=excluded.validated_at,updated_at=clock_timestamp()
  returning id into result_id;
  perform public._append_fiscal_event(
    target_company_id,'retention_rule_configured','retention_rule',result_id,clock_timestamp(),
    jsonb_build_object('data_category',trim(target_data_category),'retention_months',target_retention_months,
      'trigger_event',trim(target_trigger_event),'action_after_expiry',target_action_after_expiry,
      'externally_validated',target_validated_at is not null),'rpc','{}'::jsonb
  );
  return result_id;
end
$$;

revoke all on function public.transition_data_subject_request(uuid,text,text,text,text,timestamptz) from public,anon;
revoke all on function public.record_data_subject_request_decision(uuid,text,text,text,text,uuid,boolean) from public,anon;
revoke all on function public.generate_data_subject_export(uuid) from public,anon;
revoke all on function public.preview_company_retention_actions(uuid,timestamptz) from public,anon;
revoke all on function public.set_company_retention_rule(uuid,text,integer,text,text,text,text,timestamptz) from public,anon;
grant execute on function public.transition_data_subject_request(uuid,text,text,text,text,timestamptz) to authenticated;
grant execute on function public.record_data_subject_request_decision(uuid,text,text,text,text,uuid,boolean) to authenticated;
grant execute on function public.generate_data_subject_export(uuid) to authenticated;
grant execute on function public.preview_company_retention_actions(uuid,timestamptz) to authenticated;
grant execute on function public.set_company_retention_rule(uuid,text,integer,text,text,text,text,timestamptz) to authenticated;

alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.3',
  alter column schema_version set default '202607220046';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.3',schema_version='202607220046',updated_at=now()
where activated_at is null and mode in('off','test');

commit;
