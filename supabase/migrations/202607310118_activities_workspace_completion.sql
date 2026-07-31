begin;

-- Activites CRM : extension additive du modele historique. Les colonnes
-- existantes restent disponibles pour les anciens ecrans et exports.

insert into public.permission_definitions(
  permission_key,canonical_key,module_key,category_key,category_label,label,
  description,allowed_scopes,sensitive,editor_visible,position
) values
('crm.activities.configure','crm.activities.configure','crm','crm','Suivi commercial','Configurer les activites','Gerer les types, valeurs par defaut et filtres partages.',array['company'],true,true,132),
('crm.activities.archive','crm.activities.archive','crm','crm','Suivi commercial','Archiver les activites','Archiver sans supprimer les activites du perimetre autorise.',array['own','team','company'],true,true,133),
('crm.activities.confidential.read','crm.activities.confidential.read','crm','crm','Suivi commercial','Consulter les activites confidentielles','Consulter les activites privees auxquelles le membre ne participe pas.',array['team','company'],true,true,134)
on conflict(permission_key) do update set
 canonical_key=excluded.canonical_key,module_key=excluded.module_key,
 category_key=excluded.category_key,category_label=excluded.category_label,
 label=excluded.label,description=excluded.description,
 allowed_scopes=excluded.allowed_scopes,sensitive=excluded.sensitive,
 editor_visible=excluded.editor_visible,position=excluded.position,active=true,
 updated_at=now();

insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,'company'
from public.company_roles role
cross join (values
 ('crm.activities.configure'),('crm.activities.archive'),('crm.activities.confidential.read')
) permission(permission_key)
where role.active and role.system_key='administrator'
on conflict(role_id,permission_key) do update set scope=excluded.scope,updated_at=now();

insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,permission.scope
from public.company_roles role
cross join (values('crm.activities.archive','own')) permission(permission_key,scope)
where role.active and role.system_key='commercial'
on conflict(role_id,permission_key) do nothing;

create table if not exists public.activity_types(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  slug text not null,
  label text not null,
  icon text not null default 'check-circle',
  color text not null default '#14b8a6',
  category text not null default 'action' check(category in('communication','meeting','action','note','other')),
  default_duration_minutes integer not null default 30 check(default_duration_minutes between 0 and 10080),
  requires_result boolean not null default false,
  is_system boolean not null default false,
  active boolean not null default true,
  position integer not null default 0,
  created_by uuid default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,slug),
  check(slug ~ '^[a-z][a-z0-9_]{1,48}$')
);

create table if not exists public.activity_outcomes(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_type_id uuid references public.activity_types(id) on delete cascade,
  code text not null,
  label text not null,
  color text not null default '#64748b',
  active boolean not null default true,
  position integer not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,activity_type_id,code)
);

alter table public.activities
  add column if not exists activity_type_id uuid references public.activity_types(id) on delete set null,
  add column if not exists starts_at timestamptz,
  add column if not exists ends_at timestamptz,
  add column if not exists all_day boolean not null default false,
  add column if not exists timezone text not null default 'Europe/Paris',
  add column if not exists confidentiality text not null default 'standard',
  add column if not exists channel text,
  add column if not exists actual_duration_minutes integer,
  add column if not exists completion_percent integer not null default 0,
  add column if not exists parent_activity_id uuid references public.activities(id) on delete set null,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text;

alter table public.activities drop constraint if exists activities_confidentiality_check;
alter table public.activities add constraint activities_confidentiality_check
  check(confidentiality in('standard','team','private')) not valid;
alter table public.activities drop constraint if exists activities_completion_percent_check;
alter table public.activities add constraint activities_completion_percent_check
  check(completion_percent between 0 and 100) not valid;
alter table public.activities drop constraint if exists activities_actual_duration_check;
alter table public.activities add constraint activities_actual_duration_check
  check(actual_duration_minutes is null or actual_duration_minutes between 0 and 10080) not valid;
alter table public.activities drop constraint if exists activities_status_check;
alter table public.activities add constraint activities_status_check
  check(status in('draft','scheduled','todo','in_progress','completed','cancelled','missed','postponed')) not valid;
alter table public.activities drop constraint if exists activities_activity_type_check;

create table if not exists public.activity_reminders(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  channel text not null default 'in_app' check(channel in('in_app','email')),
  remind_at timestamptz not null,
  recipient_user_id uuid,
  status text not null default 'pending' check(status in('pending','processing','sent','failed','cancelled')),
  sent_at timestamptz,
  failure_code text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(activity_id,channel,remind_at,recipient_user_id)
);

create table if not exists public.activity_checklist_items(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  label text not null,
  completed_at timestamptz,
  completed_by uuid,
  position integer not null default 0,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.activity_attachments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  storage_bucket text not null default 'activity-attachments',
  storage_path text not null,
  original_name text not null,
  mime_type text not null,
  size_bytes bigint not null check(size_bytes between 1 and 15728640),
  sha256 text,
  archived_at timestamptz,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,storage_path)
);

