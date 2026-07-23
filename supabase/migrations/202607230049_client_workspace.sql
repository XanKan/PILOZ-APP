begin;

-- Espace Clients Piloz. Migration additive et non destructive.
-- Les champs historiques de public.clients restent disponibles. Les nouveaux
-- documents mémorisent le contact et les adresses sélectionnés, puis les
-- snapshots les figent sans modifier les snapshots déjà créés.

alter table public.clients
  add column if not exists customer_status text not null default 'active',
  add column if not exists website text,
  add column if not exists assigned_user_id uuid,
  add column if not exists accounting_label text;

alter table public.clients drop constraint if exists clients_customer_status_check;
alter table public.clients add constraint clients_customer_status_check
  check(customer_status in ('active','prospect','watch','inactive','archived')) not valid;

update public.clients
set customer_status=case
  when relationship_type='prospect' then 'prospect'
  when relationship_type='archived' then 'archived'
  when not active then 'inactive'
  else 'active'
end
where customer_status='active'
  and (relationship_type in ('prospect','archived') or not active);

alter table public.client_contacts
  add column if not exists department text,
  add column if not exists secondary_email text,
  add column if not exists mobile_e164 text,
  add column if not exists language text not null default 'fr',
  add column if not exists preferred_contact_method text,
  add column if not exists internal_comment text,
  add column if not exists active boolean not null default true,
  add column if not exists updated_by uuid;

create table if not exists public.client_contact_roles(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  contact_id uuid not null references public.client_contacts(id) on delete cascade,
  role text not null check(role in(
    'primary','commercial','billing','accounting','delivery','signatory','decision_maker','technical','other'
  )),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(contact_id,role)
);

