begin;

-- Phase 6 — connecteur abstrait, statuts séparés et qualification e-reporting.
-- Seul un sandbox local explicitement simulé est disponible. Aucune émission
-- externe de production n'est autorisée par cette migration.

-- La phase 5 utilisait un sous-ensemble de statuts. Cette contrainte est
-- élargie sans toucher aux valeurs existantes afin de conserver les statuts
-- de plateforme séparés du statut commercial.
alter table public.documents drop constraint if exists documents_electronic_invoice_status_check;
alter table public.documents add constraint documents_electronic_invoice_status_check
  check(electronic_invoice_status in('not_prepared','canonical_invalid','canonical_valid','format_blocked','format_validated',
    'ready','transmitted','received','accepted','rejected','refused','suspended','completed','paid','other','cancelled')) not valid;

create table if not exists public.platform_connectors(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  connector_code text not null,
  provider_name text not null,
  connector_kind text not null check(connector_kind in('sandbox','accredited_platform')),
  environment text not null check(environment in('sandbox','production')),
  status text not null check(status in('unconfigured','configured','tested','validation_required','active','suspended','error')),
  is_simulation boolean not null default true,
  production_enabled boolean not null default false,
  credential_secret_ref text,
  webhook_secret_ref text,
  base_url text,
  capabilities jsonb not null default '{}'::jsonb,
  non_secret_configuration jsonb not null default '{}'::jsonb,
  external_validation_evidence jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,connector_code,environment),
  check(not production_enabled or (connector_kind='accredited_platform' and environment='production'
    and not is_simulation and status='active' and credential_secret_ref is not null))
);

create table if not exists public.platform_transmissions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  connector_id uuid not null references public.platform_connectors(id) on delete restrict,
  electronic_invoice_record_id uuid references public.electronic_invoice_records(id) on delete restrict,
  reporting_record_id uuid,
  operation text not null check(operation in('send_invoice','receive_invoice','get_status','send_status','send_reporting_transaction','send_reporting_payment','download_attachment','cancel')),
  idempotency_key text not null,
  status text not null check(status in('queued','processing','retry_scheduled','succeeded','failed','dead_letter','cancelled')),
  is_simulation boolean not null,
  attempt_count integer not null default 0 check(attempt_count>=0),
  next_attempt_at timestamptz,
  external_transmission_id text,
  external_status text,
  request_hash text not null,
  response_hash text,
  last_error_code text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  unique(company_id,connector_id,idempotency_key)
);

create table if not exists public.platform_transmission_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  transmission_id uuid not null references public.platform_transmissions(id) on delete restrict,
  event_sequence integer not null check(event_sequence>0),
  event_type text not null,
  status text not null,
  occurred_at timestamptz not null default now(),
  source text not null,
  payload_hash text not null,
  payload jsonb not null default '{}'::jsonb,
  created_by uuid,
  unique(transmission_id,event_sequence)
);

create table if not exists public.platform_dead_letters(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  transmission_id uuid not null unique references public.platform_transmissions(id) on delete restrict,
  reason_code text not null,
  failed_at timestamptz not null default now(),
  retry_count integer not null,
  resolution_status text not null default 'open' check(resolution_status in('open','retry_requested','resolved','abandoned')),
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text,
  created_at timestamptz not null default now()
);

create table if not exists public.platform_webhook_receipts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  connector_id uuid not null references public.platform_connectors(id) on delete restrict,
  external_event_id text,
  received_at timestamptz not null default now(),
  body_hash text not null,
  signature_status text not null check(signature_status in('valid','invalid','missing','not_configured')),
  processing_status text not null check(processing_status in('received','processed','ignored','failed')),
  raw_storage_path text,
  error_code text,
  metadata jsonb not null default '{}'::jsonb,
  unique(connector_id,external_event_id)
);

create table if not exists public.electronic_invoice_lifecycle_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  previous_status text,
  new_status text not null check(new_status in('to_prepare','technical_validated','deposited','transmitted','received','accepted','rejected','refused','suspended','completed','paid','other')),
  external_status text,
  external_event_id text,
  source text not null,
  external_payload_hash text,
  transition_rules_version text not null default 'draft-v1-external-validation-required',
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  actor_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  unique(company_id,source,external_event_id)
);

