begin;

-- Piloz pre-accounting foundation. This migration is additive: documents,
-- payments, clients, suppliers and catalogue items remain the source of truth.

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
          'record_multi_invoice_payment','correct_payment','view_bank_references','accounting_payments_read'
        ])
        when member.role='sales' then target_permission=any(array[
          'application_read','sales_document_write','finalize_quote','manage_customer','manage_opportunity',
          'view_due_dates','resend_invoice','extensions_read','extensions_connect_own'
        ])
        when member.role='accounting' then target_permission=any(array[
          'application_read','finalize_invoice','create_credit_note','record_payment','fiscal_read',
          'create_closure','create_archive','electronic_invoice_manage','compliance_view',
          'view_due_dates','resend_invoice','view_payment_methods','view_bank_accounts','attach_payment_proof',
          'record_multi_invoice_payment','correct_payment','view_bank_references',
          'accounting_payments_read','accounting_payment_reverse','accounting_entries_read',
          'accounting_export_preview','accounting_export_validate','accounting_export_cancel',
          'accounting_attachments_download','accounting_settings_manage','accounting_vat_cash','accounting_fiscal_year_manage'
        ])
        when member.role='auditor' then target_permission=any(array[
          'application_read','fiscal_read','compliance_view','personal_data_audit','view_due_dates',
          'accounting_payments_read','accounting_entries_read','accounting_export_preview'
        ])
        when member.role in('read_only','member') then target_permission=any(array[
          'application_read','view_due_dates','extensions_read','accounting_payments_read'
        ])
        else false
      end
  )
$$;
revoke all on function public.has_company_permission(uuid,text) from public,anon;
grant execute on function public.has_company_permission(uuid,text) to authenticated;

