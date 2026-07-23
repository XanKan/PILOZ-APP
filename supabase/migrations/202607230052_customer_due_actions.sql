begin;

-- Actions des échéances clients : envoi traçable du PDF final et règlement
-- multi-factures. Cette migration est additive et ne modifie aucun encaissement
-- historique. Les écritures créées par le RPC sont append-only.

create or replace function public.has_company_permission(target_company_id uuid,target_permission text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.company_members member
    where member.company_id=target_company_id and member.user_id=auth.uid()
      and case
        when member.role in('owner','admin') then true
        when member.permissions ? target_permission then lower(member.permissions->>target_permission)='true'
        when member.role='billing' then target_permission=any(array[
          'application_read','sales_document_write','finalize_invoice','record_payment','manage_reminder','fiscal_read',
          'view_due_dates','resend_invoice','view_payment_methods','view_bank_accounts','attach_payment_proof',
          'record_multi_invoice_payment','correct_payment','view_bank_references'
        ])
        when member.role='sales' then target_permission=any(array[
          'application_read','sales_document_write','finalize_quote','manage_customer','manage_opportunity',
          'view_due_dates','resend_invoice'
        ])
        when member.role='accounting' then target_permission=any(array[
          'application_read','finalize_invoice','create_credit_note','record_payment','fiscal_read',
          'create_closure','create_archive','electronic_invoice_manage','compliance_view',
          'view_due_dates','resend_invoice','view_payment_methods','view_bank_accounts','attach_payment_proof',
          'record_multi_invoice_payment','correct_payment','view_bank_references'
        ])
        when member.role='auditor' then target_permission=any(array[
          'application_read','fiscal_read','compliance_view','personal_data_audit','view_due_dates'
        ])
        when member.role in('read_only','member') then target_permission=any(array['application_read','view_due_dates'])
        else false
      end
  )
$$;
revoke all on function public.has_company_permission(uuid,text) from public,anon;
grant execute on function public.has_company_permission(uuid,text) to authenticated;

alter table public.documents
  add column if not exists send_count integer not null default 0,
  add column if not exists last_sent_at timestamptz;

alter table public.payments
  add column if not exists payment_receipt_id uuid,
  add column if not exists payment_number text,
  add column if not exists label text;

create table if not exists public.payment_receipt_sequences(
  company_id uuid not null references public.companies(id) on delete restrict,
  year integer not null check(year between 2000 and 9999),
  next_value bigint not null default 1 check(next_value>0),
  primary key(company_id,year)
);

create table if not exists public.payment_receipts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  client_id uuid not null references public.clients(id) on delete restrict,
  payment_number text not null,
  idempotency_key uuid not null,
  request_hash text not null,
  received_amount numeric(15,2) not null check(received_amount>0),
  allocated_amount numeric(15,2) not null check(allocated_amount>=0),
  unallocated_amount numeric(15,2) not null default 0 check(unallocated_amount>=0),
  currency text not null default 'EUR',
  received_at timestamptz not null,
  value_date date,
  payment_method text not null,
  external_reference text,
  bank_reference text,
  label text,
  receiving_account jsonb not null default '{}'::jsonb,
  internal_note text,
  proof_storage_path text,
  fiscal_event_id uuid references public.fiscal_events(id) on delete restrict,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,payment_number),
  unique(company_id,idempotency_key),
  check(round(allocated_amount+unallocated_amount,2)=round(received_amount,2))
);

alter table public.payments drop constraint if exists payments_payment_receipt_id_fkey;
alter table public.payments add constraint payments_payment_receipt_id_fkey
  foreign key(payment_receipt_id) references public.payment_receipts(id) on delete restrict;