create table if not exists public.e_reporting_records(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete restrict,
  event_kind text not null check(event_kind in('transaction','payment')),
  classification text not null check(classification in('e_invoice','e_reporting_transaction','e_reporting_payment','out_of_scope','to_verify')),
  rule_code text not null,
  justification text not null,
  missing_data jsonb not null default '[]'::jsonb,
  external_validation_required boolean not null default true,
  classification_version text not null default 'fr-preclassification-v1',
  payload jsonb not null,
  payload_hash text not null,
  transmission_status text not null default 'not_queued' check(transmission_status in('not_queued','queued','simulated','transmitted','failed')),
  created_by uuid,
  created_at timestamptz not null default now()
);

do $$ begin
  if not exists(select 1 from pg_constraint where conname='platform_transmissions_reporting_record_fk') then
    alter table public.platform_transmissions add constraint platform_transmissions_reporting_record_fk
      foreign key(reporting_record_id) references public.e_reporting_records(id) on delete restrict not valid;
  end if;
end $$;

create index if not exists platform_transmissions_queue_idx on public.platform_transmissions(status,next_attempt_at,created_at);
create index if not exists platform_transmission_events_idx on public.platform_transmission_events(company_id,transmission_id,event_sequence);
create index if not exists electronic_invoice_lifecycle_document_idx on public.electronic_invoice_lifecycle_events(company_id,document_id,recorded_at);
create index if not exists e_reporting_records_document_idx on public.e_reporting_records(company_id,document_id,created_at);

