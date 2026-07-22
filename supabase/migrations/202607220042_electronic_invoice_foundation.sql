begin;

-- Phase 5 — modèle canonique et fondation de facturation électronique.
-- Aucun profil UBL/CII/Factur-X n'est préinstallé : les artefacts officiels
-- et leur licence doivent être fournis et validés avant tout export XML.

alter table public.company_settings
  add column if not exists electronic_invoicing_email text,
  add column if not exists electronic_routing_identifier text,
  add column if not exists electronic_routing_scheme text,
  add column if not exists approved_platform_name text,
  add column if not exists approved_platform_identifier text;

alter table public.clients
  add column if not exists electronic_billing_email text,
  add column if not exists electronic_routing_identifier text,
  add column if not exists electronic_routing_scheme text,
  add column if not exists customer_category text not null default 'unknown'
    check(customer_category in('unknown','b2b','b2c','public_sector')),
  add column if not exists delivery_address_line_1 text,
  add column if not exists delivery_address_line_2 text,
  add column if not exists delivery_postal_code text,
  add column if not exists delivery_city text,
  add column if not exists delivery_country_code text;

alter table public.documents
  add column if not exists operation_category text,
  add column if not exists supply_date date,
  add column if not exists contract_reference text,
  add column if not exists purchase_order_reference text,
  add column if not exists electronic_invoice_status text not null default 'not_prepared'
    check(electronic_invoice_status in('not_prepared','canonical_invalid','canonical_valid','format_blocked','format_validated','ready','transmitted','delivered','rejected','cancelled')),
  add column if not exists electronic_profile_code text,
  add column if not exists electronic_format text,
  add column if not exists electronic_invoice_record_id uuid;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='documents_operation_category_check') then
    alter table public.documents add constraint documents_operation_category_check
      check(operation_category is null or operation_category in('goods','services','goods_and_services')) not valid;
  end if;
end $$;

grant select(
  electronic_invoicing_email,electronic_routing_identifier,electronic_routing_scheme,
  approved_platform_name,approved_platform_identifier
) on public.company_settings to authenticated;
grant select(
  electronic_billing_email,electronic_routing_identifier,electronic_routing_scheme,customer_category,
  delivery_address_line_1,delivery_address_line_2,delivery_postal_code,delivery_city,delivery_country_code
) on public.clients to authenticated;
grant select(
  operation_category,supply_date,contract_reference,purchase_order_reference,electronic_invoice_status,
  electronic_profile_code,electronic_format,electronic_invoice_record_id
) on public.documents to authenticated;