create table if not exists public.activity_events(
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  event_type text not null,
  actor_user_id uuid,
  changed_fields text[] not null default '{}',
  before_data jsonb,
  after_data jsonb,
  metadata jsonb not null default '{}',
  occurred_at timestamptz not null default now()
);

create table if not exists public.activity_sync_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  provider text not null check(provider in('google_calendar','microsoft_calendar')),
  external_event_id text,
  external_url text,
  sync_status text not null default 'pending' check(sync_status in('pending','synced','conflict','error','disconnected')),
  last_synced_at timestamptz,
  last_error_code text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(activity_id,connection_id)
);

create table if not exists public.activity_saved_filters(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  name text not null,
  view_mode text not null default 'list',
  filters jsonb not null default '{}',
  is_default boolean not null default false,
  is_shared boolean not null default false,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,user_id,name)
);

alter table public.crm_activity_links drop constraint if exists crm_activity_links_entity_type_check;
alter table public.crm_activity_links add constraint crm_activity_links_entity_type_check check(entity_type in(
 'prospect','client','contact','opportunity','quote','invoice','credit_note','payment','supplier','purchase_invoice','due_date'
)) not valid;

create index if not exists activities_workspace_range_idx on public.activities(company_id,archived_at,status,starts_at,due_at,id);
create index if not exists activities_workspace_owner_idx on public.activities(company_id,assigned_user_id,team_id,status,due_at) where archived_at is null;
create index if not exists activities_workspace_search_idx on public.activities using gin(to_tsvector('simple',coalesce(subject,'')||' '||coalesce(description,'')||' '||coalesce(comment,'')));
create index if not exists activity_reminders_due_idx on public.activity_reminders(status,remind_at,company_id);
create index if not exists activity_events_activity_idx on public.activity_events(company_id,activity_id,occurred_at desc,id desc);
create index if not exists activity_checklist_activity_idx on public.activity_checklist_items(company_id,activity_id,position,id);
create index if not exists activity_attachments_activity_idx on public.activity_attachments(company_id,activity_id,created_at desc);
create index if not exists activity_sync_links_activity_idx on public.activity_sync_links(company_id,activity_id,provider);

