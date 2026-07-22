begin;

-- Phase 3 — journal fiscal append-only, registre d'encaissements et clôtures.
-- Aucune signature n'est simulée : les champs restent NULL tant qu'un KMS
-- validé n'est pas configuré.

create table if not exists public.fiscal_event_heads(
  company_id uuid primary key references public.companies(id) on delete restrict,
  last_sequence_number bigint not null default 0,
  last_event_hash text,
  updated_at timestamptz not null default now()
);

create table if not exists public.fiscal_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  sequence_number bigint not null check(sequence_number>0),
  event_type text not null,
  entity_type text not null,
  entity_id uuid,
  occurred_at timestamptz not null,
  effective_at timestamptz not null,
  actor_id uuid,
  actor_role text,
  source text not null,
  previous_hash text,
  payload jsonb not null,
  payload_hash text not null,
  event_hash text not null,
  signature text,
  signature_key_id text,
  canonicalization_version text not null,
  application_version text not null,
  schema_version text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(company_id,sequence_number),
  unique(company_id,event_hash)
);
create index if not exists fiscal_events_company_time_idx on public.fiscal_events(company_id,occurred_at,id);
create index if not exists fiscal_events_entity_idx on public.fiscal_events(company_id,entity_type,entity_id,sequence_number);

insert into public.fiscal_event_heads(company_id)
select id from public.companies on conflict(company_id) do nothing;

create or replace function public.seed_company_fiscal_event_head()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.fiscal_event_heads(company_id) values(new.id) on conflict(company_id) do nothing;
  return new;
end
$$;
revoke all on function public.seed_company_fiscal_event_head() from public,anon,authenticated;
drop trigger if exists companies_seed_fiscal_event_head on public.companies;
create trigger companies_seed_fiscal_event_head after insert on public.companies
for each row execute function public.seed_company_fiscal_event_head();

alter table public.fiscal_event_heads enable row level security;
alter table public.fiscal_events enable row level security;
drop policy if exists fiscal_event_heads_select on public.fiscal_event_heads;
create policy fiscal_event_heads_select on public.fiscal_event_heads for select to authenticated
using(public.is_company_member(company_id));
drop policy if exists fiscal_events_select on public.fiscal_events;
create policy fiscal_events_select on public.fiscal_events for select to authenticated
using(public.is_company_member(company_id));
revoke all on public.fiscal_event_heads,public.fiscal_events from anon,authenticated;
grant select on public.fiscal_event_heads,public.fiscal_events to authenticated;

