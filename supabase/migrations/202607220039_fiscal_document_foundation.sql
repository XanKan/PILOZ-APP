begin;

-- Phase 2 — fondation additive du domaine fiscal.
-- Le moteur reste désactivé par défaut. Aucune donnée historique n'est
-- rétroactivement déclarée sécurisée.

alter table public.company_settings
  add column if not exists vat_on_debits boolean not null default false;

create table if not exists public.company_fiscal_configurations(
  company_id uuid primary key references public.companies(id) on delete restrict,
  mode text not null default 'off' check(mode in('off','test','production')),
  activation_status text not null default 'not_ready'
    check(activation_status in('not_ready','ready_for_test','test_active','ready_for_production','production_active','suspended')),
  activated_at timestamptz,
  activated_by uuid,
  application_version text not null default '2026.07-compliance',
  schema_version text not null default '202607220039',
  calculation_version text not null default 'financial-v1',
  pdf_generator_version text not null default 'pdf-v2',
  electronic_format_version text not null default 'not-configured',
  fiscal_policy_version text not null default 'draft-2026-07',
  canonicalization_version text not null default 'jsonb-text-v1',
  signing_status text not null default 'not_configured'
    check(signing_status in('not_configured','test','configured','error')),
  kms_key_id text,
  prerequisites jsonb not null default '{}'::jsonb,
  activated_from_commit text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.company_fiscal_configurations(company_id)
select id from public.companies on conflict(company_id) do nothing;

create or replace function public.seed_company_fiscal_configuration()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.company_fiscal_configurations(company_id) values(new.id)
  on conflict(company_id) do nothing;
  return new;
end
$$;
revoke all on function public.seed_company_fiscal_configuration() from public,anon,authenticated;
drop trigger if exists companies_seed_fiscal_configuration on public.companies;
create trigger companies_seed_fiscal_configuration after insert on public.companies
for each row execute function public.seed_company_fiscal_configuration();

alter table public.company_fiscal_configurations enable row level security;
drop policy if exists company_fiscal_configurations_select on public.company_fiscal_configurations;
create policy company_fiscal_configurations_select on public.company_fiscal_configurations
for select to authenticated using(public.is_company_member(company_id));
revoke all on public.company_fiscal_configurations from anon,authenticated;
grant select on public.company_fiscal_configurations to authenticated;

alter table public.documents
  add column if not exists fiscal_security_status text not null default 'legacy_unsecured'
    check(fiscal_security_status in('legacy_unsecured','test_secured','secured_v1','verification_error')),
  add column if not exists application_version text,
  add column if not exists git_commit text,
  add column if not exists database_schema_version text,
  add column if not exists calculation_version text,
  add column if not exists pdf_generator_version text,
  add column if not exists electronic_format_version text,
  add column if not exists fiscal_policy_version text,
  add column if not exists canonicalization_version text,
  add column if not exists legal_mentions_snapshot jsonb not null default '[]'::jsonb,
  add column if not exists calculation_snapshot jsonb not null default '{}'::jsonb;

grant select(
  fiscal_security_status,application_version,git_commit,database_schema_version,
  calculation_version,pdf_generator_version,electronic_format_version,
  fiscal_policy_version,canonicalization_version,legal_mentions_snapshot,
  calculation_snapshot
) on public.documents to authenticated;

create table if not exists public.document_number_allocations(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  document_type text not null,
  sequence_type text not null,
  fiscal_year integer not null,
  prefix text not null,
  sequence_value bigint not null check(sequence_value>0),
  full_number text not null,
  allocated_at timestamptz not null default now(),
  allocated_by uuid,
  application_version text not null,
  schema_version text not null,
  metadata jsonb not null default '{}'::jsonb,
  unique(document_id),
  unique(company_id,sequence_type,fiscal_year,sequence_value),
  unique(company_id,document_type,full_number)
);
create index if not exists document_number_allocations_company_time_idx
  on public.document_number_allocations(company_id,allocated_at,id);
alter table public.document_number_allocations enable row level security;
drop policy if exists document_number_allocations_select on public.document_number_allocations;
create policy document_number_allocations_select on public.document_number_allocations
for select to authenticated using(public.is_company_member(company_id));
revoke all on public.document_number_allocations from anon,authenticated;
grant select on public.document_number_allocations to authenticated;

create or replace function public.protect_immutable_fiscal_row()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  raise exception 'immutable_fiscal_record' using errcode='55000';
end
$$;
revoke all on function public.protect_immutable_fiscal_row() from public,anon,authenticated;
drop trigger if exists document_number_allocations_immutable on public.document_number_allocations;
create trigger document_number_allocations_immutable before update or delete on public.document_number_allocations
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.record_document_number_allocation()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare
  fiscal_config public.company_fiscal_configurations%rowtype;
  sequence_key text; sequence_row public.document_sequences%rowtype;
  parsed_value bigint;
begin
  if new.number is null or (tg_op='UPDATE' and old.number is not distinct from new.number) then return new; end if;
  sequence_key:=public._piloz_document_sequence_key(new.document_type);
  select * into sequence_row from public.document_sequences
  where company_id=new.company_id and document_type=sequence_key
    and year=extract(year from coalesce(new.issue_date,current_date))::integer;
  begin parsed_value:=substring(new.number from '([0-9]+)$')::bigint;
  exception when others then raise exception 'document_number_not_parseable'; end;
  if sequence_row.id is null or parsed_value is null then raise exception 'document_sequence_unavailable'; end if;
  select * into fiscal_config from public.company_fiscal_configurations where company_id=new.company_id;
  insert into public.document_number_allocations(
    company_id,document_id,document_type,sequence_type,fiscal_year,prefix,sequence_value,
    full_number,allocated_by,application_version,schema_version,metadata
  ) values(
    new.company_id,new.id,new.document_type,sequence_key,
    extract(year from coalesce(new.issue_date,current_date))::integer,sequence_row.prefix,parsed_value,
    new.number,coalesce(auth.uid(),new.created_by),coalesce(fiscal_config.application_version,'2026.07-compliance'),
    coalesce(fiscal_config.schema_version,'202607220039'),
    jsonb_build_object('historical_backfill',false,'allocation_source','database_trigger')
  ) on conflict(document_id) do nothing;
  return new;
end
$$;
revoke all on function public.record_document_number_allocation() from public,anon,authenticated;
drop trigger if exists documents_record_number_allocation on public.documents;
create trigger documents_record_number_allocation after insert or update of number on public.documents
for each row execute function public.record_document_number_allocation();

-- Retourne des codes de mentions et les valeurs configurées. Aucun texte légal
-- non validé n'est inventé par cette fonction.
create or replace function public.resolve_required_invoice_mentions(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; issuer public.company_settings%rowtype;
  settings public.company_document_settings%rowtype; source_number text; mentions jsonb:='[]'::jsonb;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  select * into issuer from public.company_settings where company_id=doc.company_id;
  select * into settings from public.company_document_settings where company_id=doc.company_id;
  if issuer.subject_to_vat is false then
    mentions:=mentions||jsonb_build_array(jsonb_build_object(
      'code','vat_exemption','configured_text',nullif(trim(settings.legal_notice),''),
      'requires_legal_validation',nullif(trim(settings.legal_notice),'') is null));
  end if;
  if issuer.vat_on_debits then
    mentions:=mentions||jsonb_build_array(jsonb_build_object(
      'code','vat_on_debits','configured_text',null,'requires_legal_validation',true));
  end if;
  if doc.document_type='credit_note' then
    select number into source_number from public.documents where id=doc.source_document_id and company_id=doc.company_id;
    mentions:=mentions||jsonb_build_array(jsonb_build_object(
      'code','credit_note_reference','source_number',source_number,'requires_legal_validation',false));
  end if;
  if doc.document_type='deposit_invoice' then
    mentions:=mentions||jsonb_build_array(jsonb_build_object(
      'code','deposit_invoice','requires_legal_validation',true));
  end if;
  mentions:=mentions||jsonb_build_array(jsonb_build_object(
    'code','payment_terms','configured_text',doc.payment_terms,'requires_legal_validation',doc.payment_terms is null));
  if nullif(trim(settings.collection_fee_notice),'') is not null then
    mentions:=mentions||jsonb_build_array(jsonb_build_object(
      'code','collection_fee','configured_text',settings.collection_fee_notice,'requires_legal_validation',false));
  end if;
  return mentions;
end
$$;

create or replace function public.recalculate_document_amounts_v1(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; raw_cost numeric:=0; raw_ht numeric:=0; raw_tax numeric:=0; ratio numeric:=1;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type<>'quote' and (doc.finalized_at is not null or doc.validated_at is not null or doc.status<>'draft') then
    raise exception 'document_is_locked';
  end if;
  update public.document_lines set
    total_excl_tax=case when line_type in('item','free_item','discount') then round((quantity*unit_price*(1-discount_rate/100))::numeric,2) else 0 end,
    total_tax=case when line_type in('item','free_item','discount') then round((round((quantity*unit_price*(1-discount_rate/100))::numeric,2)*tax_rate/100)::numeric,2) else 0 end,
    total_incl_tax=case when line_type in('item','free_item','discount') then
      round((quantity*unit_price*(1-discount_rate/100))::numeric,2)+round((round((quantity*unit_price*(1-discount_rate/100))::numeric,2)*tax_rate/100)::numeric,2) else 0 end
  where document_id=doc.id;
  select coalesce(sum(quantity*unit_cost_snapshot),0),coalesce(sum(total_excl_tax),0),coalesce(sum(total_tax),0)
  into raw_cost,raw_ht,raw_tax from public.document_lines where document_id=doc.id and not optional;
  ratio:=greatest(0,1-coalesce(doc.discount_rate,0)/100);
  update public.documents set
    total_cost=round(raw_cost,2),total_excl_tax=round(raw_ht*ratio,2),
    total_tax=round(raw_tax*ratio,2),total_incl_tax=round(raw_ht*ratio,2)+round(raw_tax*ratio,2),
    calculation_version='financial-v1',calculation_snapshot=jsonb_build_object(
      'version','financial-v1','rounding','half-away-from-zero','rounding_level','line_then_document',
      'raw_excl_tax',raw_ht,'raw_tax',raw_tax,'global_discount_rate',coalesce(doc.discount_rate,0)
    ),updated_at=now()
  where id=doc.id returning * into doc;
  return jsonb_build_object('total_cost',doc.total_cost,'total_excl_tax',doc.total_excl_tax,
    'total_tax',doc.total_tax,'total_incl_tax',doc.total_incl_tax,'version','financial-v1');
end
$$;

create or replace function public.validate_invoice_for_finalization(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; issuer public.company_settings%rowtype; customer public.clients%rowtype;
  invalid_lines integer:=0; errors jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; mentions jsonb;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  select * into issuer from public.company_settings where company_id=doc.company_id;
  select * into customer from public.clients where id=doc.client_id and company_id=doc.company_id and active;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','invalid_document_type','field','document_type'));
  end if;
  if nullif(trim(issuer.legal_name),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_legal_name_required','field','issuer.legal_name')); end if;
  if issuer.siret is null or issuer.siret !~ '^[0-9]{14}$' then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_siret_required','field','issuer.siret')); end if;
  if nullif(trim(issuer.address_line1),'') is null or nullif(trim(issuer.postal_code),'') is null or nullif(trim(issuer.city),'') is null then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_address_required','field','issuer.address'));
  end if;
  if customer.id is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','client_required','field','client_id'));
  elsif coalesce(nullif(trim(customer.legal_name),''),nullif(trim(concat_ws(' ',customer.first_name,customer.last_name)),'')) is null then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','client_name_required','field','client.name'));
  end if;
  if customer.id is not null and (nullif(trim(customer.address_line_1),'') is null or nullif(trim(customer.postal_code),'') is null or nullif(trim(customer.city),'') is null or nullif(trim(customer.country_code),'') is null) then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','client_address_required','field','client.address'));
  end if;
  if doc.issue_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issue_date_required','field','issue_date')); end if;
  if doc.currency is null or doc.currency !~ '^[A-Z]{3}$' then errors:=errors||jsonb_build_array(jsonb_build_object('code','currency_invalid','field','currency')); end if;
  if doc.document_type<>'credit_note' and doc.due_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','due_date_required','field','due_date')); end if;
  if doc.document_type='credit_note' and (doc.source_document_id is null or not exists(
    select 1 from public.documents source where source.id=doc.source_document_id and source.company_id=doc.company_id
      and source.document_type in('invoice','deposit_invoice','balance_invoice') and source.finalized_at is not null
  )) then errors:=errors||jsonb_build_array(jsonb_build_object('code','credit_source_required','field','source_document_id')); end if;
  select count(*) into invalid_lines from public.document_lines where document_id=doc.id and line_type in('item','free_item','discount')
    and (optional or nullif(trim(coalesce(name,'')),'') is null or quantity<=0 or unit_price<0 or discount_rate not between 0 and 100 or tax_rate not between 0 and 100);
  if not exists(select 1 from public.document_lines where document_id=doc.id and line_type in('item','free_item','discount') and not optional) then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','document_lines_required','field','lines'));
  elsif invalid_lines>0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','invalid_document_lines','field','lines','count',invalid_lines)); end if;
  if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','document_total_must_be_positive','field','totals')); end if;
  if issuer.subject_to_vat is false and exists(select 1 from public.document_lines where document_id=doc.id and tax_rate<>0) then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','vat_rate_for_non_vat_company','field','lines.tax_rate'));
  end if;
  if nullif(trim(doc.sale_type),'') is null then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','operation_category_to_confirm','field','sale_type')); end if;
  if customer.kind='company' and customer.country_code='FR' and nullif(trim(customer.siren),'') is null then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('code','client_siren_required_for_einvoicing','field','client.siren'));
  end if;
  mentions:=public.resolve_required_invoice_mentions(doc.id);
  if exists(select 1 from jsonb_array_elements(mentions) mention where coalesce((mention->>'requires_legal_validation')::boolean,false)) then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('code','legal_mentions_require_validation','field','legal_mentions'));
  end if;
  return jsonb_build_object('valid',jsonb_array_length(errors)=0,'errors',errors,'warnings',warnings,
    'mentions',mentions,'validator_version','invoice-validator-v1');
end
$$;

create or replace function public.finalize_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; result_snapshot_id uuid; validation jsonb;
  fiscal_config public.company_fiscal_configurations%rowtype; security_status text;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then raise exception 'document_type_cannot_be_finalized'; end if;
  if doc.finalized_at is not null then
    return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'finalized_at',doc.finalized_at,
      'snapshot_id',doc.snapshot_id,'pdf_status',doc.pdf_status,'fiscal_security_status',doc.fiscal_security_status);
  end if;
  if doc.status not in('draft','to_finalize') or doc.validated_at is not null then raise exception 'invalid_document_state'; end if;
  if doc.due_date is null then
    update public.documents set due_date=case when doc.document_type='credit_note' then doc.issue_date
      else public.compute_document_due_date(doc.company_id,doc.payment_terms,doc.issue_date) end,updated_at=now()
    where id=doc.id;
  end if;
  perform public.recalculate_document_amounts_v1(doc.id);
  select * into doc from public.documents where id=doc.id for update;
  validation:=public.validate_invoice_for_finalization(doc.id);
  if not coalesce((validation->>'valid')::boolean,false) then
    raise exception 'invoice_validation_failed:%',validation->'errors' using errcode='22023';
  end if;
  if doc.number is null then
    update public.documents set number=public._piloz_take_document_number(
      doc.company_id,doc.document_type,extract(year from coalesce(doc.issue_date,current_date))::integer,false
    ),updated_at=now() where id=doc.id returning * into doc;
  end if;
  select * into fiscal_config from public.company_fiscal_configurations where company_id=doc.company_id;
  security_status:=case when fiscal_config.mode='production' and fiscal_config.activation_status='production_active' then 'secured_v1'
    when fiscal_config.mode='test' and fiscal_config.activation_status='test_active' then 'test_secured' else 'legacy_unsecured' end;
  update public.documents set
    status='finalized',validated_at=now(),finalized_at=now(),finalized_by=auth.uid(),locked_at=now(),pdf_status='pending',
    fiscal_security_status=security_status,application_version=coalesce(fiscal_config.application_version,'2026.07-compliance'),
    git_commit=coalesce(fiscal_config.activated_from_commit,'not-recorded'),
    database_schema_version=coalesce(fiscal_config.schema_version,'202607220039'),
    calculation_version=coalesce(fiscal_config.calculation_version,'financial-v1'),
    pdf_generator_version=coalesce(fiscal_config.pdf_generator_version,'pdf-v2'),
    electronic_format_version=coalesce(fiscal_config.electronic_format_version,'not-configured'),
    fiscal_policy_version=coalesce(fiscal_config.fiscal_policy_version,'draft-2026-07'),
    canonicalization_version=coalesce(fiscal_config.canonicalization_version,'jsonb-text-v1'),
    legal_mentions_snapshot=validation->'mentions',updated_at=now()
  where id=doc.id returning * into doc;
  result_snapshot_id:=public._piloz_create_document_snapshot(doc.id);
  update public.documents set snapshot_id=result_snapshot_id,updated_at=now() where id=doc.id returning * into doc;
  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by)
  values(doc.company_id,doc.id,result_snapshot_id,'pending',coalesce(auth.uid(),doc.created_by)) on conflict(snapshot_id) do nothing;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.finalized','document',doc.id,jsonb_build_object(
    'number',doc.number,'document_type',doc.document_type,'snapshot_id',result_snapshot_id,
    'fiscal_security_status',doc.fiscal_security_status,'versions',jsonb_build_object(
      'application',doc.application_version,'schema',doc.database_schema_version,'calculation',doc.calculation_version,
      'pdf',doc.pdf_generator_version,'electronic_format',doc.electronic_format_version,'fiscal_policy',doc.fiscal_policy_version
    )),auth.uid());
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'finalized_at',doc.finalized_at,
    'snapshot_id',result_snapshot_id,'pdf_status',doc.pdf_status,'fiscal_security_status',doc.fiscal_security_status,
    'validation',validation);
end
$$;

revoke all on function public.resolve_required_invoice_mentions(uuid) from public,anon;
revoke all on function public.recalculate_document_amounts_v1(uuid) from public,anon;
revoke all on function public.validate_invoice_for_finalization(uuid) from public,anon;
revoke all on function public.finalize_document(uuid) from public,anon;
grant execute on function public.resolve_required_invoice_mentions(uuid) to authenticated;
grant execute on function public.recalculate_document_amounts_v1(uuid) to authenticated;
grant execute on function public.validate_invoice_for_finalization(uuid) to authenticated;
grant execute on function public.finalize_document(uuid) to authenticated;

commit;