create table if not exists public.client_addresses(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  label text not null,
  address_type text not null default 'main' check(address_type in(
    'registered','main','billing','shipping','service','secondary','other'
  )),
  recipient_name text,
  company_name text,
  address_line_1 text not null,
  address_line_2 text,
  complement text,
  postal_code text,
  city text,
  region text,
  country_code text not null default 'FR',
  phone_e164 text,
  instructions text,
  is_primary boolean not null default false,
  is_default_billing boolean not null default false,
  is_default_shipping boolean not null default false,
  is_default_service boolean not null default false,
  active boolean not null default true,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.client_preferences
  add column if not exists default_contact_id uuid references public.client_contacts(id) on delete set null,
  add column if not exists billing_contact_id uuid references public.client_contacts(id) on delete set null,
  add column if not exists billing_address_id uuid references public.client_addresses(id) on delete set null,
  add column if not exists shipping_address_id uuid references public.client_addresses(id) on delete set null,
  add column if not exists service_address_id uuid references public.client_addresses(id) on delete set null,
  add column if not exists footer_id uuid references public.document_footers(id) on delete set null,
  add column if not exists document_notes text,
  add column if not exists internal_notes text,
  add column if not exists updated_by uuid;

create table if not exists public.company_customer_account_settings(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade unique,
  default_collective_account text not null default '411000',
  professional_collective_account text,
  individual_collective_account text,
  automatic_generation boolean not null default true,
  prefix text not null default 'CLI',
  padding smallint not null default 6 check(padding between 1 and 24),
  next_number bigint not null default 1 check(next_number>0),
  account_format text not null default 'prefix_number' check(account_format in(
    'prefix_number','c_number','initial_number','siren','custom'
  )),
  custom_pattern text,
  allow_manual boolean not null default true,
  enforce_uniqueness boolean not null default true,
  manage_inactive boolean not null default true,
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_accounting_profiles(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade unique,
  collective_account text,
  auxiliary_account text,
  assignment_mode text not null default 'automatic' check(assignment_mode in('automatic','manual')),
  accounting_label text,
  active boolean not null default true,
  effective_from date not null default current_date,
  vat_regime text,
  export_enabled boolean not null default false,
  internal_comment text,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_account_history(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  previous_auxiliary_account text,
  new_auxiliary_account text,
  collective_account text,
  assignment_mode text not null check(assignment_mode in('automatic','manual')),
  effective_from date not null,
  reason text,
  changed_by uuid not null default auth.uid(),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.client_notes(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  body text not null check(nullif(trim(body),'') is not null),
  pinned boolean not null default false,
  mentioned_user_ids uuid[] not null default '{}',
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_documents(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  contact_id uuid references public.client_contacts(id) on delete set null,
  commercial_document_id uuid references public.documents(id) on delete set null,
  file_name text not null,
  document_type text not null default 'other',
  storage_path text not null,
  mime_type text,
  size_bytes bigint check(size_bytes is null or size_bytes>=0),
  document_date date,
  internal_only boolean not null default true,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.client_tags(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  color text not null default '#64748b',
  active boolean not null default true,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,name)
);

create table if not exists public.client_tag_assignments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  tag_id uuid not null references public.client_tags(id) on delete cascade,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(client_id,tag_id)
);

create table if not exists public.client_activity_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  event_type text not null,
  summary text not null,
  entity_type text,
  entity_id uuid,
  previous_state jsonb,
  new_state jsonb,
  metadata jsonb not null default '{}',
  occurred_at timestamptz not null default now(),
  actor_user_id uuid default auth.uid(),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.client_duplicate_candidates(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  source_client_id uuid not null references public.clients(id) on delete cascade,
  candidate_client_id uuid not null references public.clients(id) on delete cascade,
  confidence numeric(5,2) not null check(confidence between 0 and 100),
  matching_fields text[] not null default '{}',
  status text not null default 'pending' check(status in('pending','ignored','confirmed','resolved')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check(source_client_id<>candidate_client_id),
  unique(company_id,source_client_id,candidate_client_id)
);

alter table public.documents
  add column if not exists contact_id uuid references public.client_contacts(id) on delete set null,
  add column if not exists billing_address_id uuid references public.client_addresses(id) on delete set null,
  add column if not exists delivery_address_id uuid references public.client_addresses(id) on delete set null;

alter table public.activities
  add column if not exists contact_id uuid references public.client_contacts(id) on delete set null;

create table if not exists public.document_contact_snapshots(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null references public.documents(id) on delete restrict,
  snapshot_id uuid not null references public.document_snapshots(id) on delete restrict,
  source_contact_id uuid,
  contact_payload jsonb not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique(snapshot_id)
);

create table if not exists public.document_address_snapshots(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null references public.documents(id) on delete restrict,
  snapshot_id uuid not null references public.document_snapshots(id) on delete restrict,
  address_kind text not null check(address_kind in('billing','delivery')),
  source_address_id uuid,
  address_payload jsonb not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique(snapshot_id,address_kind)
);

create unique index if not exists client_contacts_company_client_id_uidx
  on public.client_contacts(company_id,client_id,id);
create index if not exists client_contacts_search_idx
  on public.client_contacts(company_id,client_id,active,last_name,first_name,email);
create index if not exists client_contact_roles_client_idx
  on public.client_contact_roles(company_id,client_id,role);
create unique index if not exists client_contact_roles_one_primary_idx
  on public.client_contact_roles(client_id) where role='primary';
create index if not exists client_addresses_search_idx
  on public.client_addresses(company_id,client_id,active,address_type,city);
create unique index if not exists client_addresses_one_primary_idx
  on public.client_addresses(client_id) where is_primary and active;
create unique index if not exists client_addresses_one_billing_idx
  on public.client_addresses(client_id) where is_default_billing and active;
create unique index if not exists client_addresses_one_shipping_idx
  on public.client_addresses(client_id) where is_default_shipping and active;
create unique index if not exists client_addresses_one_service_idx
  on public.client_addresses(client_id) where is_default_service and active;
create unique index if not exists client_accounting_profiles_auxiliary_uidx
  on public.client_accounting_profiles(company_id,auxiliary_account)
  where active and auxiliary_account is not null;
create index if not exists client_account_history_timeline_idx
  on public.client_account_history(company_id,client_id,created_at desc);
create index if not exists client_notes_timeline_idx
  on public.client_notes(company_id,client_id,pinned desc,updated_at desc);
create index if not exists client_documents_timeline_idx
  on public.client_documents(company_id,client_id,document_date desc,created_at desc);
create index if not exists client_tag_assignments_client_idx
  on public.client_tag_assignments(company_id,client_id,tag_id);
create index if not exists client_activity_events_timeline_idx
  on public.client_activity_events(company_id,client_id,occurred_at desc,id desc);
create index if not exists clients_workspace_filters_idx
  on public.clients(company_id,customer_status,kind,assigned_user_id,updated_at desc);
create index if not exists documents_client_workspace_idx
  on public.documents(company_id,client_id,document_type,issue_date desc,id);
create index if not exists payments_client_workspace_idx
  on public.payments(company_id,document_id,paid_at desc,id);
create index if not exists activities_client_contact_idx
  on public.activities(company_id,client_id,contact_id,created_at desc);

create or replace function public.enforce_activity_contact_reference()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.contact_id is not null and not exists(
    select 1 from public.client_contacts c
    where c.id=new.contact_id and c.client_id=new.client_id and c.company_id=new.company_id
  ) then
    raise exception 'activity_contact_context_mismatch' using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function public.enforce_activity_contact_reference() from public,anon,authenticated;
drop trigger if exists activities_contact_context_guard on public.activities;
create trigger activities_contact_context_guard
before insert or update of client_id,company_id,contact_id on public.activities
for each row execute function public.enforce_activity_contact_reference();

-- Contrôle systématique de l'isolation : une ligne enfant ne peut jamais
-- référencer un client d'une autre entreprise, même avec un UUID deviné.
create or replace function public.enforce_client_company_reference()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare expected_company uuid;
begin
  select company_id into expected_company from public.clients where id=new.client_id;
  if expected_company is null or expected_company<>new.company_id then
    raise exception 'client_company_mismatch' using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function public.enforce_client_company_reference() from public,anon,authenticated;

do $triggers$
declare table_name text;
begin
  foreach table_name in array array[
    'client_contacts','client_contact_roles','client_addresses','client_preferences',
    'client_accounting_profiles','client_account_history','client_notes','client_documents',
    'client_tag_assignments','client_activity_events'
  ] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_tenant_guard',table_name);
    execute format(
      'create trigger %I before insert or update of company_id,client_id on public.%I for each row execute function public.enforce_client_company_reference()',
      table_name||'_tenant_guard',table_name
    );
  end loop;
end
$triggers$;

create or replace function public.enforce_client_contact_role_reference()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if not exists(
    select 1 from public.client_contacts contact
    where contact.id=new.contact_id and contact.company_id=new.company_id and contact.client_id=new.client_id
  ) then raise exception 'contact_client_mismatch' using errcode='42501'; end if;
  return new;
end
$$;
revoke all on function public.enforce_client_contact_role_reference() from public,anon,authenticated;
drop trigger if exists client_contact_roles_reference_guard on public.client_contact_roles;
create trigger client_contact_roles_reference_guard
before insert or update of company_id,client_id,contact_id on public.client_contact_roles
for each row execute function public.enforce_client_contact_role_reference();

create or replace function public.enforce_client_preferences_context()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.default_contact_id is not null and not exists(
    select 1 from public.client_contacts c where c.id=new.default_contact_id
      and c.company_id=new.company_id and c.client_id=new.client_id
  ) then raise exception 'default_contact_client_mismatch' using errcode='42501'; end if;
  if new.billing_contact_id is not null and not exists(
    select 1 from public.client_contacts c where c.id=new.billing_contact_id
      and c.company_id=new.company_id and c.client_id=new.client_id
  ) then raise exception 'billing_contact_client_mismatch' using errcode='42501'; end if;
  if new.billing_address_id is not null and not exists(
    select 1 from public.client_addresses a where a.id=new.billing_address_id
      and a.company_id=new.company_id and a.client_id=new.client_id
  ) then raise exception 'billing_address_client_mismatch' using errcode='42501'; end if;
  if new.shipping_address_id is not null and not exists(
    select 1 from public.client_addresses a where a.id=new.shipping_address_id
      and a.company_id=new.company_id and a.client_id=new.client_id
  ) then raise exception 'shipping_address_client_mismatch' using errcode='42501'; end if;
  if new.service_address_id is not null and not exists(
    select 1 from public.client_addresses a where a.id=new.service_address_id
      and a.company_id=new.company_id and a.client_id=new.client_id
  ) then raise exception 'service_address_client_mismatch' using errcode='42501'; end if;
  if new.quote_template_id is not null and not exists(
    select 1 from public.document_templates t where t.id=new.quote_template_id
      and t.company_id=new.company_id and t.document_type='quote'
  ) then raise exception 'quote_template_company_mismatch' using errcode='42501'; end if;
  if new.invoice_template_id is not null and not exists(
    select 1 from public.document_templates t where t.id=new.invoice_template_id
      and t.company_id=new.company_id and t.document_type='invoice'
  ) then raise exception 'invoice_template_company_mismatch' using errcode='42501'; end if;
  if new.footer_id is not null and not exists(
    select 1 from public.document_footers f where f.id=new.footer_id and f.company_id=new.company_id
  ) then raise exception 'footer_company_mismatch' using errcode='42501'; end if;
  return new;
end
$$;
revoke all on function public.enforce_client_preferences_context() from public,anon,authenticated;
drop trigger if exists client_preferences_context_guard on public.client_preferences;
create trigger client_preferences_context_guard
before insert or update of company_id,client_id,default_contact_id,billing_contact_id,
  billing_address_id,shipping_address_id,service_address_id,quote_template_id,invoice_template_id,footer_id
on public.client_preferences for each row execute function public.enforce_client_preferences_context();

create or replace function public.enforce_duplicate_candidate_company_reference()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if not exists(
    select 1 from public.clients source
    join public.clients candidate on candidate.id=new.candidate_client_id
    where source.id=new.source_client_id
      and source.company_id=new.company_id and candidate.company_id=new.company_id
  ) then raise exception 'client_company_mismatch' using errcode='42501'; end if;
  return new;
end
$$;
revoke all on function public.enforce_duplicate_candidate_company_reference() from public,anon,authenticated;
drop trigger if exists client_duplicate_candidates_tenant_guard on public.client_duplicate_candidates;
create trigger client_duplicate_candidates_tenant_guard
before insert or update of company_id,source_client_id,candidate_client_id
on public.client_duplicate_candidates for each row
execute function public.enforce_duplicate_candidate_company_reference();

create or replace function public.enforce_document_client_context()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare source_doc public.documents%rowtype; owner_company uuid; owner_client uuid;
begin
  if tg_op='INSERT' and new.source_document_id is not null then
    select * into source_doc from public.documents where id=new.source_document_id;
    if source_doc.id is not null and source_doc.company_id=new.company_id
       and (new.client_id is null or new.client_id=source_doc.client_id) then
      new.client_id:=coalesce(new.client_id,source_doc.client_id);
      new.contact_id:=coalesce(new.contact_id,source_doc.contact_id);
      new.billing_address_id:=coalesce(new.billing_address_id,source_doc.billing_address_id);
      new.delivery_address_id:=coalesce(new.delivery_address_id,source_doc.delivery_address_id);
    end if;
  end if;
  if new.contact_id is not null then
    select company_id,client_id into owner_company,owner_client
    from public.client_contacts where id=new.contact_id and active;
    if owner_company is distinct from new.company_id or owner_client is distinct from new.client_id then
      raise exception 'document_contact_mismatch' using errcode='42501';
    end if;
  end if;
  if new.billing_address_id is not null then
    select company_id,client_id into owner_company,owner_client
    from public.client_addresses where id=new.billing_address_id and active;
    if owner_company is distinct from new.company_id or owner_client is distinct from new.client_id then
      raise exception 'document_billing_address_mismatch' using errcode='42501';
    end if;
  end if;
  if new.delivery_address_id is not null then
    select company_id,client_id into owner_company,owner_client
    from public.client_addresses where id=new.delivery_address_id and active;
    if owner_company is distinct from new.company_id or owner_client is distinct from new.client_id then
      raise exception 'document_delivery_address_mismatch' using errcode='42501';
    end if;
  end if;
  return new;
end
$$;
revoke all on function public.enforce_document_client_context() from public,anon,authenticated;
drop trigger if exists documents_client_context_guard on public.documents;
create trigger documents_client_context_guard
before insert or update of company_id,client_id,contact_id,billing_address_id,delivery_address_id,source_document_id
on public.documents for each row execute function public.enforce_document_client_context();

-- Les données sélectionnées sont injectées avant le calcul final du hash.
create or replace function public.enrich_document_snapshot_client_context()
returns trigger language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare doc public.documents%rowtype; contact_payload jsonb; billing_payload jsonb; delivery_payload jsonb;
begin
  select * into doc from public.documents
  where id=new.document_id and company_id=new.company_id;
  if doc.id is null then raise exception 'snapshot_document_mismatch'; end if;
  if doc.contact_id is not null then
    select jsonb_build_object(
      'id',c.id,'civility',c.civility,'first_name',c.first_name,'last_name',c.last_name,
      'job_title',c.job_title,'department',c.department,'email',c.email,
      'phone_e164',c.phone_e164,'mobile_e164',c.mobile_e164,'language',c.language
    ) into contact_payload from public.client_contacts c
    where c.id=doc.contact_id and c.company_id=doc.company_id and c.client_id=doc.client_id;
  end if;
  if doc.billing_address_id is not null then
    select jsonb_build_object(
      'id',a.id,'label',a.label,'address_type',a.address_type,'recipient_name',a.recipient_name,
      'company_name',a.company_name,'address_line_1',a.address_line_1,'address_line_2',a.address_line_2,
      'complement',a.complement,'postal_code',a.postal_code,'city',a.city,'region',a.region,
      'country_code',a.country_code,'phone_e164',a.phone_e164,'instructions',a.instructions
    ) into billing_payload from public.client_addresses a
    where a.id=doc.billing_address_id and a.company_id=doc.company_id and a.client_id=doc.client_id;
  end if;
  if doc.delivery_address_id is not null then
    select jsonb_build_object(
      'id',a.id,'label',a.label,'address_type',a.address_type,'recipient_name',a.recipient_name,
      'company_name',a.company_name,'address_line_1',a.address_line_1,'address_line_2',a.address_line_2,
      'complement',a.complement,'postal_code',a.postal_code,'city',a.city,'region',a.region,
      'country_code',a.country_code,'phone_e164',a.phone_e164,'instructions',a.instructions
    ) into delivery_payload from public.client_addresses a
    where a.id=doc.delivery_address_id and a.company_id=doc.company_id and a.client_id=doc.client_id;
  end if;
  new.public_payload:=jsonb_set(
    jsonb_set(
      jsonb_set(coalesce(new.public_payload,'{}'::jsonb),'{recipient_contact}',coalesce(contact_payload,'null'::jsonb),true),
      '{billing_address}',coalesce(billing_payload,'null'::jsonb),true
    ),'{delivery_address}',coalesce(delivery_payload,'null'::jsonb),true
  );
  new.internal_payload:=jsonb_set(
    jsonb_set(
      jsonb_set(coalesce(new.internal_payload,'{}'::jsonb),'{recipient_contact}',coalesce(contact_payload,'null'::jsonb),true),
      '{billing_address}',coalesce(billing_payload,'null'::jsonb),true
    ),'{delivery_address}',coalesce(delivery_payload,'null'::jsonb),true
  );
  new.payload_hash:=encode(extensions.digest(convert_to(new.public_payload::text,'UTF8'),'sha256'),'hex');
  return new;
end
$$;
revoke all on function public.enrich_document_snapshot_client_context() from public,anon,authenticated;
drop trigger if exists document_snapshots_client_context on public.document_snapshots;
create trigger document_snapshots_client_context
before insert on public.document_snapshots for each row
execute function public.enrich_document_snapshot_client_context();

create or replace function public.persist_document_client_context_snapshot()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.public_payload->'recipient_contact' is not null
     and jsonb_typeof(new.public_payload->'recipient_contact')='object' then
    insert into public.document_contact_snapshots(
      company_id,document_id,snapshot_id,source_contact_id,contact_payload,created_by
    ) values(
      new.company_id,new.document_id,new.id,nullif(new.public_payload->'recipient_contact'->>'id','')::uuid,
      new.public_payload->'recipient_contact',new.created_by
    ) on conflict(snapshot_id) do nothing;
  end if;
  if new.public_payload->'billing_address' is not null
     and jsonb_typeof(new.public_payload->'billing_address')='object' then
    insert into public.document_address_snapshots(
      company_id,document_id,snapshot_id,address_kind,source_address_id,address_payload,created_by
    ) values(
      new.company_id,new.document_id,new.id,'billing',nullif(new.public_payload->'billing_address'->>'id','')::uuid,
      new.public_payload->'billing_address',new.created_by
    ) on conflict(snapshot_id,address_kind) do nothing;
  end if;
  if new.public_payload->'delivery_address' is not null
     and jsonb_typeof(new.public_payload->'delivery_address')='object' then
    insert into public.document_address_snapshots(
      company_id,document_id,snapshot_id,address_kind,source_address_id,address_payload,created_by
    ) values(
      new.company_id,new.document_id,new.id,'delivery',nullif(new.public_payload->'delivery_address'->>'id','')::uuid,
      new.public_payload->'delivery_address',new.created_by
    ) on conflict(snapshot_id,address_kind) do nothing;
  end if;
  return new;
end
$$;
revoke all on function public.persist_document_client_context_snapshot() from public,anon,authenticated;
drop trigger if exists document_snapshots_persist_client_context on public.document_snapshots;
create trigger document_snapshots_persist_client_context
after insert on public.document_snapshots for each row
execute function public.persist_document_client_context_snapshot();

-- Historique unifié sans copie des champs sensibles complets.
create or replace function public.log_client_workspace_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare row_data jsonb; old_data jsonb; cid uuid; client uuid; label text; kind text;
begin
  row_data:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  old_data:=case when tg_op='UPDATE' then to_jsonb(old) else null end;
  cid:=(row_data->>'company_id')::uuid;
  client:=case when tg_table_name='clients' then (row_data->>'id')::uuid else (row_data->>'client_id')::uuid end;
  if cid is null or client is null then return coalesce(new,old); end if;
  kind:=case
    when tg_table_name='clients' and tg_op='INSERT' then 'client.created'
    when tg_table_name='clients' then 'client.updated'
    when tg_table_name='client_contacts' then 'contact.'||lower(tg_op)
    when tg_table_name='client_addresses' then 'address.'||lower(tg_op)
    when tg_table_name='client_preferences' then 'preferences.'||lower(tg_op)
    when tg_table_name='client_notes' then 'note.'||lower(tg_op)
    when tg_table_name='client_documents' then 'file.'||lower(tg_op)
    when tg_table_name='client_account_history' then 'account.changed'
    else tg_table_name||'.'||lower(tg_op)
  end;
  label:=case
    when tg_table_name='clients' and tg_op='INSERT' then 'Client créé'
    when tg_table_name='clients' then 'Coordonnées du client modifiées'
    when tg_table_name='client_contacts' then 'Contact '||case when tg_op='INSERT' then 'ajouté' when tg_op='DELETE' then 'supprimé' else 'modifié' end
    when tg_table_name='client_addresses' then 'Adresse '||case when tg_op='INSERT' then 'ajoutée' when tg_op='DELETE' then 'supprimée' else 'modifiée' end
    when tg_table_name='client_preferences' then 'Préférences commerciales modifiées'
    when tg_table_name='client_notes' then 'Note '||case when tg_op='INSERT' then 'ajoutée' when tg_op='DELETE' then 'supprimée' else 'modifiée' end
    when tg_table_name='client_documents' then 'Document client '||case when tg_op='INSERT' then 'ajouté' when tg_op='DELETE' then 'supprimé' else 'modifié' end
    when tg_table_name='client_account_history' then 'Compte auxiliaire modifié'
    else 'Fiche client mise à jour'
  end;
  insert into public.client_activity_events(
    company_id,client_id,event_type,summary,entity_type,entity_id,
    previous_state,new_state,actor_user_id,created_by
  ) values(
    cid,client,kind,label,tg_table_name,(row_data->>'id')::uuid,
    case when tg_op='UPDATE' then jsonb_build_object('updated_at',old_data->>'updated_at') else null end,
    jsonb_build_object('operation',lower(tg_op)),coalesce(auth.uid(),(row_data->>'created_by')::uuid),
    coalesce(auth.uid(),(row_data->>'created_by')::uuid)
  );
  if tg_op='DELETE' then return old; end if;
  return new;
end
$$;
revoke all on function public.log_client_workspace_event() from public,anon,authenticated;

do $event_triggers$
declare table_name text;
begin
  foreach table_name in array array[
    'clients','client_contacts','client_addresses','client_preferences','client_notes',
    'client_documents','client_account_history'
  ] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_workspace_event',table_name);
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function public.log_client_workspace_event()',
      table_name||'_workspace_event',table_name
    );
  end loop;
end
$event_triggers$;

create or replace function public.log_client_document_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare event_key text; event_label text;
begin
  if new.client_id is null then return new; end if;
  if tg_op='UPDATE' and old.status is not distinct from new.status
     and old.client_id is not distinct from new.client_id then return new; end if;
  event_key:=new.document_type||case when tg_op='INSERT' then '.created' else '.'||coalesce(new.status,'updated') end;
  event_label:=case new.document_type
    when 'quote' then 'Devis'
    when 'credit_note' then 'Avoir'
    else 'Facture'
  end||case when tg_op='INSERT' then ' créé' else ' · statut '||coalesce(new.status,'modifié') end;
  insert into public.client_activity_events(
    company_id,client_id,event_type,summary,entity_type,entity_id,metadata,actor_user_id,created_by
  ) values(
    new.company_id,new.client_id,event_key,event_label,'document',new.id,
    jsonb_build_object('document_type',new.document_type,'number',new.number,'status',new.status),
    coalesce(auth.uid(),new.created_by),coalesce(auth.uid(),new.created_by)
  );
  return new;
end
$$;
revoke all on function public.log_client_document_event() from public,anon,authenticated;
drop trigger if exists documents_client_workspace_event on public.documents;
create trigger documents_client_workspace_event
after insert or update of status,client_id on public.documents for each row
execute function public.log_client_document_event();

create or replace function public.log_client_payment_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=new.document_id and company_id=new.company_id;
  if doc.client_id is not null then
    insert into public.client_activity_events(
      company_id,client_id,event_type,summary,entity_type,entity_id,metadata,actor_user_id,created_by
    ) values(
      new.company_id,doc.client_id,'payment.recorded','Paiement enregistré','payment',new.id,
      jsonb_build_object('document_id',new.document_id,'amount',new.amount,'status',new.status,'entry_type',new.entry_type),
      coalesce(auth.uid(),new.created_by),coalesce(auth.uid(),new.created_by)
    );
  end if;
  return new;
end
$$;
revoke all on function public.log_client_payment_event() from public,anon,authenticated;
drop trigger if exists payments_client_workspace_event on public.payments;
create trigger payments_client_workspace_event after insert on public.payments
for each row execute function public.log_client_payment_event();

create or replace function public.log_client_activity_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.client_id is not null then
    insert into public.client_activity_events(
      company_id,client_id,event_type,summary,entity_type,entity_id,metadata,actor_user_id,created_by
    ) values(
      new.company_id,new.client_id,'activity.'||lower(tg_op),
      case when tg_op='INSERT' then 'Activité ajoutée' else 'Activité modifiée' end,
      'activity',new.id,jsonb_build_object('activity_type',new.activity_type,'status',new.status,'subject',new.subject),
      coalesce(auth.uid(),new.created_by),coalesce(auth.uid(),new.created_by)
    );
  end if;
  return new;
end
$$;
revoke all on function public.log_client_activity_event() from public,anon,authenticated;
drop trigger if exists activities_client_workspace_event on public.activities;
create trigger activities_client_workspace_event after insert or update on public.activities
for each row execute function public.log_client_activity_event();

-- RPC atomique pour les contacts et leurs rôles.
create or replace function public.save_client_contact(
  target_client_id uuid,target_contact jsonb,target_roles text[] default '{}'
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid(); client_row public.clients%rowtype; contact_row public.client_contacts%rowtype;
  edited_contact_id uuid:=nullif(target_contact->>'id','')::uuid; primary_requested boolean;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into client_row from public.clients where id=target_client_id for update;
  if client_row.id is null or not public.is_company_member(client_row.company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  if not public.has_company_permission(client_row.company_id,'manage_customer') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if nullif(trim(target_contact->>'first_name'),'') is null
     or nullif(trim(target_contact->>'last_name'),'') is null then
    raise exception 'contact_name_required' using errcode='22023';
  end if;
  if exists(select 1 from unnest(coalesce(target_roles,'{}')) value where value not in(
    'primary','commercial','billing','accounting','delivery','signatory','decision_maker','technical','other'
  )) then raise exception 'invalid_contact_role' using errcode='22023'; end if;
  primary_requested:=coalesce((target_contact->>'is_primary')::boolean,false) or 'primary'=any(coalesce(target_roles,'{}'));
  if primary_requested then
    update public.client_contacts set is_primary=false,updated_by=actor_id,updated_at=now()
    where company_id=client_row.company_id and client_id=client_row.id and is_primary
      and (edited_contact_id is null or id<>edited_contact_id);
    delete from public.client_contact_roles
    where company_id=client_row.company_id and client_id=client_row.id and role='primary'
      and (edited_contact_id is null or client_contact_roles.contact_id<>edited_contact_id);
  end if;
  if edited_contact_id is null then
    insert into public.client_contacts(
      company_id,client_id,civility,first_name,last_name,job_title,department,email,secondary_email,
      phone_e164,mobile_e164,language,preferred_contact_method,internal_comment,is_primary,active,created_by,updated_by
    ) values(
      client_row.company_id,client_row.id,nullif(target_contact->>'civility',''),trim(target_contact->>'first_name'),
      trim(target_contact->>'last_name'),nullif(target_contact->>'job_title',''),nullif(target_contact->>'department',''),
      nullif(lower(trim(target_contact->>'email')),''),nullif(lower(trim(target_contact->>'secondary_email')),''),
      nullif(target_contact->>'phone_e164',''),nullif(target_contact->>'mobile_e164',''),
      coalesce(nullif(target_contact->>'language',''),'fr'),nullif(target_contact->>'preferred_contact_method',''),
      nullif(target_contact->>'internal_comment',''),primary_requested,
      coalesce((target_contact->>'active')::boolean,true),actor_id,actor_id
    ) returning * into contact_row;
  else
    update public.client_contacts set
      civility=nullif(target_contact->>'civility',''),first_name=trim(target_contact->>'first_name'),
      last_name=trim(target_contact->>'last_name'),job_title=nullif(target_contact->>'job_title',''),
      department=nullif(target_contact->>'department',''),email=nullif(lower(trim(target_contact->>'email')),''),
      secondary_email=nullif(lower(trim(target_contact->>'secondary_email')),''),
      phone_e164=nullif(target_contact->>'phone_e164',''),mobile_e164=nullif(target_contact->>'mobile_e164',''),
      language=coalesce(nullif(target_contact->>'language',''),'fr'),
      preferred_contact_method=nullif(target_contact->>'preferred_contact_method',''),
      internal_comment=nullif(target_contact->>'internal_comment',''),is_primary=primary_requested,
      active=coalesce((target_contact->>'active')::boolean,true),updated_by=actor_id,updated_at=now()
    where id=edited_contact_id and company_id=client_row.company_id and client_id=client_row.id
    returning * into contact_row;
    if contact_row.id is null then raise exception 'contact_not_found' using errcode='P0002'; end if;
  end if;
  delete from public.client_contact_roles where contact_id=contact_row.id;
  insert into public.client_contact_roles(company_id,client_id,contact_id,role,created_by)
  select client_row.company_id,client_row.id,contact_row.id,value,actor_id
  from unnest(array(select distinct value from unnest(
    case when primary_requested and not ('primary'=any(coalesce(target_roles,'{}')))
      then array_append(coalesce(target_roles,'{}'),'primary') else coalesce(target_roles,'{}') end
  ) value)) value;
  if primary_requested then
    insert into public.client_preferences(company_id,client_id,default_contact_id,created_by,updated_by)
    values(client_row.company_id,client_row.id,contact_row.id,actor_id,actor_id)
    on conflict(client_id) do update set default_contact_id=excluded.default_contact_id,updated_by=actor_id,updated_at=now();
  end if;
  return to_jsonb(contact_row)||jsonb_build_object('roles',coalesce(to_jsonb(target_roles),'[]'::jsonb));
end
$$;

create or replace function public.save_client_address(
  target_client_id uuid,target_address jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid(); client_row public.clients%rowtype; address_row public.client_addresses%rowtype;
  address_id uuid:=nullif(target_address->>'id','')::uuid;
  primary_requested boolean:=coalesce((target_address->>'is_primary')::boolean,false);
  billing_requested boolean:=coalesce((target_address->>'is_default_billing')::boolean,false);
  shipping_requested boolean:=coalesce((target_address->>'is_default_shipping')::boolean,false);
  service_requested boolean:=coalesce((target_address->>'is_default_service')::boolean,false);
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into client_row from public.clients where id=target_client_id for update;
  if client_row.id is null or not public.is_company_member(client_row.company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  if not public.has_company_permission(client_row.company_id,'manage_customer') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if nullif(trim(target_address->>'address_line_1'),'') is null then
    raise exception 'address_line_required' using errcode='22023';
  end if;
  if coalesce(target_address->>'address_type','main') not in(
    'registered','main','billing','shipping','service','secondary','other'
  ) then raise exception 'invalid_address_type' using errcode='22023'; end if;
  if primary_requested then update public.client_addresses set is_primary=false,updated_by=actor_id,updated_at=now()
    where client_id=client_row.id and is_primary and (address_id is null or id<>address_id); end if;
  if billing_requested then update public.client_addresses set is_default_billing=false,updated_by=actor_id,updated_at=now()
    where client_id=client_row.id and is_default_billing and (address_id is null or id<>address_id); end if;
  if shipping_requested then update public.client_addresses set is_default_shipping=false,updated_by=actor_id,updated_at=now()
    where client_id=client_row.id and is_default_shipping and (address_id is null or id<>address_id); end if;
  if service_requested then update public.client_addresses set is_default_service=false,updated_by=actor_id,updated_at=now()
    where client_id=client_row.id and is_default_service and (address_id is null or id<>address_id); end if;
  if address_id is null then
    insert into public.client_addresses(
      company_id,client_id,label,address_type,recipient_name,company_name,address_line_1,address_line_2,
      complement,postal_code,city,region,country_code,phone_e164,instructions,is_primary,
      is_default_billing,is_default_shipping,is_default_service,active,created_by,updated_by
    ) values(
      client_row.company_id,client_row.id,coalesce(nullif(trim(target_address->>'label'),''),'Adresse'),
      coalesce(nullif(target_address->>'address_type',''),'main'),nullif(target_address->>'recipient_name',''),
      nullif(target_address->>'company_name',''),trim(target_address->>'address_line_1'),
      nullif(target_address->>'address_line_2',''),nullif(target_address->>'complement',''),
      nullif(target_address->>'postal_code',''),nullif(target_address->>'city',''),nullif(target_address->>'region',''),
      coalesce(nullif(upper(target_address->>'country_code'),''),'FR'),nullif(target_address->>'phone_e164',''),
      nullif(target_address->>'instructions',''),primary_requested,billing_requested,shipping_requested,service_requested,
      coalesce((target_address->>'active')::boolean,true),actor_id,actor_id
    ) returning * into address_row;
  else
    update public.client_addresses set
      label=coalesce(nullif(trim(target_address->>'label'),''),'Adresse'),
      address_type=coalesce(nullif(target_address->>'address_type',''),'main'),
      recipient_name=nullif(target_address->>'recipient_name',''),company_name=nullif(target_address->>'company_name',''),
      address_line_1=trim(target_address->>'address_line_1'),address_line_2=nullif(target_address->>'address_line_2',''),
      complement=nullif(target_address->>'complement',''),postal_code=nullif(target_address->>'postal_code',''),
      city=nullif(target_address->>'city',''),region=nullif(target_address->>'region',''),
      country_code=coalesce(nullif(upper(target_address->>'country_code'),''),'FR'),
      phone_e164=nullif(target_address->>'phone_e164',''),instructions=nullif(target_address->>'instructions',''),
      is_primary=primary_requested,is_default_billing=billing_requested,is_default_shipping=shipping_requested,
      is_default_service=service_requested,active=coalesce((target_address->>'active')::boolean,true),
      updated_by=actor_id,updated_at=now()
    where id=address_id and company_id=client_row.company_id and client_id=client_row.id
    returning * into address_row;
    if address_row.id is null then raise exception 'address_not_found' using errcode='P0002'; end if;
  end if;
  insert into public.client_preferences(
    company_id,client_id,billing_address_id,shipping_address_id,service_address_id,created_by,updated_by
  ) values(
    client_row.company_id,client_row.id,
    case when billing_requested then address_row.id else null end,
    case when shipping_requested then address_row.id else null end,
    case when service_requested then address_row.id else null end,actor_id,actor_id
  ) on conflict(client_id) do update set
    billing_address_id=case when billing_requested then address_row.id else client_preferences.billing_address_id end,
    shipping_address_id=case when shipping_requested then address_row.id else client_preferences.shipping_address_id end,
    service_address_id=case when service_requested then address_row.id else client_preferences.service_address_id end,
    updated_by=actor_id,updated_at=now();
  return to_jsonb(address_row);
end
$$;

create or replace function public.save_client_preferences(
  target_client_id uuid,target_preferences jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid(); client_row public.clients%rowtype; result public.client_preferences%rowtype;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into client_row from public.clients where id=target_client_id;
  if client_row.id is null or not public.is_company_member(client_row.company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  if not public.has_company_permission(client_row.company_id,'manage_customer') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  insert into public.client_preferences(
    company_id,client_id,payment_method,payment_terms,payment_delay_days,language,currency,
    usual_discount_rate,assigned_user_id,quote_template_id,invoice_template_id,preferred_contact_method,
    default_contact_id,billing_contact_id,billing_address_id,shipping_address_id,service_address_id,
    footer_id,document_notes,internal_notes,created_by,updated_by
  ) values(
    client_row.company_id,client_row.id,nullif(target_preferences->>'payment_method',''),
    nullif(target_preferences->>'payment_terms',''),nullif(target_preferences->>'payment_delay_days','')::integer,
    coalesce(nullif(target_preferences->>'language',''),client_row.language,'fr'),
    coalesce(nullif(target_preferences->>'currency',''),'EUR'),
    coalesce(nullif(target_preferences->>'usual_discount_rate','')::numeric,client_row.discount_rate,0),
    nullif(target_preferences->>'assigned_user_id','')::uuid,nullif(target_preferences->>'quote_template_id','')::uuid,
    nullif(target_preferences->>'invoice_template_id','')::uuid,nullif(target_preferences->>'preferred_contact_method',''),
    nullif(target_preferences->>'default_contact_id','')::uuid,nullif(target_preferences->>'billing_contact_id','')::uuid,
    nullif(target_preferences->>'billing_address_id','')::uuid,nullif(target_preferences->>'shipping_address_id','')::uuid,
    nullif(target_preferences->>'service_address_id','')::uuid,nullif(target_preferences->>'footer_id','')::uuid,
    nullif(target_preferences->>'document_notes',''),nullif(target_preferences->>'internal_notes',''),actor_id,actor_id
  ) on conflict(client_id) do update set
    payment_method=excluded.payment_method,payment_terms=excluded.payment_terms,
    payment_delay_days=excluded.payment_delay_days,language=excluded.language,currency=excluded.currency,
    usual_discount_rate=excluded.usual_discount_rate,assigned_user_id=excluded.assigned_user_id,
    quote_template_id=excluded.quote_template_id,invoice_template_id=excluded.invoice_template_id,
    preferred_contact_method=excluded.preferred_contact_method,
    default_contact_id=case when target_preferences ? 'default_contact_id' then excluded.default_contact_id else client_preferences.default_contact_id end,
    billing_contact_id=case when target_preferences ? 'billing_contact_id' then excluded.billing_contact_id else client_preferences.billing_contact_id end,
    billing_address_id=case when target_preferences ? 'billing_address_id' then excluded.billing_address_id else client_preferences.billing_address_id end,
    shipping_address_id=case when target_preferences ? 'shipping_address_id' then excluded.shipping_address_id else client_preferences.shipping_address_id end,
    service_address_id=case when target_preferences ? 'service_address_id' then excluded.service_address_id else client_preferences.service_address_id end,
    footer_id=case when target_preferences ? 'footer_id' then excluded.footer_id else client_preferences.footer_id end,
    document_notes=excluded.document_notes,internal_notes=excluded.internal_notes,
    updated_by=actor_id,updated_at=now()
  returning * into result;
  return to_jsonb(result);
end
$$;

create or replace function public.save_document_client_context(
  target_document_id uuid,target_contact_id uuid default null,
  target_billing_address_id uuid default null,target_delivery_address_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid(); doc public.documents%rowtype; refreshed_snapshot uuid;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then
    raise exception 'document_not_found' using errcode='P0002';
  end if;
  if not public.has_company_permission(doc.company_id,'sales_document_write') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if doc.finalized_at is not null or doc.locked_at is not null then
    raise exception 'document_is_locked' using errcode='55000';
  end if;
  if doc.document_type='quote' and exists(
    select 1 from public.documents linked
    where linked.source_document_id=doc.id and linked.document_type in(
      'invoice','deposit_invoice','balance_invoice','credit_note'
    )
  ) then raise exception 'quote_locked_by_invoice' using errcode='55000'; end if;
  update public.documents set
    contact_id=target_contact_id,billing_address_id=target_billing_address_id,
    delivery_address_id=target_delivery_address_id,updated_at=now()
  where id=doc.id returning * into doc;
  if doc.document_type='quote' and doc.id is not null then
    perform public._piloz_refresh_quote_snapshot(doc.id);
    select * into doc from public.documents where id=doc.id;
  end if;
  return to_jsonb(doc);
end
$$;

create or replace function public.preview_next_client_auxiliary_account(target_company_id uuid,target_client_id uuid default null)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare settings public.company_customer_account_settings%rowtype; client_row public.clients%rowtype;
  initial_value text:='C'; result text;
begin
  if auth.uid() is null or not public.is_company_member(target_company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select * into settings from public.company_customer_account_settings where company_id=target_company_id;
  if settings.id is null then return 'CLI000001'; end if;
  if target_client_id is not null then
    select * into client_row from public.clients where id=target_client_id and company_id=target_company_id;
    initial_value:=upper(left(coalesce(nullif(client_row.legal_name,''),nullif(client_row.last_name,''),'C'),1));
  end if;
  result:=case settings.account_format
    when 'c_number' then 'C'||lpad(settings.next_number::text,settings.padding,'0')
    when 'initial_number' then initial_value||lpad(settings.next_number::text,settings.padding,'0')
    when 'siren' then coalesce(nullif(client_row.siren,''),settings.prefix||lpad(settings.next_number::text,settings.padding,'0'))
    when 'custom' then replace(replace(coalesce(nullif(settings.custom_pattern,''),'{PREFIX}{NUMBER}'),
      '{PREFIX}',settings.prefix),'{NUMBER}',lpad(settings.next_number::text,settings.padding,'0'))
    else settings.prefix||lpad(settings.next_number::text,settings.padding,'0')
  end;
  return result;
end
$$;

create or replace function public.assign_client_auxiliary_account(
  target_client_id uuid,target_assignment_mode text default 'automatic',target_auxiliary_account text default null,
  target_collective_account text default null,target_effective_from date default current_date,
  target_reason text default null,target_confirm_existing_documents boolean default false
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid(); client_row public.clients%rowtype; settings public.company_customer_account_settings%rowtype;
  profile public.client_accounting_profiles%rowtype; previous_value text; proposed text; attempts integer:=0; has_documents boolean;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  if target_assignment_mode not in('automatic','manual') then raise exception 'invalid_assignment_mode' using errcode='22023'; end if;
  select * into client_row from public.clients where id=target_client_id for update;
  if client_row.id is null or not public.is_company_member(client_row.company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  if not public.has_company_role(client_row.company_id,array['owner','admin','accounting'])
     and not public.has_company_permission(client_row.company_id,'manage_customer') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  insert into public.company_customer_account_settings(company_id,created_by,updated_by)
  values(client_row.company_id,actor_id,actor_id) on conflict(company_id) do nothing;
  select * into settings from public.company_customer_account_settings
  where company_id=client_row.company_id for update;
  select * into profile from public.client_accounting_profiles where client_id=client_row.id for update;
  previous_value:=profile.auxiliary_account;
  if target_assignment_mode='manual' then
    if not settings.allow_manual then raise exception 'manual_account_disabled' using errcode='42501'; end if;
    proposed:=upper(trim(coalesce(target_auxiliary_account,'')));
    if proposed='' or proposed!~'^[A-Z0-9._-]+$' then raise exception 'invalid_auxiliary_account' using errcode='22023'; end if;
  else
    loop
      proposed:=case settings.account_format
        when 'c_number' then 'C'||lpad(settings.next_number::text,settings.padding,'0')
        when 'initial_number' then upper(left(coalesce(nullif(client_row.legal_name,''),nullif(client_row.last_name,''),'C'),1))||lpad(settings.next_number::text,settings.padding,'0')
        when 'siren' then coalesce(nullif(regexp_replace(client_row.siren,'[^0-9]','','g'),''),settings.prefix||lpad(settings.next_number::text,settings.padding,'0'))
        when 'custom' then replace(replace(coalesce(nullif(settings.custom_pattern,''),'{PREFIX}{NUMBER}'),
          '{PREFIX}',settings.prefix),'{NUMBER}',lpad(settings.next_number::text,settings.padding,'0'))
        else settings.prefix||lpad(settings.next_number::text,settings.padding,'0')
      end;
      exit when not exists(
        select 1 from public.client_accounting_profiles existing
        where existing.company_id=client_row.company_id and existing.auxiliary_account=proposed
          and existing.active and existing.client_id<>client_row.id
      );
      settings.next_number:=settings.next_number+1; attempts:=attempts+1;
      if attempts>1000 then raise exception 'auxiliary_account_generation_exhausted'; end if;
    end loop;
  end if;
  if settings.enforce_uniqueness and exists(
    select 1 from public.client_accounting_profiles existing
    where existing.company_id=client_row.company_id and existing.auxiliary_account=proposed
      and existing.active and existing.client_id<>client_row.id
  ) then raise exception 'auxiliary_account_already_used' using errcode='23505'; end if;
  select exists(select 1 from public.documents where client_id=client_row.id) into has_documents;
  if has_documents and previous_value is not null and previous_value is distinct from proposed
     and not target_confirm_existing_documents then
    raise exception 'auxiliary_account_change_requires_confirmation' using errcode='55000';
  end if;
  insert into public.client_accounting_profiles(
    company_id,client_id,collective_account,auxiliary_account,assignment_mode,accounting_label,
    effective_from,active,internal_comment,created_by,updated_by
  ) values(
    client_row.company_id,client_row.id,
    coalesce(nullif(target_collective_account,''),
      case when client_row.kind='person' then settings.individual_collective_account else settings.professional_collective_account end,
      settings.default_collective_account),proposed,target_assignment_mode,
    coalesce(nullif(client_row.accounting_label,''),nullif(client_row.legal_name,''),trim(concat_ws(' ',client_row.first_name,client_row.last_name))),
    coalesce(target_effective_from,current_date),true,nullif(target_reason,''),actor_id,actor_id
  ) on conflict(client_id) do update set
    collective_account=excluded.collective_account,auxiliary_account=excluded.auxiliary_account,
    assignment_mode=excluded.assignment_mode,accounting_label=excluded.accounting_label,
    effective_from=excluded.effective_from,active=true,internal_comment=excluded.internal_comment,
    updated_by=actor_id,updated_at=now()
  returning * into profile;
  if previous_value is distinct from proposed then
    insert into public.client_account_history(
      company_id,client_id,previous_auxiliary_account,new_auxiliary_account,collective_account,
      assignment_mode,effective_from,reason,changed_by,created_by
    ) values(
      client_row.company_id,client_row.id,previous_value,proposed,profile.collective_account,
      target_assignment_mode,profile.effective_from,nullif(target_reason,''),actor_id,actor_id
    );
  end if;
  if target_assignment_mode='automatic' and settings.account_format<>'siren' then
    update public.company_customer_account_settings set
      next_number=greatest(next_number,settings.next_number+1),updated_by=actor_id,updated_at=now()
    where id=settings.id;
  end if;
  return to_jsonb(profile);
end
$$;

create or replace function public.save_company_customer_account_settings(target_settings jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid(); company_id_value uuid:=nullif(target_settings->>'company_id','')::uuid;
  result public.company_customer_account_settings%rowtype;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  if company_id_value is null or not public.has_company_role(company_id_value,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  insert into public.company_customer_account_settings(
    company_id,default_collective_account,professional_collective_account,individual_collective_account,
    automatic_generation,prefix,padding,next_number,account_format,custom_pattern,allow_manual,
    enforce_uniqueness,manage_inactive,created_by,updated_by
  ) values(
    company_id_value,coalesce(nullif(target_settings->>'default_collective_account',''),'411000'),
    nullif(target_settings->>'professional_collective_account',''),nullif(target_settings->>'individual_collective_account',''),
    coalesce((target_settings->>'automatic_generation')::boolean,true),
    coalesce(nullif(upper(target_settings->>'prefix'),''),'CLI'),
    coalesce(nullif(target_settings->>'padding','')::smallint,6),
    coalesce(nullif(target_settings->>'next_number','')::bigint,1),
    coalesce(nullif(target_settings->>'account_format',''),'prefix_number'),nullif(target_settings->>'custom_pattern',''),
    coalesce((target_settings->>'allow_manual')::boolean,true),
    coalesce((target_settings->>'enforce_uniqueness')::boolean,true),
    coalesce((target_settings->>'manage_inactive')::boolean,true),actor_id,actor_id
  ) on conflict(company_id) do update set
    default_collective_account=excluded.default_collective_account,
    professional_collective_account=excluded.professional_collective_account,
    individual_collective_account=excluded.individual_collective_account,
    automatic_generation=excluded.automatic_generation,prefix=excluded.prefix,padding=excluded.padding,
    next_number=excluded.next_number,account_format=excluded.account_format,custom_pattern=excluded.custom_pattern,
    allow_manual=excluded.allow_manual,enforce_uniqueness=excluded.enforce_uniqueness,
    manage_inactive=excluded.manage_inactive,updated_by=actor_id,updated_at=now()
  returning * into result;
  return to_jsonb(result);
end
$$;

create or replace function public.get_client_directory(
  target_company_id uuid,target_search text default null,target_status text default null,
  target_kind text default null,target_assigned_user_id uuid default null,
  target_limit integer default 50,target_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_company_member(target_company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  with paid as(
    select d.client_id,coalesce(sum(p.amount) filter(where p.status='confirmed'),0) amount
    from public.payments p join public.documents d on d.id=p.document_id and d.company_id=p.company_id
    where p.company_id=target_company_id group by d.client_id
  ), doc_totals as(
    select d.client_id,
      coalesce(sum(case when d.document_type in('invoice','deposit_invoice','balance_invoice')
        and d.finalized_at is not null then d.total_incl_tax
        when d.document_type='credit_note' and d.finalized_at is not null then -d.total_incl_tax else 0 end),0) invoiced,
      max(coalesce(d.finalized_at,d.updated_at)) last_document_at,
      count(*) filter(where d.document_type in('invoice','deposit_invoice','balance_invoice')
        and d.finalized_at is not null and d.due_date<current_date and d.status<>'paid') overdue_count
    from public.documents d where d.company_id=target_company_id group by d.client_id
  ), filtered as(
    select c.*,coalesce(account.auxiliary_account,'') auxiliary_account,
      coalesce(dt.invoiced,0) total_invoiced,coalesce(paid.amount,0) total_paid,
      greatest(0,coalesce(dt.invoiced,0)-coalesce(paid.amount,0)) outstanding,
      dt.last_document_at,coalesce(dt.overdue_count,0) overdue_count,
      contact.first_name contact_first_name,contact.last_name contact_last_name,
      contact.email contact_email,contact.phone_e164 contact_phone,
      count(*) over() full_count
    from public.clients c
    left join public.client_accounting_profiles account on account.client_id=c.id and account.active
    left join doc_totals dt on dt.client_id=c.id left join paid on paid.client_id=c.id
    left join lateral(
      select cc.* from public.client_contacts cc where cc.client_id=c.id and cc.active
      order by cc.is_primary desc,cc.created_at limit 1
    ) contact on true
    where c.company_id=target_company_id
      and (target_status is null or target_status='' or c.customer_status=target_status)
      and (target_kind is null or target_kind='' or c.kind=target_kind)
      and (target_assigned_user_id is null or c.assigned_user_id=target_assigned_user_id)
      and (target_search is null or trim(target_search)='' or concat_ws(' ',c.legal_name,c.trade_name,c.first_name,c.last_name,
        c.email,c.phone_e164,c.siren,c.siret,c.city,account.auxiliary_account,contact.first_name,
        contact.last_name,contact.email,contact.phone_e164) ilike '%'||trim(target_search)||'%')
    order by coalesce(c.legal_name,trim(concat_ws(' ',c.first_name,c.last_name))),c.id
    limit least(greatest(coalesce(target_limit,50),1),200) offset greatest(coalesce(target_offset,0),0)
  )
  select jsonb_build_object(
    'items',coalesce(jsonb_agg(to_jsonb(filtered)-'full_count'),'[]'::jsonb),
    'total',coalesce(max(full_count),0)
  ) into result from filtered;
  return result;
end
$$;

create or replace function public.get_client_directory_v2(
  target_company_id uuid,target_search text default null,target_filters jsonb default '{}'::jsonb,
  target_sort text default 'name',target_direction text default 'asc',
  target_limit integer default 50,target_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb; direction_value text:=case when lower(target_direction)='desc' then 'desc' else 'asc' end;
begin
  if auth.uid() is null or not public.is_company_member(target_company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_sort not in('name','invoiced','paid','outstanding','last_document','last_activity') then target_sort:='name'; end if;
  with paid as(
    select d.client_id,coalesce(sum(p.amount) filter(where p.status='confirmed'),0) amount
    from public.payments p join public.documents d on d.id=p.document_id and d.company_id=p.company_id
    where p.company_id=target_company_id group by d.client_id
  ), doc_totals as(
    select d.client_id,
      coalesce(sum(case when d.document_type in('invoice','deposit_invoice','balance_invoice')
        and d.finalized_at is not null then d.total_incl_tax
        when d.document_type='credit_note' and d.finalized_at is not null then -d.total_incl_tax else 0 end),0) invoiced,
      max(coalesce(d.finalized_at,d.updated_at)) last_document_at,
      count(*) filter(where d.document_type in('invoice','deposit_invoice','balance_invoice')
        and d.finalized_at is not null and d.due_date<current_date and d.status not in('paid','cancelled')) overdue_count
    from public.documents d where d.company_id=target_company_id group by d.client_id
  ), activity_totals as(
    select source.client_id,max(source.occurred_at) last_activity_at from(
      select a.client_id,max(coalesce(a.updated_at,a.created_at)) occurred_at
      from public.activities a where a.company_id=target_company_id and a.client_id is not null group by a.client_id
      union all
      select e.client_id,max(e.occurred_at) from public.client_activity_events e
      where e.company_id=target_company_id group by e.client_id
    ) source group by source.client_id
  ), source as(
    select c.*,coalesce(account.auxiliary_account,'') auxiliary_account,
      coalesce(dt.invoiced,0) total_invoiced,coalesce(paid.amount,0) total_paid,
      greatest(0,coalesce(dt.invoiced,0)-coalesce(paid.amount,0)) outstanding,
      dt.last_document_at,activity_totals.last_activity_at,coalesce(dt.overdue_count,0) overdue_count,
      contact.first_name contact_first_name,contact.last_name contact_last_name,
      contact.email contact_email,contact.phone_e164 contact_phone
    from public.clients c
    left join public.client_accounting_profiles account on account.client_id=c.id and account.active
    left join doc_totals dt on dt.client_id=c.id left join paid on paid.client_id=c.id
    left join activity_totals on activity_totals.client_id=c.id
    left join lateral(
      select cc.* from public.client_contacts cc where cc.client_id=c.id and cc.active
      order by cc.is_primary desc,cc.created_at limit 1
    ) contact on true
    where c.company_id=target_company_id
      and (coalesce(target_filters->>'status','')='' or c.customer_status=target_filters->>'status')
      and (coalesce(target_filters->>'kind','')='' or c.kind=target_filters->>'kind')
      and (coalesce(target_filters->>'assigned_user_id','')='' or c.assigned_user_id=(target_filters->>'assigned_user_id')::uuid)
      and (coalesce(target_filters->>'tag','')='' or exists(
        select 1 from unnest(coalesce(c.tags,'{}'::text[])) tag where tag ilike '%'||(target_filters->>'tag')||'%'
      ))
      and (not coalesce((target_filters->>'overdue')::boolean,false) or coalesce(dt.overdue_count,0)>0)
      and (not coalesce((target_filters->>'debtor')::boolean,false) or greatest(0,coalesce(dt.invoiced,0)-coalesce(paid.amount,0))>0)
      and (coalesce(target_filters->>'inactive_days','')='' or activity_totals.last_activity_at is null
        or activity_totals.last_activity_at<now()-make_interval(days=>(target_filters->>'inactive_days')::integer))
      and (target_search is null or trim(target_search)='' or concat_ws(' ',c.legal_name,c.trade_name,c.first_name,c.last_name,
        c.email,c.phone_e164,c.siren,c.siret,c.city,account.auxiliary_account,contact.first_name,
        contact.last_name,contact.email,contact.phone_e164) ilike '%'||trim(target_search)||'%')
  ), ordered as(
    select source.*,count(*) over() full_count from source order by
      case when target_sort='name' and direction_value='asc' then coalesce(legal_name,trim(concat_ws(' ',first_name,last_name))) end asc nulls last,
      case when target_sort='name' and direction_value='desc' then coalesce(legal_name,trim(concat_ws(' ',first_name,last_name))) end desc nulls last,
      case when target_sort='invoiced' and direction_value='asc' then total_invoiced end asc nulls last,
      case when target_sort='invoiced' and direction_value='desc' then total_invoiced end desc nulls last,
      case when target_sort='paid' and direction_value='asc' then total_paid end asc nulls last,
      case when target_sort='paid' and direction_value='desc' then total_paid end desc nulls last,
      case when target_sort='outstanding' and direction_value='asc' then outstanding end asc nulls last,
      case when target_sort='outstanding' and direction_value='desc' then outstanding end desc nulls last,
      case when target_sort='last_document' and direction_value='asc' then last_document_at end asc nulls last,
      case when target_sort='last_document' and direction_value='desc' then last_document_at end desc nulls last,
      case when target_sort='last_activity' and direction_value='asc' then last_activity_at end asc nulls last,
      case when target_sort='last_activity' and direction_value='desc' then last_activity_at end desc nulls last,
      id
    limit least(greatest(coalesce(target_limit,50),1),200) offset greatest(coalesce(target_offset,0),0)
  )
  select jsonb_build_object(
    'items',coalesce(jsonb_agg(to_jsonb(ordered)-'full_count'),'[]'::jsonb),
    'total',coalesce(max(full_count),0)
  ) into result from ordered;
  return result;
end
$$;

create or replace function public.get_client_workspace_summary(target_client_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare client_row public.clients%rowtype; result jsonb;
begin
  if auth.uid() is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into client_row from public.clients where id=target_client_id;
  if client_row.id is null or not public.is_company_member(client_row.company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  select jsonb_build_object(
    'client',to_jsonb(client_row),
    'preferences',(select to_jsonb(p) from public.client_preferences p where p.client_id=client_row.id),
    'accounting',(select to_jsonb(a) from public.client_accounting_profiles a where a.client_id=client_row.id),
    'primary_contact',(select to_jsonb(c) from public.client_contacts c where c.client_id=client_row.id and c.active order by c.is_primary desc,c.created_at limit 1),
    'primary_address',(select to_jsonb(a) from public.client_addresses a where a.client_id=client_row.id and a.active order by a.is_primary desc,a.created_at limit 1),
    'tags',coalesce((select jsonb_agg(to_jsonb(t) order by t.name) from public.client_tag_assignments x join public.client_tags t on t.id=x.tag_id where x.client_id=client_row.id),'[]'::jsonb),
    'metrics',jsonb_build_object(
      'quoted',coalesce((select sum(total_incl_tax) from public.documents where client_id=client_row.id and document_type='quote'),0),
      'accepted',coalesce((select sum(total_incl_tax) from public.documents where client_id=client_row.id and document_type='quote' and status in('accepted','invoiced')),0),
      'invoiced',coalesce((select sum(case when document_type='credit_note' then -total_incl_tax else total_incl_tax end) from public.documents where client_id=client_row.id and document_type in('invoice','deposit_invoice','balance_invoice','credit_note') and finalized_at is not null),0),
      'paid',coalesce((select sum(p.amount) from public.payments p join public.documents d on d.id=p.document_id where d.client_id=client_row.id and p.status='confirmed'),0),
      'overdue',coalesce((select count(*) from public.documents where client_id=client_row.id and document_type in('invoice','deposit_invoice','balance_invoice') and finalized_at is not null and due_date<current_date and status<>'paid'),0),
      'open_activities',coalesce((select count(*) from public.activities where client_id=client_row.id and status not in('completed','cancelled')),0)
    ),
    'last_activity_at',(select max(value) from(
      select max(updated_at) value from public.activities where client_id=client_row.id
      union all select max(occurred_at) from public.client_activity_events where client_id=client_row.id
    ) dates)
  ) into result;
  return result;
end
$$;

create or replace function public.detect_client_duplicates(target_company_id uuid,target_client jsonb,target_exclude_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_company_member(target_company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'name',coalesce(c.legal_name,trim(concat_ws(' ',c.first_name,c.last_name))),
    'email',c.email,'phone',c.phone_e164,'siren',c.siren,'siret',c.siret,
    'matching_fields',array_remove(array[
      case when nullif(target_client->>'siren','') is not null and c.siren=target_client->>'siren' then 'siren' end,
      case when nullif(target_client->>'siret','') is not null and c.siret=target_client->>'siret' then 'siret' end,
      case when nullif(lower(target_client->>'email'),'') is not null and lower(c.email)=lower(target_client->>'email') then 'email' end,
      case when nullif(target_client->>'phone_e164','') is not null and c.phone_e164=target_client->>'phone_e164' then 'phone' end,
      case when nullif(lower(target_client->>'legal_name'),'') is not null and lower(c.legal_name)=lower(target_client->>'legal_name') then 'name' end
    ],null)
  ) order by c.updated_at desc),'[]'::jsonb) into result
  from public.clients c
  where c.company_id=target_company_id and (target_exclude_id is null or c.id<>target_exclude_id)
    and (
      (nullif(target_client->>'siren','') is not null and c.siren=target_client->>'siren') or
      (nullif(target_client->>'siret','') is not null and c.siret=target_client->>'siret') or
      (nullif(lower(target_client->>'email'),'') is not null and lower(c.email)=lower(target_client->>'email')) or
      (nullif(target_client->>'phone_e164','') is not null and c.phone_e164=target_client->>'phone_e164') or
      (nullif(lower(target_client->>'legal_name'),'') is not null and lower(c.legal_name)=lower(target_client->>'legal_name'))
    );
  return result;
end
$$;

-- Migration prudente des coordonnées historiques : uniquement lorsque la
-- structure normalisée équivalente n'existe pas déjà.
insert into public.client_contacts(
  company_id,client_id,first_name,last_name,email,phone_e164,is_primary,active,created_by,updated_by
)
select c.company_id,c.id,
  coalesce(nullif(c.first_name,''),case when c.contact_name is not null then split_part(c.contact_name,' ',1) else 'Contact' end),
  coalesce(nullif(c.last_name,''),case when c.contact_name is not null then nullif(trim(substr(c.contact_name,length(split_part(c.contact_name,' ',1))+1)),'') else null end,'principal'),
  c.email,c.phone_e164,true,true,c.created_by,c.created_by
from public.clients c
where not exists(select 1 from public.client_contacts cc where cc.client_id=c.id)
  and (c.contact_name is not null or c.first_name is not null or c.last_name is not null or c.email is not null or c.phone_e164 is not null);

insert into public.client_contact_roles(company_id,client_id,contact_id,role,created_by)
select c.company_id,c.client_id,c.id,'primary',coalesce(c.created_by,(select owner_user_id from public.companies where id=c.company_id))
from public.client_contacts c where c.is_primary
on conflict(contact_id,role) do nothing;

insert into public.client_addresses(
  company_id,client_id,label,address_type,company_name,address_line_1,address_line_2,
  postal_code,city,country_code,is_primary,is_default_billing,is_default_shipping,active,created_by,updated_by
)
select c.company_id,c.id,'Adresse principale','main',c.legal_name,c.address_line_1,c.address_line_2,
  c.postal_code,c.city,coalesce(c.country_code,'FR'),true,
  c.billing_address_line_1 is null,true,true,c.created_by,c.created_by
from public.clients c
where nullif(trim(c.address_line_1),'') is not null
  and not exists(select 1 from public.client_addresses a where a.client_id=c.id);

insert into public.client_addresses(
  company_id,client_id,label,address_type,company_name,address_line_1,address_line_2,
  postal_code,city,country_code,is_default_billing,active,created_by,updated_by
)
select c.company_id,c.id,'Adresse de facturation','billing',c.legal_name,c.billing_address_line_1,c.billing_address_line_2,
  c.billing_postal_code,c.billing_city,coalesce(c.billing_country_code,c.country_code,'FR'),true,true,c.created_by,c.created_by
from public.clients c
where nullif(trim(c.billing_address_line_1),'') is not null
  and not exists(select 1 from public.client_addresses a where a.client_id=c.id and a.is_default_billing);

insert into public.client_preferences(
  company_id,client_id,payment_method,payment_terms,language,currency,usual_discount_rate,
  default_contact_id,billing_address_id,shipping_address_id,created_by,updated_by
)
select c.company_id,c.id,c.preferred_payment_method,c.payment_terms,c.language,'EUR',c.discount_rate,
  (select cc.id from public.client_contacts cc where cc.client_id=c.id and cc.is_primary order by cc.created_at limit 1),
  (select a.id from public.client_addresses a where a.client_id=c.id and a.is_default_billing order by a.created_at limit 1),
  (select a.id from public.client_addresses a where a.client_id=c.id and (a.is_default_shipping or a.is_primary) order by a.is_default_shipping desc,a.created_at limit 1),
  c.created_by,c.created_by
from public.clients c
on conflict(client_id) do update set
  default_contact_id=coalesce(client_preferences.default_contact_id,excluded.default_contact_id),
  billing_address_id=coalesce(client_preferences.billing_address_id,excluded.billing_address_id),
  shipping_address_id=coalesce(client_preferences.shipping_address_id,excluded.shipping_address_id);

insert into public.company_customer_account_settings(company_id,created_by,updated_by)
select id,owner_user_id,owner_user_id from public.companies on conflict(company_id) do nothing;

create or replace function public.seed_company_customer_account_settings()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.company_customer_account_settings(company_id,created_by,updated_by)
  values(new.id,new.owner_user_id,new.owner_user_id) on conflict(company_id) do nothing;
  return new;
end
$$;
revoke all on function public.seed_company_customer_account_settings() from public,anon,authenticated;
drop trigger if exists companies_seed_customer_account_settings on public.companies;
create trigger companies_seed_customer_account_settings after insert on public.companies
for each row execute function public.seed_company_customer_account_settings();

-- RLS : lecture strictement limitée à l'entreprise. Les journaux et snapshots
-- sont append-only et ne peuvent pas être écrasés depuis le navigateur.
do $rls$
declare table_name text;
begin
  foreach table_name in array array[
    'client_contacts','client_contact_roles','client_addresses','client_preferences','client_accounting_profiles','client_notes',
    'client_documents','client_tags','client_tag_assignments','client_duplicate_candidates'
  ] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check(public.has_company_permission(company_id,''manage_customer'') and created_by=auth.uid())',table_name||'_insert',table_name);
    execute format('create policy %I on public.%I for update to authenticated using(public.has_company_permission(company_id,''manage_customer'')) with check(public.has_company_permission(company_id,''manage_customer''))',table_name||'_update',table_name);
    execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete',table_name);
  end loop;
end
$rls$;

drop policy if exists clients_insert on public.clients;
drop policy if exists clients_update on public.clients;
drop policy if exists clients_delete on public.clients;
create policy clients_insert on public.clients for insert to authenticated
with check(public.has_company_permission(company_id,'manage_customer') and created_by=auth.uid());
create policy clients_update on public.clients for update to authenticated
using(public.has_company_permission(company_id,'manage_customer'))
with check(public.has_company_permission(company_id,'manage_customer'));
create policy clients_delete on public.clients for delete to authenticated
using(public.has_company_role(company_id,array['owner','admin']));

drop policy if exists activities_insert on public.activities;
drop policy if exists activities_update on public.activities;
drop policy if exists activities_delete on public.activities;
create policy activities_insert on public.activities for insert to authenticated
with check(
  (public.has_company_permission(company_id,'manage_customer')
    or public.has_company_permission(company_id,'manage_opportunity'))
  and created_by=auth.uid()
);
create policy activities_update on public.activities for update to authenticated
using(public.has_company_permission(company_id,'manage_customer') or public.has_company_permission(company_id,'manage_opportunity'))
with check(public.has_company_permission(company_id,'manage_customer') or public.has_company_permission(company_id,'manage_opportunity'));
create policy activities_delete on public.activities for delete to authenticated
using(public.has_company_role(company_id,array['owner','admin']));

alter table public.company_customer_account_settings enable row level security;
drop policy if exists company_customer_account_settings_select on public.company_customer_account_settings;
drop policy if exists company_customer_account_settings_write on public.company_customer_account_settings;
create policy company_customer_account_settings_select on public.company_customer_account_settings
for select to authenticated using(public.is_company_member(company_id));
create policy company_customer_account_settings_write on public.company_customer_account_settings
for all to authenticated using(public.has_company_role(company_id,array['owner','admin']))
with check(public.has_company_role(company_id,array['owner','admin']));

-- Les commerciaux autorisés peuvent joindre des fichiers uniquement dans le
-- dossier client de leur entreprise. La lecture reste couverte par la policy
-- company_files_select existante et le bucket demeure privé.
drop policy if exists company_client_files_insert on storage.objects;
create policy company_client_files_insert on storage.objects
for insert to authenticated with check(
  bucket_id='company-files'
  and (storage.foldername(name))[2]='clients'
  and public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_customer')
);

do $immutable_rls$
declare table_name text;
begin
  foreach table_name in array array[
    'client_account_history','client_activity_events','document_contact_snapshots','document_address_snapshots'
  ] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    execute format('drop trigger if exists %I on public.%I',table_name||'_immutable',table_name);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.protect_immutable_fiscal_row()',table_name||'_immutable',table_name);
  end loop;
end
$immutable_rls$;

do $updated_at$
declare table_name text;
begin
  foreach table_name in array array[
    'client_contacts','client_addresses','client_preferences','company_customer_account_settings',
    'client_accounting_profiles','client_notes','client_documents','client_tags'
  ] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_set_updated_at',table_name);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
  end loop;
end
$updated_at$;

revoke all on public.client_contact_roles,public.client_addresses,public.company_customer_account_settings,
  public.client_accounting_profiles,public.client_account_history,public.client_notes,public.client_documents,
  public.client_tags,public.client_tag_assignments,public.client_activity_events,public.client_duplicate_candidates,
  public.document_contact_snapshots,public.document_address_snapshots from anon,authenticated;
grant select,insert,update,delete on public.client_contact_roles,public.client_addresses,
  public.client_accounting_profiles,public.client_notes,public.client_documents,public.client_tags,
  public.client_tag_assignments,public.client_duplicate_candidates to authenticated;
grant select on public.company_customer_account_settings,public.client_account_history,
  public.client_activity_events,public.document_contact_snapshots,public.document_address_snapshots to authenticated;
grant select on public.client_contacts,public.client_preferences to authenticated;
grant select,insert,update,delete on public.clients to authenticated;
grant select(contact_id,billing_address_id,delivery_address_id) on public.documents to authenticated;
grant select(contact_id),insert(contact_id),update(contact_id) on public.activities to authenticated;

revoke all on function public.save_client_contact(uuid,jsonb,text[]) from public,anon;
revoke all on function public.save_client_address(uuid,jsonb) from public,anon;
revoke all on function public.save_client_preferences(uuid,jsonb) from public,anon;
revoke all on function public.save_document_client_context(uuid,uuid,uuid,uuid) from public,anon;
revoke all on function public.preview_next_client_auxiliary_account(uuid,uuid) from public,anon;
revoke all on function public.assign_client_auxiliary_account(uuid,text,text,text,date,text,boolean) from public,anon;
revoke all on function public.save_company_customer_account_settings(jsonb) from public,anon;
revoke all on function public.get_client_directory(uuid,text,text,text,uuid,integer,integer) from public,anon;
revoke all on function public.get_client_directory_v2(uuid,text,jsonb,text,text,integer,integer) from public,anon;
revoke all on function public.get_client_workspace_summary(uuid) from public,anon;
revoke all on function public.detect_client_duplicates(uuid,jsonb,uuid) from public,anon;
grant execute on function public.save_client_contact(uuid,jsonb,text[]) to authenticated;
grant execute on function public.save_client_address(uuid,jsonb) to authenticated;
grant execute on function public.save_client_preferences(uuid,jsonb) to authenticated;
grant execute on function public.save_document_client_context(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.preview_next_client_auxiliary_account(uuid,uuid) to authenticated;
grant execute on function public.assign_client_auxiliary_account(uuid,text,text,text,date,text,boolean) to authenticated;
grant execute on function public.save_company_customer_account_settings(jsonb) to authenticated;
grant execute on function public.get_client_directory(uuid,text,text,text,uuid,integer,integer) to authenticated;
grant execute on function public.get_client_directory_v2(uuid,text,jsonb,text,text,integer,integer) to authenticated;
grant execute on function public.get_client_workspace_summary(uuid) to authenticated;
grant execute on function public.detect_client_duplicates(uuid,jsonb,uuid) to authenticated;

alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.5',
  alter column schema_version set default '202607230049';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.5',schema_version='202607230049',updated_at=now()
where application_version is distinct from '0.9.0-compliance.5'
   or schema_version is distinct from '202607230049';

commit;
