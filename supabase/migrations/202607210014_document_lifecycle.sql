-- Cycle documentaire Piloz : brouillon, finalisation, conversion, paiement et traçabilité.
-- Migration additive et idempotente. Aucune donnée métier existante n'est supprimée.
begin;

-- ---------------------------------------------------------------------------
-- 1. Colonnes de cycle et intégrité locataire
-- ---------------------------------------------------------------------------

alter table public.documents
  add column if not exists draft_number text,
  add column if not exists finalized_at timestamptz,
  add column if not exists finalized_by uuid,
  add column if not exists locked_at timestamptz,
  add column if not exists snapshot_id uuid,
  add column if not exists final_pdf_path text,
  add column if not exists final_pdf_sha256 text,
  add column if not exists final_pdf_generated_at timestamptz,
  add column if not exists pdf_status text not null default 'none',
  add column if not exists accepted_at timestamptz,
  add column if not exists rejected_at timestamptz,
  add column if not exists expired_at timestamptz,
  add column if not exists pipeline_stage text,
  add column if not exists root_document_id uuid,
  add column if not exists version_reason text;

alter table public.document_lines
  add column if not exists source_line_id uuid,
  add column if not exists cumulative_progress_percent numeric(5,2),
  add column if not exists line_metadata jsonb not null default '{}'::jsonb;

alter table public.payments add column if not exists comment text;

create unique index if not exists documents_company_id_id_uidx on public.documents(company_id,id);
create unique index if not exists documents_draft_number_uidx on public.documents(company_id,draft_number) where draft_number is not null;
create unique index if not exists document_lines_company_id_id_uidx on public.document_lines(company_id,id);
create unique index if not exists document_lines_document_id_id_uidx on public.document_lines(document_id,id);
create unique index if not exists clients_company_id_id_uidx on public.clients(company_id,id);
create unique index if not exists catalog_items_company_id_id_uidx on public.catalog_items(company_id,id);
create unique index if not exists document_templates_company_id_id_uidx on public.document_templates(company_id,id);
create unique index if not exists opportunities_company_id_id_uidx on public.opportunities(company_id,id);