create or replace function public.seed_company_activity_types(target_company_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 insert into public.activity_types(company_id,slug,label,icon,color,category,default_duration_minutes,requires_result,is_system,position,created_by,updated_by)
 select target_company_id,row_value.slug,row_value.label,row_value.icon,row_value.color,row_value.category,row_value.duration,row_value.requires_result,true,row_value.position,auth.uid(),auth.uid()
 from (values
  ('call','Appel','phone','#0ea5e9','communication',30,true,10),
  ('email','E-mail','mail','#6366f1','communication',20,false,20),
  ('meeting','Rendez-vous','calendar','#8b5cf6','meeting',60,true,30),
  ('video','Visioconference','video','#7c3aed','meeting',45,true,40),
  ('task','Tache','check-circle','#14b8a6','action',30,false,50),
  ('reminder','Relance','bell','#f59e0b','action',15,true,60),
  ('demo','Demonstration','monitor','#06b6d4','meeting',60,true,70),
  ('presentation','Presentation','presentation','#0891b2','meeting',45,true,75),
  ('visit','Visite','map-pin','#22c55e','meeting',60,true,80),
  ('note','Note','file-text','#64748b','note',0,false,90),
  ('event','Evenement','calendar-days','#ec4899','other',60,false,100),
  ('quote_followup','Relance de devis','file-clock','#f97316','action',20,true,110),
  ('proposal','Proposition commerciale','file-signature','#0f766e','action',30,true,120),
  ('invoice_followup','Relance de facture','receipt','#dc2626','action',20,true,130),
  ('payment_followup','Relance de paiement','circle-euro','#b91c1c','action',20,true,140),
  ('administrative','Administratif','briefcase','#475569','other',30,false,150),
  ('other','Autre','circle','#94a3b8','other',30,false,160)
 ) row_value(slug,label,icon,color,category,duration,requires_result,position)
 on conflict(company_id,slug) do update set
  label=case when activity_types.is_system then excluded.label else activity_types.label end,
  icon=case when activity_types.is_system then excluded.icon else activity_types.icon end,
  category=case when activity_types.is_system then excluded.category else activity_types.category end,
  is_system=activity_types.is_system or excluded.is_system,
  updated_at=now();
end
$$;

select public.seed_company_activity_types(company.id) from public.companies company;

update public.activities activity set
 activity_type_id=activity_type_row.id,
 starts_at=coalesce(activity.starts_at,activity.scheduled_at,activity.due_at),
 ends_at=coalesce(activity.ends_at,coalesce(activity.scheduled_at,activity.due_at)+make_interval(mins=>greatest(0,coalesce(activity.duration_minutes,30))))
from public.activity_types activity_type_row
where activity.activity_type_id is null and activity_type_row.company_id=activity.company_id and activity_type_row.slug=activity.activity_type;

create or replace function public.provision_company_activity_types()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.seed_company_activity_types(new.id); return new; end
$$;
drop trigger if exists companies_provision_activity_types on public.companies;
create trigger companies_provision_activity_types after insert on public.companies
for each row execute function public.provision_company_activity_types();

create or replace function public.validate_activity_workspace_row()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare resolved_type public.activity_types%rowtype;
begin
 if new.activity_type_id is not null then
  select * into resolved_type from public.activity_types activity_type
  where activity_type.id=new.activity_type_id and activity_type.company_id=new.company_id and activity_type.active;
 else
  select * into resolved_type from public.activity_types activity_type
  where activity_type.company_id=new.company_id and activity_type.slug=coalesce(nullif(new.activity_type,''),'task') and activity_type.active;
 end if;
 if resolved_type.id is null then raise exception 'activity_type_invalid'; end if;
 new.activity_type_id:=resolved_type.id;
 new.activity_type:=resolved_type.slug;
 new.starts_at:=coalesce(new.starts_at,new.scheduled_at,new.due_at);
 new.due_at:=coalesce(new.due_at,new.starts_at);
 new.scheduled_at:=coalesce(new.scheduled_at,new.starts_at);
 if new.ends_at is null and new.starts_at is not null then
  new.ends_at:=new.starts_at+make_interval(mins=>greatest(0,coalesce(new.duration_minutes,resolved_type.default_duration_minutes)));
 end if;
 if new.ends_at is not null and new.starts_at is not null and new.ends_at<new.starts_at then raise exception 'activity_end_before_start'; end if;
 if new.status='completed' then
  new.completed_at:=coalesce(new.completed_at,now()); new.completion_percent:=100;
 elsif new.status='cancelled' then
  new.cancelled_at:=coalesce(new.cancelled_at,now());
 end if;
 new.updated_at:=now();
 new.updated_by:=coalesce(auth.uid(),new.updated_by,new.created_by);
 return new;
end
$$;
drop trigger if exists activities_validate_workspace on public.activities;
create trigger activities_validate_workspace before insert or update on public.activities
for each row execute function public.validate_activity_workspace_row();

create or replace function public.activity_changed_fields(previous_row public.activities,current_row public.activities)
returns text[] language sql immutable set search_path=public,pg_temp as $$
 select coalesce(array_agg(field_name order by field_name),'{}'::text[])
 from (values
  ('subject',previous_row.subject is distinct from current_row.subject),
  ('description',previous_row.description is distinct from current_row.description),
  ('activity_type',previous_row.activity_type is distinct from current_row.activity_type),
  ('status',previous_row.status is distinct from current_row.status),
  ('priority',previous_row.priority is distinct from current_row.priority),
  ('starts_at',previous_row.starts_at is distinct from current_row.starts_at),
  ('ends_at',previous_row.ends_at is distinct from current_row.ends_at),
  ('assigned_user_id',previous_row.assigned_user_id is distinct from current_row.assigned_user_id),
  ('team_id',previous_row.team_id is distinct from current_row.team_id),
  ('client_id',previous_row.client_id is distinct from current_row.client_id),
  ('opportunity_id',previous_row.opportunity_id is distinct from current_row.opportunity_id),
  ('document_id',previous_row.document_id is distinct from current_row.document_id),
  ('confidentiality',previous_row.confidentiality is distinct from current_row.confidentiality),
  ('result',previous_row.result is distinct from current_row.result),
  ('archived_at',previous_row.archived_at is distinct from current_row.archived_at)
 ) changed(field_name,is_changed) where is_changed
$$;

create or replace function public.log_activity_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare fields text[];
begin
 if tg_op='INSERT' then
  insert into public.activity_events(company_id,activity_id,event_type,actor_user_id,changed_fields,after_data)
  values(new.company_id,new.id,'created',coalesce(auth.uid(),new.created_by),array['created'],to_jsonb(new));
 elsif tg_op='UPDATE' then
  fields:=public.activity_changed_fields(old,new);
  if cardinality(fields)>0 then
   insert into public.activity_events(company_id,activity_id,event_type,actor_user_id,changed_fields,before_data,after_data)
   values(new.company_id,new.id,case when 'status'=any(fields) then 'status_changed' when 'assigned_user_id'=any(fields) then 'assigned' else 'updated' end,
    coalesce(auth.uid(),new.updated_by),fields,to_jsonb(old),to_jsonb(new));
  end if;
 end if;
 return new;
end
$$;
drop trigger if exists activities_append_event on public.activities;
create trigger activities_append_event after insert or update on public.activities
for each row execute function public.log_activity_event();

create or replace function public.prevent_activity_physical_delete()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if auth.uid() is not null then raise exception 'activity_archive_required' using errcode='42501'; end if;
 return old;
end
$$;
drop trigger if exists activities_prevent_physical_delete on public.activities;
create trigger activities_prevent_physical_delete before delete on public.activities
for each row execute function public.prevent_activity_physical_delete();

commit;