create table if not exists public.electronic_format_profiles(
  id uuid primary key default gen_random_uuid(),
  profile_code text not null unique,
  format text not null check(format in('ubl','cii','facturx')),
  profile_version text not null,
  specification_name text not null,
  specification_source text not null,
  specification_published_at date,
  xsd_storage_path text,
  schematron_storage_path text,
  artifact_hashes jsonb not null default '{}'::jsonb,
  validation_status text not null default 'not_verified'
    check(validation_status in('not_verified','verified','revoked')),
  installed_at timestamptz,
  installed_by uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.electronic_invoice_records(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  snapshot_id uuid not null references public.document_snapshots(id) on delete restrict,
  record_version integer not null check(record_version>0),
  canonical_format text not null default 'piloz-canonical-invoice',
  canonical_version text not null default '1.0',
  canonical_payload jsonb not null,
  canonical_hash text not null,
  validation_status text not null check(validation_status in('valid','invalid')),
  source_snapshot_hash text not null,
  application_version text not null,
  schema_version text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique(document_id,record_version),
  unique(company_id,canonical_hash)
);

create table if not exists public.electronic_invoice_validation_reports(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  electronic_invoice_record_id uuid not null references public.electronic_invoice_records(id) on delete restrict,
  validation_kind text not null check(validation_kind in('canonical_business_rules','xsd','schematron','platform')),
  profile_id uuid references public.electronic_format_profiles(id) on delete restrict,
  status text not null check(status in('valid','invalid','blocked','not_run')),
  errors jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  validator_name text not null,
  validator_version text not null,
  report_hash text not null,
  created_at timestamptz not null default now(),
  created_by uuid
);

create table if not exists public.electronic_invoice_artifacts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  electronic_invoice_record_id uuid not null references public.electronic_invoice_records(id) on delete restrict,
  direction text not null check(direction in('outbound','inbound')),
  format text not null check(format in('ubl','cii','facturx','internal_json')),
  profile_id uuid references public.electronic_format_profiles(id) on delete restrict,
  original_storage_path text,
  pdf_storage_path text,
  artifact_sha256 text not null,
  pdf_sha256 text,
  media_type text not null,
  validation_report_id uuid references public.electronic_invoice_validation_reports(id) on delete restrict,
  status text not null check(status in('stored','validated','invalid','blocked')),
  created_at timestamptz not null default now(),
  created_by uuid,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists electronic_invoice_records_company_document_idx
  on public.electronic_invoice_records(company_id,document_id,record_version desc);
create unique index if not exists electronic_invoice_records_company_id_uidx
  on public.electronic_invoice_records(company_id,id);
create index if not exists electronic_invoice_reports_record_idx
  on public.electronic_invoice_validation_reports(company_id,electronic_invoice_record_id,created_at);
create index if not exists electronic_invoice_artifacts_record_idx
  on public.electronic_invoice_artifacts(company_id,electronic_invoice_record_id,created_at);

do $$ begin
  if not exists(select 1 from pg_constraint where conname='documents_electronic_invoice_record_company_fk') then
    alter table public.documents add constraint documents_electronic_invoice_record_company_fk
      foreign key(company_id,electronic_invoice_record_id)
      references public.electronic_invoice_records(company_id,id) not valid;
  end if;
end $$;

alter table public.electronic_format_profiles enable row level security;
alter table public.electronic_invoice_records enable row level security;
alter table public.electronic_invoice_validation_reports enable row level security;
alter table public.electronic_invoice_artifacts enable row level security;
drop policy if exists electronic_format_profiles_select on public.electronic_format_profiles;
create policy electronic_format_profiles_select on public.electronic_format_profiles for select to authenticated using(true);
drop policy if exists electronic_invoice_records_select on public.electronic_invoice_records;
create policy electronic_invoice_records_select on public.electronic_invoice_records for select to authenticated
using(public.is_company_member(company_id));
drop policy if exists electronic_invoice_validation_reports_select on public.electronic_invoice_validation_reports;
create policy electronic_invoice_validation_reports_select on public.electronic_invoice_validation_reports for select to authenticated
using(public.is_company_member(company_id));
drop policy if exists electronic_invoice_artifacts_select on public.electronic_invoice_artifacts;
create policy electronic_invoice_artifacts_select on public.electronic_invoice_artifacts for select to authenticated
using(public.is_company_member(company_id));
revoke all on public.electronic_format_profiles,public.electronic_invoice_records,
  public.electronic_invoice_validation_reports,public.electronic_invoice_artifacts from anon,authenticated;
grant select on public.electronic_format_profiles,public.electronic_invoice_records,
  public.electronic_invoice_validation_reports,public.electronic_invoice_artifacts to authenticated;

drop trigger if exists electronic_format_profiles_immutable on public.electronic_format_profiles;
create trigger electronic_format_profiles_immutable before update or delete on public.electronic_format_profiles
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists electronic_invoice_records_immutable on public.electronic_invoice_records;
create trigger electronic_invoice_records_immutable before update or delete on public.electronic_invoice_records
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists electronic_invoice_validation_reports_immutable on public.electronic_invoice_validation_reports;
create trigger electronic_invoice_validation_reports_immutable before update or delete on public.electronic_invoice_validation_reports
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists electronic_invoice_artifacts_immutable on public.electronic_invoice_artifacts;
create trigger electronic_invoice_artifacts_immutable before update or delete on public.electronic_invoice_artifacts
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.build_canonical_invoice(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; snapshot public.document_snapshots%rowtype; client_row public.clients%rowtype;
  payment_rows jsonb; linked_rows jsonb; tax_rows jsonb;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then
    raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note')
    or doc.finalized_at is null or doc.snapshot_id is null then raise exception 'finalized_fiscal_document_required'; end if;
  select * into snapshot from public.document_snapshots where id=doc.snapshot_id and company_id=doc.company_id;
  if snapshot.id is null then raise exception 'document_snapshot_missing'; end if;
  select * into client_row from public.clients where id=doc.client_id and company_id=doc.company_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'entry_type',p.entry_type,'amount',p.amount,'currency',p.currency,'paid_at',p.paid_at,
    'method',p.payment_method,'reference',p.reference,'reverses_payment_id',p.reverses_payment_id,
    'payload_hash',p.payload_hash) order by p.paid_at,p.id),'[]'::jsonb)
    into payment_rows from public.payments p where p.document_id=doc.id and p.company_id=doc.company_id;
  select coalesce(jsonb_agg(jsonb_build_object('link_type',l.link_type,'source_document_id',l.source_document_id,
    'target_document_id',l.target_document_id,'metadata',l.metadata) order by l.created_at,l.id),'[]'::jsonb)
    into linked_rows from public.document_links l where l.company_id=doc.company_id
      and (l.source_document_id=doc.id or l.target_document_id=doc.id);
  select coalesce(jsonb_agg(jsonb_build_object('rate',rate,'taxable_amount',taxable,'tax_amount',tax,'total_amount',total)
    order by rate),'[]'::jsonb) into tax_rows from(
      select coalesce(nullif(line->>'tax_rate','')::numeric,0) rate,
        round(sum(coalesce(nullif(line->>'total_excl_tax','')::numeric,0)),2) taxable,
        round(sum(coalesce(nullif(line->>'total_tax','')::numeric,0)),2) tax,
        round(sum(coalesce(nullif(line->>'total_incl_tax','')::numeric,0)),2) total
      from jsonb_array_elements(snapshot.public_payload->'lines') line
      where coalesce(line->>'optional','false')<>'true' group by coalesce(nullif(line->>'tax_rate','')::numeric,0)
    ) grouped;
  return jsonb_build_object(
    'format','piloz-canonical-invoice','format_version','1.0',
    'supplier',coalesce(snapshot.public_payload->'issuer','{}'::jsonb)||jsonb_build_object(
      'electronic_invoicing_email',(snapshot.public_payload->'issuer')->>'electronic_invoicing_email',
      'routing_identifier',(snapshot.public_payload->'issuer')->>'electronic_routing_identifier',
      'routing_scheme',(snapshot.public_payload->'issuer')->>'electronic_routing_scheme'),
    'customer',coalesce(snapshot.public_payload->'client','{}'::jsonb)||jsonb_build_object(
      'category',coalesce(client_row.customer_category,'unknown'),'electronic_billing_email',client_row.electronic_billing_email,
      'routing_identifier',client_row.electronic_routing_identifier,'routing_scheme',client_row.electronic_routing_scheme),
    'invoice',jsonb_build_object('id',doc.id,'number',doc.number,'type',doc.document_type,'issue_date',doc.issue_date,
      'due_date',doc.due_date,'supply_date',doc.supply_date,'currency',doc.currency,'language',doc.language,
      'operation_category',coalesce(doc.operation_category,doc.sale_type),'subject',doc.subject,
      'contract_reference',doc.contract_reference,'purchase_order_reference',coalesce(doc.purchase_order_reference,doc.client_reference)),
    'lines',coalesce(snapshot.public_payload->'lines','[]'::jsonb),'tax_breakdown',tax_rows,
    'totals',jsonb_build_object('excl_tax',doc.total_excl_tax,'tax',doc.total_tax,'incl_tax',doc.total_incl_tax,
      'paid',coalesce((select sum(p.amount) from public.payments p where p.document_id=doc.id and p.status='confirmed'),0),
      'payable',greatest(0,doc.total_incl_tax-coalesce((select sum(p.amount) from public.payments p where p.document_id=doc.id and p.status='confirmed'),0))),
    'payment',jsonb_build_object('terms',doc.payment_terms,'method',doc.payment_method,'entries',payment_rows),
    'references',linked_rows,
    'delivery',jsonb_build_object('date',doc.supply_date,'address',jsonb_build_object(
      'line1',client_row.delivery_address_line_1,'line2',client_row.delivery_address_line_2,
      'postal_code',client_row.delivery_postal_code,'city',client_row.delivery_city,'country_code',client_row.delivery_country_code)),
    'reporting',jsonb_build_object('customer_category',coalesce(client_row.customer_category,'unknown'),
      'country_code',client_row.country_code,'operation_category',coalesce(doc.operation_category,doc.sale_type),
      'classification_status','requires_rule_engine_validation'),
    'lifecycle',jsonb_build_object('status',doc.electronic_invoice_status,'finalized_at',doc.finalized_at),
    'source',jsonb_build_object('snapshot_id',snapshot.id,'snapshot_hash',snapshot.payload_hash,
      'application_version',doc.application_version,'git_commit',doc.git_commit,'schema_version',doc.database_schema_version,
      'calculation_version',doc.calculation_version,'pdf_generator_version',doc.pdf_generator_version,
      'electronic_format_version',doc.electronic_format_version,'fiscal_policy_version',doc.fiscal_policy_version)
  );