do $constraints$
begin
  if not exists(select 1 from pg_constraint where conname='documents_client_company_fk') then
    alter table public.documents add constraint documents_client_company_fk
      foreign key(company_id,client_id) references public.clients(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_source_company_fk') then
    alter table public.documents add constraint documents_source_company_fk
      foreign key(company_id,source_document_id) references public.documents(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_root_company_fk') then
    alter table public.documents add constraint documents_root_company_fk
      foreign key(company_id,root_document_id) references public.documents(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_template_company_fk') then
    alter table public.documents add constraint documents_template_company_fk
      foreign key(company_id,template_id) references public.document_templates(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_opportunity_company_fk') then
    alter table public.documents add constraint documents_opportunity_company_fk
      foreign key(company_id,opportunity_id) references public.opportunities(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_lines_document_company_fk') then
    alter table public.document_lines add constraint document_lines_document_company_fk
      foreign key(company_id,document_id) references public.documents(company_id,id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_lines_item_company_fk') then
    alter table public.document_lines add constraint document_lines_item_company_fk
      foreign key(company_id,item_id) references public.catalog_items(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_lines_source_company_fk') then
    alter table public.document_lines add constraint document_lines_source_company_fk
      foreign key(company_id,source_line_id) references public.document_lines(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_lines_section_same_document_fk') then
    alter table public.document_lines add constraint document_lines_section_same_document_fk
      foreign key(document_id,section_id) references public.document_lines(document_id,id)
      deferrable initially deferred not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='payments_document_company_fk') then
    alter table public.payments add constraint payments_document_company_fk
      foreign key(company_id,document_id) references public.documents(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_pdf_status_check') then
    alter table public.documents add constraint documents_pdf_status_check
      check(pdf_status in('none','pending','ready','error')) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_lifecycle_status_check') then
    alter table public.documents add constraint documents_lifecycle_status_check check(status in(
      'draft','to_finalize','finalized','validated','to_send','sent','viewed','pending',
      'accepted','rejected','expired','invoiced','partially_invoiced','partially_paid',
      'paid','overdue','cancelled','archived','confirmed','partial','completed',
      'partially_delivered','delivered','signed','terminated','renewed','issued'
    )) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_lines_progress_range') then
    alter table public.document_lines add constraint document_lines_progress_range
      check(cumulative_progress_percent is null or cumulative_progress_percent between 0 and 100) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_lines_billable_quantity_nonnegative') then
    alter table public.document_lines add constraint document_lines_billable_quantity_nonnegative
      check(line_type not in('item','free_item','discount') or quantity>=0) not valid;
  end if;
end
$constraints$;

-- ---------------------------------------------------------------------------
-- 2. Structures normalisées : snapshots, PDF, liens, commentaires et réglages
-- ---------------------------------------------------------------------------

create table if not exists public.document_snapshots(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  snapshot_version integer not null check(snapshot_version>0),
  snapshot_kind text not null default 'finalization' check(snapshot_kind in('finalization','version','correction')),
  public_payload jsonb not null,
  internal_payload jsonb not null,
  payload_hash text not null,
  pdf_storage_path text,
  pdf_sha256 text,
  pdf_status text not null default 'pending' check(pdf_status in('pending','ready','error')),
  pdf_generated_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique(document_id,snapshot_version)
);
create unique index if not exists document_snapshots_company_id_id_uidx on public.document_snapshots(company_id,id);
create index if not exists document_snapshots_company_document_idx on public.document_snapshots(company_id,document_id,created_at desc);

create table if not exists public.document_pdf_jobs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  snapshot_id uuid not null,
  status text not null default 'pending' check(status in('pending','processing','completed','failed')),
  attempts integer not null default 0 check(attempts>=0),
  last_error_code text,
  available_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(snapshot_id)
);

create table if not exists public.document_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  source_document_id uuid not null,
  target_document_id uuid not null,
  link_type text not null check(link_type in('invoice','deposit','progress','balance','credit_note','proforma','version','related')),
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check(source_document_id<>target_document_id),
  unique(source_document_id,target_document_id,link_type)
);
create index if not exists document_links_company_source_idx on public.document_links(company_id,source_document_id);
create index if not exists document_links_company_target_idx on public.document_links(company_id,target_document_id);

create table if not exists public.document_comments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null,
  body text not null check(nullif(trim(body),'') is not null),
  mentioned_user_ids uuid[] not null default '{}'::uuid[],
  edited_at timestamptz,
  deleted_at timestamptz,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists document_comments_company_document_idx on public.document_comments(company_id,document_id,created_at);

create table if not exists public.payment_methods(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  label text not null,
  active boolean not null default true,
  is_default boolean not null default false,
  position integer not null default 0,
  details text,
  is_custom boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,code)
);
create unique index if not exists payment_methods_default_uidx on public.payment_methods(company_id) where is_default and active;

create table if not exists public.payment_terms(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  label text not null,
  days integer check(days is null or days between 0 and 365),
  calculation_rule text not null default 'days' check(calculation_rule in('days','receipt','end_of_month','days_end_of_month')),
  active boolean not null default true,
  is_default boolean not null default false,
  position integer not null default 0,
  details text,
  is_custom boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,code)
);
create unique index if not exists payment_terms_default_uidx on public.payment_terms(company_id) where is_default and active;

create table if not exists public.document_pipeline_stages(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  slug text not null,
  name text not null,
  position integer not null,
  color text not null default '#64748b',
  active boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,slug)
);

create table if not exists public.pipeline_items(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  quote_document_id uuid not null,
  stage_slug text not null default 'draft',
  next_activity_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,quote_document_id)
);
create index if not exists pipeline_items_company_stage_idx on public.pipeline_items(company_id,stage_slug,updated_at desc);

do $new_constraints$
begin
  if not exists(select 1 from pg_constraint where conname='document_snapshots_document_company_fk') then
    alter table public.document_snapshots add constraint document_snapshots_document_company_fk
      foreign key(company_id,document_id) references public.documents(company_id,id) on delete restrict not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='documents_snapshot_company_fk') then
    alter table public.documents add constraint documents_snapshot_company_fk
      foreign key(company_id,snapshot_id) references public.document_snapshots(company_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_pdf_jobs_document_company_fk') then
    alter table public.document_pdf_jobs add constraint document_pdf_jobs_document_company_fk
      foreign key(company_id,document_id) references public.documents(company_id,id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_pdf_jobs_snapshot_company_fk') then
    alter table public.document_pdf_jobs add constraint document_pdf_jobs_snapshot_company_fk
      foreign key(company_id,snapshot_id) references public.document_snapshots(company_id,id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_links_source_company_fk') then
    alter table public.document_links add constraint document_links_source_company_fk
      foreign key(company_id,source_document_id) references public.documents(company_id,id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_links_target_company_fk') then
    alter table public.document_links add constraint document_links_target_company_fk
      foreign key(company_id,target_document_id) references public.documents(company_id,id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='document_comments_document_company_fk') then
    alter table public.document_comments add constraint document_comments_document_company_fk
      foreign key(company_id,document_id) references public.documents(company_id,id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='pipeline_items_quote_company_fk') then
    alter table public.pipeline_items add constraint pipeline_items_quote_company_fk
      foreign key(company_id,quote_document_id) references public.documents(company_id,id) on delete cascade not valid;
  end if;
end
$new_constraints$;

-- ---------------------------------------------------------------------------
-- 3. RLS et privilèges explicites
-- ---------------------------------------------------------------------------

alter table public.document_snapshots enable row level security;
alter table public.document_pdf_jobs enable row level security;
alter table public.document_links enable row level security;
alter table public.document_comments enable row level security;
alter table public.payment_methods enable row level security;
alter table public.payment_terms enable row level security;
alter table public.document_pipeline_stages enable row level security;
alter table public.pipeline_items enable row level security;

drop policy if exists document_snapshots_select on public.document_snapshots;
create policy document_snapshots_select on public.document_snapshots for select to authenticated
  using(public.is_company_member(company_id));
drop policy if exists document_pdf_jobs_select on public.document_pdf_jobs;
create policy document_pdf_jobs_select on public.document_pdf_jobs for select to authenticated
  using(public.is_company_member(company_id));
drop policy if exists document_links_select on public.document_links;
create policy document_links_select on public.document_links for select to authenticated
  using(public.is_company_member(company_id));

drop policy if exists document_comments_select on public.document_comments;
drop policy if exists document_comments_insert on public.document_comments;
drop policy if exists document_comments_update on public.document_comments;
drop policy if exists document_comments_delete on public.document_comments;
create policy document_comments_select on public.document_comments for select to authenticated
  using(public.is_company_member(company_id));
create policy document_comments_insert on public.document_comments for insert to authenticated
  with check(public.is_company_member(company_id) and created_by=auth.uid());
create policy document_comments_update on public.document_comments for update to authenticated
  using(public.is_company_member(company_id) and (created_by=auth.uid() or public.has_company_role(company_id,array['owner','admin'])))
  with check(public.is_company_member(company_id) and (created_by=auth.uid() or public.has_company_role(company_id,array['owner','admin'])));
create policy document_comments_delete on public.document_comments for delete to authenticated
  using(public.is_company_member(company_id) and (created_by=auth.uid() or public.has_company_role(company_id,array['owner','admin'])));

do $settings_policies$
declare t text;
begin
  foreach t in array array['payment_methods','payment_terms','document_pipeline_stages'] loop
    execute format('drop policy if exists %I on public.%I',t||'_select',t);
    execute format('drop policy if exists %I on public.%I',t||'_insert',t);
    execute format('drop policy if exists %I on public.%I',t||'_update',t);
    execute format('drop policy if exists %I on public.%I',t||'_delete',t);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',t||'_select',t);
    execute format('create policy %I on public.%I for insert to authenticated with check(public.has_company_role(company_id,array[''owner'',''admin'']) and created_by=auth.uid())',t||'_insert',t);
    execute format('create policy %I on public.%I for update to authenticated using(public.has_company_role(company_id,array[''owner'',''admin''])) with check(public.has_company_role(company_id,array[''owner'',''admin'']))',t||'_update',t);
    execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',t||'_delete',t);
  end loop;
end
$settings_policies$;

drop policy if exists pipeline_items_select on public.pipeline_items;
create policy pipeline_items_select on public.pipeline_items for select to authenticated
  using(public.is_company_member(company_id));

revoke all on public.document_snapshots,public.document_pdf_jobs,public.document_links,
  public.document_comments,public.payment_methods,public.payment_terms,
  public.document_pipeline_stages,public.pipeline_items from anon,authenticated;
grant select(id,company_id,document_id,snapshot_version,snapshot_kind,public_payload,payload_hash,
  pdf_storage_path,pdf_sha256,pdf_status,pdf_generated_at,created_by,created_at)
  on public.document_snapshots to authenticated;
grant select on public.document_pdf_jobs,public.document_links,public.document_comments,
  public.payment_methods,public.payment_terms,public.document_pipeline_stages,public.pipeline_items to authenticated;
grant insert,update,delete on public.document_comments,public.payment_methods,public.payment_terms,
  public.document_pipeline_stages to authenticated;
grant select(draft_number,finalized_at,finalized_by,locked_at,snapshot_id,final_pdf_path,
  final_pdf_sha256,final_pdf_generated_at,pdf_status,accepted_at,rejected_at,expired_at,pipeline_stage,
  root_document_id,version_reason) on public.documents to authenticated;
grant select(source_line_id,cumulative_progress_percent,line_metadata) on public.document_lines to authenticated;
grant select(comment) on public.payments to authenticated;

drop trigger if exists document_pdf_jobs_set_updated_at on public.document_pdf_jobs;
create trigger document_pdf_jobs_set_updated_at before update on public.document_pdf_jobs
  for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists document_comments_set_updated_at on public.document_comments;
create trigger document_comments_set_updated_at before update on public.document_comments
  for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists payment_methods_set_updated_at on public.payment_methods;
create trigger payment_methods_set_updated_at before update on public.payment_methods
  for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists payment_terms_set_updated_at on public.payment_terms;
create trigger payment_terms_set_updated_at before update on public.payment_terms
  for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists document_pipeline_stages_set_updated_at on public.document_pipeline_stages;
create trigger document_pipeline_stages_set_updated_at before update on public.document_pipeline_stages
  for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists pipeline_items_set_updated_at on public.pipeline_items;
create trigger pipeline_items_set_updated_at before update on public.pipeline_items
  for each row execute function public.set_current_timestamp_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Valeurs par défaut, numéros de brouillon et séquences officielles
-- ---------------------------------------------------------------------------

insert into public.payment_methods(company_id,code,label,active,is_default,position,is_custom,created_by)
select c.id,v.code,v.label,true,v.code='bank_transfer',v.position,false,c.owner_user_id
from public.companies c cross join(values
  ('bank_transfer','Virement bancaire',10),('direct_debit','Prélèvement',20),
  ('card','Carte',30),('cheque','Chèque',40),('cash','Espèces',50),
  ('paypal','PayPal',60),('other','Autre',70)
)v(code,label,position)
on conflict(company_id,code) do nothing;

insert into public.payment_terms(company_id,code,label,days,calculation_rule,active,is_default,position,is_custom,created_by)
select c.id,v.code,v.label,v.days,v.rule,true,v.code='days_30',v.position,false,c.owner_user_id
from public.companies c cross join(values
  ('cash','Comptant',0,'days',10),('receipt','À réception',0,'receipt',20),
  ('days_7','7 jours',7,'days',30),('days_15','15 jours',15,'days',40),
  ('days_30','30 jours',30,'days',50),('days_45','45 jours',45,'days',60),
  ('days_60','60 jours',60,'days',70),('end_of_month','Fin de mois',0,'end_of_month',80),
  ('days_30_end_of_month','30 jours fin de mois',30,'days_end_of_month',90)
)v(code,label,days,rule,position)
on conflict(company_id,code) do nothing;

insert into public.document_pipeline_stages(company_id,slug,name,position,color,created_by)
select c.id,v.slug,v.name,v.position,v.color,c.owner_user_id
from public.companies c cross join(values
  ('draft','Brouillon',10,'#64748b'),('to_finalize','À finaliser',20,'#64748b'),
  ('finalized','Finalisé',30,'#2563eb'),('sent','Envoyé',40,'#0f766e'),
  ('pending','En attente',50,'#d97706'),('accepted','Accepté',60,'#16a34a'),
  ('rejected','Refusé',70,'#b91c1c'),('expired','Expiré',80,'#9f1239'),
  ('invoicing','Facturation',90,'#0891b2'),('partially_collected','Partiellement encaissé',100,'#f59e0b'),
  ('collected','Encaissé',110,'#15803d')
)v(slug,name,position,color)
on conflict(company_id,slug) do nothing;

create or replace function public.seed_company_document_lifecycle_defaults()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.payment_methods(company_id,code,label,active,is_default,position,is_custom,created_by) values
    (new.id,'bank_transfer','Virement bancaire',true,true,10,false,new.owner_user_id),
    (new.id,'direct_debit','Prélèvement',true,false,20,false,new.owner_user_id),
    (new.id,'card','Carte',true,false,30,false,new.owner_user_id),
    (new.id,'cheque','Chèque',true,false,40,false,new.owner_user_id),
    (new.id,'cash','Espèces',true,false,50,false,new.owner_user_id),
    (new.id,'paypal','PayPal',true,false,60,false,new.owner_user_id),
    (new.id,'other','Autre',true,false,70,false,new.owner_user_id)
  on conflict(company_id,code) do nothing;
  insert into public.payment_terms(company_id,code,label,days,calculation_rule,active,is_default,position,is_custom,created_by) values
    (new.id,'cash','Comptant',0,'days',true,false,10,false,new.owner_user_id),
    (new.id,'receipt','À réception',0,'receipt',true,false,20,false,new.owner_user_id),
    (new.id,'days_7','7 jours',7,'days',true,false,30,false,new.owner_user_id),
    (new.id,'days_15','15 jours',15,'days',true,false,40,false,new.owner_user_id),
    (new.id,'days_30','30 jours',30,'days',true,true,50,false,new.owner_user_id),
    (new.id,'days_45','45 jours',45,'days',true,false,60,false,new.owner_user_id),
    (new.id,'days_60','60 jours',60,'days',true,false,70,false,new.owner_user_id),
    (new.id,'end_of_month','Fin de mois',0,'end_of_month',true,false,80,false,new.owner_user_id),
    (new.id,'days_30_end_of_month','30 jours fin de mois',30,'days_end_of_month',true,false,90,false,new.owner_user_id)
  on conflict(company_id,code) do nothing;
  insert into public.document_pipeline_stages(company_id,slug,name,position,color,created_by)
  select new.id,v.slug,v.name,v.position,v.color,new.owner_user_id from(values
    ('draft','Brouillon',10,'#64748b'),('to_finalize','À finaliser',20,'#64748b'),
    ('finalized','Finalisé',30,'#2563eb'),('sent','Envoyé',40,'#0f766e'),
    ('pending','En attente',50,'#d97706'),('accepted','Accepté',60,'#16a34a'),
    ('rejected','Refusé',70,'#b91c1c'),('expired','Expiré',80,'#9f1239'),
    ('invoicing','Facturation',90,'#0891b2'),('partially_collected','Partiellement encaissé',100,'#f59e0b'),
    ('collected','Encaissé',110,'#15803d')
  )v(slug,name,position,color) on conflict(company_id,slug) do nothing;
  return new;
end
$$;
drop trigger if exists companies_seed_document_lifecycle_defaults on public.companies;
create trigger companies_seed_document_lifecycle_defaults after insert on public.companies
  for each row execute function public.seed_company_document_lifecycle_defaults();

create or replace function public._piloz_document_sequence_key(target_type text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select case
    when target_type='quote' then 'quote'
    when target_type in('invoice','deposit_invoice','balance_invoice') then 'invoice'
    when target_type='credit_note' then 'credit_note'
    else target_type
  end
$$;

create or replace function public._piloz_document_prefix(target_company_id uuid,target_type text,is_draft boolean default false)
returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare configured text; base text;
begin
  select case
    when target_type='quote' then quote_prefix
    when target_type in('invoice','deposit_invoice','balance_invoice') then invoice_prefix
    when target_type='credit_note' then credit_prefix
    when target_type='sales_order' then order_prefix
    when target_type='delivery_note' then delivery_prefix
    when target_type='purchase_order' then purchase_order_prefix
    else null end
  into configured from public.company_document_settings where company_id=target_company_id;
  base:=coalesce(nullif(upper(trim(configured)),''),case
    when target_type='quote' then 'DEV'
    when target_type in('invoice','deposit_invoice','balance_invoice') then 'FAC'
    when target_type='credit_note' then 'AV'
    when target_type='proforma_invoice' then 'PRO'
    when target_type='purchase_order' then 'BCF'
    when target_type='delivery_note' then 'BL'
    else upper(left(replace(target_type,'_',''),3)) end);
  return case when is_draft then 'BROUILLON-'||base else base end;
end
$$;

create or replace function public._piloz_take_document_number(
  target_company_id uuid,target_type text,target_year integer,is_draft boolean default false
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare sequence_key text; sequence_row public.document_sequences%rowtype; desired_prefix text;
begin
  if target_company_id is null or target_year not between 2000 and 2200 then raise exception 'invalid_document_sequence'; end if;
  sequence_key:=case when is_draft then 'draft:' else '' end||public._piloz_document_sequence_key(target_type);
  desired_prefix:=public._piloz_document_prefix(target_company_id,target_type,is_draft);
  insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
  values(target_company_id,sequence_key,desired_prefix,target_year,1,4,coalesce(auth.uid(),(select owner_user_id from public.companies where id=target_company_id)))
  on conflict(company_id,document_type,year) do nothing;
  select * into sequence_row from public.document_sequences
  where company_id=target_company_id and document_type=sequence_key and year=target_year for update;
  if sequence_row.id is null then raise exception 'document_sequence_unavailable'; end if;
  if sequence_row.next_value=1 and sequence_row.prefix is distinct from desired_prefix then
    update public.document_sequences set prefix=desired_prefix,updated_at=now() where id=sequence_row.id
    returning * into sequence_row;
  end if;
  update public.document_sequences set next_value=next_value+1,updated_at=now() where id=sequence_row.id;
  return sequence_row.prefix||'-'||target_year::text||'-'||lpad(sequence_row.next_value::text,sequence_row.padding,'0');
end
$$;

-- La fonction historique reste disponible pour les opérations non légales
-- (commandes, livraisons...) mais ne peut plus consommer une séquence de vente.
create or replace function public.next_document_number(
  target_company_id uuid,target_type text,target_year integer default extract(year from current_date)::integer
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if target_type in('quote','invoice','deposit_invoice','balance_invoice','credit_note') then
    raise exception 'official_number_requires_finalization' using errcode='42501';
  end if;
  return public._piloz_take_document_number(target_company_id,target_type,target_year,false);
end
$$;

create or replace function public.assign_document_draft_number()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status='draft' and new.draft_number is null and new.document_type in(
    'quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice'
  ) then
    new.draft_number:=public._piloz_take_document_number(
      new.company_id,new.document_type,extract(year from coalesce(new.issue_date,current_date))::integer,true
    );
  end if;
  return new;
end
$$;
drop trigger if exists documents_assign_draft_number on public.documents;
create trigger documents_assign_draft_number before insert or update of status,issue_date on public.documents
  for each row execute function public.assign_document_draft_number();

create or replace function public.ensure_document_draft_number(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.status<>'draft' then raise exception 'document_is_not_draft'; end if;
  if doc.draft_number is null then
    update public.documents set draft_number=public._piloz_take_document_number(
      doc.company_id,doc.document_type,extract(year from doc.issue_date)::integer,true
    ),updated_at=now() where id=doc.id returning * into doc;
  end if;
  return jsonb_build_object('id',doc.id,'draft_number',doc.draft_number,'number',doc.number,'status',doc.status,'updated_at',doc.updated_at);
end
$$;

do $draft_backfill$
declare doc record;
begin
  for doc in select id,company_id,document_type,issue_date from public.documents
    where status='draft' and draft_number is null and document_type in(
      'quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice'
    ) order by company_id,created_at,id
  loop
    update public.documents set draft_number=public._piloz_take_document_number(
      doc.company_id,doc.document_type,extract(year from coalesce(doc.issue_date,current_date))::integer,true
    ) where id=doc.id;
  end loop;
end
$draft_backfill$;

create or replace function public.compute_document_due_date(target_company_id uuid,target_term text,target_issue_date date)
returns date language plpgsql stable security definer set search_path=public,pg_temp as $$
declare term_row public.payment_terms%rowtype; month_end date;
begin
  select * into term_row from public.payment_terms
  where company_id=target_company_id and active and (code=target_term or lower(label)=lower(target_term))
  order by (code=target_term) desc limit 1;
  if term_row.id is null then return target_issue_date+30; end if;
  month_end:=(date_trunc('month',target_issue_date)+interval '1 month - 1 day')::date;
  return case term_row.calculation_rule
    when 'receipt' then target_issue_date
    when 'end_of_month' then month_end
    when 'days_end_of_month' then (date_trunc('month',target_issue_date+coalesce(term_row.days,0))+interval '1 month - 1 day')::date
    else target_issue_date+coalesce(term_row.days,0) end;
end
$$;

-- Sauvegarde transactionnelle : le document et toutes ses lignes réussissent
-- ensemble, ou l'ancien brouillon reste entièrement intact.
create or replace function public.save_document_draft(
  target_document_id uuid,target_document jsonb,target_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; target_company_id uuid; target_type text; line_data jsonb;
  saved_id uuid; line_position integer:=0;
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
    if doc.status<>'draft' or doc.validated_at is not null or doc.finalized_at is not null then raise exception 'document_is_locked'; end if;
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
  select * into doc from public.documents where id=saved_id;
  return jsonb_build_object('id',doc.id,'draft_number',doc.draft_number,'number',doc.number,
    'status',doc.status,'updated_at',doc.updated_at);
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Finalisation, instantané légal et PDF définitif
-- ---------------------------------------------------------------------------

create or replace function public._piloz_create_document_snapshot(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; issuer jsonb; document_settings jsonb; customer jsonb;
  public_lines jsonb; internal_lines jsonb; template_payload jsonb;
  public_snapshot jsonb; internal_snapshot jsonb; snapshot_hash text;
  next_version integer; result_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.finalized_at is null then raise exception 'document_not_finalized'; end if;
  select to_jsonb(s) into issuer from public.company_settings s where s.company_id=doc.company_id;
  select to_jsonb(s) into document_settings from public.company_document_settings s where s.company_id=doc.company_id;
  select to_jsonb(c) into customer from public.clients c where c.id=doc.client_id and c.company_id=doc.company_id;
  select coalesce(jsonb_agg(
    to_jsonb(l)-array['unit_cost_snapshot','line_metadata','created_by','created_at','updated_at']::text[] order by l.position
  ),'[]'::jsonb),coalesce(jsonb_agg(to_jsonb(l) order by l.position),'[]'::jsonb)
  into public_lines,internal_lines from public.document_lines l where l.document_id=doc.id;
  select jsonb_build_object(
    'template',to_jsonb(t),
    'version',to_jsonb(tv)
  ) into template_payload
  from public.document_templates t
  left join public.document_template_versions tv on tv.template_id=t.id and tv.version=t.current_version
  where t.id=doc.template_id and t.company_id=doc.company_id;

  public_snapshot:=jsonb_build_object(
    'schema_version',1,
    'captured_at',now(),
    'document',to_jsonb(doc)-array['total_cost','internal_notes','final_pdf_path','final_pdf_sha256']::text[],
    'lines',public_lines,
    'issuer',coalesce(issuer,'{}'::jsonb),
    'document_settings',coalesce(document_settings,'{}'::jsonb)-'mandate_reference',
    'client',coalesce(customer,'{}'::jsonb),
    'template',coalesce(template_payload,'{}'::jsonb)
  );
  internal_snapshot:=jsonb_build_object(
    'schema_version',1,'captured_at',now(),'document',to_jsonb(doc),'lines',internal_lines,
    'issuer',coalesce(issuer,'{}'::jsonb),'document_settings',coalesce(document_settings,'{}'::jsonb),
    'client',coalesce(customer,'{}'::jsonb),'template',coalesce(template_payload,'{}'::jsonb)
  );
  snapshot_hash:=encode(digest(convert_to(public_snapshot::text,'UTF8'),'sha256'),'hex');
  select coalesce(max(snapshot_version),0)+1 into next_version
  from public.document_snapshots where document_id=doc.id;
  insert into public.document_snapshots(
    company_id,document_id,snapshot_version,snapshot_kind,public_payload,internal_payload,
    payload_hash,pdf_status,created_by
  ) values(
    doc.company_id,doc.id,next_version,'finalization',public_snapshot,internal_snapshot,
    snapshot_hash,'pending',coalesce(auth.uid(),doc.created_by)
  ) returning id into result_id;
  return result_id;
end
$$;

create or replace function public.finalize_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; official_number text; result_snapshot_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type not in('quote','invoice','deposit_invoice','balance_invoice','credit_note') then
    raise exception 'document_type_cannot_be_finalized';
  end if;
  if doc.finalized_at is not null then
    return jsonb_build_object('id',doc.id,'draft_number',doc.draft_number,'number',doc.number,
      'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',doc.snapshot_id,'pdf_status',doc.pdf_status);
  end if;
  if doc.status not in('draft','to_finalize') or doc.validated_at is not null then raise exception 'invalid_document_state'; end if;
  if not public.is_company_onboarded(doc.company_id) then raise exception 'company_onboarding_required' using errcode='42501'; end if;
  if doc.client_id is null or not exists(select 1 from public.clients where id=doc.client_id and company_id=doc.company_id and active) then
    raise exception 'document_client_required';
  end if;
  if not exists(select 1 from public.document_lines where document_id=doc.id and line_type in('item','free_item','discount')
    and not optional and nullif(trim(coalesce(name,'')),'') is not null and quantity>0) then
    raise exception 'document_lines_required';
  end if;
  if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then raise exception 'document_total_must_be_positive'; end if;
  if doc.document_type='quote' and doc.validity_date is null then raise exception 'quote_validity_date_required'; end if;
  if doc.document_type in('invoice','deposit_invoice','balance_invoice','credit_note') and doc.due_date is null then
    update public.documents set due_date=public.compute_document_due_date(doc.company_id,doc.payment_terms,doc.issue_date)
    where id=doc.id returning * into doc;
  end if;
  official_number:=public._piloz_take_document_number(
    doc.company_id,doc.document_type,extract(year from doc.issue_date)::integer,false
  );
  update public.documents set
    number=official_number,status='finalized',validated_at=now(),finalized_at=now(),
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
  return jsonb_build_object('id',doc.id,'draft_number',doc.draft_number,'number',doc.number,
    'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',result_snapshot_id,'pdf_status',doc.pdf_status);
end
$$;

-- Compatibilité avec l'ancien éditeur sans exposer le coût interne dans la
-- valeur de retour de la RPC historique.
create or replace function public.validate_invoice(target_document_id uuid)
returns public.documents language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
  perform public.finalize_document(target_document_id);
  select * into doc from public.documents where id=target_document_id;
  doc.total_cost:=0;
  return doc;
end
$$;

create or replace function public.attach_document_final_pdf(
  target_document_id uuid,target_storage_path text,target_sha256 text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.snapshot_id is null or doc.finalized_at is null then raise exception 'document_not_finalized'; end if;
  if nullif(trim(target_storage_path),'') is null or split_part(target_storage_path,'/',1)<>doc.company_id::text then
    raise exception 'invalid_pdf_storage_path';
  end if;
  update public.document_snapshots set pdf_storage_path=target_storage_path,pdf_sha256=nullif(trim(target_sha256),''),
    pdf_status='ready',pdf_generated_at=now() where id=doc.snapshot_id and company_id=doc.company_id;
  update public.documents set final_pdf_path=target_storage_path,final_pdf_sha256=nullif(trim(target_sha256),''),
    final_pdf_generated_at=now(),pdf_status='ready',updated_at=now() where id=doc.id;
  update public.document_pdf_jobs set status='completed',completed_at=now(),updated_at=now()
  where snapshot_id=doc.snapshot_id;
  return doc.snapshot_id;
end
$$;

create or replace function public.transition_document_status(target_document_id uuid,target_status text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; allowed boolean:=false;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if target_status=doc.status then return jsonb_build_object('id',doc.id,'status',doc.status); end if;
  if doc.finalized_at is null then
    allowed:=doc.status='draft' and target_status in('to_finalize','cancelled','archived');
  elsif doc.document_type='quote' then
    allowed:=target_status in('finalized','sent','pending','accepted','rejected','expired','invoiced','partially_invoiced','archived');
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

create or replace function public.protect_final_document_lifecycle()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare privileged boolean:=current_user in('postgres','service_role','supabase_admin');
begin
  if privileged then return case when tg_op='DELETE' then old else new end; end if;
  if tg_op='DELETE' and (old.finalized_at is not null or old.validated_at is not null) then
    raise exception 'finalized_document_cannot_be_deleted' using errcode='55000';
  end if;
  if tg_op='UPDATE' and (
    new.finalized_at is distinct from old.finalized_at or new.validated_at is distinct from old.validated_at
    or new.number is distinct from old.number
    or (new.status is distinct from old.status and new.document_type in(
      'quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice'
    ))
  ) then raise exception 'document_lifecycle_rpc_required' using errcode='42501'; end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists documents_protect_final_lifecycle on public.documents;
create trigger documents_protect_final_lifecycle before update or delete on public.documents
  for each row execute function public.protect_final_document_lifecycle();

create or replace function public.protect_snapshot_immutability()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if current_user in('postgres','service_role','supabase_admin') then return case when tg_op='DELETE' then old else new end; end if;
  raise exception 'document_snapshot_is_immutable' using errcode='55000';
end
$$;
drop trigger if exists document_snapshots_immutable on public.document_snapshots;
create trigger document_snapshots_immutable before update or delete on public.document_snapshots
  for each row execute function public.protect_snapshot_immutability();

create or replace function public.save_document_comment(
  target_document_id uuid,comment_body text,mentioned_user_ids uuid[] default '{}'::uuid[]
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; mentioned uuid; result_id uuid;
begin
  if nullif(trim(comment_body),'') is null then raise exception 'comment_body_required'; end if;
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  foreach mentioned in array coalesce(mentioned_user_ids,'{}'::uuid[]) loop
    if not exists(select 1 from public.company_members where company_id=doc.company_id and user_id=mentioned) then
      raise exception 'mentioned_user_is_not_company_member';
    end if;
  end loop;
  insert into public.document_comments(company_id,document_id,body,mentioned_user_ids,created_by,updated_by)
  values(doc.company_id,doc.id,trim(comment_body),coalesce(mentioned_user_ids,'{}'::uuid[]),auth.uid(),auth.uid())
  returning id into result_id;
  return result_id;
end
$$;

create or replace function public.delete_document_comment(target_comment_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.document_comments%rowtype;
begin
  select * into target from public.document_comments where id=target_comment_id for update;
  if target.id is null or not public.is_company_member(target.company_id) then raise exception 'comment_not_found' using errcode='P0002'; end if;
  if target.created_by<>auth.uid() and not public.has_company_role(target.company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  update public.document_comments set deleted_at=now(),body='Commentaire supprimé',mentioned_user_ids='{}'::uuid[],
    updated_by=auth.uid(),updated_at=now() where id=target.id;
  return target.id;
end
$$;

create or replace function public.update_document_comment(
  target_comment_id uuid,comment_body text,mentioned_user_ids uuid[] default '{}'::uuid[]
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.document_comments%rowtype; mentioned uuid;
begin
  if nullif(trim(comment_body),'') is null then raise exception 'comment_body_required'; end if;
  select * into target from public.document_comments where id=target_comment_id for update;
  if target.id is null or target.deleted_at is not null or not public.is_company_member(target.company_id) then
    raise exception 'comment_not_found' using errcode='P0002';
  end if;
  if target.created_by<>auth.uid() and not public.has_company_role(target.company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  foreach mentioned in array coalesce(mentioned_user_ids,'{}'::uuid[]) loop
    if not exists(select 1 from public.company_members where company_id=target.company_id and user_id=mentioned) then
      raise exception 'mentioned_user_is_not_company_member';
    end if;
  end loop;
  update public.document_comments set body=trim(comment_body),mentioned_user_ids=coalesce($3,'{}'::uuid[]),
    edited_at=now(),updated_by=auth.uid(),updated_at=now() where id=target.id;
  return target.id;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Conversion atomique : facture, acompte, situation, solde et avoir
-- ---------------------------------------------------------------------------

create or replace function public._piloz_copy_document_lines(source_document uuid,target_document uuid)
returns void language sql security definer set search_path=public,pg_temp as $$
  with mapped as materialized(
    select source_line.*,gen_random_uuid() as target_line_id
    from public.document_lines source_line where source_line.document_id=source_document
  )
  insert into public.document_lines(
    id,company_id,document_id,position,line_type,section_id,item_id,reference,name,description,
    quantity,unit,unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,
    source_line_id,cumulative_progress_percent,line_metadata,created_by
  )
  select
    line.target_line_id,target.company_id,target.id,line.position,line.line_type,
    (select section.target_line_id from mapped section where section.id=line.section_id),
    line.item_id,line.reference,line.name,line.description,line.quantity,line.unit,line.unit_cost_snapshot,
    line.unit_price,line.discount_rate,line.tax_rate,line.optional,line.id,line.cumulative_progress_percent,
    line.line_metadata,auth.uid()
  from mapped line cross join public.documents target
  where target.id=target_document
  order by line.position
$$;

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
  if source.finalized_at is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_must_be_finalized'; end if;
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
    update public.documents set status='invoiced',pipeline_stage='invoicing',updated_at=now() where id=source.id;
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
  if source.finalized_at is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_must_be_finalized'; end if;
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
  update public.documents set status=case when status='invoiced' then status else 'partially_invoiced' end,
    pipeline_stage='invoicing',updated_at=now() where id=source.id;
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
  if source.finalized_at is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_must_be_finalized'; end if;
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
  update public.documents set status=case when status='invoiced' then status else 'partially_invoiced' end,
    pipeline_stage='invoicing',updated_at=now() where id=source.id;
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
  if source.finalized_at is null or source.status in('rejected','expired','cancelled','archived') then raise exception 'quote_must_be_finalized'; end if;
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
  update public.documents set status='invoiced',pipeline_stage='invoicing',updated_at=now() where id=source.id;
  return target_id;
end
$$;

create or replace function public.create_credit_note(
  target_invoice_id uuid,credit_reason text,line_adjustments jsonb default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; target_id uuid; existing_id uuid; adjustment jsonb;
  source_line public.document_lines%rowtype; position_value integer:=0; already_credited numeric; available_credit numeric;
begin
  if nullif(trim(credit_reason),'') is null then raise exception 'credit_reason_required'; end if;
  select * into source from public.documents where id=target_invoice_id for update;
  if source.id is null or source.document_type not in('invoice','deposit_invoice','balance_invoice')
    or not public.is_company_member(source.company_id) then raise exception 'invoice_not_found' using errcode='P0002'; end if;
  if source.finalized_at is null and source.validated_at is null then raise exception 'invoice_must_be_finalized'; end if;
  select link.target_document_id into existing_id from public.document_links link
  join public.documents target on target.id=link.target_document_id
  where link.source_document_id=source.id and link.link_type='credit_note' and target.status='draft'
  order by target.created_at desc limit 1;
  if existing_id is not null then return existing_id; end if;
  select coalesce(sum(target.total_incl_tax),0) into already_credited
  from public.document_links link join public.documents target on target.id=link.target_document_id
  where link.source_document_id=source.id and link.link_type='credit_note' and target.status not in('cancelled','archived');
  available_credit:=greatest(source.total_incl_tax-already_credited,0);
  if available_credit<=0.01 then raise exception 'invoice_already_fully_credited'; end if;
  insert into public.documents(
    company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
    payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
    opportunity_id,assigned_user_id,template_id,metadata,created_by
  ) values(
    source.company_id,'credit_note',source.client_id,'draft',current_date,current_date,
    'Avoir — '||coalesce(source.number,source.draft_number),source.client_reference,source.currency,source.language,
    source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,source.discount_rate,source.id,
    coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
    coalesce((select default_invoice_template_id from public.company_document_settings where company_id=source.company_id),source.template_id),
    source.metadata||jsonb_build_object('conversion','credit_note','source_invoice_id',source.id,'credit_reason',trim(credit_reason)),auth.uid()
  ) returning id into target_id;
  if line_adjustments is null then
    perform public._piloz_copy_document_lines(source.id,target_id);
  else
    if jsonb_typeof(line_adjustments)<>'array' or jsonb_array_length(line_adjustments)=0 then raise exception 'line_adjustments_required'; end if;
    for adjustment in select value from jsonb_array_elements(line_adjustments) loop
      select * into source_line from public.document_lines
      where id=nullif(adjustment->>'line_id','')::uuid and document_id=source.id;
      if source_line.id is null or source_line.line_type not in('item','free_item','discount') then raise exception 'invalid_credit_line'; end if;
      position_value:=position_value+1;
      insert into public.document_lines(
        company_id,document_id,position,line_type,item_id,reference,name,description,quantity,unit,
        unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,source_line_id,line_metadata,created_by
      ) values(
        source.company_id,target_id,position_value,source_line.line_type,source_line.item_id,source_line.reference,
        source_line.name,source_line.description,
        least(coalesce(nullif(adjustment->>'quantity','')::numeric,source_line.quantity),source_line.quantity),source_line.unit,
        source_line.unit_cost_snapshot,coalesce(nullif(adjustment->>'unit_price','')::numeric,source_line.unit_price),
        source_line.discount_rate,source_line.tax_rate,false,source_line.id,
        jsonb_build_object('credit_reason',trim(credit_reason)),auth.uid()
      );
    end loop;
  end if;
  if (select total_incl_tax from public.documents where id=target_id)>available_credit+0.01 then raise exception 'credit_exceeds_invoice_balance'; end if;
  insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
  values(source.company_id,source.id,target_id,'credit_note',jsonb_build_object('reason',trim(credit_reason)),auth.uid());
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(source.company_id,auth.uid(),'credit_note.created','document',target_id,
    jsonb_build_object('source_invoice_id',source.id,'reason',trim(credit_reason)),auth.uid());
  return target_id;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Paiements, réglages et pipeline documentaire
-- ---------------------------------------------------------------------------

create or replace function public.enforce_single_payment_default()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.is_default then
    new.active:=true;
    execute format('update public.%I set is_default=false,updated_at=now() where company_id=$1 and id<>$2 and is_default',tg_table_name)
      using new.company_id,new.id;
  end if;
  return new;
end
$$;
drop trigger if exists payment_methods_single_default on public.payment_methods;
create trigger payment_methods_single_default before insert or update of is_default on public.payment_methods
  for each row execute function public.enforce_single_payment_default();
drop trigger if exists payment_terms_single_default on public.payment_terms;
create trigger payment_terms_single_default before insert or update of is_default on public.payment_terms
  for each row execute function public.enforce_single_payment_default();

create or replace function public.protect_builtin_payment_setting()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if not old.is_custom then raise exception 'builtin_payment_setting_cannot_be_deleted' using errcode='55000'; end if;
  return old;
end
$$;
drop trigger if exists payment_methods_protect_builtin on public.payment_methods;
create trigger payment_methods_protect_builtin before delete on public.payment_methods
  for each row execute function public.protect_builtin_payment_setting();
drop trigger if exists payment_terms_protect_builtin on public.payment_terms;
create trigger payment_terms_protect_builtin before delete on public.payment_terms
  for each row execute function public.protect_builtin_payment_setting();

create or replace function public.record_document_payment_v2(
  target_document_id uuid,payment_amount numeric,payment_method text default null,
  payment_reference text default null,payment_date timestamptz default now(),payment_comment text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; payment_id uuid; paid numeric; new_status text;
  remaining_payment numeric; schedule_row public.payment_schedules%rowtype; allocation numeric;
begin
  if payment_amount is null or payment_amount<=0 then raise exception 'invalid_payment_amount'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.document_type not in('invoice','deposit_invoice','balance_invoice')
    or (doc.finalized_at is null and doc.validated_at is null)
    or doc.status in('draft','cancelled','archived') then raise exception 'invalid_invoice_state'; end if;
  if not public.is_company_member(doc.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if nullif(trim(payment_method),'') is not null and exists(select 1 from public.payment_methods where company_id=doc.company_id)
    and not exists(select 1 from public.payment_methods where company_id=doc.company_id and active
      and (code=payment_method or lower(label)=lower(payment_method))) then raise exception 'inactive_payment_method'; end if;
  select coalesce(sum(amount),0) into paid from public.payments where document_id=doc.id and status='confirmed';
  if paid+payment_amount>doc.total_incl_tax+0.01 then raise exception 'payment_exceeds_balance'; end if;
  insert into public.payments(company_id,document_id,amount,currency,paid_at,payment_method,reference,comment,status,created_by)
  values(doc.company_id,doc.id,round(payment_amount,2),doc.currency,coalesce(payment_date,now()),
    nullif(trim(payment_method),''),nullif(trim(payment_reference),''),nullif(trim(payment_comment),''),'confirmed',auth.uid())
  returning id into payment_id;
  paid:=paid+round(payment_amount,2);
  new_status:=case when paid>=doc.total_incl_tax-0.01 then 'paid' else 'partially_paid' end;
  update public.documents set status=new_status,updated_at=now() where id=doc.id;
  remaining_payment:=round(payment_amount,2);
  for schedule_row in select * from public.payment_schedules
    where document_id=doc.id and status in('pending','partial') order by due_date,id for update
  loop
    exit when remaining_payment<=0;
    allocation:=least(remaining_payment,greatest(0,schedule_row.amount-schedule_row.paid_amount));
    update public.payment_schedules set paid_amount=paid_amount+allocation,
      status=case when paid_amount+allocation>=amount then 'paid' else 'partial' end,updated_at=now()
    where id=schedule_row.id;
    remaining_payment:=remaining_payment-allocation;
  end loop;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'payment.recorded','payment',payment_id,
    jsonb_build_object('document_id',doc.id,'amount',round(payment_amount,2),'status',new_status),auth.uid());
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
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  target public.payments%rowtype; doc public.documents%rowtype; confirmed_total numeric;
  remaining numeric; schedule_row public.payment_schedules%rowtype; allocation numeric;
begin
  if nullif(trim(cancellation_reason),'') is null then raise exception 'cancellation_reason_required'; end if;
  select * into target from public.payments where id=target_payment_id for update;
  if target.id is null or target.status<>'confirmed' then raise exception 'invalid_payment_state'; end if;
  if not public.is_company_member(target.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select * into doc from public.documents where id=target.document_id and company_id=target.company_id for update;
  if doc.id is null then raise exception 'invoice_not_found'; end if;
  update public.payments set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),
    cancellation_reason=trim($2),updated_at=now() where id=target.id;
  select coalesce(sum(amount),0) into confirmed_total from public.payments where document_id=doc.id and status='confirmed';
  update public.payment_schedules set paid_amount=0,status='pending',updated_at=now()
  where document_id=doc.id and status<>'cancelled';
  remaining:=confirmed_total;
  for schedule_row in select * from public.payment_schedules
    where document_id=doc.id and status<>'cancelled' order by due_date,id for update
  loop
    allocation:=least(remaining,schedule_row.amount);
    update public.payment_schedules set paid_amount=allocation,
      status=case when allocation>=amount then 'paid' when allocation>0 then 'partial' else 'pending' end,
      updated_at=now() where id=schedule_row.id;
    remaining:=greatest(0,remaining-allocation);
  end loop;
  update public.documents set status=case when confirmed_total>=total_incl_tax-0.01 then 'paid'
    when confirmed_total>0 then 'partially_paid' else case when sent_at is not null then 'sent' else 'finalized' end end,
    updated_at=now() where id=doc.id;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(target.company_id,auth.uid(),'payment.cancelled','payment',target.id,to_jsonb(target),
    jsonb_build_object('reason',trim($2),'cancelled_by',auth.uid()),auth.uid());
  return target.id;
end
$$;

create or replace function public.protect_confirmed_payment()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if current_user in('postgres','service_role','supabase_admin') then return case when tg_op='DELETE' then old else new end; end if;
  if (tg_op='DELETE' and old.status='confirmed') or (tg_op='UPDATE' and old.status='confirmed') then
    raise exception 'payment_mutation_rpc_required' using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists payments_protect_confirmed on public.payments;
create trigger payments_protect_confirmed before update or delete on public.payments
  for each row execute function public.protect_confirmed_payment();

create or replace function public.sync_document_pipeline(target_quote_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  quote public.documents%rowtype; invoice_total numeric:=0; collected_total numeric:=0;
  target_stage text; next_activity timestamptz;
begin
  select * into quote from public.documents where id=target_quote_id and document_type='quote' for update;
  if quote.id is null then return; end if;
  select coalesce(sum(invoice.total_incl_tax),0),coalesce(sum(payment_totals.paid),0)
  into invoice_total,collected_total
  from public.documents invoice
  left join lateral(
    select sum(payment.amount) paid from public.payments payment
    where payment.document_id=invoice.id and payment.status='confirmed'
  )payment_totals on true
  where invoice.company_id=quote.company_id and invoice.source_document_id=quote.id
    and invoice.document_type in('invoice','deposit_invoice','balance_invoice')
    and invoice.status not in('cancelled','archived');
  target_stage:=case
    when quote.status='rejected' then 'rejected'
    when quote.status='expired' then 'expired'
    when invoice_total>0 and collected_total>=invoice_total-0.01 then 'collected'
    when invoice_total>0 and collected_total>0 then 'partially_collected'
    when invoice_total>0 then 'invoicing'
    when quote.status='accepted' then 'accepted'
    when quote.status in('sent','viewed') then 'sent'
    when quote.status='pending' then 'pending'
    when quote.finalized_at is not null or quote.status in('finalized','validated') then 'finalized'
    when quote.status='to_finalize' then 'to_finalize'
    else 'draft' end;
  select min(coalesce(a.due_at,a.scheduled_at)) into next_activity from public.activities a
  where a.company_id=quote.company_id and a.document_id=quote.id
    and coalesce(a.status,case when a.completed_at is null then 'todo' else 'completed' end) not in('completed','cancelled')
    and coalesce(a.due_at,a.scheduled_at)>=now();
  update public.documents set pipeline_stage=target_stage,
    metadata=jsonb_set(coalesce(metadata,'{}'::jsonb),'{pipeline_stage}',to_jsonb(target_stage),true),updated_at=now()
  where id=quote.id and (pipeline_stage is distinct from target_stage or metadata->>'pipeline_stage' is distinct from target_stage);
  insert into public.pipeline_items(company_id,quote_document_id,stage_slug,next_activity_at,metadata,created_by)
  values(quote.company_id,quote.id,target_stage,next_activity,
    jsonb_build_object('total_invoiced',invoice_total,'total_collected',collected_total),coalesce(auth.uid(),quote.created_by))
  on conflict(company_id,quote_document_id) do update set stage_slug=excluded.stage_slug,
    next_activity_at=excluded.next_activity_at,metadata=excluded.metadata,updated_at=now();
end
$$;

create or replace function public.sync_document_pipeline_from_document()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare quote_id uuid;
begin
  quote_id:=case when new.document_type='quote' then new.id
    when new.document_type in('invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice') then new.source_document_id
    else null end;
  if quote_id is not null then perform public.sync_document_pipeline(quote_id); end if;
  return new;
end
$$;
drop trigger if exists documents_sync_document_pipeline on public.documents;
create trigger documents_sync_document_pipeline after insert or update of status,finalized_at,sent_at on public.documents
  for each row execute function public.sync_document_pipeline_from_document();

create or replace function public.sync_document_pipeline_from_payment()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare invoice_id uuid; quote_id uuid;
begin
  invoice_id:=case when tg_op='DELETE' then old.document_id else new.document_id end;
  select source_document_id into quote_id from public.documents where id=invoice_id;
  if quote_id is not null then perform public.sync_document_pipeline(quote_id); end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists payments_sync_document_pipeline on public.payments;
create trigger payments_sync_document_pipeline after insert or update of status or delete on public.payments
  for each row execute function public.sync_document_pipeline_from_payment();

create or replace view public.document_pipeline_view with (security_invoker=true) as
select
  quote.company_id,quote.id quote_document_id,quote.draft_number,quote.number,quote.subject,
  quote.client_id,client.legal_name client_legal_name,client.first_name client_first_name,client.last_name client_last_name,
  quote.total_excl_tax,quote.total_incl_tax,quote.status,quote.pipeline_stage,
  quote.assigned_user_id,quote.validity_date,item.next_activity_at,
  coalesce(metrics.invoice_count,0) invoice_count,coalesce(metrics.total_invoiced,0) total_invoiced,
  coalesce(metrics.total_collected,0) total_collected,
  greatest(coalesce(metrics.total_invoiced,0)-coalesce(metrics.total_collected,0),0) remaining_to_collect,
  greatest(quote.total_incl_tax-coalesce(metrics.total_invoiced,0),0) remaining_to_invoice,
  coalesce(metrics.linked_documents,'[]'::jsonb) linked_documents
from public.documents quote
left join public.clients client on client.id=quote.client_id and client.company_id=quote.company_id
left join public.pipeline_items item on item.quote_document_id=quote.id and item.company_id=quote.company_id
left join lateral(
  select count(*) invoice_count,coalesce(sum(invoice.total_incl_tax),0) total_invoiced,
    coalesce(sum(payment_totals.paid),0) total_collected,
    jsonb_agg(jsonb_build_object('id',invoice.id,'type',invoice.document_type,'number',invoice.number,
      'draft_number',invoice.draft_number,'status',invoice.status,'total_incl_tax',invoice.total_incl_tax)
      order by invoice.created_at) linked_documents
  from public.documents invoice
  left join lateral(select sum(payment.amount) paid from public.payments payment
    where payment.document_id=invoice.id and payment.status='confirmed')payment_totals on true
  where invoice.company_id=quote.company_id and invoice.source_document_id=quote.id
    and invoice.document_type in('invoice','deposit_invoice','balance_invoice')
    and invoice.status not in('cancelled','archived')
)metrics on true
where quote.document_type='quote' and quote.archived_at is null;

grant select on public.document_pipeline_view to authenticated;

-- Les factures déjà validées restent identifiées comme finalisées. Aucun
-- numéro, ligne ou montant historique n'est modifié par ce rattrapage.
update public.documents set finalized_at=validated_at,locked_at=coalesce(locked_at,validated_at),
  pipeline_stage=coalesce(pipeline_stage,case when document_type='quote' then 'finalized' else pipeline_stage end)
where validated_at is not null and finalized_at is null;

do $pipeline_backfill$
declare quote_id uuid;
begin
  for quote_id in select id from public.documents where document_type='quote' loop
    perform public.sync_document_pipeline(quote_id);
  end loop;
end
$pipeline_backfill$;

-- Les écritures sensibles ne sont plus disponibles par REST direct.
drop policy if exists payments_insert on public.payments;
drop policy if exists payments_update on public.payments;
drop policy if exists payments_delete on public.payments;
drop policy if exists document_sequences_insert on public.document_sequences;
drop policy if exists document_sequences_update on public.document_sequences;
drop policy if exists document_sequences_delete on public.document_sequences;
drop policy if exists document_sequences_insert_admin on public.document_sequences;
drop policy if exists document_sequences_update_admin on public.document_sequences;
drop policy if exists document_sequences_delete_admin on public.document_sequences;
revoke insert,update,delete on public.payments,public.document_sequences from authenticated;
revoke execute on function public.reopen_invoice_for_correction(uuid,text) from authenticated;

-- Surface RPC explicite. Les helpers internes ne sont jamais exécutables par
-- un navigateur, même si une ancienne configuration de privilèges subsiste.
revoke all on function public._piloz_document_sequence_key(text) from public,anon,authenticated;
revoke all on function public._piloz_document_prefix(uuid,text,boolean) from public,anon,authenticated;
revoke all on function public._piloz_take_document_number(uuid,text,integer,boolean) from public,anon,authenticated;
revoke all on function public._piloz_create_document_snapshot(uuid) from public,anon,authenticated;
revoke all on function public._piloz_copy_document_lines(uuid,uuid) from public,anon,authenticated;
revoke all on function public.sync_document_pipeline(uuid) from public,anon,authenticated;
revoke all on function public.compute_document_due_date(uuid,text,date) from public,anon,authenticated;
revoke all on function public.seed_company_document_lifecycle_defaults() from public,anon,authenticated;
revoke all on function public.assign_document_draft_number() from public,anon,authenticated;
revoke all on function public.enforce_single_payment_default() from public,anon,authenticated;
revoke all on function public.protect_builtin_payment_setting() from public,anon,authenticated;
revoke all on function public.protect_final_document_lifecycle() from public,anon,authenticated;
revoke all on function public.protect_snapshot_immutability() from public,anon,authenticated;
revoke all on function public.protect_confirmed_payment() from public,anon,authenticated;
revoke all on function public.sync_document_pipeline_from_document() from public,anon,authenticated;
revoke all on function public.sync_document_pipeline_from_payment() from public,anon,authenticated;

revoke all on function public.ensure_document_draft_number(uuid) from public,anon;
revoke all on function public.next_document_number(uuid,text,integer) from public,anon;
revoke all on function public.save_document_draft(uuid,jsonb,jsonb) from public,anon;
revoke all on function public.finalize_document(uuid) from public,anon;
revoke all on function public.validate_invoice(uuid) from public,anon;
revoke all on function public.attach_document_final_pdf(uuid,text,text) from public,anon;
revoke all on function public.transition_document_status(uuid,text) from public,anon;
revoke all on function public.save_document_comment(uuid,text,uuid[]) from public,anon;
revoke all on function public.update_document_comment(uuid,text,uuid[]) from public,anon;
revoke all on function public.delete_document_comment(uuid) from public,anon;
revoke all on function public.convert_quote_to_invoice(uuid,text) from public,anon;
revoke all on function public.create_deposit_invoice(uuid,numeric,numeric) from public,anon;
revoke all on function public.create_progress_invoice(uuid,jsonb) from public,anon;
revoke all on function public.create_balance_invoice(uuid) from public,anon;
revoke all on function public.create_credit_note(uuid,text,jsonb) from public,anon;
revoke all on function public.record_document_payment_v2(uuid,numeric,text,text,timestamptz,text) from public,anon;
revoke all on function public.record_document_payment(uuid,numeric,text,text,timestamptz) from public,anon;
revoke all on function public.cancel_document_payment(uuid,text) from public,anon;

grant execute on function public.next_document_number(uuid,text,integer) to authenticated;
grant execute on function public.ensure_document_draft_number(uuid) to authenticated;
grant execute on function public.save_document_draft(uuid,jsonb,jsonb) to authenticated;
grant execute on function public.finalize_document(uuid) to authenticated;
grant execute on function public.validate_invoice(uuid) to authenticated;
grant execute on function public.attach_document_final_pdf(uuid,text,text) to authenticated;
grant execute on function public.transition_document_status(uuid,text) to authenticated;
grant execute on function public.save_document_comment(uuid,text,uuid[]) to authenticated;
grant execute on function public.update_document_comment(uuid,text,uuid[]) to authenticated;
grant execute on function public.delete_document_comment(uuid) to authenticated;
grant execute on function public.convert_quote_to_invoice(uuid,text) to authenticated;
grant execute on function public.create_deposit_invoice(uuid,numeric,numeric) to authenticated;
grant execute on function public.create_progress_invoice(uuid,jsonb) to authenticated;
grant execute on function public.create_balance_invoice(uuid) to authenticated;
grant execute on function public.create_credit_note(uuid,text,jsonb) to authenticated;
grant execute on function public.record_document_payment_v2(uuid,numeric,text,text,timestamptz,text) to authenticated;
grant execute on function public.record_document_payment(uuid,numeric,text,text,timestamptz) to authenticated;
grant execute on function public.cancel_document_payment(uuid,text) to authenticated;

commit;