create table if not exists public.payment_allocations(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  payment_receipt_id uuid not null references public.payment_receipts(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  ledger_payment_id uuid not null references public.payments(id) on delete restrict,
  amount numeric(15,2) not null check(amount>0),
  currency text not null default 'EUR',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(payment_receipt_id,document_id),
  unique(ledger_payment_id)
);

create table if not exists public.document_email_deliveries(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  client_id uuid references public.clients(id) on delete restrict,
  delivery_mode text not null check(delivery_mode in('provider','manual','mail_app')),
  delivery_status text not null check(delivery_status in('sent','recorded','failed')),
  recipient_to text[] not null default '{}',
  recipient_cc text[] not null default '{}',
  subject text not null,
  template_key text not null default 'invoice-resend-default',
  message_preview text,
  pdf_storage_path text not null,
  pdf_sha256 text,
  provider text,
  provider_message_id text,
  technical_code text,
  sent_at timestamptz,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists payment_receipts_company_client_idx
  on public.payment_receipts(company_id,client_id,received_at desc,id desc);
create index if not exists payment_allocations_document_idx
  on public.payment_allocations(company_id,document_id,created_at desc);
create index if not exists document_email_deliveries_document_idx
  on public.document_email_deliveries(company_id,document_id,created_at desc);
create index if not exists document_email_deliveries_client_idx
  on public.document_email_deliveries(company_id,client_id,created_at desc);

alter table public.payment_receipt_sequences enable row level security;
alter table public.payment_receipts enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.document_email_deliveries enable row level security;

drop policy if exists payment_receipt_sequences_select on public.payment_receipt_sequences;
create policy payment_receipt_sequences_select on public.payment_receipt_sequences for select to authenticated
  using(public.has_company_permission(company_id,'record_multi_invoice_payment'));
drop policy if exists payment_receipts_select on public.payment_receipts;
create policy payment_receipts_select on public.payment_receipts for select to authenticated
  using(public.has_company_permission(company_id,'view_due_dates'));
drop policy if exists payment_allocations_select on public.payment_allocations;
create policy payment_allocations_select on public.payment_allocations for select to authenticated
  using(public.has_company_permission(company_id,'view_due_dates'));
drop policy if exists document_email_deliveries_select on public.document_email_deliveries;
create policy document_email_deliveries_select on public.document_email_deliveries for select to authenticated
  using(public.has_company_permission(company_id,'view_due_dates'));

create or replace view public.payment_receipt_read_model with(security_barrier=true) as
select
  receipt.id,receipt.company_id,receipt.client_id,receipt.payment_number,
  receipt.received_amount,receipt.allocated_amount,receipt.unallocated_amount,receipt.currency,
  receipt.received_at,receipt.value_date,receipt.payment_method,receipt.external_reference,
  case when public.has_company_permission(receipt.company_id,'view_bank_references')
    then receipt.bank_reference else null end bank_reference,
  receipt.label,
  case when public.has_company_permission(receipt.company_id,'view_bank_accounts')
    then receipt.receiving_account else '{}'::jsonb end receiving_account,
  receipt.internal_note,
  case when public.has_company_permission(receipt.company_id,'attach_payment_proof')
    then receipt.proof_storage_path else null end proof_storage_path,
  receipt.created_by,receipt.created_at
from public.payment_receipts receipt
where public.has_company_permission(receipt.company_id,'view_due_dates');

drop policy if exists company_payment_proofs_insert on storage.objects;
create policy company_payment_proofs_insert on storage.objects for insert to authenticated with check(
  bucket_id='company-files'
  and (storage.foldername(name))[2]='payments'
  and public.has_company_permission((storage.foldername(name))[1]::uuid,'attach_payment_proof')
);

revoke all on public.payment_receipt_sequences,public.payment_receipts,public.payment_allocations,
  public.document_email_deliveries from anon,authenticated;
revoke all on public.payment_receipt_read_model from anon,authenticated;
grant select on public.payment_allocations,public.document_email_deliveries,public.payment_receipt_read_model to authenticated;
grant select(send_count,last_sent_at) on public.documents to authenticated;
grant select(payment_receipt_id,payment_number,label) on public.payments to authenticated;

drop trigger if exists payment_receipts_immutable on public.payment_receipts;
create trigger payment_receipts_immutable before update or delete on public.payment_receipts
  for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists payment_allocations_immutable on public.payment_allocations;
create trigger payment_allocations_immutable before update or delete on public.payment_allocations
  for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists document_email_deliveries_immutable on public.document_email_deliveries;
create trigger document_email_deliveries_immutable before update or delete on public.document_email_deliveries
  for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.apply_document_email_delivery_counter()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.delivery_status in('sent','recorded') then
    update public.documents set send_count=send_count+1,last_sent_at=coalesce(new.sent_at,new.created_at),
      sent_at=coalesce(sent_at,coalesce(new.sent_at,new.created_at)),updated_at=now()
    where id=new.document_id and company_id=new.company_id;
  end if;
  return new;
end
$$;
drop trigger if exists document_email_deliveries_apply_counter on public.document_email_deliveries;
create trigger document_email_deliveries_apply_counter after insert on public.document_email_deliveries
  for each row execute function public.apply_document_email_delivery_counter();

create or replace function public.record_multi_invoice_payment(
  target_allocations jsonb,
  payment_amount numeric,
  payment_method_code text,
  payment_date timestamptz default now(),
  payment_value_date date default null,
  payment_reference text default null,
  payment_bank_reference text default null,
  payment_label text default null,
  payment_note text default null,
  receiving_account_snapshot jsonb default '{}'::jsonb,
  proof_storage_path text default null,
  allow_unallocated boolean default false,
  target_idempotency_key uuid default gen_random_uuid()
) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  allocation_row jsonb;
  allocation_document_id uuid;
  allocation_amount numeric;
  doc public.documents%rowtype;
  first_company_id uuid;
  first_client_id uuid;
  first_currency text;
  seen_documents uuid[]:='{}'::uuid[];
  allocation_total numeric:=0;
  already_paid numeric;
  unallocated numeric;
  receipt_id uuid:=gen_random_uuid();
  payment_id uuid;
  receipt_number text;
  sequence_value bigint;
  sequence_year integer:=extract(year from coalesce(payment_date,now()))::integer;
  config public.company_fiscal_configurations%rowtype;
  account_config public.company_document_settings%rowtype;
  event_id uuid;
  receipt_event_id uuid;
  payload jsonb;
  payload_digest text;
  request_digest text;
  previous_receipt public.payment_receipts%rowtype;
  result_documents jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if target_idempotency_key is null then raise exception 'idempotency_key_required'; end if;
  if jsonb_typeof(target_allocations)<>'array' or jsonb_array_length(target_allocations)=0 then
    raise exception 'payment_allocations_required';
  end if;
  if payment_amount is null or round(payment_amount,2)<=0 then raise exception 'invalid_payment_amount'; end if;
  if nullif(trim(payment_method_code),'') is null then raise exception 'payment_method_required'; end if;
  request_digest:=encode(extensions.digest(convert_to(jsonb_build_object(
    'allocations',target_allocations,'amount',round(payment_amount,2),'method',payment_method_code,
    'date',coalesce(payment_date,now()),'value_date',payment_value_date,'reference',payment_reference,
    'bank_reference',payment_bank_reference,'label',payment_label,'note',payment_note,
    'proof',proof_storage_path,'allow_unallocated',allow_unallocated
  )::text,'UTF8'),'sha256'),'hex');

  for allocation_row in
    select element from jsonb_array_elements(target_allocations) as allocation_rows(element)
    order by element->>'document_id'
  loop
    begin
      allocation_document_id:=(allocation_row->>'document_id')::uuid;
      allocation_amount:=round((allocation_row->>'amount')::numeric,2);
    exception when others then
      raise exception 'invalid_payment_allocation';
    end;
    if allocation_document_id is null or allocation_amount<=0 then raise exception 'invalid_payment_allocation'; end if;
    if allocation_document_id=any(seen_documents) then raise exception 'duplicate_payment_allocation'; end if;
    seen_documents:=array_append(seen_documents,allocation_document_id);

    select * into doc from public.documents where id=allocation_document_id for update;
    if first_company_id is null then
      if doc.id is null then raise exception 'invalid_invoice_state'; end if;
      first_company_id:=doc.company_id; first_client_id:=doc.client_id; first_currency:=doc.currency;
      if not public.has_company_permission(first_company_id,'record_multi_invoice_payment') then
        raise exception 'missing_permission:record_multi_invoice_payment' using errcode='42501';
      end if;
      select * into previous_receipt from public.payment_receipts
        where company_id=first_company_id and idempotency_key=target_idempotency_key;
      if previous_receipt.id is not null then
        if not public.has_company_permission(first_company_id,'record_multi_invoice_payment') then
          raise exception 'missing_permission:record_multi_invoice_payment' using errcode='42501';
        end if;
        if previous_receipt.request_hash<>request_digest then raise exception 'idempotency_payload_mismatch'; end if;
        return jsonb_build_object(
          'receipt_id',previous_receipt.id,'payment_number',previous_receipt.payment_number,
          'received_amount',previous_receipt.received_amount,'allocated_amount',previous_receipt.allocated_amount,
          'unallocated_amount',previous_receipt.unallocated_amount,'idempotent',true
        );
      end if;
    elsif doc.company_id<>first_company_id or doc.client_id is distinct from first_client_id
      or doc.currency is distinct from first_currency then
      raise exception 'payment_allocations_must_share_company_client_currency';
    end if;
    if doc.document_type not in('invoice','deposit_invoice','balance_invoice')
      or doc.finalized_at is null or doc.status in('draft','cancelled','archived') then
      raise exception 'invalid_invoice_state';
    end if;
    select coalesce(sum(amount),0) into already_paid from public.payments
      where document_id=doc.id and status='confirmed';
    if allocation_amount>greatest(0,doc.total_incl_tax-already_paid)+0.01 then
      raise exception 'payment_exceeds_balance';
    end if;
    allocation_total:=allocation_total+allocation_amount;
  end loop;

  if not public.has_company_permission(first_company_id,'record_multi_invoice_payment') then
    raise exception 'missing_permission:record_multi_invoice_payment' using errcode='42501';
  end if;
  select * into account_config from public.company_document_settings where company_id=first_company_id;
  receiving_account_snapshot:=jsonb_strip_nulls(jsonb_build_object(
    'bank_name',nullif(account_config.bank_name,''),
    'account_holder',nullif(account_config.bank_account_holder,''),
    'iban_last4',case when nullif(regexp_replace(coalesce(account_config.iban,''),'\s','','g'),'') is null then null
      else right(regexp_replace(account_config.iban,'\s','','g'),4) end,
    'bic',nullif(account_config.bic,'')
  ));
  if not exists(select 1 from public.payment_methods method
    where method.company_id=first_company_id and method.active and method.code=payment_method_code) then
    raise exception 'inactive_payment_method';
  end if;
  if exists(select 1 from public.fiscal_closures closure
    where closure.company_id=first_company_id and coalesce(payment_date,now())>=closure.period_start
      and coalesce(payment_date,now())<closure.period_end) then
    raise exception 'payment_date_in_closed_period';
  end if;
  if proof_storage_path is not null and proof_storage_path not like first_company_id::text||'/payments/%' then
    raise exception 'invalid_payment_proof_path';
  end if;

  allocation_total:=round(allocation_total,2);
  unallocated:=round(payment_amount,2)-allocation_total;
  if unallocated<0 then raise exception 'allocations_exceed_received_amount'; end if;
  if unallocated>0 and not allow_unallocated then raise exception 'unallocated_amount_confirmation_required'; end if;

  select * into previous_receipt from public.payment_receipts
    where company_id=first_company_id and idempotency_key=target_idempotency_key;
  if previous_receipt.id is not null then
    if previous_receipt.request_hash<>request_digest then raise exception 'idempotency_payload_mismatch'; end if;
    return jsonb_build_object(
      'receipt_id',previous_receipt.id,'payment_number',previous_receipt.payment_number,
      'received_amount',previous_receipt.received_amount,'allocated_amount',previous_receipt.allocated_amount,
      'unallocated_amount',previous_receipt.unallocated_amount,'idempotent',true
    );
  end if;

  insert into public.payment_receipt_sequences(company_id,year,next_value)
  values(first_company_id,sequence_year,2)
  on conflict(company_id,year) do update
    set next_value=public.payment_receipt_sequences.next_value+1
  returning next_value-1 into sequence_value;
  receipt_number:='REG-'||sequence_year::text||'-'||lpad(sequence_value::text,6,'0');
  select * into config from public.company_fiscal_configurations where company_id=first_company_id;

  payload:=jsonb_build_object(
    'receipt_id',receipt_id,'payment_number',receipt_number,'client_id',first_client_id,
    'received_amount',round(payment_amount,2),'allocated_amount',allocation_total,
    'unallocated_amount',unallocated,'currency',first_currency,'received_at',coalesce(payment_date,now()),
    'payment_method',payment_method_code,'allocation_count',jsonb_array_length(target_allocations)
  );
  receipt_event_id:=public._append_fiscal_event(first_company_id,'payment_receipt_recorded','payment_receipt',
    receipt_id,coalesce(payment_date,now()),payload,'rpc','{}'::jsonb);

  insert into public.payment_receipts(
    id,company_id,client_id,payment_number,idempotency_key,request_hash,received_amount,allocated_amount,
    unallocated_amount,currency,received_at,value_date,payment_method,external_reference,
    bank_reference,label,receiving_account,internal_note,proof_storage_path,fiscal_event_id,created_by
  ) values(
    receipt_id,first_company_id,first_client_id,receipt_number,target_idempotency_key,request_digest,round(payment_amount,2),
    allocation_total,unallocated,first_currency,coalesce(payment_date,now()),payment_value_date,
    trim(payment_method_code),nullif(trim(payment_reference),''),nullif(trim(payment_bank_reference),''),
    nullif(trim(payment_label),''),coalesce(receiving_account_snapshot,'{}'::jsonb),nullif(trim(payment_note),''),
    nullif(trim(proof_storage_path),''),receipt_event_id,auth.uid()
  );

  for allocation_row in select element from jsonb_array_elements(target_allocations) as allocation_rows(element) order by element->>'document_id'
  loop
    allocation_document_id:=(allocation_row->>'document_id')::uuid;
    allocation_amount:=round((allocation_row->>'amount')::numeric,2);
    select * into doc from public.documents where id=allocation_document_id;
    payment_id:=gen_random_uuid();
    payload:=jsonb_build_object(
      'payment_id',payment_id,'payment_receipt_id',receipt_id,'payment_number',receipt_number,
      'document_id',doc.id,'document_number',doc.number,'client_id',doc.client_id,
      'amount',allocation_amount,'currency',doc.currency,'paid_at',coalesce(payment_date,now()),
      'payment_method',payment_method_code,'reference',payment_reference
    );
    payload_digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
    event_id:=public._append_fiscal_event(first_company_id,'payment_allocated','payment',payment_id,
      coalesce(payment_date,now()),payload,'rpc','{}'::jsonb);
    insert into public.payments(
      id,company_id,document_id,amount,currency,paid_at,payment_method,reference,status,comment,
      entry_type,fiscal_event_id,payload_hash,application_version,schema_version,created_by,
      payment_receipt_id,payment_number,label
    ) values(
      payment_id,first_company_id,doc.id,allocation_amount,doc.currency,coalesce(payment_date,now()),
      trim(payment_method_code),nullif(trim(payment_reference),''),'confirmed',nullif(trim(payment_note),''),
      'payment',event_id,payload_digest,coalesce(config.application_version,'2026.07-compliance'),
      '202607230052',auth.uid(),receipt_id,receipt_number,nullif(trim(payment_label),'')
    );
    insert into public.payment_allocations(
      company_id,payment_receipt_id,document_id,ledger_payment_id,amount,currency,created_by
    ) values(first_company_id,receipt_id,doc.id,payment_id,allocation_amount,doc.currency,auth.uid());
    perform public._rebuild_document_payment_projection(doc.id);
    update public.reminders set status='cancelled',updated_at=now()
      where company_id=first_company_id and document_id=doc.id and status='pending'
        and not exists(select 1 from public.documents current_doc
          where current_doc.id=doc.id and current_doc.status<>'paid');
    result_documents:=result_documents||jsonb_build_array(jsonb_build_object(
      'document_id',doc.id,'payment_id',payment_id,'allocated_amount',allocation_amount,
      'remaining_amount',greatest(0,doc.total_incl_tax-(select coalesce(sum(amount),0) from public.payments where document_id=doc.id and status='confirmed'))
    ));
  end loop;

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(first_company_id,auth.uid(),'payment.multi_invoice_recorded','payment_receipt',receipt_id,
    jsonb_build_object('payment_number',receipt_number,'client_id',first_client_id,'received_amount',round(payment_amount,2),
      'allocated_amount',allocation_total,'unallocated_amount',unallocated,'document_count',jsonb_array_length(target_allocations)),auth.uid());
  insert into public.client_activity_events(
    company_id,client_id,event_type,summary,entity_type,entity_id,metadata,actor_user_id,created_by
  ) values(first_company_id,first_client_id,'payment.receipt_recorded','Règlement '||receipt_number||' enregistré',
    'payment_receipt',receipt_id,jsonb_build_object('received_amount',round(payment_amount,2),
      'allocated_amount',allocation_total,'unallocated_amount',unallocated),auth.uid(),auth.uid());

  return jsonb_build_object(
    'receipt_id',receipt_id,'payment_number',receipt_number,'received_amount',round(payment_amount,2),
    'allocated_amount',allocation_total,'unallocated_amount',unallocated,'documents',result_documents,'idempotent',false
  );
end
$$;

create or replace function public.record_manual_document_email(
  target_document_id uuid,target_to text[],target_cc text[],target_subject text,target_message text,
  target_mode text default 'manual',target_template_key text default 'invoice-resend-default'
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; delivery_id uuid:=gen_random_uuid();
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null then raise exception 'final_pdf_required'; end if;
  if not public.has_company_permission(doc.company_id,'resend_invoice') then
    raise exception 'missing_permission:resend_invoice' using errcode='42501';
  end if;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice')
    or doc.finalized_at is null or nullif(doc.final_pdf_path,'') is null then raise exception 'final_pdf_required'; end if;
  if target_mode not in('manual','mail_app') then raise exception 'invalid_delivery_mode'; end if;
  if coalesce(cardinality(target_to),0)=0 or nullif(trim(target_subject),'') is null then
    raise exception 'email_recipient_subject_required';
  end if;
  if exists(select 1 from unnest(coalesce(target_to,'{}')||coalesce(target_cc,'{}')) address
    where address !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'invalid_email_recipient';
  end if;
  insert into public.document_email_deliveries(
    id,company_id,document_id,client_id,delivery_mode,delivery_status,recipient_to,recipient_cc,
    subject,template_key,message_preview,pdf_storage_path,pdf_sha256,sent_at,created_by
  ) values(
    delivery_id,doc.company_id,doc.id,doc.client_id,target_mode,'recorded',target_to,coalesce(target_cc,'{}'),
    trim(target_subject),coalesce(nullif(trim(target_template_key),''),'invoice-resend-default'),
    left(coalesce(target_message,''),1000),doc.final_pdf_path,doc.final_pdf_sha256,now(),auth.uid()
  );
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.email_manual_recorded','document',doc.id,
    jsonb_build_object('delivery_id',delivery_id,'mode',target_mode,'recipient_count',cardinality(target_to)+coalesce(cardinality(target_cc),0)),auth.uid());
  if doc.client_id is not null then
    insert into public.client_activity_events(
      company_id,client_id,event_type,summary,entity_type,entity_id,metadata,actor_user_id,created_by
    ) values(doc.company_id,doc.client_id,'invoice.email_recorded','Envoi manuel de la facture enregistré',
      'document_email_delivery',delivery_id,jsonb_build_object('document_id',doc.id,'mode',target_mode),auth.uid(),auth.uid());
  end if;
  return delivery_id;
end
$$;

create or replace function public.reverse_payment_receipt(
  target_receipt_id uuid,
  target_entry_type text,
  target_reason text,
  target_effective_at timestamptz default now()
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  receipt public.payment_receipts%rowtype;
  allocation record;
  reversed_amount numeric:=0;
  reversal_ids jsonb:='[]'::jsonb;
  reversal_id uuid;
  already_reversed numeric;
  remaining_amount numeric;
begin
  if auth.uid() is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if target_entry_type not in('correction','refund','rejection','chargeback') then
    raise exception 'invalid_payment_reversal_type';
  end if;
  if nullif(trim(target_reason),'') is null then raise exception 'payment_reversal_reason_required'; end if;

  select * into receipt from public.payment_receipts where id=target_receipt_id for update;
  if receipt.id is null then raise exception 'payment_receipt_not_found'; end if;
  if not public.has_company_permission(receipt.company_id,'correct_payment') then
    raise exception 'missing_permission:correct_payment' using errcode='42501';
  end if;

  for allocation in
    select item.ledger_payment_id,item.document_id,item.amount
    from public.payment_allocations item
    where item.payment_receipt_id=receipt.id and item.company_id=receipt.company_id
    order by item.document_id,item.id
    for update
  loop
    select coalesce(-sum(payment.amount),0) into already_reversed
    from public.payments payment
    where payment.reverses_payment_id=allocation.ledger_payment_id
      and payment.status='confirmed'
      and payment.entry_type in('correction','refund','rejection','chargeback');
    remaining_amount:=round(greatest(allocation.amount-already_reversed,0),2);
    if remaining_amount>0 then
      reversal_id:=public.record_document_payment_reversal(
        allocation.ledger_payment_id,target_entry_type,remaining_amount,trim(target_reason),coalesce(target_effective_at,now())
      );
      reversed_amount:=reversed_amount+remaining_amount;
      reversal_ids:=reversal_ids||jsonb_build_array(jsonb_build_object(
        'document_id',allocation.document_id,'reversal_id',reversal_id,'amount',remaining_amount
      ));
    end if;
  end loop;
  if reversed_amount<=0 then raise exception 'payment_already_fully_reversed'; end if;

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(receipt.company_id,auth.uid(),'payment.receipt_reversed','payment_receipt',receipt.id,
    jsonb_build_object('payment_number',receipt.payment_number,'entry_type',target_entry_type,
      'reason',trim(target_reason),'reversed_amount',round(reversed_amount,2),'allocations',reversal_ids),auth.uid());
  insert into public.client_activity_events(
    company_id,client_id,event_type,summary,entity_type,entity_id,metadata,actor_user_id,created_by
  ) values(receipt.company_id,receipt.client_id,'payment.receipt_reversed',
    'Correction du règlement '||receipt.payment_number,'payment_receipt',receipt.id,
    jsonb_build_object('entry_type',target_entry_type,'reason',trim(target_reason),
      'reversed_amount',round(reversed_amount,2),'allocations',reversal_ids),auth.uid(),auth.uid());
  return jsonb_build_object('receipt_id',receipt.id,'payment_number',receipt.payment_number,
    'reversed_amount',round(reversed_amount,2),'reversals',reversal_ids);
end
$$;

revoke all on function public.record_multi_invoice_payment(jsonb,numeric,text,timestamptz,date,text,text,text,text,jsonb,text,boolean,uuid) from public,anon;
grant execute on function public.record_multi_invoice_payment(jsonb,numeric,text,timestamptz,date,text,text,text,text,jsonb,text,boolean,uuid) to authenticated;
revoke all on function public.record_manual_document_email(uuid,text[],text[],text,text,text,text) from public,anon;
grant execute on function public.record_manual_document_email(uuid,text[],text[],text,text,text,text) to authenticated;
revoke all on function public.reverse_payment_receipt(uuid,text,text,timestamptz) from public,anon;
grant execute on function public.reverse_payment_receipt(uuid,text,text,timestamptz) to authenticated;

commit;