end
$$;
revoke all on function public.build_canonical_invoice(uuid) from public,anon;
grant execute on function public.build_canonical_invoice(uuid) to authenticated;

create or replace function public.create_canonical_invoice_record(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype; snapshot public.document_snapshots%rowtype; payload jsonb; digest text;
  errors jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; record_id uuid:=gen_random_uuid(); report_id uuid:=gen_random_uuid();
  report_payload jsonb; report_digest text; next_version integer; result_status text; event_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  payload:=public.build_canonical_invoice(doc.id);
  select * into snapshot from public.document_snapshots where id=doc.snapshot_id and company_id=doc.company_id;
  if nullif(payload#>>'{invoice,number}','') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','invoice_number_required','field','invoice.number')); end if;
  if nullif(payload#>>'{invoice,issue_date}','') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issue_date_required','field','invoice.issue_date')); end if;
  if nullif(payload#>>'{invoice,currency}','') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','currency_required','field','invoice.currency')); end if;
  if nullif(coalesce(payload#>>'{supplier,legal_name}',payload#>>'{supplier,trade_name}'),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','supplier_name_required','field','supplier.legal_name')); end if;
  if nullif(payload#>>'{supplier,siren}','') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','supplier_siren_required','field','supplier.siren')); end if;
  if nullif(coalesce(payload#>>'{customer,legal_name}',payload#>>'{customer,last_name}'),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','customer_name_required','field','customer')); end if;
  if jsonb_array_length(coalesce(payload->'lines','[]'::jsonb))=0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','invoice_line_required','field','lines')); end if;
  if coalesce(payload#>>'{customer,category}','unknown')='unknown' then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','customer_category_to_confirm','field','customer.category')); end if;
  if nullif(payload#>>'{invoice,operation_category}','') is null then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','operation_category_to_confirm','field','invoice.operation_category')); end if;
  if nullif(payload#>>'{customer,routing_identifier}','') is null then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','routing_identifier_missing','field','customer.routing_identifier')); end if;
  result_status:=case when jsonb_array_length(errors)=0 then 'valid' else 'invalid' end;
  digest:=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex');
  select coalesce(max(record_version),0)+1 into next_version from public.electronic_invoice_records where document_id=doc.id;
  insert into public.electronic_invoice_records(
    id,company_id,document_id,snapshot_id,record_version,canonical_payload,canonical_hash,validation_status,
    source_snapshot_hash,application_version,schema_version,created_by
  ) values(record_id,doc.company_id,doc.id,snapshot.id,next_version,payload,digest,result_status,snapshot.payload_hash,
    coalesce(doc.application_version,'2026.07-compliance'),'202607220042',auth.uid());
  report_payload:=jsonb_build_object('record_id',record_id,'status',result_status,'errors',errors,'warnings',warnings,
    'validator','piloz-canonical-business-rules','validator_version','1.0');
  report_digest:=encode(extensions.digest(convert_to(report_payload::text,'UTF8'),'sha256'),'hex');
  insert into public.electronic_invoice_validation_reports(
    id,company_id,electronic_invoice_record_id,validation_kind,status,errors,warnings,validator_name,validator_version,
    report_hash,created_by
  ) values(report_id,doc.company_id,record_id,'canonical_business_rules',result_status,errors,warnings,
    'piloz-canonical-business-rules','1.0',report_digest,auth.uid());
  update public.documents set electronic_invoice_status=case when result_status='valid' then 'canonical_valid' else 'canonical_invalid' end,
    electronic_invoice_record_id=record_id,electronic_format='internal_json',updated_at=now() where id=doc.id;
  perform public._append_fiscal_event(doc.company_id,'electronic_invoice_canonicalized','document',doc.id,clock_timestamp(),
    jsonb_build_object('record_id',record_id,'canonical_hash',digest,'validation_status',result_status,
      'error_count',jsonb_array_length(errors),'warning_count',jsonb_array_length(warnings),'source_snapshot_hash',snapshot.payload_hash),
    'rpc','{}'::jsonb);
  return jsonb_build_object('record_id',record_id,'validation_report_id',report_id,'status',result_status,
    'canonical_hash',digest,'errors',errors,'warnings',warnings,'profile_exports','blocked_until_official_profiles_are_installed');
end
$$;
revoke all on function public.create_canonical_invoice_record(uuid) from public,anon;
grant execute on function public.create_canonical_invoice_record(uuid) to authenticated;

create or replace function public.check_electronic_format_profile(target_format text,target_profile_code text default null)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare profile public.electronic_format_profiles%rowtype;
begin
  if target_format not in('ubl','cii','facturx') then raise exception 'unsupported_electronic_format'; end if;
  select * into profile from public.electronic_format_profiles where format=target_format
    and (target_profile_code is null or profile_code=target_profile_code)
    and validation_status='verified' order by installed_at desc nulls last limit 1;
  if profile.id is null then return jsonb_build_object('ready',false,'format',target_format,
    'code','official_profile_not_configured','message','Le profil officiel XSD/Schematron n''est pas installé ou vérifié.',
    'external_validation_required',true); end if;
  return jsonb_build_object('ready',true,'format',target_format,'profile_id',profile.id,
    'profile_code',profile.profile_code,'profile_version',profile.profile_version,'external_validation_required',true);
end
$$;
revoke all on function public.check_electronic_format_profile(text,text) from public,anon;
grant execute on function public.check_electronic_format_profile(text,text) to authenticated;

commit;