drop trigger if exists fiscal_event_heads_immutable on public.fiscal_event_heads;
-- La tête est mise à jour uniquement par la fonction SECURITY DEFINER ; son
-- accès direct est déjà révoqué. Les événements eux-mêmes sont immuables.
drop trigger if exists fiscal_events_immutable on public.fiscal_events;
create trigger fiscal_events_immutable before update or delete on public.fiscal_events
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public._fiscal_event_material(
  target_sequence bigint,target_event_type text,target_entity_type text,target_entity_id uuid,
  target_occurred_at timestamptz,target_effective_at timestamptz,target_previous_hash text,target_payload_hash text,
  target_application_version text,target_schema_version text,target_canonicalization_version text
) returns text language sql immutable set search_path=public,pg_temp as $$
  select concat_ws('|',target_sequence::text,target_event_type,target_entity_type,coalesce(target_entity_id::text,''),
    to_char(target_occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    to_char(target_effective_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    coalesce(target_previous_hash,''),target_payload_hash,target_application_version,target_schema_version,target_canonicalization_version)
$$;
revoke all on function public._fiscal_event_material(bigint,text,text,uuid,timestamptz,timestamptz,text,text,text,text,text) from public,anon,authenticated;

create or replace function public._append_fiscal_event(
  target_company_id uuid,target_event_type text,target_entity_type text,target_entity_id uuid,
  target_effective_at timestamptz,target_payload jsonb,target_source text,target_metadata jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  head public.fiscal_event_heads%rowtype; config public.company_fiscal_configurations%rowtype;
  next_sequence bigint; event_time timestamptz:=clock_timestamp(); normalized_payload jsonb;
  calculated_payload_hash text; calculated_event_hash text; result_id uuid; role_value text;
begin
  if target_company_id is null or nullif(trim(target_event_type),'') is null or nullif(trim(target_entity_type),'') is null then
    raise exception 'invalid_fiscal_event';
  end if;
  if auth.uid() is not null and not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  insert into public.fiscal_event_heads(company_id) values(target_company_id) on conflict(company_id) do nothing;
  select * into head from public.fiscal_event_heads where company_id=target_company_id for update;
  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  select role into role_value from public.company_members where company_id=target_company_id and user_id=auth.uid();
  next_sequence:=head.last_sequence_number+1;
  normalized_payload:=coalesce(target_payload,'{}'::jsonb);
  calculated_payload_hash:=encode(extensions.digest(convert_to(normalized_payload::text,'UTF8'),'sha256'),'hex');
  calculated_event_hash:=encode(extensions.digest(convert_to(public._fiscal_event_material(
    next_sequence,target_event_type,target_entity_type,target_entity_id,event_time,coalesce(target_effective_at,event_time),
    head.last_event_hash,calculated_payload_hash,coalesce(config.application_version,'2026.07-compliance'),
    coalesce(config.schema_version,'202607220040'),coalesce(config.canonicalization_version,'jsonb-text-v1')
  ),'UTF8'),'sha256'),'hex');
  insert into public.fiscal_events(
    company_id,sequence_number,event_type,entity_type,entity_id,occurred_at,effective_at,actor_id,actor_role,
    source,previous_hash,payload,payload_hash,event_hash,signature,signature_key_id,canonicalization_version,
    application_version,schema_version,metadata
  ) values(
    target_company_id,next_sequence,trim(target_event_type),trim(target_entity_type),target_entity_id,event_time,
    coalesce(target_effective_at,event_time),auth.uid(),role_value,coalesce(nullif(trim(target_source),''),'server'),
    head.last_event_hash,normalized_payload,calculated_payload_hash,calculated_event_hash,null,null,
    coalesce(config.canonicalization_version,'jsonb-text-v1'),coalesce(config.application_version,'2026.07-compliance'),
    coalesce(config.schema_version,'202607220040'),coalesce(target_metadata,'{}'::jsonb)||jsonb_build_object(
      'signature_status',coalesce(config.signing_status,'not_configured'),'local_timezone','Europe/Paris'
    )
  ) returning id into result_id;
  update public.fiscal_event_heads set last_sequence_number=next_sequence,last_event_hash=calculated_event_hash,updated_at=event_time
  where company_id=target_company_id;
  return result_id;
end
$$;
revoke all on function public._append_fiscal_event(uuid,text,text,uuid,timestamptz,jsonb,text,jsonb) from public,anon,authenticated;

create or replace function public.verify_fiscal_event_chain(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare
  event_row public.fiscal_events%rowtype; expected_sequence bigint:=1; expected_previous text:=null;
  expected_payload text; expected_event text; anomalies jsonb:='[]'::jsonb; checked_count bigint:=0;
begin
  if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  for event_row in select * from public.fiscal_events where company_id=target_company_id order by sequence_number loop
    checked_count:=checked_count+1;
    expected_payload:=encode(extensions.digest(convert_to(event_row.payload::text,'UTF8'),'sha256'),'hex');
    expected_event:=encode(extensions.digest(convert_to(public._fiscal_event_material(
      event_row.sequence_number,event_row.event_type,event_row.entity_type,event_row.entity_id,event_row.occurred_at,
      event_row.effective_at,event_row.previous_hash,event_row.payload_hash,event_row.application_version,
      event_row.schema_version,event_row.canonicalization_version
    ),'UTF8'),'sha256'),'hex');
    if event_row.sequence_number<>expected_sequence then anomalies:=anomalies||jsonb_build_array(jsonb_build_object('sequence',event_row.sequence_number,'code','sequence_break','expected',expected_sequence)); end if;
    if event_row.previous_hash is distinct from expected_previous then anomalies:=anomalies||jsonb_build_array(jsonb_build_object('sequence',event_row.sequence_number,'code','previous_hash_mismatch')); end if;
    if event_row.payload_hash<>expected_payload then anomalies:=anomalies||jsonb_build_array(jsonb_build_object('sequence',event_row.sequence_number,'code','payload_hash_mismatch')); end if;
    if event_row.event_hash<>expected_event then anomalies:=anomalies||jsonb_build_array(jsonb_build_object('sequence',event_row.sequence_number,'code','event_hash_mismatch')); end if;
    expected_sequence:=event_row.sequence_number+1;expected_previous:=event_row.event_hash;
  end loop;
  return jsonb_build_object('valid',jsonb_array_length(anomalies)=0,'checked_events',checked_count,
    'last_sequence',expected_sequence-1,'last_hash',expected_previous,'anomalies',anomalies,
    'signature_verification','not_available_without_kms','verified_at',clock_timestamp());
end
$$;
revoke all on function public.verify_fiscal_event_chain(uuid) from public,anon;
grant execute on function public.verify_fiscal_event_chain(uuid) to authenticated;

create or replace function public.log_finalized_document_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare snapshot_hash text; event_kind text;
begin
  if new.finalized_at is null or new.snapshot_id is null or new.snapshot_id is not distinct from old.snapshot_id then return new; end if;
  select payload_hash into snapshot_hash from public.document_snapshots where id=new.snapshot_id and company_id=new.company_id;
  event_kind:=case when new.document_type='credit_note' then 'credit_note_finalized' else 'invoice_finalized' end;
  perform public._append_fiscal_event(new.company_id,event_kind,'document',new.id,new.finalized_at,jsonb_build_object(
    'number',new.number,'document_type',new.document_type,'snapshot_id',new.snapshot_id,'snapshot_hash',snapshot_hash,
    'total_excl_tax',new.total_excl_tax,'total_tax',new.total_tax,'total_incl_tax',new.total_incl_tax,
    'currency',new.currency,'fiscal_security_status',new.fiscal_security_status,'versions',jsonb_build_object(
      'application',new.application_version,'git_commit',new.git_commit,'schema',new.database_schema_version,
      'calculation',new.calculation_version,'pdf',new.pdf_generator_version,'electronic_format',new.electronic_format_version,
      'fiscal_policy',new.fiscal_policy_version
    )),'database_trigger',jsonb_build_object('post_activation_only',true));
  return new;
end
$$;
revoke all on function public.log_finalized_document_event() from public,anon,authenticated;
drop trigger if exists documents_log_finalized_fiscal_event on public.documents;
create trigger documents_log_finalized_fiscal_event after update of snapshot_id on public.documents
for each row execute function public.log_finalized_document_event();

create or replace function public.log_final_document_status_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if old.finalized_at is null or new.status is not distinct from old.status then return new; end if;
  perform public._append_fiscal_event(new.company_id,'document_status_changed','document',new.id,clock_timestamp(),
    jsonb_build_object('number',new.number,'old_status',old.status,'new_status',new.status),'database_trigger','{}'::jsonb);
  return new;
end
$$;
revoke all on function public.log_final_document_status_event() from public,anon,authenticated;
drop trigger if exists documents_log_final_status_event on public.documents;
create trigger documents_log_final_status_event after update of status on public.documents
for each row execute function public.log_final_document_status_event();

-- Le tableau historique payments devient le registre d'encaissement append-only.
alter table public.payments
  add column if not exists entry_type text not null default 'payment'
    check(entry_type in('payment','correction','refund','rejection','chargeback','overpayment')),
  add column if not exists reverses_payment_id uuid references public.payments(id) on delete restrict,
  add column if not exists correction_reason text,
  add column if not exists fiscal_event_id uuid references public.fiscal_events(id) on delete restrict,
  add column if not exists payload_hash text,
  add column if not exists application_version text,
  add column if not exists schema_version text;

alter table public.payments drop constraint if exists payments_amount_check;
alter table public.payments add constraint payments_signed_amount_check check(
  (entry_type in('payment','overpayment') and amount>0) or
  (entry_type in('correction','refund','rejection','chargeback') and amount<0)
);
-- L'ancienne migration de cycle de vie n'accordait explicitement que la
-- colonne `comment` : une lecture REST du registre échouait donc dès qu'elle
-- demandait le montant ou l'état. Le droit reste strictement en lecture et la
-- RLS continue d'isoler chaque entreprise.
grant select(
  id,company_id,document_id,amount,currency,paid_at,payment_method,reference,
  status,created_by,created_at,updated_at,comment,entry_type,
  reverses_payment_id,correction_reason,fiscal_event_id,payload_hash,
  application_version,schema_version
) on public.payments to authenticated;
create unique index if not exists payments_single_full_reversal_idx on public.payments(reverses_payment_id)
where reverses_payment_id is not null and entry_type in('correction','rejection','chargeback');

create or replace function public.protect_fiscal_payment_entry()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  raise exception 'payment_ledger_is_append_only' using errcode='55000';
end
$$;
revoke all on function public.protect_fiscal_payment_entry() from public,anon,authenticated;
drop trigger if exists payments_protect_confirmed on public.payments;
drop trigger if exists payments_append_only on public.payments;
create trigger payments_append_only before update or delete on public.payments
for each row execute function public.protect_fiscal_payment_entry();

create or replace function public._rebuild_document_payment_projection(target_document_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; paid numeric:=0; new_status text; remaining numeric; schedule_row public.payment_schedules%rowtype; allocation numeric;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null then raise exception 'invoice_not_found'; end if;
  select coalesce(sum(amount),0) into paid from public.payments where document_id=doc.id and status='confirmed';
  new_status:=case when paid>=doc.total_incl_tax-0.01 then 'paid' when paid>0 then 'partially_paid'
    when doc.due_date<current_date then 'overdue' else 'finalized' end;
  update public.documents set status=new_status,updated_at=now() where id=doc.id;
  update public.payment_schedules set paid_amount=0,status='pending',updated_at=now()
  where document_id=doc.id and status<>'cancelled';
  remaining:=greatest(paid,0);
  for schedule_row in select * from public.payment_schedules where document_id=doc.id and status<>'cancelled' order by due_date,id for update loop
    allocation:=least(remaining,schedule_row.amount);
    update public.payment_schedules set paid_amount=allocation,status=case when allocation>=amount-0.01 then 'paid' when allocation>0 then 'partial' else 'pending' end,updated_at=now()
    where id=schedule_row.id;
    remaining:=greatest(remaining-allocation,0);
  end loop;
end
$$;
revoke all on function public._rebuild_document_payment_projection(uuid) from public,anon,authenticated;

create or replace function public.record_document_payment_v2(
  target_document_id uuid,payment_amount numeric,payment_method text default null,
  payment_reference text default null,payment_date timestamptz default now(),payment_comment text default null
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype; payment_id uuid:=gen_random_uuid(); paid numeric; config public.company_fiscal_configurations%rowtype;
  event_id uuid; payload jsonb; payload_digest text;
begin
  if payment_amount is null or payment_amount<=0 then raise exception 'invalid_payment_amount'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.document_type not in('invoice','deposit_invoice','balance_invoice')
    or doc.finalized_at is null or doc.status in('draft','cancelled','archived') then raise exception 'invalid_invoice_state'; end if;
  if not public.is_company_member(doc.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select coalesce(sum(amount),0) into paid from public.payments where document_id=doc.id and status='confirmed';
  if paid+payment_amount>doc.total_incl_tax+0.01 then raise exception 'payment_exceeds_balance'; end if;
  select * into config from public.company_fiscal_configurations where company_id=doc.company_id;
  payload:=jsonb_build_object('payment_id',payment_id,'document_id',doc.id,'document_number',doc.number,
    'client_id',doc.client_id,'amount',round(payment_amount,2),'currency',doc.currency,'paid_at',coalesce(payment_date,now()),
    'payment_method',payment_method,'reference',payment_reference,'comment_present',nullif(trim(payment_comment),'') is not null);
  payload_digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  event_id:=public._append_fiscal_event(doc.company_id,'payment_recorded','payment',payment_id,coalesce(payment_date,now()),payload,'rpc','{}'::jsonb);
  insert into public.payments(
    id,company_id,document_id,amount,currency,paid_at,payment_method,reference,status,comment,entry_type,
    fiscal_event_id,payload_hash,application_version,schema_version,created_by
  ) values(
    payment_id,doc.company_id,doc.id,round(payment_amount,2),doc.currency,coalesce(payment_date,now()),
    nullif(trim(payment_method),''),nullif(trim(payment_reference),''),'confirmed',nullif(trim(payment_comment),''),'payment',
    event_id,payload_digest,coalesce(config.application_version,'2026.07-compliance'),coalesce(config.schema_version,'202607220040'),auth.uid()
  );
  perform public._rebuild_document_payment_projection(doc.id);
  return payment_id;
end
$$;

create or replace function public.record_document_payment(
  target_document_id uuid,payment_amount numeric,payment_method text default null,
  payment_reference text default null,payment_date timestamptz default now()
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
begin
  return public.record_document_payment_v2(target_document_id,payment_amount,payment_method,payment_reference,payment_date,null);
end
$$;

create or replace function public.cancel_document_payment(target_payment_id uuid,cancellation_reason text)
returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  target public.payments%rowtype; correction_id uuid:=gen_random_uuid(); config public.company_fiscal_configurations%rowtype;
  event_id uuid; payload jsonb; payload_digest text;
begin
  if nullif(trim(cancellation_reason),'') is null then raise exception 'cancellation_reason_required'; end if;
  select * into target from public.payments where id=target_payment_id for update;
  if target.id is null or target.status<>'confirmed' or target.entry_type not in('payment','overpayment') then raise exception 'invalid_payment_state'; end if;
  if not public.is_company_member(target.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if exists(select 1 from public.payments where reverses_payment_id=target.id and status='confirmed') then raise exception 'payment_already_corrected'; end if;
  select * into config from public.company_fiscal_configurations where company_id=target.company_id;
  payload:=jsonb_build_object('correction_id',correction_id,'reverses_payment_id',target.id,'document_id',target.document_id,
    'amount',-target.amount,'currency',target.currency,'reason',trim(cancellation_reason));
  payload_digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  event_id:=public._append_fiscal_event(target.company_id,'payment_corrected','payment',correction_id,clock_timestamp(),payload,'rpc','{}'::jsonb);
  insert into public.payments(
    id,company_id,document_id,amount,currency,paid_at,payment_method,reference,status,comment,entry_type,
    reverses_payment_id,correction_reason,fiscal_event_id,payload_hash,application_version,schema_version,created_by
  ) values(
    correction_id,target.company_id,target.document_id,-target.amount,target.currency,clock_timestamp(),target.payment_method,
    target.reference,'confirmed','Correction : '||trim(cancellation_reason),'correction',target.id,trim(cancellation_reason),
    event_id,payload_digest,coalesce(config.application_version,'2026.07-compliance'),coalesce(config.schema_version,'202607220040'),auth.uid()
  );
  perform public._rebuild_document_payment_projection(target.document_id);
  return correction_id;
end
$$;

revoke all on function public.record_document_payment_v2(uuid,numeric,text,text,timestamptz,text) from public,anon;
revoke all on function public.record_document_payment(uuid,numeric,text,text,timestamptz) from public,anon;
revoke all on function public.cancel_document_payment(uuid,text) from public,anon;
grant execute on function public.record_document_payment_v2(uuid,numeric,text,text,timestamptz,text) to authenticated;
grant execute on function public.record_document_payment(uuid,numeric,text,text,timestamptz) to authenticated;
grant execute on function public.cancel_document_payment(uuid,text) to authenticated;

create table if not exists public.fiscal_closures(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  closure_type text not null check(closure_type in('daily','monthly','annual')),
  period_start timestamptz not null,
  period_end timestamptz not null,
  closure_number text not null,
  created_at timestamptz not null default now(),
  created_by uuid,
  total_collections numeric(15,2) not null,
  total_corrections numeric(15,2) not null,
  total_refunds numeric(15,2) not null,
  payment_method_breakdown jsonb not null,
  vat_breakdown jsonb not null,
  cumulative_totals jsonb not null,
  event_count bigint not null,
  first_event_sequence bigint,
  last_event_sequence bigint,
  period_hash text not null,
  previous_closure_hash text,
  closure_hash text not null,
  signature text,
  signature_key_id text,
  integrity_status text not null default 'unsigned' check(integrity_status in('unsigned','signed','verification_error')),
  application_version text not null,
  schema_version text not null,
  metadata jsonb not null default '{}'::jsonb,
  finalized_at timestamptz not null default now(),
  unique(company_id,closure_type,period_start,period_end),
  unique(company_id,closure_number),
  check(period_end>period_start)
);
create index if not exists fiscal_closures_company_period_idx on public.fiscal_closures(company_id,period_start,period_end);
alter table public.fiscal_closures enable row level security;
drop policy if exists fiscal_closures_select on public.fiscal_closures;
create policy fiscal_closures_select on public.fiscal_closures for select to authenticated using(public.is_company_member(company_id));
revoke all on public.fiscal_closures from anon,authenticated;
grant select on public.fiscal_closures to authenticated;
drop trigger if exists fiscal_closures_immutable on public.fiscal_closures;
create trigger fiscal_closures_immutable before update or delete on public.fiscal_closures
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.generate_fiscal_closure(
  target_company_id uuid,target_closure_type text,target_period_start timestamptz,target_period_end timestamptz
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  config public.company_fiscal_configurations%rowtype; closure_id uuid:=gen_random_uuid(); closure_number_value text;
  collections numeric:=0; corrections numeric:=0; refunds numeric:=0; method_breakdown jsonb:='{}'::jsonb;
  first_sequence bigint; last_sequence bigint; events_count bigint:=0; previous_hash text; cumulative jsonb;
  summary jsonb; period_digest text; closure_digest text; event_id uuid;
begin
  if target_closure_type not in('daily','monthly','annual') or target_period_start is null or target_period_end<=target_period_start then raise exception 'invalid_closure_period'; end if;
  if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
  if target_period_end>clock_timestamp() then raise exception 'closure_period_not_finished'; end if;
  if exists(select 1 from public.fiscal_closures where company_id=target_company_id and closure_type=target_closure_type
    and tstzrange(period_start,period_end,'[)')&&tstzrange(target_period_start,target_period_end,'[)')) then raise exception 'closure_period_overlap'; end if;
  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  select coalesce(sum(amount) filter(where entry_type in('payment','overpayment')),0),
    coalesce(sum(amount) filter(where entry_type in('correction','rejection','chargeback')),0),
    coalesce(sum(amount) filter(where entry_type='refund'),0)
  into collections,corrections,refunds from public.payments
  where company_id=target_company_id and status='confirmed' and paid_at>=target_period_start and paid_at<target_period_end;
  select coalesce(jsonb_object_agg(method,total),'{}'::jsonb) into method_breakdown from(
    select coalesce(nullif(payment_method,''),'unspecified') method,round(sum(amount),2) total from public.payments
    where company_id=target_company_id and status='confirmed' and paid_at>=target_period_start and paid_at<target_period_end
    group by coalesce(nullif(payment_method,''),'unspecified')
  ) methods;
  select min(sequence_number),max(sequence_number),count(*) into first_sequence,last_sequence,events_count
  from public.fiscal_events where company_id=target_company_id and occurred_at>=target_period_start and occurred_at<target_period_end;
  select closure_hash into previous_hash from public.fiscal_closures where company_id=target_company_id
  order by period_end desc,created_at desc limit 1;
  select jsonb_build_object('collections',coalesce(sum(total_collections),0)+collections,
    'corrections',coalesce(sum(total_corrections),0)+corrections,'refunds',coalesce(sum(total_refunds),0)+refunds)
  into cumulative from public.fiscal_closures where company_id=target_company_id;
  closure_number_value:=public._piloz_take_document_number(target_company_id,'closure_'||target_closure_type,
    extract(year from target_period_end at time zone 'UTC')::integer,false);
  summary:=jsonb_build_object('closure_id',closure_id,'closure_type',target_closure_type,'period_start',target_period_start,
    'period_end',target_period_end,'closure_number',closure_number_value,'collections',collections,'corrections',corrections,
    'refunds',refunds,'payment_method_breakdown',method_breakdown,'vat_breakdown_status','not_computed_requires_validation',
    'event_count',events_count,'first_event_sequence',first_sequence,'last_event_sequence',last_sequence,'previous_closure_hash',previous_hash);
  period_digest:=encode(extensions.digest(convert_to(summary::text,'UTF8'),'sha256'),'hex');
  closure_digest:=encode(extensions.digest(convert_to(concat_ws('|',previous_hash,period_digest,closure_number_value,
    coalesce(config.application_version,'2026.07-compliance'),coalesce(config.schema_version,'202607220040')),'UTF8'),'sha256'),'hex');
  insert into public.fiscal_closures(
    id,company_id,closure_type,period_start,period_end,closure_number,created_by,total_collections,total_corrections,
    total_refunds,payment_method_breakdown,vat_breakdown,cumulative_totals,event_count,first_event_sequence,last_event_sequence,
    period_hash,previous_closure_hash,closure_hash,signature,signature_key_id,integrity_status,application_version,schema_version,metadata
  ) values(
    closure_id,target_company_id,target_closure_type,target_period_start,target_period_end,closure_number_value,auth.uid(),
    collections,corrections,refunds,method_breakdown,jsonb_build_object('status','not_computed_requires_validation'),cumulative,
    events_count,first_sequence,last_sequence,period_digest,previous_hash,closure_digest,null,null,'unsigned',
    coalesce(config.application_version,'2026.07-compliance'),coalesce(config.schema_version,'202607220040'),
    jsonb_build_object('signature_status','not_configured','nf525_closure_level','requires_external_validation')
  );
  event_id:=public._append_fiscal_event(target_company_id,target_closure_type||'_closure_created','fiscal_closure',closure_id,
    target_period_end,summary||jsonb_build_object('period_hash',period_digest,'closure_hash',closure_digest),'rpc','{}'::jsonb);
  return closure_id;
end
$$;
revoke all on function public.generate_fiscal_closure(uuid,text,timestamptz,timestamptz) from public,anon;
grant execute on function public.generate_fiscal_closure(uuid,text,timestamptz,timestamptz) to authenticated;

commit;