drop policy if exists external_connections_select on public.external_connections;
create policy external_connections_select on public.external_connections for select to authenticated using(
  public.is_company_member(company_id) and (
    user_id=auth.uid()
    or (connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
  )
);

-- Connection content follows the same ownership boundary as the connection
-- itself: an administrator never gains access to a personal mailbox or
-- calendar merely because of their company role.
drop policy if exists external_sync_states_select on public.external_sync_states;
create policy external_sync_states_select on public.external_sync_states for select to authenticated using(
  public.is_company_member(company_id) and exists(
    select 1 from public.external_connections connection
    where connection.id=external_sync_states.connection_id and (
      connection.user_id=auth.uid()
      or (connection.connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
    )
  )
);
drop policy if exists external_sync_jobs_select on public.external_sync_jobs;
create policy external_sync_jobs_select on public.external_sync_jobs for select to authenticated using(
  public.is_company_member(company_id) and exists(
    select 1 from public.external_connections connection
    where connection.id=external_sync_jobs.connection_id and (
      connection.user_id=auth.uid()
      or (connection.connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
    )
  )
);
drop policy if exists external_event_links_select on public.external_event_links;
create policy external_event_links_select on public.external_event_links for select to authenticated using(
  public.is_company_member(company_id) and exists(
    select 1 from public.external_connections connection
    where connection.id=external_event_links.connection_id and (
      connection.user_id=auth.uid()
      or (connection.connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
    )
  )
);
drop policy if exists external_mail_links_select on public.external_mail_links;
create policy external_mail_links_select on public.external_mail_links for select to authenticated using(
  public.is_company_member(company_id) and exists(
    select 1 from public.external_connections connection
    where connection.id=external_mail_links.connection_id and (
      connection.user_id=auth.uid()
      or (connection.connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
    )
  )
);

create table if not exists public.accounting_fiscal_years(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  name text not null,
  starts_on date not null,
  ends_on date not null,
  status text not null default 'open' check(status in('upcoming','open','to_close','closed')),
  previous_year_id uuid references public.accounting_fiscal_years(id) on delete set null,
  next_year_id uuid references public.accounting_fiscal_years(id) on delete set null,
  auto_create_next boolean not null default true,
  auto_close boolean not null default false,
  closed_at timestamptz,
  closed_by uuid,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  updated_by uuid default auth.uid(), updated_at timestamptz not null default now(),
  check(ends_on>=starts_on), unique(company_id,starts_on,ends_on)
);

create or replace function public.reject_accounting_fiscal_year_overlap()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if exists(select 1 from public.accounting_fiscal_years year
    where year.company_id=new.company_id and year.id<>new.id
      and not (year.starts_on=new.starts_on and year.ends_on=new.ends_on)
      and daterange(year.starts_on,year.ends_on,'[]') && daterange(new.starts_on,new.ends_on,'[]')) then
    raise exception 'accounting_fiscal_year_overlap';
  end if;
  return new;
end $$;
drop trigger if exists accounting_fiscal_year_no_overlap on public.accounting_fiscal_years;
create trigger accounting_fiscal_year_no_overlap before insert or update of starts_on,ends_on
on public.accounting_fiscal_years for each row execute function public.reject_accounting_fiscal_year_overlap();

create table if not exists public.accounting_journals(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  code text not null check(code~'^[A-Z0-9_-]{1,12}$'), label text not null,
  journal_type text not null check(journal_type in('sales','purchases','bank','cash','adjustment')),
  financial_account_id uuid, active boolean not null default true, display_order integer not null default 0,
  created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now(),
  unique(company_id,code)
);

create table if not exists public.accounting_settings(
  company_id uuid primary key references public.companies(id) on delete restrict,
  customer_collective_account text not null default '411000', supplier_collective_account text not null default '401000',
  customer_auxiliary_enabled boolean not null default true, supplier_auxiliary_enabled boolean not null default true,
  customer_auxiliary_prefix text not null default 'CLI', supplier_auxiliary_prefix text not null default 'FOU',
  auxiliary_length smallint not null default 10 check(auxiliary_length=10), auxiliary_padding_character text not null default '_' check(length(auxiliary_padding_character)=1),
  default_sales_account text not null default '706000', default_purchase_account text not null default '607000',
  default_bank_account text not null default '512100', default_cash_account text not null default '531000', values_in_transit_account text not null default '511000',
  deposit_account text not null default '419100', deposit_apply_auxiliary boolean not null default true,
  deposit_method text not null default 'dedicated' check(deposit_method in('suspense','dedicated','direct')),
  vat_on_cash_enabled boolean not null default false, vat_on_debits boolean not null default false,
  fec_review_required boolean not null default true,
  created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now()
);

create table if not exists public.supplier_accounting_profiles(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  collective_account text, auxiliary_account text, assignment_mode text not null default 'automatic' check(assignment_mode in('automatic','manual')),
  accounting_label text, active boolean not null default true, effective_from date not null default current_date,
  created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now(),
  unique(company_id,supplier_id)
);

create table if not exists public.accounting_third_party_identifiers(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  party_type text not null check(party_type in('client','supplier')), party_id uuid not null,
  identifier text not null check(identifier~'^[A-Z0-9_]{10}$'), label text not null,
  effective_from date not null default current_date, effective_until date, forced boolean not null default false,
  change_reason text, created_by uuid default auth.uid(),created_at timestamptz not null default now(),
  check(effective_until is null or effective_until>=effective_from), unique(company_id,party_type,party_id,effective_from)
);
create unique index if not exists accounting_third_party_identifier_current_unique
  on public.accounting_third_party_identifiers(company_id,identifier) where effective_until is null;
create unique index if not exists accounting_third_party_party_current_unique
  on public.accounting_third_party_identifiers(company_id,party_type,party_id) where effective_until is null;

create table if not exists public.accounting_account_mappings(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  direction text not null check(direction in('sale','purchase')), scope_type text not null check(scope_type in('global','item_type','category','item')),
  scope_value text not null default '*', account_code text not null check(account_code~'^[A-Z0-9]{3,20}$'),
  vat_extension text, use_complete_account boolean not null default true, effective_from date not null default current_date,
  active boolean not null default true, created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now(),
  unique(company_id,direction,scope_type,scope_value,effective_from)
);

create table if not exists public.accounting_vat_mappings(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  tax_rate numeric(6,3) not null, purchase_account text, sales_account text, suspense_account text,
  sale_account_extension text, purchase_account_extension text, active boolean not null default true,
  effective_from date not null default current_date, created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now(),
  unique(company_id,tax_rate,effective_from)
);

create table if not exists public.accounting_financial_accounts(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  company_bank_account_id uuid, name text not null, iban_last4 text, account_code text not null,
  journal_id uuid references public.accounting_journals(id) on delete set null, account_type text not null default 'bank' check(account_type in('bank','cash','in_transit','other')),
  active boolean not null default true, created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now()
);
alter table public.accounting_journals drop constraint if exists accounting_journals_financial_account_id_fkey;
alter table public.accounting_journals add constraint accounting_journals_financial_account_id_fkey foreign key(financial_account_id) references public.accounting_financial_accounts(id) on delete set null;

create table if not exists public.accounting_payment_method_mappings(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  payment_method text not null, financial_account_code text, account_extension text, suspense_account text,
  journal_id uuid references public.accounting_journals(id) on delete set null, active boolean not null default true,
  created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now(),
  unique(company_id,payment_method)
);

create table if not exists public.accounting_complementary_accounts(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  setting_key text not null, label text not null, account_code text not null, apply_auxiliary boolean not null default false,
  vat_rate numeric(6,3), active boolean not null default true, created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_by uuid default auth.uid(),updated_at timestamptz not null default now(),
  unique(company_id,setting_key)
);

create table if not exists public.accounting_config_history(
  id bigint generated always as identity primary key, company_id uuid not null references public.companies(id) on delete restrict,
  table_name text not null, record_id uuid, old_value jsonb, new_value jsonb, effective_on date not null default current_date,
  reason text, changed_by uuid default auth.uid(), changed_at timestamptz not null default now()
);

create table if not exists public.accounting_entry_sequences(
  company_id uuid not null references public.companies(id) on delete restrict, fiscal_year integer not null,
  next_value bigint not null default 1 check(next_value>0), primary key(company_id,fiscal_year)
);

create table if not exists public.accounting_entries(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  fiscal_year_id uuid not null references public.accounting_fiscal_years(id) on delete restrict,
  journal_id uuid not null references public.accounting_journals(id) on delete restrict,
  entry_number text not null, entry_date date not null, piece_reference text not null, piece_date date not null,
  label text not null, currency text not null default 'EUR', source_type text not null, source_id uuid not null,
  event_kind text not null default 'original', document_id uuid references public.documents(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete restrict, status text not null default 'posted' check(status in('posted','corrective','exported')),
  validated_at timestamptz not null default now(), created_by uuid default auth.uid(),created_at timestamptz not null default now(),
  unique(company_id,entry_number),unique(company_id,source_type,source_id,event_kind)
);

create table if not exists public.accounting_entry_lines(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  entry_id uuid not null references public.accounting_entries(id) on delete restrict, line_number integer not null,
  account_code text not null, account_label text not null, auxiliary_code text, auxiliary_label text, third_party_id uuid,
  line_label text not null, debit numeric(15,2) not null default 0 check(debit>=0), credit numeric(15,2) not null default 0 check(credit>=0),
  currency text not null default 'EUR', foreign_amount numeric(15,2), source_line_id uuid references public.document_lines(id) on delete restrict,
  tax_rate numeric(6,3), created_by uuid default auth.uid(),created_at timestamptz not null default now(),
  check((debit>0 and credit=0) or (credit>0 and debit=0)), unique(entry_id,line_number)
);

create table if not exists public.accounting_export_adapters(
  id uuid primary key default gen_random_uuid(), adapter_key text not null unique, name text not null,
  adapter_group text not null check(adapter_group in('generic','fec','proprietary')),
  availability text not null default 'to_configure' check(availability in('available','to_configure','disabled')),
  verification_note text not null, created_at timestamptz not null default now()
);
create table if not exists public.accounting_export_adapter_versions(
  id uuid primary key default gen_random_uuid(), adapter_id uuid not null references public.accounting_export_adapters(id) on delete restrict,
  version integer not null, specification jsonb not null, golden_file_sha256 text, tested_at timestamptz,
  created_at timestamptz not null default now(), unique(adapter_id,version)
);
create table if not exists public.accounting_export_batches(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete restrict,
  export_number text not null, journal_type text not null check(journal_type in('sales','purchases','bank','fec')),
  starts_on date not null, ends_on date not null, adapter_version_id uuid references public.accounting_export_adapter_versions(id) on delete restrict,
  format_key text not null, include_attachments boolean not null default false, include_corrections boolean not null default true,
  status text not null default 'previewed' check(status in('draft','previewed','validated','cancelled','error')),
  entry_count integer not null default 0, piece_count integer not null default 0,total_debit numeric(15,2) not null default 0,total_credit numeric(15,2) not null default 0,
  snapshot jsonb not null default '{}'::jsonb, snapshot_sha256 text, validation_report jsonb not null default '{}'::jsonb,
  comment text, created_by uuid default auth.uid(),created_at timestamptz not null default now(),validated_by uuid,validated_at timestamptz,
  check(ends_on>=starts_on),unique(company_id,export_number)
);
create table if not exists public.accounting_export_batch_entries(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  export_batch_id uuid not null references public.accounting_export_batches(id) on delete restrict,
  accounting_entry_id uuid not null references public.accounting_entries(id) on delete restrict,
  entry_snapshot jsonb not null,created_at timestamptz not null default now(),unique(export_batch_id,accounting_entry_id)
);
create index if not exists accounting_export_batch_entries_entry_idx
  on public.accounting_export_batch_entries(accounting_entry_id);
create table if not exists public.accounting_export_files(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  export_batch_id uuid not null references public.accounting_export_batches(id) on delete restrict,
  file_kind text not null check(file_kind in('entries','manifest','attachments_zip','validation_report')),
  file_name text not null,mime_type text not null,storage_path text,content_text text,sha256 text not null,size_bytes bigint not null default 0,
  created_at timestamptz not null default now(),unique(export_batch_id,file_kind)
);
create table if not exists public.accounting_export_cancellations(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  export_batch_id uuid not null references public.accounting_export_batches(id) on delete restrict,
  reason text not null check(length(trim(reason))>=3),cancelled_by uuid not null default auth.uid(),cancelled_at timestamptz not null default now()
);

create table if not exists public.vat_cash_collection_runs(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  starts_on date not null,ends_on date not null,status text not null default 'preview' check(status in('preview','validated','cancelled')),
  classification text not null default 'preparatory',filters jsonb not null default '{}'::jsonb,
  total_collected numeric(15,2) not null default 0,total_tax_base numeric(15,2) not null default 0,total_vat numeric(15,2) not null default 0,
  snapshot jsonb not null default '{}'::jsonb,created_by uuid default auth.uid(),created_at timestamptz not null default now(),
  check(ends_on>=starts_on)
);
create table if not exists public.vat_cash_collection_lines(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  run_id uuid not null references public.vat_cash_collection_runs(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete restrict,document_id uuid references public.documents(id) on delete restrict,
  payment_date date not null,collected_amount numeric(15,2) not null,tax_rate numeric(6,3) not null,
  collected_tax_base numeric(15,2) not null,collected_vat numeric(15,2) not null,
  calculation_method text not null,scope_status text not null check(scope_status in('included','debits_option','out_of_scope','review')),
  correction boolean not null default false,details jsonb not null default '{}'::jsonb,created_at timestamptz not null default now()
);

insert into public.accounting_export_adapters(adapter_key,name,adapter_group,availability,verification_note) values
 ('csv_aux_separate','CSV — auxiliaire séparé','generic','available','Format générique documenté par Piloz.'),
 ('csv_aux_label','CSV — auxiliaire et libellé séparés','generic','available','Format générique documenté par Piloz.'),
 ('csv_debit_credit','CSV — débit et crédit séparés','generic','available','Format générique documenté par Piloz.'),
 ('fec_technical','FEC — validation technique','fec','available','Validation technique uniquement. Revue comptable requise.'),
 ('acd','ACD','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('cegid_csv','Cegid CSV','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('cegid_v7','Cegid version 7 et plus','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('cegid_y2','Cegid Y2','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('ciel','Ciel','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('ebp_pro_csv','EBP Pro CSV','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('ewinfic','eWinfic','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('isa_compta','ISA Compta','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('myunisoft','MyUnisoft','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('quadratus','Quadratus','proprietary','to_configure','Spécification ou fichier validé requis.'),
 ('sage_coala','Sage Coala','proprietary','to_configure','Spécification ou fichier validé requis.')
on conflict(adapter_key) do update set name=excluded.name,adapter_group=excluded.adapter_group,availability=excluded.availability,verification_note=excluded.verification_note;

insert into public.accounting_export_adapter_versions(adapter_id,version,specification)
select id,1,jsonb_build_object('encoding','UTF-8','separator',';','date_format','YYYYMMDD','decimal_separator',',','validated_by','Piloz generic tests')
from public.accounting_export_adapters where availability='available'
on conflict(adapter_id,version) do nothing;

create or replace function public._bootstrap_company_accounting(target_company_id uuid,target_date date default current_date)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare year_start date:=make_date(extract(year from target_date)::integer,1,1);year_end date:=make_date(extract(year from target_date)::integer,12,31);
begin
  insert into public.accounting_settings(company_id,created_by) values(target_company_id,auth.uid()) on conflict(company_id) do nothing;
  insert into public.accounting_fiscal_years(company_id,name,starts_on,ends_on,status,created_by)
    select target_company_id,extract(year from target_date)::text,year_start,year_end,'open',auth.uid()
    where not exists(select 1 from public.accounting_fiscal_years existing where existing.company_id=target_company_id and target_date between existing.starts_on and existing.ends_on)
    on conflict(company_id,starts_on,ends_on) do nothing;
  insert into public.accounting_journals(company_id,code,label,journal_type,display_order,created_by) values
    (target_company_id,'AC','Journal d’achats','purchases',10,auth.uid()),(target_company_id,'VT','Journal de ventes','sales',20,auth.uid()),
    (target_company_id,'BQ','Journal de banque','bank',30,auth.uid()),(target_company_id,'CA','Journal de caisse','cash',40,auth.uid())
  on conflict(company_id,code) do nothing;
  insert into public.accounting_vat_mappings(company_id,tax_rate,purchase_account,sales_account,suspense_account,sale_account_extension,purchase_account_extension,effective_from,created_by) values
    (target_company_id,2.1,'445664','445714','445804','004','4',year_start,auth.uid()),
    (target_company_id,5.5,'445661','445711','445801','001','1',year_start,auth.uid()),
    (target_company_id,8.5,'445665','445715','445805','005','5',year_start,auth.uid()),
    (target_company_id,10,'445663','445713','445803','003','3',year_start,auth.uid()),
    (target_company_id,20,'445662','445712','445802','002','2',year_start,auth.uid())
  on conflict(company_id,tax_rate,effective_from) do nothing;
  insert into public.accounting_account_mappings(company_id,direction,scope_type,scope_value,account_code,effective_from,created_by) values
    (target_company_id,'sale','global','*','706000',year_start,auth.uid()),(target_company_id,'purchase','global','*','607000',year_start,auth.uid())
  on conflict(company_id,direction,scope_type,scope_value,effective_from) do nothing;
  insert into public.accounting_complementary_accounts(company_id,setting_key,label,account_code,created_by) values
    (target_company_id,'discount_granted','Escomptes accordés','665',auth.uid()),(target_company_id,'discount_received','Escomptes obtenus','765',auth.uid()),
    (target_company_id,'retention','Retenue de garantie','4117',auth.uid()),(target_company_id,'prorata','Compte prorata','606800',auth.uid()),
    (target_company_id,'price_revision','Révision de prix','704100',auth.uid()),(target_company_id,'other_deduction_ht','Autres déductions HT','604100',auth.uid()),
    (target_company_id,'other_deduction_ttc','Autres déductions TTC','41800',auth.uid())
  on conflict(company_id,setting_key) do nothing;
end $$;

create or replace function public.bootstrap_company_accounting(target_company_id uuid,target_date date default current_date)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.has_company_permission(target_company_id,'accounting_settings_manage') then raise exception 'forbidden' using errcode='42501';end if;
  perform public._bootstrap_company_accounting(target_company_id,target_date);
end $$;

do $$ declare company_row record;begin for company_row in select id from public.companies loop perform public._bootstrap_company_accounting(company_row.id,current_date);end loop;end $$;

create or replace function public.bootstrap_new_company_accounting()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public._bootstrap_company_accounting(new.id,current_date);return new;end $$;
drop trigger if exists companies_bootstrap_accounting on public.companies;
create trigger companies_bootstrap_accounting after insert on public.companies for each row execute function public.bootstrap_new_company_accounting();

create or replace function public.next_accounting_entry_number(target_company_id uuid,target_date date)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare target_year integer:=extract(year from target_date)::integer;value bigint;
begin
  insert into public.accounting_entry_sequences(company_id,fiscal_year,next_value) values(target_company_id,target_year,1) on conflict do nothing;
  update public.accounting_entry_sequences set next_value=next_value+1 where company_id=target_company_id and fiscal_year=target_year returning next_value-1 into value;
  return 'EC-'||target_year||'-'||lpad(value::text,8,'0');
end $$;

create or replace function public.normalized_third_party_identifier(raw_label text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select rpad(left(regexp_replace(translate(upper(coalesce(raw_label,'')),
    'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝŸŒÆ','AAAAAACEEEEIIIINOOOOOUUUUYYOA'),
    '[^A-Z0-9]','','g'),10),10,'_')
$$;

create or replace function public.ensure_accounting_third_party_identifier(target_company_id uuid,target_party_type text,target_party_id uuid,target_label text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare candidate text;sequence integer:=0;existing text;
begin
  select identifier into existing from public.accounting_third_party_identifiers where company_id=target_company_id and party_type=target_party_type and party_id=target_party_id and effective_until is null;
  if existing is not null then return existing;end if;
  candidate:=public.normalized_third_party_identifier(target_label);
  while exists(select 1 from public.accounting_third_party_identifiers where company_id=target_company_id and identifier=candidate and effective_until is null) loop
    sequence:=sequence+1;candidate:=left(public.normalized_third_party_identifier(target_label),greatest(1,10-length(sequence::text)))||sequence::text;
  end loop;
  insert into public.accounting_third_party_identifiers(company_id,party_type,party_id,identifier,label,created_by)
    values(target_company_id,target_party_type,target_party_id,candidate,coalesce(nullif(trim(target_label),''),'Tiers'),auth.uid());
  return candidate;
end $$;

create or replace function public._generate_document_accounting_entry(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;settings public.accounting_settings%rowtype;fiscal public.accounting_fiscal_years%rowtype;journal public.accounting_journals%rowtype;
  entry_id uuid;entry_num text;party_label text;auxiliary text;collective text;direction text;sign integer:=1;line_no integer:=0;line_row record;
  account_code text;vat_account text;sum_debit numeric:=0;sum_credit numeric:=0;gross numeric;net numeric;tax numeric;
  source_net numeric:=0;net_adjustment numeric:=0;discount_adjustment numeric:=0;deposit_adjustment numeric:=0;
  adjustment_row record;tax_row record;source_tax numeric:=0;posted_tax numeric:=0;allocated_tax numeric:=0;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or doc.finalized_at is null or doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice') then return null;end if;
  select id into entry_id from public.accounting_entries where company_id=doc.company_id and source_type='document' and source_id=doc.id and event_kind='original';if entry_id is not null then return entry_id;end if;
  perform public._bootstrap_company_accounting(doc.company_id,doc.issue_date);
  select * into settings from public.accounting_settings where company_id=doc.company_id;
  select * into fiscal from public.accounting_fiscal_years where company_id=doc.company_id and doc.issue_date between starts_on and ends_on limit 1;
  direction:=case when doc.document_type='purchase_invoice' then 'purchase' else 'sale' end;
  select * into journal from public.accounting_journals where company_id=doc.company_id and journal_type=case when direction='sale' then 'sales' else 'purchases' end and active order by display_order,id limit 1;
  if fiscal.id is null or journal.id is null then raise exception 'accounting_configuration_incomplete';end if;
  if doc.document_type='credit_note' then sign:=-1;end if;
  if direction='sale' then
    select coalesce(nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),'Client') into party_label from public.clients client where client.id=doc.client_id;
    auxiliary:=public.ensure_accounting_third_party_identifier(doc.company_id,'client',doc.client_id,party_label);
    select coalesce(profile.collective_account,settings.customer_collective_account),coalesce(profile.auxiliary_account,auxiliary) into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;
    collective:=coalesce(collective,settings.customer_collective_account);
  else
    select coalesce(nullif(trim(supplier.legal_name),''),'Fournisseur') into party_label from public.suppliers supplier where supplier.id=doc.supplier_id;
    auxiliary:=public.ensure_accounting_third_party_identifier(doc.company_id,'supplier',doc.supplier_id,party_label);
    select coalesce(profile.collective_account,settings.supplier_collective_account),coalesce(profile.auxiliary_account,auxiliary) into collective,auxiliary from public.supplier_accounting_profiles profile where profile.supplier_id=doc.supplier_id;
    collective:=coalesce(collective,settings.supplier_collective_account);
  end if;
  entry_num:=public.next_accounting_entry_number(doc.company_id,doc.issue_date);
  insert into public.accounting_entries(company_id,fiscal_year_id,journal_id,entry_number,entry_date,piece_reference,piece_date,label,currency,source_type,source_id,event_kind,document_id,status,created_by)
  values(doc.company_id,fiscal.id,journal.id,entry_num,doc.issue_date,coalesce(doc.number,doc.id::text),doc.issue_date,coalesce(doc.subject,case when direction='sale' then 'Vente ' else 'Achat ' end||coalesce(doc.number,'')),doc.currency,'document',doc.id,'original',doc.id,'posted',coalesce(doc.finalized_by,doc.created_by)) returning id into entry_id;
  gross:=round(abs(doc.total_incl_tax),2);net:=round(abs(doc.total_excl_tax),2);tax:=round(abs(doc.total_tax),2);
  line_no:=line_no+1;
  insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,auxiliary_code,auxiliary_label,third_party_id,line_label,debit,credit,currency,created_by)
  values(doc.company_id,entry_id,line_no,collective,party_label,auxiliary,party_label,coalesce(doc.client_id,doc.supplier_id),coalesce(doc.number,'Document'),
    case when (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then gross else 0 end,
    case when (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then gross else 0 end,doc.currency,coalesce(doc.finalized_by,doc.created_by));
  if (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then sum_debit:=sum_debit+gross;else sum_credit:=sum_credit+gross;end if;
  for line_row in select line.id,line.item_id,line.tax_rate,round(abs(line.total_excl_tax),2) amount,item.category_id,item.item_type
    from public.document_lines line left join public.catalog_items item on item.id=line.item_id where line.document_id=doc.id and line.line_type in('item','free_item') and abs(line.total_excl_tax)>0 order by line.position,line.id
  loop
    select profile_code into account_code from (
      select profile.sales_account_code profile_code,1 rank from public.item_accounting_profiles profile where direction='sale' and profile.company_id=doc.company_id and profile.item_id=line_row.item_id and profile.is_active
      union all select profile.purchase_account_code,1 from public.item_accounting_profiles profile where direction='purchase' and profile.company_id=doc.company_id and profile.item_id=line_row.item_id and profile.is_active
      union all select profile.sales_account_code,2 from public.item_accounting_profiles profile where direction='sale' and profile.company_id=doc.company_id and profile.category_id=line_row.category_id and profile.is_active
      union all select profile.purchase_account_code,2 from public.item_accounting_profiles profile where direction='purchase' and profile.company_id=doc.company_id and profile.category_id=line_row.category_id and profile.is_active
      union all select profile.sales_account_code,3 from public.item_accounting_profiles profile where direction='sale' and profile.company_id=doc.company_id and profile.item_type=line_row.item_type and profile.is_active
      union all select profile.purchase_account_code,3 from public.item_accounting_profiles profile where direction='purchase' and profile.company_id=doc.company_id and profile.item_type=line_row.item_type and profile.is_active
    ) resolved where profile_code is not null order by rank limit 1;
    account_code:=coalesce(account_code,case when direction='sale' then settings.default_sales_account else settings.default_purchase_account end);
    line_no:=line_no+1;
    insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,source_line_id,tax_rate,created_by)
    values(doc.company_id,entry_id,line_no,account_code,case when direction='sale' then 'Ventes' else 'Achats' end,coalesce(doc.number,'Document'),
      case when (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then line_row.amount else 0 end,
      case when (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then line_row.amount else 0 end,doc.currency,line_row.id,line_row.tax_rate,coalesce(doc.finalized_by,doc.created_by));
    if (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then sum_debit:=sum_debit+line_row.amount;else sum_credit:=sum_credit+line_row.amount;end if;
    source_net:=source_net+line_row.amount;
  end loop;
  -- A global discount and an advance-payment deduction reduce the document
  -- total without rewriting the original market lines. They are deliberately
  -- separated so the audit trail never confuses a commercial discount with an
  -- advance already invoiced.
  net_adjustment:=round(source_net-net,2);
  if net_adjustment>0.01 and coalesce(doc.discount_rate,0)>0 then
    discount_adjustment:=least(net_adjustment,round(source_net*doc.discount_rate/100,2));
  end if;
  deposit_adjustment:=round(net_adjustment-discount_adjustment,2);
  for adjustment_row in
    select * from (values
      (discount_adjustment,
       coalesce((select complementary.account_code from public.accounting_complementary_accounts complementary
                 where complementary.company_id=doc.company_id
                   and complementary.setting_key=case when direction='sale' then 'discount_granted' else 'discount_received' end
                   and complementary.active order by complementary.updated_at desc,complementary.id desc limit 1),
                case when direction='sale' then '665' else '765' end),
       case when direction='sale' then 'Escomptes accordés' else 'Escomptes obtenus' end),
      (deposit_adjustment,
       case when direction='sale' then settings.deposit_account else settings.default_purchase_account end,
       case when direction='sale' then 'Acomptes déjà facturés' else 'Ajustement achats' end)
    ) values_to_post(amount,adjustment_account,adjustment_label)
    where abs(amount)>0.01
  loop
    line_no:=line_no+1;
    insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,created_by)
    values(doc.company_id,entry_id,line_no,adjustment_row.adjustment_account,adjustment_row.adjustment_label,coalesce(doc.number,'Document'),
      case when ((direction='sale' and sign=1) or (direction='purchase' and sign=-1)) and adjustment_row.amount>0 then adjustment_row.amount
           when ((direction='purchase' and sign=1) or (direction='sale' and sign=-1)) and adjustment_row.amount<0 then abs(adjustment_row.amount) else 0 end,
      case when ((direction='purchase' and sign=1) or (direction='sale' and sign=-1)) and adjustment_row.amount>0 then adjustment_row.amount
           when ((direction='sale' and sign=1) or (direction='purchase' and sign=-1)) and adjustment_row.amount<0 then abs(adjustment_row.amount) else 0 end,
      doc.currency,coalesce(doc.finalized_by,doc.created_by));
    if ((direction='sale' and sign=1) or (direction='purchase' and sign=-1)) and adjustment_row.amount>0
       or ((direction='purchase' and sign=1) or (direction='sale' and sign=-1)) and adjustment_row.amount<0 then
      sum_debit:=sum_debit+abs(adjustment_row.amount);
    else
      sum_credit:=sum_credit+abs(adjustment_row.amount);
    end if;
  end loop;

  -- Post one VAT line per effective rate. The final document tax is allocated
  -- proportionally after global discounts/advance deductions; the last rate
  -- receives the rounding remainder. This replaces the incorrect average-rate
  -- shortcut used by the first implementation.
  if tax>0 then
    select coalesce(sum(rate_tax),0) into source_tax from (
      select round(sum(abs(coalesce(line.total_tax,0))),2) rate_tax
      from public.document_lines line
      where line.document_id=doc.id and line.line_type in('item','free_item','discount') and abs(coalesce(line.total_tax,0))>0
      group by line.tax_rate
    ) taxes;
    if source_tax<=0 then raise exception 'accounting_vat_breakdown_missing';end if;
    for tax_row in
      select line.tax_rate,round(sum(abs(coalesce(line.total_tax,0))),2) source_amount,
             row_number() over(order by line.tax_rate) rate_number,
             count(*) over() rate_count
      from public.document_lines line
      where line.document_id=doc.id and line.line_type in('item','free_item','discount') and abs(coalesce(line.total_tax,0))>0
      group by line.tax_rate
      order by line.tax_rate
    loop
      allocated_tax:=case when tax_row.rate_number=tax_row.rate_count then round(tax-posted_tax,2)
                          else round(tax*tax_row.source_amount/source_tax,2) end;
      if abs(allocated_tax)<=0.01 then continue;end if;
      select case when direction='sale' then mapping.sales_account else mapping.purchase_account end into vat_account
      from public.accounting_vat_mappings mapping
      where mapping.company_id=doc.company_id and mapping.active and mapping.tax_rate=tax_row.tax_rate
        and mapping.effective_from<=doc.issue_date
      order by mapping.effective_from desc,mapping.id desc limit 1;
      if vat_account is null then raise exception 'accounting_vat_account_missing:%',tax_row.tax_rate;end if;
      line_no:=line_no+1;
      insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,tax_rate,created_by)
      values(doc.company_id,entry_id,line_no,vat_account,case when direction='sale' then 'TVA collectée' else 'TVA déductible' end,coalesce(doc.number,'Document'),
        case when (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then allocated_tax else 0 end,
        case when (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then allocated_tax else 0 end,
        doc.currency,tax_row.tax_rate,coalesce(doc.finalized_by,doc.created_by));
      posted_tax:=posted_tax+allocated_tax;
      if (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then sum_debit:=sum_debit+allocated_tax;else sum_credit:=sum_credit+allocated_tax;end if;
    end loop;
  end if;
  if abs(sum_debit-sum_credit)>0.01 then raise exception 'accounting_entry_unbalanced:%',round(sum_debit-sum_credit,2);end if;
  return entry_id;
end $$;

create or replace function public.generate_document_accounting_entry(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare company_id_value uuid;
begin
  select company_id into company_id_value from public.documents where id=target_document_id;
  if company_id_value is null or not public.has_company_permission(company_id_value,'accounting_entries_read') then raise exception 'forbidden' using errcode='42501';end if;
  return public._generate_document_accounting_entry(target_document_id);
end $$;

create or replace function public.accounting_document_finalized_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if old.finalized_at is null and new.finalized_at is not null then perform public._generate_document_accounting_entry(new.id);end if;return new;
end $$;
drop trigger if exists documents_generate_accounting on public.documents;
create trigger documents_generate_accounting after update of finalized_at on public.documents for each row execute function public.accounting_document_finalized_trigger();

create or replace function public._generate_payment_accounting_entry(target_payment public.payments)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;settings public.accounting_settings%rowtype;fiscal public.accounting_fiscal_years%rowtype;journal public.accounting_journals%rowtype;generated_entry_id uuid;entry_num text;party_label text;auxiliary text;collective text;financial text;amount numeric;
begin
  if target_payment.status<>'confirmed' then return null;end if;
  select id into generated_entry_id from public.accounting_entries where company_id=target_payment.company_id and source_type='payment' and source_id=target_payment.id and event_kind='original';if generated_entry_id is not null then return generated_entry_id;end if;
  select * into doc from public.documents where id=target_payment.document_id;perform public._bootstrap_company_accounting(target_payment.company_id,target_payment.paid_at::date);
  select * into settings from public.accounting_settings where company_id=target_payment.company_id;
  select * into fiscal from public.accounting_fiscal_years where company_id=target_payment.company_id and target_payment.paid_at::date between starts_on and ends_on limit 1;
  select * into journal from public.accounting_journals where company_id=target_payment.company_id and journal_type='bank' and active order by display_order,id limit 1;
  select coalesce(nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),'Client') into party_label from public.clients client where client.id=doc.client_id;
  auxiliary:=public.ensure_accounting_third_party_identifier(target_payment.company_id,'client',doc.client_id,party_label);
  select coalesce(profile.collective_account,settings.customer_collective_account),coalesce(profile.auxiliary_account,auxiliary) into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;
  collective:=coalesce(collective,settings.customer_collective_account);financial:=coalesce((select financial_account_code from public.accounting_payment_method_mappings where company_id=target_payment.company_id and lower(payment_method)=lower(coalesce(target_payment.payment_method,'')) and active),settings.default_bank_account);
  amount:=round(abs(target_payment.amount),2);entry_num:=public.next_accounting_entry_number(target_payment.company_id,target_payment.paid_at::date);
  insert into public.accounting_entries(company_id,fiscal_year_id,journal_id,entry_number,entry_date,piece_reference,piece_date,label,currency,source_type,source_id,event_kind,document_id,payment_id,status,created_by)
  values(target_payment.company_id,fiscal.id,journal.id,entry_num,target_payment.paid_at::date,coalesce(target_payment.payment_number,target_payment.reference,target_payment.id::text),target_payment.paid_at::date,coalesce(target_payment.label,'Règlement '||coalesce(doc.number,'')),target_payment.currency,'payment',target_payment.id,'original',doc.id,target_payment.id,case when target_payment.amount<0 then 'corrective' else 'posted' end,target_payment.created_by) returning id into generated_entry_id;
  insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,created_by) values
   (target_payment.company_id,generated_entry_id,1,financial,'Compte financier',coalesce(target_payment.label,'Règlement'),case when target_payment.amount>0 then amount else 0 end,case when target_payment.amount<0 then amount else 0 end,target_payment.currency,target_payment.created_by),
   (target_payment.company_id,generated_entry_id,2,collective,party_label,coalesce(target_payment.label,'Règlement'),case when target_payment.amount<0 then amount else 0 end,case when target_payment.amount>0 then amount else 0 end,target_payment.currency,target_payment.created_by);
  update public.accounting_entry_lines target set auxiliary_code=auxiliary,auxiliary_label=party_label,third_party_id=doc.client_id where target.entry_id=generated_entry_id and target.line_number=2;
  return generated_entry_id;
end $$;

create or replace function public.accounting_payment_insert_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public._generate_payment_accounting_entry(new);return new;end $$;
drop trigger if exists payments_generate_accounting on public.payments;
create trigger payments_generate_accounting after insert on public.payments for each row execute function public.accounting_payment_insert_trigger();

create or replace function public.validate_accounting_configuration(target_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare blocking jsonb:='[]';warnings jsonb:='[]';information jsonb:='[]';
begin
  if not public.has_company_permission(target_company_id,'accounting_entries_read') then raise exception 'forbidden' using errcode='42501';end if;
  if not exists(select 1 from public.accounting_fiscal_years where company_id=target_company_id and status='open' and current_date between starts_on and ends_on) then blocking:=blocking||jsonb_build_array(jsonb_build_object('code','open_fiscal_year_missing','message','Aucun exercice ouvert pour la date actuelle.'));end if;
  if not exists(select 1 from public.accounting_journals where company_id=target_company_id and journal_type='sales' and active) then blocking:=blocking||jsonb_build_array(jsonb_build_object('code','sales_journal_missing','message','Journal de ventes manquant.'));end if;
  if not exists(select 1 from public.accounting_journals where company_id=target_company_id and journal_type='purchases' and active) then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','purchase_journal_missing','message','Journal d’achats non configuré.'));end if;
  if not exists(select 1 from public.accounting_settings where company_id=target_company_id and customer_collective_account<>'' and default_sales_account<>'') then blocking:=blocking||jsonb_build_array(jsonb_build_object('code','base_accounts_missing','message','Comptes clients ou ventes manquants.'));end if;
  if exists(select 1 from public.accounting_entries entry left join lateral(select coalesce(sum(line.debit),0) debit,coalesce(sum(line.credit),0) credit from public.accounting_entry_lines line where line.entry_id=entry.id) sums on true where entry.company_id=target_company_id and abs(sums.debit-sums.credit)>0.01) then blocking:=blocking||jsonb_build_array(jsonb_build_object('code','unbalanced_entries','message','Des écritures sont déséquilibrées.'));end if;
  if exists(select 1 from public.accounting_export_adapters where adapter_group='proprietary' and availability<>'available') then information:=information||jsonb_build_array(jsonb_build_object('code','proprietary_adapters_disabled','message','Les formats propriétaires non vérifiés restent À configurer.'));end if;
  return jsonb_build_object('ok',jsonb_array_length(blocking)=0,'blocking',blocking,'warnings',warnings,'information',information,'checked_at',now());
end $$;

create or replace function public.preview_accounting_export(target_company_id uuid,target_journal_type text,target_starts_on date,target_ends_on date,target_format_key text,target_include_corrections boolean default true)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare report jsonb;entries jsonb;accounts jsonb;pieces integer;debit numeric;credit numeric;adapter record;
begin
  if not public.has_company_permission(target_company_id,'accounting_export_preview') then raise exception 'forbidden' using errcode='42501';end if;
  if target_ends_on<target_starts_on then raise exception 'invalid_period';end if;
  select * into adapter from public.accounting_export_adapters where adapter_key=target_format_key;
  if adapter.id is null then raise exception 'unknown_export_adapter';end if;
  if adapter.availability<>'available' then raise exception 'export_adapter_not_verified';end if;
  report:=public.validate_accounting_configuration(target_company_id);
  select coalesce(jsonb_agg(entry_payload order by entry_date,entry_number),'[]'::jsonb),count(distinct piece_reference),coalesce(sum(entry_debit),0),coalesce(sum(entry_credit),0)
    into entries,pieces,debit,credit from (
      select entry.entry_date,entry.entry_number,entry.piece_reference,entry.label,entry.currency,entry.id,
        coalesce(sum(line.debit),0) entry_debit,coalesce(sum(line.credit),0) entry_credit,
        jsonb_build_object('id',entry.id,'entry_number',entry.entry_number,'entry_date',entry.entry_date,'piece_reference',entry.piece_reference,'piece_date',entry.piece_date,'label',entry.label,'journal_code',journal.code,'journal_label',journal.label,'document_id',entry.document_id,'payment_id',entry.payment_id,'debit',sum(line.debit),'credit',sum(line.credit),'balanced',abs(sum(line.debit)-sum(line.credit))<=0.01,
          'lines',jsonb_agg(jsonb_build_object('account_code',line.account_code,'account_label',line.account_label,'auxiliary_code',line.auxiliary_code,'auxiliary_label',line.auxiliary_label,'line_label',line.line_label,'debit',line.debit,'credit',line.credit,'tax_rate',line.tax_rate) order by line.line_number)) entry_payload
      from public.accounting_entries entry join public.accounting_journals journal on journal.id=entry.journal_id join public.accounting_entry_lines line on line.entry_id=entry.id
      where entry.company_id=target_company_id and entry.entry_date between target_starts_on and target_ends_on
        and (target_journal_type='fec' or journal.journal_type=target_journal_type)
        and (target_include_corrections or entry.status<>'corrective')
        and not exists(select 1 from public.accounting_export_batch_entries exported join public.accounting_export_batches batch on batch.id=exported.export_batch_id where exported.accounting_entry_id=entry.id and batch.status='validated')
      group by entry.id,journal.code,journal.label
    ) payload;
  select coalesce(jsonb_agg(value order by account_code),'[]'::jsonb) into accounts from (
    select line.account_code,jsonb_build_object('account_code',line.account_code,'account_label',max(line.account_label),'debit',sum(line.debit),'credit',sum(line.credit),'line_count',count(*)) value
    from public.accounting_entry_lines line join public.accounting_entries entry on entry.id=line.entry_id join public.accounting_journals journal on journal.id=entry.journal_id
    where entry.company_id=target_company_id and entry.entry_date between target_starts_on and target_ends_on
      and (target_journal_type='fec' or journal.journal_type=target_journal_type)
      and (target_include_corrections or entry.status<>'corrective')
      and not exists(select 1 from public.accounting_export_batch_entries exported join public.accounting_export_batches batch on batch.id=exported.export_batch_id where exported.accounting_entry_id=entry.id and batch.status='validated')
    group by line.account_code
  ) summary;
  return jsonb_build_object('ok',(report->>'ok')::boolean and abs(debit-credit)<=0.01,'journal_type',target_journal_type,'starts_on',target_starts_on,'ends_on',target_ends_on,'format',target_format_key,'adapter_status',adapter.availability,'piece_count',pieces,'entry_count',jsonb_array_length(entries),'total_debit',round(debit,2),'total_credit',round(credit,2),'accounts',accounts,'entries',entries,'configuration',report,'fec_status',case when target_format_key='fec_technical' then 'Revue comptable requise' else null end);
end $$;

create or replace function public.validate_accounting_export(target_company_id uuid,target_journal_type text,target_starts_on date,target_ends_on date,target_format_key text,target_include_attachments boolean default false,target_include_corrections boolean default true,target_comment text default null)
returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare preview jsonb;batch_id uuid:=gen_random_uuid();number text;content text;adapter_version uuid;
begin
  if not public.has_company_permission(target_company_id,'accounting_export_validate') then raise exception 'forbidden' using errcode='42501';end if;
  preview:=public.preview_accounting_export(target_company_id,target_journal_type,target_starts_on,target_ends_on,target_format_key,target_include_corrections);
  if not (preview->>'ok')::boolean then raise exception 'accounting_export_blocked';end if;
  if coalesce((preview->>'entry_count')::integer,0)=0 then raise exception 'accounting_export_empty';end if;
  number:='EXP-'||extract(year from current_date)::integer||'-'||upper(left(target_journal_type,3))||'-'||substr(replace(batch_id::text,'-',''),1,8);
  select version.id into adapter_version from public.accounting_export_adapter_versions version join public.accounting_export_adapters adapter on adapter.id=version.adapter_id where adapter.adapter_key=target_format_key order by version.version desc limit 1;
  insert into public.accounting_export_batches(id,company_id,export_number,journal_type,starts_on,ends_on,adapter_version_id,format_key,include_attachments,include_corrections,status,entry_count,piece_count,total_debit,total_credit,snapshot,snapshot_sha256,validation_report,comment,created_by,validated_by,validated_at)
  values(batch_id,target_company_id,number,target_journal_type,target_starts_on,target_ends_on,adapter_version,target_format_key,target_include_attachments,target_include_corrections,'validated',(preview->>'entry_count')::integer,(preview->>'piece_count')::integer,(preview->>'total_debit')::numeric,(preview->>'total_credit')::numeric,preview,encode(extensions.digest(convert_to(preview::text,'UTF8'),'sha256'),'hex'),preview->'configuration',nullif(trim(target_comment),''),auth.uid(),auth.uid(),now());
  insert into public.accounting_export_batch_entries(company_id,export_batch_id,accounting_entry_id,entry_snapshot)
    select target_company_id,batch_id,(item->>'id')::uuid,item from jsonb_array_elements(preview->'entries') item;
  if target_format_key='fec_technical' then
    content:='JournalCode;JournalLib;EcritureNum;EcritureDate;CompteNum;CompteLib;CompAuxNum;CompAuxLib;PieceRef;PieceDate;EcritureLib;Debit;Credit;EcritureLet;DateLet;ValidDate;Montantdevise;Idevise'||chr(10);
    select content||coalesce(string_agg(concat_ws(';',journal.code,journal.label,entry.entry_number,to_char(entry.entry_date,'YYYYMMDD'),line.account_code,replace(line.account_label,';',' '),coalesce(line.auxiliary_code,''),replace(coalesce(line.auxiliary_label,''),';',' '),replace(entry.piece_reference,';',' '),to_char(entry.piece_date,'YYYYMMDD'),replace(line.line_label,';',' '),replace(to_char(line.debit,'FM999999999990.00'),'.',','),replace(to_char(line.credit,'FM999999999990.00'),'.',','),'','',to_char(entry.validated_at::date,'YYYYMMDD'),coalesce(replace(to_char(line.foreign_amount,'FM999999999990.00'),'.',','),''),case when line.foreign_amount is null then '' else line.currency end),chr(10) order by entry.entry_date,entry.entry_number,line.line_number),'') into content
    from public.accounting_export_batch_entries selected join public.accounting_entries entry on entry.id=selected.accounting_entry_id join public.accounting_journals journal on journal.id=entry.journal_id join public.accounting_entry_lines line on line.entry_id=entry.id where selected.export_batch_id=batch_id;
  elsif target_format_key='csv_aux_separate' then
    content:='Date;Journal;Piece;Compte;CompteAuxiliaire;Libelle;Debit;Credit;Devise'||chr(10);
    select content||coalesce(string_agg(concat_ws(';',to_char(entry.entry_date,'DD/MM/YYYY'),journal.code,replace(entry.piece_reference,';',' '),line.account_code,coalesce(line.auxiliary_code,''),replace(line.line_label,';',' '),replace(to_char(line.debit,'FM999999999990.00'),'.',','),replace(to_char(line.credit,'FM999999999990.00'),'.',','),line.currency),chr(10) order by entry.entry_date,entry.entry_number,line.line_number),'') into content
    from public.accounting_export_batch_entries selected join public.accounting_entries entry on entry.id=selected.accounting_entry_id join public.accounting_journals journal on journal.id=entry.journal_id join public.accounting_entry_lines line on line.entry_id=entry.id where selected.export_batch_id=batch_id;
  elsif target_format_key='csv_aux_label' then
    content:='Date;Journal;Piece;Compte;CompteAuxiliaire;LibelleAuxiliaire;Libelle;Debit;Credit;Devise'||chr(10);
    select content||coalesce(string_agg(concat_ws(';',to_char(entry.entry_date,'DD/MM/YYYY'),journal.code,replace(entry.piece_reference,';',' '),line.account_code,coalesce(line.auxiliary_code,''),replace(coalesce(line.auxiliary_label,''),';',' '),replace(line.line_label,';',' '),replace(to_char(line.debit,'FM999999999990.00'),'.',','),replace(to_char(line.credit,'FM999999999990.00'),'.',','),line.currency),chr(10) order by entry.entry_date,entry.entry_number,line.line_number),'') into content
    from public.accounting_export_batch_entries selected join public.accounting_entries entry on entry.id=selected.accounting_entry_id join public.accounting_journals journal on journal.id=entry.journal_id join public.accounting_entry_lines line on line.entry_id=entry.id where selected.export_batch_id=batch_id;
  else
    content:='Journal;Date;Ecriture;Piece;Compte;LibelleCompte;CompteAuxiliaire;LibelleAuxiliaire;Libelle;Debit;Credit;Devise'||chr(10);
    select content||coalesce(string_agg(concat_ws(';',journal.code,to_char(entry.entry_date,'DD/MM/YYYY'),entry.entry_number,replace(entry.piece_reference,';',' '),line.account_code,replace(line.account_label,';',' '),coalesce(line.auxiliary_code,''),replace(coalesce(line.auxiliary_label,''),';',' '),replace(line.line_label,';',' '),replace(to_char(line.debit,'FM999999999990.00'),'.',','),replace(to_char(line.credit,'FM999999999990.00'),'.',','),line.currency),chr(10) order by entry.entry_date,entry.entry_number,line.line_number),'') into content
    from public.accounting_export_batch_entries selected join public.accounting_entries entry on entry.id=selected.accounting_entry_id join public.accounting_journals journal on journal.id=entry.journal_id join public.accounting_entry_lines line on line.entry_id=entry.id where selected.export_batch_id=batch_id;
  end if;
  insert into public.accounting_export_files(company_id,export_batch_id,file_kind,file_name,mime_type,content_text,sha256,size_bytes)
    values(target_company_id,batch_id,'entries',number||case when target_format_key='fec_technical' then '.txt' else '.csv' end,'text/plain; charset=utf-8',content,encode(extensions.digest(convert_to(content,'UTF8'),'sha256'),'hex'),octet_length(content));
  return batch_id;
end $$;

create or replace function public.cancel_accounting_export(target_batch_id uuid,target_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare batch public.accounting_export_batches%rowtype;cancellation_id uuid;
begin
  select * into batch from public.accounting_export_batches where id=target_batch_id;
  if batch.id is null or not public.has_company_permission(batch.company_id,'accounting_export_cancel') then raise exception 'forbidden' using errcode='42501';end if;
  if batch.status<>'validated' then raise exception 'export_not_validated';end if;
  if length(trim(coalesce(target_reason,'')))<3 then raise exception 'cancellation_reason_required';end if;
  insert into public.accounting_export_cancellations(company_id,export_batch_id,reason,cancelled_by) values(batch.company_id,batch.id,trim(target_reason),auth.uid()) returning id into cancellation_id;
  update public.accounting_export_batches set status='cancelled' where id=batch.id;
  return cancellation_id;
end $$;

create or replace function public.preview_vat_cash_collection(target_company_id uuid,target_starts_on date,target_ends_on date,target_include_corrections boolean default true)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare rows jsonb;total_collected numeric;total_base numeric;total_vat numeric;settings public.accounting_settings%rowtype;
begin
  if not public.has_company_permission(target_company_id,'accounting_vat_cash') then raise exception 'forbidden' using errcode='42501';end if;
  select * into settings from public.accounting_settings where company_id=target_company_id;
  with payment_documents as (
    select payment.id payment_id,payment.payment_number,payment.paid_at::date payment_date,payment.amount,
      doc.id document_id,doc.number document_number,doc.client_id,doc.operation_category,doc.total_incl_tax
    from public.payments payment join public.documents doc on doc.id=payment.document_id
    where payment.company_id=target_company_id and payment.status='confirmed'
      and payment.paid_at::date between target_starts_on and target_ends_on and doc.total_incl_tax<>0
      and (target_include_corrections or payment.amount>0)
  ), tax_groups as (
    select selected.payment_id,selected.payment_number,selected.payment_date,selected.amount,selected.document_id,
      selected.document_number,selected.client_id,selected.operation_category,line.tax_rate,
      sum(line.total_excl_tax) raw_base,sum(line.total_tax) raw_vat,sum(line.total_incl_tax) raw_total,
      sum(sum(line.total_incl_tax)) over(partition by selected.payment_id) document_lines_total
    from payment_documents selected join public.document_lines line on line.document_id=selected.document_id
    where line.line_type in('item','free_item','discount') and not line.optional
    group by selected.payment_id,selected.payment_number,selected.payment_date,selected.amount,selected.document_id,
      selected.document_number,selected.client_id,selected.operation_category,line.tax_rate
  ), allocated as (
    select grouped.*,
      round(grouped.amount*grouped.raw_total/nullif(grouped.document_lines_total,0),2) collected,
      round((grouped.amount*grouped.raw_total/nullif(grouped.document_lines_total,0))*grouped.raw_base/nullif(grouped.raw_total,0),2) base,
      round((grouped.amount*grouped.raw_total/nullif(grouped.document_lines_total,0))*grouped.raw_vat/nullif(grouped.raw_total,0),2) vat
    from tax_groups grouped where grouped.document_lines_total<>0 and grouped.raw_total<>0
  ), data as (
    select allocated.*,
      jsonb_build_object('payment_id',payment_id,'document_id',document_id,'payment_date',payment_date,
        'payment_number',payment_number,'document_number',document_number,'client_id',client_id,
        'collected_amount',collected,'tax_base',base,'vat',vat,'tax_rate',tax_rate,
        'method','Prorata TTC ventilé par taux des lignes de la facture',
        'scope_status',case when settings.vat_on_debits then 'debits_option' when coalesce(operation_category,'') ilike '%service%' then 'included' else 'review' end,
        'correction',amount<0) value
    from allocated
  )
  select coalesce(jsonb_agg(value order by payment_date,document_number,tax_rate),'[]'::jsonb),
    coalesce(sum(collected),0),coalesce(sum(base),0),coalesce(sum(vat),0)
  into rows,total_collected,total_base,total_vat from data;
  return jsonb_build_object('label','Calcul préparatoire — à valider par votre comptable.','starts_on',target_starts_on,'ends_on',target_ends_on,'total_collected',round(total_collected,2),'total_tax_base',round(total_base,2),'total_vat',round(total_vat,2),'lines',rows,'classification_note','Les biens, services, option sur les débits et opérations à vérifier restent distingués. La ventilation multi-taux est calculée au prorata TTC de chaque groupe de lignes.');
end $$;

create or replace function public.accounting_config_audit_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare company_value uuid;record_value uuid;new_value jsonb;old_value jsonb;
begin
  new_value:=case when tg_op='DELETE' then null else to_jsonb(new) end;
  old_value:=case when tg_op='INSERT' then null else to_jsonb(old) end;
  company_value:=coalesce(nullif(new_value->>'company_id','')::uuid,nullif(old_value->>'company_id','')::uuid);
  record_value:=coalesce(nullif(new_value->>'id','')::uuid,nullif(old_value->>'id','')::uuid,company_value);
  insert into public.accounting_config_history(company_id,table_name,record_id,old_value,new_value,changed_by)
  values(company_value,tg_table_name,record_value,old_value,new_value,auth.uid());
  return coalesce(new,old);
end $$;

do $$ declare table_name text;begin
  foreach table_name in array array['accounting_fiscal_years','accounting_journals','accounting_settings','accounting_account_mappings','accounting_vat_mappings','accounting_financial_accounts','accounting_payment_method_mappings','accounting_complementary_accounts','supplier_accounting_profiles'] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_audit',table_name);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.accounting_config_audit_trigger()',table_name||'_audit',table_name);
  end loop;
end $$;

do $$ declare table_name text;begin
  foreach table_name in array array['accounting_fiscal_years','accounting_journals','accounting_settings','supplier_accounting_profiles','accounting_third_party_identifiers','accounting_account_mappings','accounting_vat_mappings','accounting_financial_accounts','accounting_payment_method_mappings','accounting_complementary_accounts','accounting_config_history','accounting_entry_sequences','accounting_entries','accounting_entry_lines','accounting_export_batches','accounting_export_batch_entries','accounting_export_files','accounting_export_cancellations','vat_cash_collection_runs','vat_cash_collection_lines'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
  end loop;
end $$;

do $$ declare table_name text;begin
  foreach table_name in array array['accounting_fiscal_years','accounting_journals','accounting_settings','supplier_accounting_profiles','accounting_third_party_identifiers','accounting_account_mappings','accounting_vat_mappings','accounting_financial_accounts','accounting_payment_method_mappings','accounting_complementary_accounts'] loop
    execute format('drop policy if exists %I on public.%I',table_name||'_write',table_name);
    execute format('create policy %I on public.%I for all to authenticated using(public.has_company_permission(company_id,''accounting_settings_manage'')) with check(public.has_company_permission(company_id,''accounting_settings_manage''))',table_name||'_write',table_name);
  end loop;
end $$;

alter table public.accounting_export_adapters enable row level security;
alter table public.accounting_export_adapter_versions enable row level security;
create policy accounting_export_adapters_read on public.accounting_export_adapters for select to authenticated using(true);
create policy accounting_export_adapter_versions_read on public.accounting_export_adapter_versions for select to authenticated using(true);

revoke all on public.accounting_entries,public.accounting_entry_lines,public.accounting_export_batches,public.accounting_export_batch_entries,public.accounting_export_files,public.accounting_export_cancellations,public.vat_cash_collection_runs,public.vat_cash_collection_lines from anon,authenticated;
grant select on public.accounting_entries,public.accounting_entry_lines,public.accounting_export_batches,public.accounting_export_batch_entries,public.accounting_export_files,public.accounting_export_cancellations,public.vat_cash_collection_runs,public.vat_cash_collection_lines to authenticated;
grant select on public.accounting_export_adapters,public.accounting_export_adapter_versions to authenticated;
grant select,insert,update on public.accounting_fiscal_years,public.accounting_journals,public.accounting_settings,public.supplier_accounting_profiles,public.accounting_third_party_identifiers,public.accounting_account_mappings,public.accounting_vat_mappings,public.accounting_financial_accounts,public.accounting_payment_method_mappings,public.accounting_complementary_accounts to authenticated;
grant select on public.accounting_config_history to authenticated;

revoke all on function public.bootstrap_company_accounting(uuid,date),public.generate_document_accounting_entry(uuid),public.validate_accounting_configuration(uuid),public.preview_accounting_export(uuid,text,date,date,text,boolean),public.validate_accounting_export(uuid,text,date,date,text,boolean,boolean,text),public.cancel_accounting_export(uuid,text),public.preview_vat_cash_collection(uuid,date,date,boolean) from public,anon;
grant execute on function public.bootstrap_company_accounting(uuid,date),public.generate_document_accounting_entry(uuid),public.validate_accounting_configuration(uuid),public.preview_accounting_export(uuid,text,date,date,text,boolean),public.validate_accounting_export(uuid,text,date,date,text,boolean,boolean,text),public.cancel_accounting_export(uuid,text),public.preview_vat_cash_collection(uuid,date,date,boolean) to authenticated;

commit;