do $$ declare table_name text; begin
  foreach table_name in array array['platform_connectors','platform_transmissions','platform_transmission_events',
    'platform_dead_letters','platform_webhook_receipts','electronic_invoice_lifecycle_events','e_reporting_records'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    execute format('revoke all on public.%I from anon,authenticated',table_name);
    execute format('grant select on public.%I to authenticated',table_name);
  end loop;
end $$;

drop trigger if exists platform_transmission_events_immutable on public.platform_transmission_events;
create trigger platform_transmission_events_immutable before update or delete on public.platform_transmission_events
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists platform_webhook_receipts_immutable on public.platform_webhook_receipts;
create trigger platform_webhook_receipts_immutable before update or delete on public.platform_webhook_receipts
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists electronic_invoice_lifecycle_events_immutable on public.electronic_invoice_lifecycle_events;
create trigger electronic_invoice_lifecycle_events_immutable before update or delete on public.electronic_invoice_lifecycle_events
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists e_reporting_records_immutable on public.e_reporting_records;
create trigger e_reporting_records_immutable before update or delete on public.e_reporting_records
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.create_platform_sandbox(target_company_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare connector_id uuid;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
  insert into public.platform_connectors(
    company_id,connector_code,provider_name,connector_kind,environment,status,is_simulation,production_enabled,
    capabilities,non_secret_configuration,created_by
  ) values(target_company_id,'PILOZ_SANDBOX','PILOZ — Simulation','sandbox','sandbox','tested',true,false,
    jsonb_build_object('send_invoice',true,'statuses',true,'e_reporting',true,'webhooks',false),
    jsonb_build_object('display_label','Simulation','external_network',false),auth.uid())
  on conflict(company_id,connector_code,environment) do update set updated_at=now()
  returning id into connector_id;
  perform public._append_fiscal_event(target_company_id,'fiscal_setting_changed','platform_connector',connector_id,clock_timestamp(),
    jsonb_build_object('connector_code','PILOZ_SANDBOX','environment','sandbox','is_simulation',true,
      'production_enabled',false),'rpc',jsonb_build_object('claim','simulation_only'));
  return connector_id;
end
$$;
revoke all on function public.create_platform_sandbox(uuid) from public,anon;
grant execute on function public.create_platform_sandbox(uuid) to authenticated;

create or replace function public.run_platform_sandbox_simulation(
  target_record_id uuid,target_operation text,target_idempotency_key text
) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  record_row public.electronic_invoice_records%rowtype; connector public.platform_connectors%rowtype;
  transmission public.platform_transmissions%rowtype; payload jsonb; digest text;
begin
  if target_operation not in('send_invoice','get_status','send_status') then raise exception 'sandbox_operation_not_supported'; end if;
  if nullif(trim(target_idempotency_key),'') is null or length(target_idempotency_key)>128 then raise exception 'invalid_idempotency_key'; end if;
  select * into record_row from public.electronic_invoice_records where id=target_record_id;
  if record_row.id is null or not public.is_company_member(record_row.company_id) then raise exception 'electronic_invoice_record_not_found' using errcode='P0002'; end if;
  select * into connector from public.platform_connectors where company_id=record_row.company_id
    and connector_code='PILOZ_SANDBOX' and environment='sandbox' and is_simulation limit 1;
  if connector.id is null then raise exception 'sandbox_connector_not_configured'; end if;
  select * into transmission from public.platform_transmissions where company_id=record_row.company_id
    and connector_id=connector.id and idempotency_key=trim(target_idempotency_key);
  if transmission.id is not null then return jsonb_build_object('transmission_id',transmission.id,'status',transmission.status,
    'display_status','Simulation','idempotent',true,'is_simulation',true); end if;
  payload:=jsonb_build_object('record_id',record_row.id,'canonical_hash',record_row.canonical_hash,
    'operation',target_operation,'simulation',true,'external_network',false);
  digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  insert into public.platform_transmissions(
    company_id,connector_id,electronic_invoice_record_id,operation,idempotency_key,status,is_simulation,attempt_count,
    external_transmission_id,external_status,request_hash,response_hash,created_by,completed_at,metadata
  ) values(record_row.company_id,connector.id,record_row.id,target_operation,trim(target_idempotency_key),'succeeded',true,1,
    'SIM-'||gen_random_uuid()::text,'simulation_completed',digest,digest,auth.uid(),clock_timestamp(),
    jsonb_build_object('display_status','Simulation','sent_to_administration',false)) returning * into transmission;
  insert into public.platform_transmission_events(company_id,transmission_id,event_sequence,event_type,status,source,payload_hash,payload,created_by)
  values
    (record_row.company_id,transmission.id,1,'queued','queued','sandbox',digest,jsonb_build_object('simulation',true),auth.uid()),
    (record_row.company_id,transmission.id,2,'simulation_completed','succeeded','sandbox',digest,
      jsonb_build_object('simulation',true,'external_network',false,'sent_to_administration',false),auth.uid());
  perform public._append_fiscal_event(record_row.company_id,'platform_simulation_completed','platform_transmission',transmission.id,
    clock_timestamp(),jsonb_build_object('transmission_id',transmission.id,'operation',target_operation,'record_id',record_row.id,
      'simulation',true,'sent_to_administration',false),'sandbox','{}'::jsonb);
  return jsonb_build_object('transmission_id',transmission.id,'status','succeeded','display_status','Simulation',
    'idempotent',false,'is_simulation',true,'sent_to_administration',false);
end
$$;
revoke all on function public.run_platform_sandbox_simulation(uuid,text,text) from public,anon;
grant execute on function public.run_platform_sandbox_simulation(uuid,text,text) to authenticated;

create or replace function public.classify_transaction_for_french_einvoicing(
  target_document_id uuid,target_event_kind text default 'transaction',target_payment_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype; client_row public.clients%rowtype; issuer public.company_settings%rowtype;
  result_value text; rule_value text; reason_value text; missing jsonb:='[]'::jsonb; record_id uuid:=gen_random_uuid();
  payload jsonb; digest text;
begin
  if target_event_kind not in('transaction','payment') then raise exception 'invalid_reporting_event_kind'; end if;
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  select * into client_row from public.clients where id=doc.client_id and company_id=doc.company_id;
  select * into issuer from public.company_settings where company_id=doc.company_id;
  if nullif(client_row.customer_category,'unknown') is null then missing:=missing||jsonb_build_array(jsonb_build_object('field','client.customer_category')); end if;
  if nullif(client_row.country_code,'') is null then missing:=missing||jsonb_build_array(jsonb_build_object('field','client.country_code')); end if;
  if nullif(coalesce(doc.operation_category,doc.sale_type),'') is null then missing:=missing||jsonb_build_array(jsonb_build_object('field','document.operation_category')); end if;
  if jsonb_array_length(missing)>0 then
    result_value:='to_verify';rule_value:='FR-PRECHECK-MISSING';reason_value:='Des données de qualification sont manquantes.';
  elsif client_row.customer_category='public_sector' then
    result_value:='to_verify';rule_value:='FR-PRECHECK-PUBLIC';reason_value:='Le secteur public nécessite un routage et une validation spécifiques.';
  elsif target_event_kind='payment' and coalesce(doc.operation_category,doc.sale_type) in('services','service') then
    result_value:='e_reporting_payment';rule_value:='FR-PRECHECK-SERVICE-PAYMENT';reason_value:='Encaissement d’une prestation à qualifier pour le e-reporting.';
  elsif client_row.customer_category='b2b' and client_row.country_code='FR' then
    result_value:='e_invoice';rule_value:='FR-PRECHECK-B2B-FR';reason_value:='Transaction B2B France présélectionnée pour le e-invoicing.';
  elsif client_row.customer_category='b2c' or client_row.country_code<>'FR' then
    result_value:='e_reporting_transaction';rule_value:='FR-PRECHECK-B2C-INTL';reason_value:='Transaction B2C ou internationale présélectionnée pour le e-reporting.';
  else
    result_value:='to_verify';rule_value:='FR-PRECHECK-UNRESOLVED';reason_value:='Le cas doit être validé avec les règles réglementaires en vigueur.';
  end if;
  payload:=jsonb_build_object('document_id',doc.id,'payment_id',target_payment_id,'event_kind',target_event_kind,
    'classification',result_value,'rule',rule_value,'justification',reason_value,'missing_data',missing,
    'customer_category',client_row.customer_category,'customer_country',client_row.country_code,
    'operation_category',coalesce(doc.operation_category,doc.sale_type),'issuer_country',issuer.country_code,
    'external_validation_required',true);
  digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  insert into public.e_reporting_records(
    id,company_id,document_id,payment_id,event_kind,classification,rule_code,justification,missing_data,
    external_validation_required,payload,payload_hash,created_by
  ) values(record_id,doc.company_id,doc.id,target_payment_id,target_event_kind,result_value,rule_value,reason_value,
    missing,true,payload,digest,auth.uid());
  perform public._append_fiscal_event(doc.company_id,'e_reporting_classified','e_reporting_record',record_id,clock_timestamp(),
    payload||jsonb_build_object('payload_hash',digest),'rpc','{}'::jsonb);
  return jsonb_build_object('record_id',record_id,'classification',result_value,'rule',rule_value,
    'justification',reason_value,'missing_data',missing,'external_validation_required',true,'transmitted',false);
end
$$;
revoke all on function public.classify_transaction_for_french_einvoicing(uuid,text,uuid) from public,anon;
grant execute on function public.classify_transaction_for_french_einvoicing(uuid,text,uuid) to authenticated;

create or replace function public.record_electronic_invoice_lifecycle_event(
  target_document_id uuid,target_new_status text,target_external_status text,target_external_event_id text,
  target_source text,target_external_payload_hash text,target_occurred_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; previous text; result_id uuid:=gen_random_uuid(); allowed boolean:=false;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null then raise exception 'document_not_found'; end if;
  previous:=case doc.electronic_invoice_status
    when 'not_prepared' then 'to_prepare' when 'canonical_valid' then 'technical_validated'
    when 'format_validated' then 'technical_validated' when 'ready' then 'technical_validated'
    else doc.electronic_invoice_status end;
  allowed:=target_new_status='other' or
    (previous='to_prepare' and target_new_status in('technical_validated','rejected')) or
    (previous='technical_validated' and target_new_status in('deposited','rejected','suspended')) or
    (previous='deposited' and target_new_status in('transmitted','rejected','suspended')) or
    (previous='transmitted' and target_new_status in('received','accepted','rejected','refused','suspended','completed')) or
    (previous in('received','suspended') and target_new_status in('accepted','rejected','refused','completed')) or
    (previous in('accepted','completed') and target_new_status='paid');
  if not allowed then raise exception 'electronic_lifecycle_transition_not_allowed'; end if;
  insert into public.electronic_invoice_lifecycle_events(
    id,company_id,document_id,previous_status,new_status,external_status,external_event_id,source,
    external_payload_hash,occurred_at,actor_id,metadata
  ) values(result_id,doc.company_id,doc.id,previous,target_new_status,target_external_status,
    nullif(trim(target_external_event_id),''),coalesce(nullif(trim(target_source),''),'connector'),
    target_external_payload_hash,coalesce(target_occurred_at,clock_timestamp()),auth.uid(),
    jsonb_build_object('transition_rules_status','external_validation_required'));
  update public.documents set electronic_invoice_status=case target_new_status
    when 'to_prepare' then 'not_prepared' when 'technical_validated' then 'format_validated'
    when 'deposited' then 'ready' else target_new_status end,updated_at=now() where id=doc.id;
  perform public._append_fiscal_event(doc.company_id,'electronic_invoice_status_changed','document',doc.id,
    coalesce(target_occurred_at,clock_timestamp()),jsonb_build_object('previous_status',previous,
      'new_status',target_new_status,'external_status',target_external_status,'external_event_id',target_external_event_id,
      'external_payload_hash',target_external_payload_hash),'connector','{}'::jsonb);
  return result_id;
end
$$;
revoke all on function public.record_electronic_invoice_lifecycle_event(uuid,text,text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.record_electronic_invoice_lifecycle_event(uuid,text,text,text,text,text,timestamptz) to service_role;

commit;
