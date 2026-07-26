begin;

-- CRM Piloz Command Center. Migration additive et compatible avec les objets
-- commerciaux existants. Les prospects continuent d'utiliser public.clients afin
-- qu'une conversion ne duplique jamais le tiers.

create table if not exists public.crm_pipelines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  slug text not null,
  description text,
  pipeline_type text not null default 'sales',
  status text not null default 'active' check(status in('draft','active','inactive','archived')),
  owner_user_id uuid,
  color text not null default '#14b8a6',
  currency text not null default 'EUR',
  position integer not null default 0,
  is_default boolean not null default false,
  automation_settings jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,slug)
);
create unique index if not exists crm_pipelines_one_default_idx on public.crm_pipelines(company_id) where is_default and status<>'archived';
create index if not exists crm_pipelines_company_order_idx on public.crm_pipelines(company_id,status,position,id);

alter table public.pipeline_stages
  add column if not exists pipeline_id uuid references public.crm_pipelines(id) on delete restrict,
  add column if not exists description text,
  add column if not exists stage_type text not null default 'open',
  add column if not exists recommended_delay_days integer,
  add column if not exists entry_rules jsonb not null default '{}'::jsonb,
  add column if not exists exit_rules jsonb not null default '{}'::jsonb,
  add column if not exists automation_rules jsonb not null default '[]'::jsonb,
  add column if not exists updated_by uuid default auth.uid();
alter table public.pipeline_stages drop constraint if exists pipeline_stages_stage_type_check;
alter table public.pipeline_stages add constraint pipeline_stages_stage_type_check
  check(stage_type in('open','won','lost','suspended')) not valid;
create index if not exists pipeline_stages_pipeline_order_idx on public.pipeline_stages(company_id,pipeline_id,position) where active;

create table if not exists public.crm_sources(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, slug text not null, color text not null default '#64748b', position integer not null default 0,
  is_active boolean not null default true, is_system boolean not null default false,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,slug)
);

create table if not exists public.crm_loss_reasons(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, slug text not null, position integer not null default 0, is_active boolean not null default true,
  requires_comment boolean not null default false, is_system boolean not null default false,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,slug)
);

alter table public.clients
  add column if not exists crm_status text not null default 'new',
  add column if not exists crm_score numeric(6,2) not null default 0,
  add column if not exists crm_score_label text not null default 'cold',
  add column if not exists crm_score_override numeric(6,2),
  add column if not exists crm_score_override_reason text,
  add column if not exists crm_source_id uuid references public.crm_sources(id) on delete set null,
  add column if not exists crm_conversion_source_id uuid references public.crm_sources(id) on delete set null,
  add column if not exists assigned_user_id uuid,
  add column if not exists crm_last_activity_at timestamptz,
  add column if not exists next_activity_at timestamptz,
  add column if not exists converted_at timestamptz,
  add column if not exists converted_from_prospect_id uuid,
  add column if not exists crm_tags_cache text[] not null default '{}';
alter table public.clients drop constraint if exists clients_crm_status_check;
alter table public.clients add constraint clients_crm_status_check check(crm_status in(
  'new','to_qualify','qualified','in_progress','to_follow_up','not_interested','converted','archived'
)) not valid;
alter table public.clients drop constraint if exists clients_crm_score_label_check;
alter table public.clients add constraint clients_crm_score_label_check check(crm_score_label in('cold','watch','warm','hot','priority')) not valid;
create index if not exists clients_crm_directory_idx on public.clients(company_id,relationship_type,crm_status,assigned_user_id,created_at desc);
create index if not exists clients_crm_score_idx on public.clients(company_id,crm_score desc,crm_last_activity_at) where relationship_type='prospect' and active;
create index if not exists clients_crm_email_idx on public.clients(company_id,lower(email)) where email is not null;
create index if not exists clients_crm_phone_idx on public.clients(company_id,phone_e164) where phone_e164 is not null;
create index if not exists clients_crm_siret_idx on public.clients(company_id,siret) where siret is not null;
create index if not exists clients_crm_search_text_idx on public.clients using gin(to_tsvector('simple',coalesce(legal_name,'')||' '||coalesce(trade_name,'')||' '||coalesce(first_name,'')||' '||coalesce(last_name,'')||' '||coalesce(email,'')));

alter table public.opportunities
  add column if not exists pipeline_id uuid references public.crm_pipelines(id) on delete restrict,
  add column if not exists pipeline_stage_id uuid references public.pipeline_stages(id) on delete restrict,
  add column if not exists source_id uuid references public.crm_sources(id) on delete set null,
  add column if not exists primary_contact_id uuid references public.client_contacts(id) on delete set null,
  add column if not exists forecast_category text not null default 'potential',
  add column if not exists opportunity_type text,
  add column if not exists score numeric(6,2) not null default 0,
  add column if not exists actual_amount numeric(15,2),
  add column if not exists recurring_amount numeric(15,2),
  add column if not exists recurrence text,
  add column if not exists competitors text[],
  add column if not exists won_at timestamptz,
  add column if not exists lost_at timestamptz,
  add column if not exists lost_reason_id uuid references public.crm_loss_reasons(id) on delete set null,
  add column if not exists success_reason text,
  add column if not exists close_comment text,
  add column if not exists reopened_at timestamptz,
  add column if not exists next_action text,
  add column if not exists updated_by uuid default auth.uid();
alter table public.opportunities drop constraint if exists opportunities_forecast_category_check;
alter table public.opportunities add constraint opportunities_forecast_category_check
  check(forecast_category in('commit','probable','potential','unqualified','won','lost')) not valid;
create index if not exists opportunities_crm_kanban_idx on public.opportunities(company_id,pipeline_id,pipeline_stage_id,stage_entered_at,id) where archived_at is null;
create index if not exists opportunities_crm_forecast_idx on public.opportunities(company_id,forecast_category,expected_close_date,assigned_user_id) where archived_at is null;
create index if not exists opportunities_crm_search_idx on public.opportunities using gin(to_tsvector('simple',coalesce(name,'')||' '||coalesce(need_subject,'')||' '||coalesce(description,'')));

alter table public.activities
  add column if not exists contact_id uuid references public.client_contacts(id) on delete set null,
  add column if not exists location text,
  add column if not exists meeting_url text,
  add column if not exists external_calendar text,
  add column if not exists external_event_id text,
  add column if not exists recurrence_rule text,
  add column if not exists outcome_code text,
  add column if not exists next_action text;
create index if not exists activities_crm_workspace_idx on public.activities(company_id,status,due_at,assigned_user_id,id);
create index if not exists activities_crm_links_idx on public.activities(company_id,client_id,opportunity_id,created_at desc);

create table if not exists public.crm_opportunity_products(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  opportunity_id uuid not null references public.opportunities(id) on delete cascade,
  catalog_item_id uuid references public.catalog_items(id) on delete set null,
  name text not null, description text, quantity numeric(15,4) not null default 1,
  unit_price numeric(15,4) not null default 0, discount_rate numeric(5,2) not null default 0,
  estimated_cost numeric(15,4), currency text not null default 'EUR', position integer not null default 0,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists crm_opportunity_products_opp_idx on public.crm_opportunity_products(company_id,opportunity_id,position);

create table if not exists public.crm_activity_participants(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  participant_type text not null check(participant_type in('user','contact','external')),
  participant_id uuid, display_name text, email text, response_status text,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists crm_activity_participants_activity_idx on public.crm_activity_participants(company_id,activity_id);

create table if not exists public.crm_activity_links(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  entity_type text not null check(entity_type in('prospect','client','contact','opportunity','quote','invoice','due_date')),
  entity_id uuid not null,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(activity_id,entity_type,entity_id)
);
create index if not exists crm_activity_links_entity_idx on public.crm_activity_links(company_id,entity_type,entity_id,created_at desc);

create table if not exists public.crm_notes(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  entity_type text not null check(entity_type in('prospect','client','contact','opportunity')),
  entity_id uuid not null, body text not null, is_pinned boolean not null default false,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists crm_notes_entity_idx on public.crm_notes(company_id,entity_type,entity_id,is_pinned desc,created_at desc);

create table if not exists public.crm_tags(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, slug text not null, color text not null default '#64748b', description text, is_active boolean not null default true,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,slug)
);
create table if not exists public.crm_tag_assignments(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  tag_id uuid not null references public.crm_tags(id) on delete cascade,
  entity_type text not null check(entity_type in('prospect','client','contact','opportunity','activity')),
  entity_id uuid not null,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,tag_id,entity_type,entity_id)
);
create index if not exists crm_tag_assignments_entity_idx on public.crm_tag_assignments(company_id,entity_type,entity_id);

create table if not exists public.crm_custom_fields(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  object_type text not null check(object_type in('prospect','contact','opportunity')),
  name text not null, slug text not null, description text, field_type text not null check(field_type in('text','number','amount','date','boolean','select','multiselect','url','email','phone')),
  is_required boolean not null default false, is_active boolean not null default true, position integer not null default 0,
  options jsonb not null default '[]'::jsonb, visibility jsonb not null default '{}'::jsonb, permissions jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,object_type,slug)
);
create table if not exists public.crm_custom_field_values(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  field_id uuid not null references public.crm_custom_fields(id) on delete cascade,
  entity_id uuid not null, value jsonb not null default 'null'::jsonb,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,field_id,entity_id)
);
create index if not exists crm_custom_values_entity_idx on public.crm_custom_field_values(company_id,entity_id,field_id);

create table if not exists public.crm_automation_rules(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, description text, status text not null default 'draft' check(status in('draft','active','paused','archived')),
  trigger_type text not null, trigger_config jsonb not null default '{}'::jsonb,
  conditions jsonb not null default '[]'::jsonb, actions jsonb not null default '[]'::jsonb,
  position integer not null default 0, last_run_at timestamptz, run_count bigint not null default 0,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists crm_automation_rules_trigger_idx on public.crm_automation_rules(company_id,trigger_type,status,position);
create table if not exists public.crm_automation_runs(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  rule_id uuid not null references public.crm_automation_rules(id) on delete cascade,
  entity_type text, entity_id uuid, status text not null default 'queued' check(status in('queued','running','completed','failed','skipped')),
  attempt integer not null default 1, input jsonb not null default '{}'::jsonb, output jsonb not null default '{}'::jsonb,
  error_code text, error_message text, started_at timestamptz, finished_at timestamptz,
  created_by uuid not null default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists crm_automation_runs_rule_idx on public.crm_automation_runs(company_id,rule_id,created_at desc);

create table if not exists public.crm_sequences(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, description text, status text not null default 'draft' check(status in('draft','active','paused','archived')),
  exit_rules jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.crm_sequence_steps(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  sequence_id uuid not null references public.crm_sequences(id) on delete cascade,
  position integer not null default 0, delay_days integer not null default 0,
  action_type text not null check(action_type in('email_draft','email_send','call_task','task','notification')),
  configuration jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(sequence_id,position)
);
create table if not exists public.crm_sequence_enrollments(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  sequence_id uuid not null references public.crm_sequences(id) on delete cascade,
  prospect_id uuid not null references public.clients(id) on delete cascade,
  opportunity_id uuid references public.opportunities(id) on delete set null,
  status text not null default 'active' check(status in('active','paused','completed','removed','failed')),
  current_step integer not null default 0, next_run_at timestamptz, exit_reason text,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(sequence_id,prospect_id,status)
);
create index if not exists crm_sequence_enrollments_due_idx on public.crm_sequence_enrollments(company_id,status,next_run_at);

create table if not exists public.crm_saved_views(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null default auth.uid(), object_type text not null, name text not null,
  filters jsonb not null default '{}'::jsonb, columns jsonb not null default '[]'::jsonb, sorting jsonb not null default '[]'::jsonb,
  is_shared boolean not null default false, is_default boolean not null default false,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,user_id,object_type,name)
);
create table if not exists public.crm_segments(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, object_type text not null check(object_type in('prospect','client','opportunity')),
  rules jsonb not null default '[]'::jsonb, is_active boolean not null default true, last_computed_at timestamptz,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.crm_score_rules(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, object_type text not null default 'prospect' check(object_type in('prospect','opportunity')),
  criterion text not null, operator text not null, criterion_value jsonb not null default 'null'::jsonb,
  points numeric(6,2) not null, reason text not null, position integer not null default 0, is_active boolean not null default true,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.crm_score_history(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  entity_type text not null check(entity_type in('prospect','opportunity')), entity_id uuid not null,
  previous_score numeric(6,2), new_score numeric(6,2) not null, level text not null,
  explanation jsonb not null default '[]'::jsonb, is_manual boolean not null default false, reason text,
  created_by uuid not null default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists crm_score_history_entity_idx on public.crm_score_history(company_id,entity_type,entity_id,created_at desc);

create table if not exists public.crm_timeline_events(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  entity_type text not null, entity_id uuid not null, event_type text not null,
  title text not null, summary text, related_type text, related_id uuid,
  payload jsonb not null default '{}'::jsonb, actor_user_id uuid default auth.uid(),
  created_by uuid not null default auth.uid(), occurred_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create index if not exists crm_timeline_entity_idx on public.crm_timeline_events(company_id,entity_type,entity_id,occurred_at desc,id desc);

create table if not exists public.company_dashboard_defaults(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  role text not null, visible_blocks jsonb not null default '[]'::jsonb, block_order jsonb not null default '[]'::jsonb,
  block_sizes jsonb not null default '{}'::jsonb, selected_metrics jsonb not null default '[]'::jsonb,
  created_by uuid not null default auth.uid(), updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,role)
);

do $rls$
declare table_name text;
begin
  foreach table_name in array array[
    'crm_pipelines','crm_sources','crm_loss_reasons','crm_opportunity_products','crm_activity_participants',
    'crm_activity_links','crm_notes','crm_tags','crm_tag_assignments','crm_custom_fields','crm_custom_field_values',
    'crm_automation_rules','crm_automation_runs','crm_sequences','crm_sequence_steps','crm_sequence_enrollments',
    'crm_saved_views','crm_segments','crm_score_rules','crm_score_history','crm_timeline_events','company_dashboard_defaults'
  ] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    if table_name not in('crm_score_history','crm_timeline_events','crm_automation_runs') then
      execute format('create policy %I on public.%I for insert to authenticated with check(public.has_company_role(company_id,array[''owner'',''admin'',''billing'',''sales'',''accounting'',''member'']) and created_by=auth.uid())',table_name||'_insert',table_name);
      execute format('create policy %I on public.%I for update to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'',''billing'',''sales'',''accounting'',''member''])) with check(public.has_company_role(company_id,array[''owner'',''admin'',''billing'',''sales'',''accounting'',''member'']))',table_name||'_update',table_name);
      execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete',table_name);
    end if;
  end loop;
end
$rls$;

-- Les vues sauvegardées privées restent visibles uniquement par leur auteur ; les
-- vues partagées sont visibles par l'entreprise.
drop policy if exists crm_saved_views_select on public.crm_saved_views;
create policy crm_saved_views_select on public.crm_saved_views for select to authenticated
  using(public.is_company_member(company_id) and (user_id=auth.uid() or is_shared));
drop policy if exists crm_saved_views_update on public.crm_saved_views;
create policy crm_saved_views_update on public.crm_saved_views for update to authenticated
  using(public.has_company_role(company_id,array['owner','admin','billing','sales','accounting','member']) and user_id=auth.uid())
  with check(public.has_company_role(company_id,array['owner','admin','billing','sales','accounting','member']) and user_id=auth.uid());

do $updated$
declare table_name text;
begin
  foreach table_name in array array[
    'crm_pipelines','crm_sources','crm_loss_reasons','crm_opportunity_products','crm_activity_participants',
    'crm_activity_links','crm_notes','crm_tags','crm_tag_assignments','crm_custom_fields','crm_custom_field_values',
    'crm_automation_rules','crm_sequences','crm_sequence_steps','crm_sequence_enrollments','crm_saved_views',
    'crm_segments','crm_score_rules','company_dashboard_defaults'
  ] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_set_updated_at',table_name);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
  end loop;
end
$updated$;

create or replace function public._crm_context()
returns table(company_id uuid,role text,can_manage boolean,can_view_all boolean,can_write boolean,can_margin boolean)
language sql stable security definer set search_path=public,pg_temp as $$
  select member.company_id,member.role,
    member.role in('owner','admin'),
    member.role in('owner','admin','manager','sales_manager','accounting','auditor','read_only'),
    member.role not in('auditor','read_only'),
    public.has_company_permission(member.company_id,'view_margins')
  from public.company_members member
  left join public.user_preferences preference on preference.user_id=member.user_id
  where member.user_id=auth.uid() and (preference.company_id is null or preference.company_id=member.company_id)
  order by case when preference.company_id=member.company_id then 0 else 1 end,member.created_at
  limit 1
$$;

create or replace function public._crm_slug(value text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select trim(both '-' from regexp_replace(lower(translate(coalesce(value,''),'àâäáãåçéèêëîïíôöóõùûüúÿñ','aaaaaaceeeeiiioooouuuuy n')),'[^a-z0-9]+','-','g'))
$$;

create or replace function public._crm_seed_company(target_company_id uuid,target_owner_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare pipeline_uuid uuid;
begin
  insert into public.crm_pipelines(company_id,name,slug,description,pipeline_type,status,color,currency,position,is_default,created_by,updated_by)
  values(target_company_id,'Ventes principales','ventes-principales','Pipeline commercial principal','sales','active','#14b8a6','EUR',10,true,target_owner_id,target_owner_id)
  on conflict(company_id,slug) do update set is_default=case when not exists(select 1 from public.crm_pipelines p where p.company_id=target_company_id and p.is_default and p.status<>'archived') then true else public.crm_pipelines.is_default end
  returning id into pipeline_uuid;
  if pipeline_uuid is null then select id into pipeline_uuid from public.crm_pipelines where company_id=target_company_id and is_default and status<>'archived' order by position,id limit 1; end if;

  insert into public.crm_sources(company_id,name,slug,position,is_system,created_by,updated_by)
  select target_company_id,value.name,value.slug,value.position,true,target_owner_id,target_owner_id from(values
    ('Site internet','site-internet',10),('Formulaire','formulaire',20),('Recommandation','recommandation',30),
    ('Prospection','prospection',40),('Réseau social','reseau-social',50),('Salon','salon',60),
    ('Appel entrant','appel-entrant',70),('Partenaire','partenaire',80),('Import','import',90),('Autre','autre',100)
  )value(name,slug,position) on conflict(company_id,slug) do nothing;

  insert into public.crm_loss_reasons(company_id,name,slug,position,requires_comment,is_system,created_by,updated_by)
  select target_company_id,value.name,value.slug,value.position,value.comment,true,target_owner_id,target_owner_id from(values
    ('Prix trop élevé','prix-trop-eleve',10,false),('Concurrent choisi','concurrent-choisi',20,false),
    ('Projet reporté','projet-reporte',30,false),('Projet annulé','projet-annule',40,false),
    ('Aucun budget','aucun-budget',50,false),('Aucun retour','aucun-retour',60,false),
    ('Besoin non adapté','besoin-non-adapte',70,false),('Délai trop long','delai-trop-long',80,false),
    ('Prospect non qualifié','prospect-non-qualifie',90,false),('Autre','autre',100,true)
  )value(name,slug,position,comment) on conflict(company_id,slug) do nothing;

  update public.pipeline_stages set pipeline_id=pipeline_uuid,
    stage_type=case when is_won then 'won' when is_lost then 'lost' else stage_type end
  where company_id=target_company_id and pipeline_id is null;

  if not exists(select 1 from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid) then
    insert into public.pipeline_stages(company_id,pipeline_id,name,slug,position,probability,color,active,is_won,is_lost,stage_type,recommended_delay_days,created_by,updated_by)
    select target_company_id,pipeline_uuid,value.name,value.slug,value.position,value.probability,value.color,true,value.kind='won',value.kind='lost',value.kind,value.delay,target_owner_id,target_owner_id
    from(values
      ('Nouveau','new',10,5::numeric,'#64748b','open',2),('À qualifier','to_qualify',20,15::numeric,'#3b82f6','open',4),
      ('Contact établi','contacted',30,25::numeric,'#0ea5e9','open',7),('Rendez-vous planifié','meeting',40,40::numeric,'#6366f1','open',10),
      ('Besoin identifié','qualified',50,55::numeric,'#8b5cf6','open',10),('Proposition à préparer','proposal',60,65::numeric,'#a855f7','open',7),
      ('Devis envoyé','quote_sent',70,75::numeric,'#f59e0b','open',10),('Négociation','negotiation',80,85::numeric,'#f97316','open',14),
      ('Gagné','won',90,100::numeric,'#16a34a','won',null),('Perdu','lost',100,0::numeric,'#ef4444','lost',null)
    )value(name,slug,position,probability,color,kind,delay) on conflict(company_id,slug) do nothing;
  end if;

  update public.opportunities opportunity set pipeline_id=pipeline_uuid,
    pipeline_stage_id=coalesce(opportunity.pipeline_stage_id,(select stage.id from public.pipeline_stages stage where stage.company_id=opportunity.company_id and stage.pipeline_id=pipeline_uuid and stage.slug=opportunity.stage limit 1))
  where opportunity.company_id=target_company_id and opportunity.pipeline_id is null;
end
$$;

create or replace function public.seed_company_crm_defaults()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._crm_seed_company(new.id,new.owner_user_id);return new;end
$$;
drop trigger if exists companies_seed_crm_defaults on public.companies;
create trigger companies_seed_crm_defaults after insert on public.companies for each row execute function public.seed_company_crm_defaults();

do $seed$
declare company_row record;
begin
  for company_row in select id,owner_user_id from public.companies loop
    perform public._crm_seed_company(company_row.id,company_row.owner_user_id);
  end loop;
end
$seed$;

create or replace function public.create_crm_pipeline(target_name text,target_description text default null,target_currency text default 'EUR',target_pipeline_type text default 'sales')
returns public.crm_pipelines language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.crm_pipelines%rowtype;slug_value text;source_pipeline uuid;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_manage then raise exception 'crm_forbidden' using errcode='42501'; end if;
  if nullif(trim(target_name),'') is null then raise exception 'crm_pipeline_name_required'; end if;
  slug_value:=public._crm_slug(target_name)||'-'||substr(gen_random_uuid()::text,1,6);
  insert into public.crm_pipelines(company_id,name,slug,description,currency,pipeline_type,position,created_by,updated_by)
  values(context_row.company_id,trim(target_name),slug_value,nullif(trim(target_description),''),coalesce(nullif(target_currency,''),'EUR'),coalesce(nullif(target_pipeline_type,''),'sales'),
    coalesce((select max(position)+10 from public.crm_pipelines where company_id=context_row.company_id),10),auth.uid(),auth.uid()) returning * into result;
  select id into source_pipeline from public.crm_pipelines where company_id=context_row.company_id and is_default and status<>'archived' limit 1;
  insert into public.pipeline_stages(company_id,pipeline_id,name,slug,description,position,probability,color,active,is_won,is_lost,stage_type,recommended_delay_days,entry_rules,exit_rules,automation_rules,created_by,updated_by)
  select context_row.company_id,result.id,stage.name,result.slug||'-'||stage.slug,stage.description,stage.position,stage.probability,stage.color,true,stage.is_won,stage.is_lost,stage.stage_type,stage.recommended_delay_days,stage.entry_rules,stage.exit_rules,stage.automation_rules,auth.uid(),auth.uid()
  from public.pipeline_stages stage where stage.pipeline_id=source_pipeline and stage.active order by stage.position;
  return result;
end
$$;

create or replace function public.duplicate_crm_pipeline(target_pipeline_id uuid,target_name text)
returns public.crm_pipelines language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;source public.crm_pipelines%rowtype;result public.crm_pipelines%rowtype;slug_value text;
begin
  select * into context_row from public._crm_context();
  select * into source from public.crm_pipelines where id=target_pipeline_id and company_id=context_row.company_id;
  if source.id is null or not context_row.can_manage then raise exception 'crm_forbidden' using errcode='42501'; end if;
  slug_value:=public._crm_slug(coalesce(nullif(trim(target_name),''),source.name||' copie'))||'-'||substr(gen_random_uuid()::text,1,6);
  insert into public.crm_pipelines(company_id,name,slug,description,pipeline_type,status,owner_user_id,color,currency,position,is_default,automation_settings,created_by,updated_by)
  values(source.company_id,coalesce(nullif(trim(target_name),''),source.name||' copie'),slug_value,source.description,source.pipeline_type,'active',source.owner_user_id,source.color,source.currency,
    coalesce((select max(position)+10 from public.crm_pipelines where company_id=source.company_id),10),false,source.automation_settings,auth.uid(),auth.uid()) returning * into result;
  insert into public.pipeline_stages(company_id,pipeline_id,name,slug,description,position,probability,color,active,is_won,is_lost,stage_type,recommended_delay_days,entry_rules,exit_rules,automation_rules,created_by,updated_by)
  select source.company_id,result.id,stage.name,result.slug||'-'||public._crm_slug(stage.name),stage.description,stage.position,stage.probability,stage.color,stage.active,stage.is_won,stage.is_lost,stage.stage_type,stage.recommended_delay_days,stage.entry_rules,stage.exit_rules,stage.automation_rules,auth.uid(),auth.uid()
  from public.pipeline_stages stage where stage.pipeline_id=source.id order by stage.position;
  return result;
end
$$;

create or replace function public.create_crm_prospect(target_payload jsonb)
returns public.clients language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.clients%rowtype;email_value text;kind_value text;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write then raise exception 'crm_forbidden' using errcode='42501'; end if;
  kind_value:=coalesce(nullif(target_payload->>'kind',''),'company');
  if kind_value not in('company','person') then raise exception 'crm_invalid_prospect_kind'; end if;
  email_value:=nullif(lower(trim(target_payload->>'email')),'');
  if email_value is not null and exists(select 1 from public.clients client where client.company_id=context_row.company_id and lower(client.email)=email_value and client.active) then
    raise exception 'crm_duplicate_email';
  end if;
  insert into public.clients(company_id,kind,legal_name,trade_name,first_name,last_name,email,phone_e164,siren,siret,address_line_1,address_line_2,postal_code,city,country_code,relationship_type,crm_status,crm_source_id,assigned_user_id,contact_name,created_by)
  values(context_row.company_id,kind_value,nullif(trim(target_payload->>'legal_name'),''),nullif(trim(target_payload->>'trade_name'),''),nullif(trim(target_payload->>'first_name'),''),nullif(trim(target_payload->>'last_name'),''),email_value,nullif(trim(target_payload->>'phone_e164'),''),nullif(trim(target_payload->>'siren'),''),nullif(trim(target_payload->>'siret'),''),nullif(trim(target_payload->>'address_line_1'),''),nullif(trim(target_payload->>'address_line_2'),''),nullif(trim(target_payload->>'postal_code'),''),nullif(trim(target_payload->>'city'),''),coalesce(nullif(target_payload->>'country_code',''),'FR'),'prospect',coalesce(nullif(target_payload->>'crm_status',''),'new'),nullif(target_payload->>'source_id','')::uuid,nullif(target_payload->>'assigned_user_id','')::uuid,nullif(trim(target_payload->>'contact_name'),''),auth.uid()) returning * into result;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,created_by)
  values(result.company_id,'prospect',result.id,'prospect_created','Prospect créé',coalesce(result.legal_name,result.trade_name,result.first_name||' '||result.last_name),auth.uid());
  return result;
end
$$;

create or replace function public.convert_crm_prospect(target_prospect_id uuid,target_existing_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;prospect public.clients%rowtype;target public.clients%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into prospect from public.clients where id=target_prospect_id and company_id=context_row.company_id for update;
  if prospect.id is null or prospect.relationship_type<>'prospect' or not context_row.can_write then raise exception 'crm_invalid_prospect' using errcode='42501'; end if;
  if target_existing_client_id is null then
    update public.clients set relationship_type='client',crm_status='converted',converted_at=now(),updated_at=now() where id=prospect.id returning * into target;
  else
    select * into target from public.clients where id=target_existing_client_id and company_id=prospect.company_id and relationship_type='client' and active for update;
    if target.id is null or target.id=prospect.id then raise exception 'crm_invalid_conversion_target'; end if;
    update public.client_contacts set is_primary=false where client_id=prospect.id and is_primary;
    update public.client_contacts set client_id=target.id where client_id=prospect.id;
    update public.opportunities set client_id=target.id where client_id=prospect.id;
    update public.activities set client_id=target.id where client_id=prospect.id;
    update public.documents set client_id=target.id where client_id=prospect.id;
    update public.reminders set client_id=target.id where client_id=prospect.id;
    update public.clients set relationship_type='archived',crm_status='converted',converted_at=now(),active=false,updated_at=now() where id=prospect.id;
  end if;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,related_type,related_id,created_by)
  values(prospect.company_id,'prospect',prospect.id,'prospect_converted','Prospect converti en client',coalesce(target.legal_name,target.trade_name,target.first_name||' '||target.last_name),'client',target.id,auth.uid());
  return jsonb_build_object('client_id',target.id,'prospect_id',prospect.id,'merged',target_existing_client_id is not null);
end
$$;

create or replace function public.create_crm_opportunity(target_payload jsonb)
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;pipeline public.crm_pipelines%rowtype;stage public.pipeline_stages%rowtype;result public.opportunities%rowtype;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write then raise exception 'crm_forbidden' using errcode='42501'; end if;
  select * into pipeline from public.crm_pipelines where company_id=context_row.company_id and id=coalesce(nullif(target_payload->>'pipeline_id','')::uuid,(select id from public.crm_pipelines where company_id=context_row.company_id and is_default and status='active' limit 1));
  select * into stage from public.pipeline_stages where company_id=context_row.company_id and pipeline_id=pipeline.id and id=coalesce(nullif(target_payload->>'stage_id','')::uuid,(select id from public.pipeline_stages where pipeline_id=pipeline.id and active order by position limit 1));
  if pipeline.id is null or stage.id is null or nullif(trim(target_payload->>'name'),'') is null then raise exception 'crm_invalid_opportunity'; end if;
  insert into public.opportunities(company_id,client_id,name,stage,amount,probability,owner_user_id,next_action_at,notes,contact_id,expected_close_date,assigned_user_id,source,need_subject,description,priority,health,collaborator_user_ids,pipeline_id,pipeline_stage_id,source_id,primary_contact_id,forecast_category,opportunity_type,recurring_amount,recurrence,next_action,created_by,updated_by)
  values(context_row.company_id,nullif(target_payload->>'client_id','')::uuid,trim(target_payload->>'name'),stage.slug,coalesce((target_payload->>'amount')::numeric,0),coalesce((target_payload->>'probability')::numeric,stage.probability),nullif(target_payload->>'assigned_user_id','')::uuid,nullif(target_payload->>'next_action_at','')::timestamptz,nullif(target_payload->>'notes',''),nullif(target_payload->>'contact_id','')::uuid,nullif(target_payload->>'expected_close_date','')::date,nullif(target_payload->>'assigned_user_id','')::uuid,nullif(target_payload->>'source',''),nullif(target_payload->>'need_subject',''),nullif(target_payload->>'description',''),coalesce(nullif(target_payload->>'priority',''),'normal'),'watch','{}'::uuid[],pipeline.id,stage.id,nullif(target_payload->>'source_id','')::uuid,nullif(target_payload->>'contact_id','')::uuid,coalesce(nullif(target_payload->>'forecast_category',''),'potential'),nullif(target_payload->>'opportunity_type',''),nullif(target_payload->>'recurring_amount','')::numeric,nullif(target_payload->>'recurrence',''),nullif(target_payload->>'next_action',''),auth.uid(),auth.uid()) returning * into result;
  return result;
end
$$;

create or replace function public.move_crm_opportunity(target_opportunity_id uuid,target_stage_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity public.opportunities%rowtype;stage public.pipeline_stages%rowtype;previous_stage uuid;
begin
  select * into context_row from public._crm_context();
  select * into opportunity from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id for update;
  select * into stage from public.pipeline_stages where id=target_stage_id and company_id=context_row.company_id and pipeline_id=opportunity.pipeline_id and active;
  if opportunity.id is null or stage.id is null or not context_row.can_write then raise exception 'crm_forbidden' using errcode='42501'; end if;
  if stage.stage_type in('won','lost') then raise exception 'crm_close_dialog_required'; end if;
  previous_stage:=opportunity.pipeline_stage_id;
  update public.opportunities set pipeline_stage_id=stage.id,stage=stage.slug,probability=stage.probability,
    stage_entered_at=now(),forecast_category=case when forecast_category in('won','lost') then 'potential' else forecast_category end,
    health=case when health in('won','lost') then 'watch' else health end,closed_at=null,updated_by=auth.uid(),updated_at=now()
  where id=opportunity.id;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,created_by)
  values(opportunity.company_id,'opportunity',opportunity.id,'stage_changed','Étape modifiée',stage.name,jsonb_build_object('from_stage_id',previous_stage,'to_stage_id',stage.id),auth.uid());
  return jsonb_build_object('id',opportunity.id,'stage_id',stage.id,'stage',stage.slug,'probability',stage.probability,'updated_at',now());
end
$$;

create or replace function public.close_crm_opportunity(target_opportunity_id uuid,target_outcome text,target_amount numeric default null,target_reason_id uuid default null,target_comment text default null,target_closed_at timestamptz default now())
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity public.opportunities%rowtype;stage public.pipeline_stages%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into opportunity from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id for update;
  if opportunity.id is null or not context_row.can_write or target_outcome not in('won','lost','reopen') then raise exception 'crm_forbidden' using errcode='42501'; end if;
  if target_outcome='lost' and target_reason_id is null then raise exception 'crm_loss_reason_required'; end if;
  if target_outcome='reopen' then
    select * into stage from public.pipeline_stages where pipeline_id=opportunity.pipeline_id and stage_type='open' and active order by position limit 1;
    update public.opportunities set stage=stage.slug,pipeline_stage_id=stage.id,probability=stage.probability,forecast_category='potential',health='watch',closed_at=null,won_at=null,lost_at=null,reopened_at=now(),updated_by=auth.uid(),updated_at=now() where id=opportunity.id returning * into opportunity;
  else
    select * into stage from public.pipeline_stages where pipeline_id=opportunity.pipeline_id and stage_type=target_outcome and active order by position limit 1;
    if stage.id is null then raise exception 'crm_final_stage_missing'; end if;
    update public.opportunities set stage=stage.slug,pipeline_stage_id=stage.id,probability=stage.probability,
      forecast_category=target_outcome,health=target_outcome,closed_at=coalesce(target_closed_at,now()),
      won_at=case when target_outcome='won' then coalesce(target_closed_at,now()) else null end,
      lost_at=case when target_outcome='lost' then coalesce(target_closed_at,now()) else null end,
      actual_amount=coalesce(target_amount,amount),lost_reason_id=case when target_outcome='lost' then target_reason_id else null end,
      lost_reason=case when target_outcome='lost' then (select name from public.crm_loss_reasons where id=target_reason_id and company_id=opportunity.company_id) else null end,
      success_reason=case when target_outcome='won' then nullif(trim(target_comment),'') else success_reason end,
      close_comment=nullif(trim(target_comment),''),updated_by=auth.uid(),updated_at=now()
    where id=opportunity.id returning * into opportunity;
  end if;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,created_by)
  values(opportunity.company_id,'opportunity',opportunity.id,'opportunity_'||target_outcome,
    case target_outcome when 'won' then 'Opportunité gagnée' when 'lost' then 'Opportunité perdue' else 'Opportunité rouverte' end,
    target_comment,jsonb_build_object('amount',opportunity.actual_amount,'reason_id',target_reason_id),auth.uid());
  return opportunity;
end
$$;

create or replace function public.create_crm_activity(target_payload jsonb)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.activities%rowtype;type_value text;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write then raise exception 'crm_forbidden' using errcode='42501'; end if;
  type_value:=coalesce(nullif(target_payload->>'activity_type',''),'task');
  insert into public.activities(company_id,opportunity_id,client_id,contact_id,document_id,activity_type,subject,description,scheduled_at,due_at,duration_minutes,priority,status,reminder_at,assigned_user_id,location,meeting_url,external_calendar,metadata,created_by,updated_by)
  values(context_row.company_id,nullif(target_payload->>'opportunity_id','')::uuid,nullif(target_payload->>'client_id','')::uuid,nullif(target_payload->>'contact_id','')::uuid,nullif(target_payload->>'document_id','')::uuid,type_value,trim(target_payload->>'subject'),nullif(target_payload->>'description',''),nullif(target_payload->>'scheduled_at','')::timestamptz,nullif(target_payload->>'due_at','')::timestamptz,nullif(target_payload->>'duration_minutes','')::integer,coalesce(nullif(target_payload->>'priority',''),'normal'),coalesce(nullif(target_payload->>'status',''),'todo'),nullif(target_payload->>'reminder_at','')::timestamptz,coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,auth.uid()),nullif(target_payload->>'location',''),nullif(target_payload->>'meeting_url',''),nullif(target_payload->>'external_calendar',''),coalesce(target_payload->'metadata','{}'::jsonb),auth.uid(),auth.uid()) returning * into result;
  return result;
end
$$;

create or replace function public.complete_crm_activity(target_activity_id uuid,target_result text default null,target_next_action text default null)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.activities%rowtype;
begin
  select * into context_row from public._crm_context();
  update public.activities set status='completed',completed_at=now(),result=nullif(trim(target_result),''),next_action=nullif(trim(target_next_action),''),updated_by=auth.uid(),updated_at=now()
  where id=target_activity_id and company_id=context_row.company_id and context_row.can_write returning * into result;
  if result.id is null then raise exception 'crm_forbidden' using errcode='42501'; end if;
  return result;
end
$$;

create or replace function public.recalculate_crm_score(target_prospect_id uuid,target_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;prospect public.clients%rowtype;calculated numeric:=0;previous numeric;level text;explanation jsonb:='[]'::jsonb;activity_count integer;recent_activity timestamptz;opportunity_count integer;quote_count integer;
begin
  select * into context_row from public._crm_context();
  select * into prospect from public.clients where id=target_prospect_id and company_id=context_row.company_id and relationship_type='prospect' for update;
  if prospect.id is null then raise exception 'crm_prospect_not_found'; end if;
  previous:=prospect.crm_score;
  if prospect.email is not null then calculated:=calculated+8;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','E-mail renseigné','points',8));end if;
  if prospect.phone_e164 is not null then calculated:=calculated+8;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Téléphone renseigné','points',8));end if;
  if prospect.siren is not null or prospect.siret is not null then calculated:=calculated+8;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Entreprise identifiée','points',8));end if;
  select count(*),max(coalesce(completed_at,scheduled_at,created_at)) into activity_count,recent_activity from public.activities where company_id=prospect.company_id and client_id=prospect.id;
  if activity_count>0 then calculated:=calculated+least(20,activity_count*3);explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Interactions enregistrées','points',least(20,activity_count*3)));end if;
  if recent_activity>now()-interval '14 days' then calculated:=calculated+15;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Activité récente','points',15));
  elsif recent_activity is not null and recent_activity<now()-interval '45 days' then calculated:=calculated-10;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Inactivité supérieure à 45 jours','points',-10));end if;
  select count(*) into opportunity_count from public.opportunities where company_id=prospect.company_id and client_id=prospect.id and archived_at is null;
  if opportunity_count>0 then calculated:=calculated+20;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Opportunité ouverte','points',20));end if;
  select count(*) into quote_count from public.documents where company_id=prospect.company_id and client_id=prospect.id and document_type='quote' and status not in('draft','archived','cancelled');
  if quote_count>0 then calculated:=calculated+20;explanation:=explanation||jsonb_build_array(jsonb_build_object('reason','Devis envoyé','points',20));end if;
  calculated:=greatest(0,least(100,coalesce(prospect.crm_score_override,calculated)));
  level:=case when calculated>=85 then 'priority' when calculated>=65 then 'hot' when calculated>=40 then 'warm' when calculated>=20 then 'watch' else 'cold' end;
  update public.clients set crm_score=calculated,crm_score_label=level,crm_last_activity_at=recent_activity,updated_at=now() where id=prospect.id;
  insert into public.crm_score_history(company_id,entity_type,entity_id,previous_score,new_score,level,explanation,is_manual,reason,created_by)
  values(prospect.company_id,'prospect',prospect.id,previous,calculated,level,explanation,prospect.crm_score_override is not null,target_reason,auth.uid());
  return jsonb_build_object('score',calculated,'level',level,'explanation',explanation);
end
$$;

create or replace function public.get_crm_pipeline_workspace(target_pipeline_id uuid default null,target_search text default null,target_filters jsonb default '{}'::jsonb,target_page integer default 1,target_page_size integer default 75)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;pipeline_uuid uuid;result jsonb;page_size integer:=least(100,greatest(10,coalesce(target_page_size,75)));offset_rows integer:=greatest(0,(coalesce(target_page,1)-1)*least(100,greatest(10,coalesce(target_page_size,75))));
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501'; end if;
  select id into pipeline_uuid from public.crm_pipelines where company_id=context_row.company_id and status='active' and (id=target_pipeline_id or target_pipeline_id is null and is_default) order by is_default desc,position limit 1;
  if pipeline_uuid is null then select id into pipeline_uuid from public.crm_pipelines where company_id=context_row.company_id and status='active' order by position limit 1; end if;
  with scoped as(
    select opportunity.*,client.legal_name,client.trade_name,client.first_name,client.last_name,client.relationship_type,
      stage.name stage_name,stage.color stage_color,stage.stage_type,source.name source_name,
      coalesce(opportunity.actual_amount,opportunity.amount,0)*coalesce(opportunity.probability,0)/100 weighted_amount,
      extract(day from now()-coalesce(opportunity.stage_entered_at,opportunity.created_at))::integer days_in_stage,
      (select jsonb_build_object('id',activity.id,'subject',activity.subject,'due_at',coalesce(activity.due_at,activity.scheduled_at),'type',activity.activity_type)
       from public.activities activity where activity.company_id=opportunity.company_id and activity.opportunity_id=opportunity.id and activity.status in('todo','in_progress','postponed') order by coalesce(activity.due_at,activity.scheduled_at) nulls last limit 1) next_activity,
      (select count(*) from public.documents document where document.company_id=opportunity.company_id and document.opportunity_id=opportunity.id and document.document_type='quote') quote_count,
      row_number() over(partition by opportunity.pipeline_stage_id order by opportunity.expected_close_date nulls last,opportunity.amount desc,opportunity.created_at desc) stage_row,
      count(*) over() total_count
    from public.opportunities opportunity
    left join public.clients client on client.id=opportunity.client_id and client.company_id=opportunity.company_id
    left join public.pipeline_stages stage on stage.id=opportunity.pipeline_stage_id
    left join public.crm_sources source on source.id=opportunity.source_id
    where opportunity.company_id=context_row.company_id and opportunity.pipeline_id=pipeline_uuid and opportunity.archived_at is null
      and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid() or opportunity.owner_user_id=auth.uid() or auth.uid()=any(opportunity.collaborator_user_ids))
      and (nullif(trim(target_search),'') is null or to_tsvector('simple',coalesce(opportunity.name,'')||' '||coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')) @@ plainto_tsquery('simple',trim(target_search)))
      and (coalesce(target_filters->>'owner','')='' or opportunity.assigned_user_id=(target_filters->>'owner')::uuid)
      and (coalesce(target_filters->>'priority','')='' or opportunity.priority=target_filters->>'priority')
      and (coalesce(target_filters->>'forecast','')='' or opportunity.forecast_category=target_filters->>'forecast')
  ), paged as(select * from scoped where stage_row<=page_size order by stage_name,expected_close_date nulls last,amount desc offset offset_rows limit page_size*20)
  select jsonb_build_object(
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,'write',context_row.can_write,'margin',context_row.can_margin),
    'pipelines',coalesce((select jsonb_agg(to_jsonb(pipeline) order by pipeline.position,pipeline.name) from public.crm_pipelines pipeline where pipeline.company_id=context_row.company_id and pipeline.status<>'archived'),'[]'::jsonb),
    'pipeline',(select to_jsonb(pipeline) from public.crm_pipelines pipeline where pipeline.id=pipeline_uuid),
    'stages',coalesce((select jsonb_agg(to_jsonb(stage) order by stage.position,stage.id) from public.pipeline_stages stage where stage.company_id=context_row.company_id and stage.pipeline_id=pipeline_uuid and stage.active),'[]'::jsonb),
    'opportunities',coalesce((select jsonb_agg(to_jsonb(paged)-'stage_row'-'total_count' order by expected_close_date nulls last,amount desc) from paged),'[]'::jsonb),
    'summary',jsonb_build_object(
      'open_count',(select count(*) from scoped where stage_type='open'),
      'total_amount',coalesce((select round(sum(coalesce(amount,0)),2) from scoped where stage_type='open'),0),
      'weighted_amount',coalesce((select round(sum(weighted_amount),2) from scoped where stage_type='open'),0),
      'closing_this_month',(select count(*) from scoped where stage_type='open' and expected_close_date>=date_trunc('month',current_date)::date and expected_close_date<(date_trunc('month',current_date)+interval '1 month')::date),
      'overdue',(select count(*) from scoped where stage_type='open' and expected_close_date<current_date),
      'total_count',coalesce((select max(total_count) from scoped),0)
    )
  ) into result;
  return result;
end
$$;

create or replace function public.get_crm_prospect_directory(target_search text default null,target_status text default null,target_owner uuid default null,target_page integer default 1,target_page_size integer default 50)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result jsonb;page_size integer:=least(100,greatest(10,coalesce(target_page_size,50)));offset_rows integer:=greatest(0,(coalesce(target_page,1)-1)*least(100,greatest(10,coalesce(target_page_size,50))));
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  with scoped as(
    select client.*,source.name source_name,
      (select count(*) from public.opportunities opportunity where opportunity.company_id=client.company_id and opportunity.client_id=client.id and opportunity.archived_at is null) opportunity_count,
      (select coalesce(sum(opportunity.amount),0) from public.opportunities opportunity where opportunity.company_id=client.company_id and opportunity.client_id=client.id and opportunity.archived_at is null) potential_amount,
      (select jsonb_build_object('id',activity.id,'subject',activity.subject,'due_at',coalesce(activity.due_at,activity.scheduled_at),'type',activity.activity_type) from public.activities activity where activity.company_id=client.company_id and activity.client_id=client.id and activity.status in('todo','in_progress','postponed') order by coalesce(activity.due_at,activity.scheduled_at) nulls last limit 1) next_activity,
      count(*) over() total_count
    from public.clients client left join public.crm_sources source on source.id=client.crm_source_id
    where client.company_id=context_row.company_id and client.relationship_type='prospect' and client.active
      and (context_row.can_view_all or client.assigned_user_id=auth.uid())
      and (target_status is null or target_status='' or client.crm_status=target_status)
      and (target_owner is null or client.assigned_user_id=target_owner)
      and (nullif(trim(target_search),'') is null or to_tsvector('simple',coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')||' '||coalesce(client.first_name,'')||' '||coalesce(client.last_name,'')||' '||coalesce(client.email,'')) @@ plainto_tsquery('simple',trim(target_search)))
  ),paged as(select * from scoped order by crm_score desc,created_at desc offset offset_rows limit page_size)
  select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(paged)-'total_count' order by crm_score desc,created_at desc),'[]'::jsonb),'total',coalesce(max(total_count),0),'page',greatest(1,coalesce(target_page,1)),'page_size',page_size,
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,'write',context_row.can_write)) into result from paged;
  return result;
end
$$;

create or replace function public.get_crm_activity_workspace(target_view text default 'list',target_filter text default 'upcoming',target_owner uuid default null,target_start date default null,target_end date default null,target_page integer default 1,target_page_size integer default 80)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result jsonb;date_start date:=coalesce(target_start,current_date-30);date_end date:=coalesce(target_end,current_date+60);page_size integer:=least(100,greatest(10,coalesce(target_page_size,80)));
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  with scoped as(
    select activity.*,client.legal_name,client.trade_name,client.first_name,client.last_name,opportunity.name opportunity_name,count(*) over() total_count
    from public.activities activity left join public.clients client on client.id=activity.client_id left join public.opportunities opportunity on opportunity.id=activity.opportunity_id
    where activity.company_id=context_row.company_id and (context_row.can_view_all or activity.assigned_user_id=auth.uid())
      and (target_owner is null or activity.assigned_user_id=target_owner)
      and coalesce(activity.due_at,activity.scheduled_at,activity.created_at)::date between date_start and date_end
      and case target_filter when 'today' then coalesce(activity.due_at,activity.scheduled_at)::date=current_date
        when 'overdue' then activity.status not in('completed','cancelled') and coalesce(activity.due_at,activity.scheduled_at)<now()
        when 'completed' then activity.status='completed'
        when 'without_next' then activity.status='completed' and nullif(activity.next_action,'') is null
        else activity.status not in('completed','cancelled') end
  ),paged as(select * from scoped order by coalesce(due_at,scheduled_at,created_at) offset greatest(0,(coalesce(target_page,1)-1)*page_size) limit page_size)
  select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(paged)-'total_count' order by coalesce(due_at,scheduled_at,created_at)),'[]'::jsonb),'total',coalesce(max(total_count),0),'view',target_view,'filter',target_filter,
    'permissions',jsonb_build_object('view_all',context_row.can_view_all,'write',context_row.can_write)) into result from paged;
  return result;
end
$$;

create or replace function public.get_crm_opportunity_detail(target_opportunity_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity_row public.opportunities%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into opportunity_row from public.opportunities opportunity
  where opportunity.id=target_opportunity_id and opportunity.company_id=context_row.company_id
    and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid() or opportunity.owner_user_id=auth.uid() or auth.uid()=any(opportunity.collaborator_user_ids));
  if opportunity_row.id is null then raise exception 'crm_opportunity_not_found' using errcode='P0002'; end if;
  return jsonb_build_object(
    'opportunity',to_jsonb(opportunity_row),
    'client',(select to_jsonb(client) from public.clients client where client.id=opportunity_row.client_id),
    'contact',(select to_jsonb(contact) from public.client_contacts contact where contact.id=opportunity_row.primary_contact_id),
    'pipeline',(select to_jsonb(pipeline) from public.crm_pipelines pipeline where pipeline.id=opportunity_row.pipeline_id),
    'stage',(select to_jsonb(stage) from public.pipeline_stages stage where stage.id=opportunity_row.pipeline_stage_id),
    'source',(select to_jsonb(source) from public.crm_sources source where source.id=opportunity_row.source_id),
    'products',coalesce((select jsonb_agg(to_jsonb(row) order by position,id) from public.crm_opportunity_products row where row.company_id=context_row.company_id and row.opportunity_id=opportunity_row.id),'[]'::jsonb),
    'activities',coalesce((select jsonb_agg(to_jsonb(row) order by coalesce(due_at,scheduled_at,created_at) desc) from public.activities row where row.company_id=context_row.company_id and row.opportunity_id=opportunity_row.id),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(row) order by created_at desc) from public.documents row where row.company_id=context_row.company_id and row.opportunity_id=opportunity_row.id),'[]'::jsonb),
    'notes',coalesce((select jsonb_agg(to_jsonb(row)||jsonb_build_object('title',case when row.is_pinned then 'Note épinglée' else 'Note' end,'content',row.body) order by row.is_pinned desc,row.created_at desc) from public.crm_notes row where row.company_id=context_row.company_id and row.entity_type='opportunity' and row.entity_id=opportunity_row.id),'[]'::jsonb),
    'timeline',coalesce((select jsonb_agg(to_jsonb(row) order by occurred_at desc,created_at desc) from public.crm_timeline_events row where row.company_id=context_row.company_id and (row.entity_type='opportunity' and row.entity_id=opportunity_row.id or row.related_type='opportunity' and row.related_id=opportunity_row.id) limit 200),'[]'::jsonb),
    'tags',coalesce((select jsonb_agg(to_jsonb(tag) order by tag.name) from public.crm_tag_assignments assignment join public.crm_tags tag on tag.id=assignment.tag_id where assignment.company_id=context_row.company_id and assignment.entity_type='opportunity' and assignment.entity_id=opportunity_row.id),'[]'::jsonb),
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,'write',context_row.can_write,'margin',context_row.can_margin)
  );
end
$$;

create or replace function public.get_crm_prospect_detail(target_prospect_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;prospect_row public.clients%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into prospect_row from public.clients prospect where prospect.id=target_prospect_id and prospect.company_id=context_row.company_id
    and prospect.relationship_type in('prospect','archived') and (context_row.can_view_all or prospect.assigned_user_id=auth.uid());
  if prospect_row.id is null then raise exception 'crm_prospect_not_found' using errcode='P0002'; end if;
  return jsonb_build_object(
    'prospect',to_jsonb(prospect_row),
    'source',(select to_jsonb(source) from public.crm_sources source where source.id=prospect_row.crm_source_id),
    'contacts',coalesce((select jsonb_agg(to_jsonb(row) order by is_primary desc,created_at) from public.client_contacts row where row.company_id=context_row.company_id and row.client_id=prospect_row.id),'[]'::jsonb),
    'opportunities',coalesce((select jsonb_agg(to_jsonb(row) order by created_at desc) from public.opportunities row where row.company_id=context_row.company_id and row.client_id=prospect_row.id and row.archived_at is null),'[]'::jsonb),
    'activities',coalesce((select jsonb_agg(to_jsonb(row) order by coalesce(due_at,scheduled_at,created_at) desc) from public.activities row where row.company_id=context_row.company_id and row.client_id=prospect_row.id),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(row) order by created_at desc) from public.documents row where row.company_id=context_row.company_id and row.client_id=prospect_row.id),'[]'::jsonb),
    'score_history',coalesce((select jsonb_agg(to_jsonb(row) order by created_at desc) from public.crm_score_history row where row.company_id=context_row.company_id and row.entity_type='prospect' and row.entity_id=prospect_row.id limit 100),'[]'::jsonb),
    'timeline',coalesce((select jsonb_agg(to_jsonb(row) order by occurred_at desc,created_at desc) from public.crm_timeline_events row where row.company_id=context_row.company_id and (row.entity_type='prospect' and row.entity_id=prospect_row.id or row.related_type='prospect' and row.related_id=prospect_row.id) limit 200),'[]'::jsonb),
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,'write',context_row.can_write,'margin',context_row.can_margin)
  );
end
$$;

create or replace function public.get_crm_configuration()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  return jsonb_build_object(
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,'write',context_row.can_write,'margin',context_row.can_margin),
    'pipelines',coalesce((select jsonb_agg(to_jsonb(row) order by position,name) from public.crm_pipelines row where row.company_id=context_row.company_id and status<>'archived'),'[]'::jsonb),
    'stages',coalesce((select jsonb_agg(to_jsonb(stage) order by pipeline.position,stage.position,stage.name) from public.pipeline_stages stage join public.crm_pipelines pipeline on pipeline.id=stage.pipeline_id where stage.company_id=context_row.company_id and stage.active and pipeline.status<>'archived'),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(to_jsonb(row) order by position,name) from public.crm_sources row where row.company_id=context_row.company_id and is_active),'[]'::jsonb),
    'loss_reasons',coalesce((select jsonb_agg(to_jsonb(row) order by position,name) from public.crm_loss_reasons row where row.company_id=context_row.company_id and is_active),'[]'::jsonb),
    'tags',coalesce((select jsonb_agg(to_jsonb(row) order by name) from public.crm_tags row where row.company_id=context_row.company_id and is_active),'[]'::jsonb),
    'automations',coalesce((select jsonb_agg(to_jsonb(row) order by position,name) from public.crm_automation_rules row where row.company_id=context_row.company_id and status<>'archived'),'[]'::jsonb),
    'automation_runs',coalesce((select jsonb_agg(jsonb_build_object(
      'id',run.id,'rule_id',run.rule_id,'entity_type',run.entity_type,'entity_id',run.entity_id,
      'status',run.status,'attempt',run.attempt,'error_code',run.error_code,
      'error_message',case when context_row.can_manage then run.error_message else null end,
      'started_at',run.started_at,'finished_at',run.finished_at,'created_at',run.created_at
    ) order by run.created_at desc) from(select * from public.crm_automation_runs where company_id=context_row.company_id order by created_at desc limit 50)run),'[]'::jsonb),
    'sequences',coalesce((select jsonb_agg(to_jsonb(row) order by name) from public.crm_sequences row where row.company_id=context_row.company_id and status<>'archived'),'[]'::jsonb)
  );
end
$$;

create or replace function public.get_crm_forecast(target_start date default date_trunc('month',current_date)::date,target_end date default (date_trunc('month',current_date)+interval '1 month - 1 day')::date,target_pipeline_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  return jsonb_build_object('start',target_start,'end',target_end,
    'buckets',coalesce((select jsonb_agg(jsonb_build_object('category',forecast_category,'count',count,'amount',amount,'weighted',weighted) order by array_position(array['commit','probable','potential','unqualified','won','lost'],forecast_category)) from(
      select forecast_category,count(*) count,round(sum(coalesce(actual_amount,amount,0)),2) amount,round(sum(coalesce(actual_amount,amount,0)*coalesce(probability,0)/100),2) weighted
      from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.archived_at is null and opportunity.expected_close_date between target_start and target_end and (target_pipeline_id is null or opportunity.pipeline_id=target_pipeline_id) and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid()) group by forecast_category
    )bucket),'[]'::jsonb));
end
$$;

create or replace function public.get_crm_priority_actions(target_limit integer default 12)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  return coalesce((with actions as(
    select 100 priority,'overdue_activity' kind,activity.id,activity.subject title,'Activité en retard' detail,coalesce(activity.due_at,activity.scheduled_at) action_date,0::numeric impact,activity.assigned_user_id
    from public.activities activity where activity.company_id=context_row.company_id and activity.status not in('completed','cancelled') and coalesce(activity.due_at,activity.scheduled_at)<now() and (context_row.can_view_all or activity.assigned_user_id=auth.uid())
    union all
    select 80,'stale_opportunity',opportunity.id,opportunity.name,'Aucune activité récente',coalesce(opportunity.next_action_at,opportunity.expected_close_date::timestamptz),coalesce(opportunity.amount,0),opportunity.assigned_user_id
    from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.archived_at is null and opportunity.closed_at is null and opportunity.updated_at<now()-interval '14 days' and not exists(select 1 from public.activities activity where activity.opportunity_id=opportunity.id and activity.created_at>now()-interval '14 days') and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid())
    union all
    select 70,'hot_prospect',client.id,coalesce(client.legal_name,client.trade_name,client.first_name||' '||client.last_name),'Prospect chaud sans prochaine action',client.next_activity_at,0,client.assigned_user_id
    from public.clients client where client.company_id=context_row.company_id and client.relationship_type='prospect' and client.active and client.crm_score_label in('hot','priority') and client.next_activity_at is null and (context_row.can_view_all or client.assigned_user_id=auth.uid())
  ) select jsonb_agg(jsonb_build_object('priority',priority,'kind',kind,'id',id,'title',title,'detail',detail,'date',action_date,'impact',impact,'assigned_user_id',assigned_user_id,'can_write',context_row.can_write,'tone',case when priority>=100 then 'danger' when priority>=80 then 'warning' else 'info' end) order by priority desc,action_date nulls last) from(select * from actions order by priority desc,action_date nulls last limit least(50,greatest(1,target_limit)))limited),'[]'::jsonb);
end
$$;

create or replace function public.get_crm_reports(target_start date default date_trunc('month',current_date)::date,target_end date default current_date,target_pipeline_id uuid default null,target_owner uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  return jsonb_build_object(
    'period',jsonb_build_object('start',target_start,'end',target_end),
    'pipeline',coalesce((select jsonb_agg(jsonb_build_object('stage_id',stage.id,'stage',stage.name,'color',stage.color,'count',coalesce(stats.count,0),'amount',coalesce(stats.amount,0),'weighted',coalesce(stats.weighted,0)) order by stage.position) from public.pipeline_stages stage left join lateral(
      select count(*) count,round(sum(coalesce(opportunity.amount,0)),2) amount,round(sum(coalesce(opportunity.amount,0)*coalesce(opportunity.probability,0)/100),2) weighted from public.opportunities opportunity where opportunity.pipeline_stage_id=stage.id and opportunity.archived_at is null and (target_owner is null or opportunity.assigned_user_id=target_owner) and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid())
    )stats on true where stage.company_id=context_row.company_id and (target_pipeline_id is null or stage.pipeline_id=target_pipeline_id) and stage.active),'[]'::jsonb),
    'outcomes',jsonb_build_object(
      'won_count',(select count(*) from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.won_at::date between target_start and target_end and (target_pipeline_id is null or opportunity.pipeline_id=target_pipeline_id) and (target_owner is null or opportunity.assigned_user_id=target_owner) and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid())),
      'won_amount',coalesce((select round(sum(coalesce(actual_amount,amount,0)),2) from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.won_at::date between target_start and target_end and (target_pipeline_id is null or opportunity.pipeline_id=target_pipeline_id) and (target_owner is null or opportunity.assigned_user_id=target_owner) and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid())),0),
      'lost_count',(select count(*) from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.lost_at::date between target_start and target_end and (target_pipeline_id is null or opportunity.pipeline_id=target_pipeline_id) and (target_owner is null or opportunity.assigned_user_id=target_owner) and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid())),
      'conversion_rate',(select round(100.0*count(*) filter(where won_at is not null)/nullif(count(*) filter(where won_at is not null or lost_at is not null),0),1) from public.opportunities opportunity where opportunity.company_id=context_row.company_id and coalesce(opportunity.closed_at::date,opportunity.created_at::date) between target_start and target_end and (target_pipeline_id is null or opportunity.pipeline_id=target_pipeline_id) and (target_owner is null or opportunity.assigned_user_id=target_owner) and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid()))
    ),
    'loss_reasons',coalesce((select jsonb_agg(jsonb_build_object('reason',coalesce(reason.name,opportunity.lost_reason,'Autre'),'count',count) order by count desc) from(select lost_reason_id,lost_reason,count(*) count from public.opportunities where company_id=context_row.company_id and lost_at::date between target_start and target_end and (target_pipeline_id is null or pipeline_id=target_pipeline_id) and (target_owner is null or assigned_user_id=target_owner) and (context_row.can_view_all or assigned_user_id=auth.uid()) group by lost_reason_id,lost_reason)opportunity left join public.crm_loss_reasons reason on reason.id=opportunity.lost_reason_id),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(jsonb_build_object('source',coalesce(source.name,'Non renseignée'),'opportunities',stats.count,'won',stats.won,'amount',stats.amount) order by stats.amount desc) from(select source_id,count(*) count,count(*) filter(where won_at is not null) won,round(sum(coalesce(actual_amount,amount,0)) filter(where won_at is not null),2) amount from public.opportunities where company_id=context_row.company_id and created_at::date between target_start and target_end and (target_pipeline_id is null or pipeline_id=target_pipeline_id) and (target_owner is null or assigned_user_id=target_owner) and (context_row.can_view_all or assigned_user_id=auth.uid()) group by source_id)stats left join public.crm_sources source on source.id=stats.source_id),'[]'::jsonb),
    'activities',jsonb_build_object('completed',(select count(*) from public.activities where company_id=context_row.company_id and completed_at::date between target_start and target_end and (context_row.can_view_all or assigned_user_id=auth.uid())),'overdue',(select count(*) from public.activities where company_id=context_row.company_id and status not in('completed','cancelled') and coalesce(due_at,scheduled_at)<now() and (context_row.can_view_all or assigned_user_id=auth.uid())))
  );
end
$$;

create or replace function public.get_crm_dashboard_summary()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501';end if;
  return jsonb_build_object(
    'pipeline_total',coalesce((select round(sum(coalesce(amount,0)),2) from public.opportunities where company_id=context_row.company_id and archived_at is null and closed_at is null and (context_row.can_view_all or assigned_user_id=auth.uid())),0),
    'pipeline_weighted',coalesce((select round(sum(coalesce(amount,0)*coalesce(probability,0)/100),2) from public.opportunities where company_id=context_row.company_id and archived_at is null and closed_at is null and (context_row.can_view_all or assigned_user_id=auth.uid())),0),
    'open_opportunities',(select count(*) from public.opportunities where company_id=context_row.company_id and archived_at is null and closed_at is null and (context_row.can_view_all or assigned_user_id=auth.uid())),
    'closing_this_month',(select count(*) from public.opportunities where company_id=context_row.company_id and archived_at is null and closed_at is null and expected_close_date>=date_trunc('month',current_date)::date and expected_close_date<(date_trunc('month',current_date)+interval '1 month')::date and (context_row.can_view_all or assigned_user_id=auth.uid())),
    'priorities',public.get_crm_priority_actions(6),
    'forecast',public.get_crm_forecast(date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month - 1 day')::date,null),
    'stages',coalesce((select jsonb_agg(jsonb_build_object('id',stage.id,'name',stage.name,'color',stage.color,'count',stats.count,'amount',stats.amount,'weighted',stats.weighted) order by stage.position) from public.pipeline_stages stage join public.crm_pipelines pipeline on pipeline.id=stage.pipeline_id and pipeline.is_default left join lateral(select count(*) count,coalesce(round(sum(opportunity.amount),2),0) amount,coalesce(round(sum(opportunity.amount*opportunity.probability/100),2),0) weighted from public.opportunities opportunity where opportunity.pipeline_stage_id=stage.id and opportunity.archived_at is null and (context_row.can_view_all or opportunity.assigned_user_id=auth.uid()))stats on true where stage.company_id=context_row.company_id and stage.active),'[]'::jsonb)
  );
end
$$;

create or replace function public.get_dashboard_command_center(period_key text default 'current_month',custom_start date default null,custom_end date default null,comparison_mode text default 'previous')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare base jsonb;crm jsonb;
begin
  base:=public.get_dashboard_cockpit(period_key,custom_start,custom_end,comparison_mode);
  crm:=public.get_crm_dashboard_summary();
  return base||jsonb_build_object('crm',crm,'priority_actions',coalesce(base->'priority_actions','[]'::jsonb)||coalesce(crm->'priorities','[]'::jsonb));
end
$$;

-- Chronologie unifiée alimentée par les changements réellement observés.
create or replace function public.log_crm_entity_timeline()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare row_value jsonb:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;previous jsonb:=case when tg_op='UPDATE' then to_jsonb(old) else null end;cid uuid;eid uuid;event_name text;entity_name text;
begin
  cid:=(row_value->>'company_id')::uuid;eid:=(row_value->>'id')::uuid;
  if tg_table_name='opportunities' then entity_name:='opportunity';event_name:=case when tg_op='INSERT' then 'opportunity_created' when tg_op='DELETE' then 'opportunity_deleted' when previous->>'assigned_user_id' is distinct from row_value->>'assigned_user_id' then 'owner_changed' else 'opportunity_updated' end;
  elsif tg_table_name='activities' then entity_name:='activity';event_name:=case when tg_op='INSERT' then 'activity_created' when row_value->>'status'='completed' and previous->>'status' is distinct from 'completed' then 'activity_completed' else 'activity_updated' end;
  else return case when tg_op='DELETE' then old else new end;end if;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,actor_user_id,created_by)
  values(cid,entity_name,eid,event_name,replace(initcap(replace(event_name,'_',' ')),'Crm ',''),coalesce(row_value->>'name',row_value->>'subject'),jsonb_build_object('operation',tg_op),auth.uid(),coalesce(auth.uid(),(row_value->>'created_by')::uuid));
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists opportunities_crm_timeline on public.opportunities;
drop trigger if exists activities_crm_timeline on public.activities;
create trigger opportunities_crm_timeline after insert or update or delete on public.opportunities for each row execute function public.log_crm_entity_timeline();
create trigger activities_crm_timeline after insert or update or delete on public.activities for each row execute function public.log_crm_entity_timeline();

create or replace function public.sync_crm_activity_rollup()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.client_id is not null then
    update public.clients set
      crm_last_activity_at=(select max(coalesce(completed_at,scheduled_at,created_at)) from public.activities where company_id=new.company_id and client_id=new.client_id and (status='completed' or completed_at is not null)),
      next_activity_at=(select min(coalesce(due_at,scheduled_at)) from public.activities where company_id=new.company_id and client_id=new.client_id and status in('todo','in_progress','postponed') and coalesce(due_at,scheduled_at)>=now()),updated_at=now()
    where id=new.client_id and company_id=new.company_id;
  end if;
  return new;
end
$$;
drop trigger if exists activities_crm_rollup on public.activities;
create trigger activities_crm_rollup after insert or update of status,due_at,scheduled_at,completed_at on public.activities for each row execute function public.sync_crm_activity_rollup();

-- Exécution synchrone des règles simples. Chaque événement possède une clé
-- d'idempotence ; une action externe (e-mail) est explicitement ignorée tant
-- qu'aucun connecteur n'a confirmé l'envoi.
alter table public.crm_automation_runs add column if not exists idempotency_key text;
create unique index if not exists crm_automation_runs_idempotency_idx
  on public.crm_automation_runs(company_id,idempotency_key) where idempotency_key is not null;

create or replace function public.run_crm_automation_event()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare
  row_value jsonb:=to_jsonb(new);previous_value jsonb:=case when tg_op='UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  company_uuid uuid:=(to_jsonb(new)->>'company_id')::uuid;entity_uuid uuid:=(to_jsonb(new)->>'id')::uuid;
  entity_name text;trigger_name text;rule public.crm_automation_rules%rowtype;action_value jsonb;
  event_key text;run_uuid uuid;actor_uuid uuid;skipped_external boolean:=false;
begin
  if tg_table_name='opportunities' then
    entity_name:='opportunity';
    if tg_op='INSERT' then trigger_name:='opportunity_created';
    elsif new.forecast_category='won' and old.forecast_category is distinct from 'won' then trigger_name:='opportunity_won';
    elsif new.forecast_category='lost' and old.forecast_category is distinct from 'lost' then trigger_name:='opportunity_lost';
    elsif new.pipeline_stage_id is distinct from old.pipeline_stage_id then trigger_name:='opportunity_stage_changed';
    end if;
  elsif tg_table_name='activities' then
    entity_name:='activity';
    if tg_op='UPDATE' and new.status='completed' and old.status is distinct from 'completed' then trigger_name:='activity_completed'; end if;
  elsif tg_table_name='documents' then
    entity_name:='document';
    if tg_op='UPDATE' and new.document_type='quote' and new.status='accepted' and old.status is distinct from 'accepted' then trigger_name:='quote_accepted';
    elsif tg_op='UPDATE' and new.document_type in('invoice','deposit_invoice','progress_invoice') and new.status in('paid','collected') and old.status is distinct from new.status then trigger_name:='invoice_paid';
    end if;
  end if;
  if trigger_name is null then return new; end if;
  select coalesce(auth.uid(),company.owner_user_id) into actor_uuid from public.companies company where company.id=company_uuid;

  for rule in select * from public.crm_automation_rules automation
    where automation.company_id=company_uuid and automation.status='active' and automation.trigger_type=trigger_name
    order by automation.position,automation.id
  loop
    if coalesce(rule.trigger_config->>'stage_id','')<>'' and coalesce(row_value->>'pipeline_stage_id','')<>rule.trigger_config->>'stage_id' then continue; end if;
    event_key:=md5(rule.id::text||':'||entity_name||':'||entity_uuid::text||':'||trigger_name||':'||coalesce(row_value->>'updated_at',row_value->>'created_at',clock_timestamp()::text));
    run_uuid:=null;
    insert into public.crm_automation_runs(company_id,rule_id,entity_type,entity_id,status,input,idempotency_key,created_by,started_at)
    values(company_uuid,rule.id,entity_name,entity_uuid,'running',jsonb_build_object('trigger',trigger_name,'row',row_value,'previous',previous_value),event_key,actor_uuid,now())
    on conflict do nothing returning id into run_uuid;
    if run_uuid is null then continue; end if;
    skipped_external:=false;
    begin
      for action_value in select value from jsonb_array_elements(coalesce(rule.actions,'[]'::jsonb)) loop
        if action_value->>'type'='create_activity' then
          insert into public.activities(company_id,opportunity_id,client_id,activity_type,subject,due_at,priority,status,assigned_user_id,metadata,created_by,updated_by)
          values(company_uuid,case when entity_name='opportunity' then entity_uuid else null end,
            case when entity_name='opportunity' then nullif(row_value->>'client_id','')::uuid when entity_name='activity' then nullif(row_value->>'client_id','')::uuid else null end,
            coalesce(nullif(action_value->>'activity_type',''),'task'),coalesce(nullif(action_value->>'subject',''),rule.name),
            now()+make_interval(days=>coalesce(nullif(action_value->>'due_days','')::integer,1)),coalesce(nullif(action_value->>'priority',''),'normal'),'todo',
            coalesce(nullif(action_value->>'assigned_user_id','')::uuid,nullif(row_value->>'assigned_user_id','')::uuid,actor_uuid),
            jsonb_build_object('automation_rule_id',rule.id,'automation_run_id',run_uuid),actor_uuid,actor_uuid);
        elsif action_value->>'type'='notify_user' then
          insert into public.notifications(company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by)
          values(company_uuid,coalesce(nullif(action_value->>'user_id','')::uuid,nullif(row_value->>'assigned_user_id','')::uuid,actor_uuid),'crm_automation',
            coalesce(nullif(action_value->>'title',''),rule.name),nullif(action_value->>'message',''),entity_name,entity_uuid,
            case when entity_name='opportunity' then '#crm/pipeline/'||entity_uuid::text else '#crm/activities' end,
            jsonb_build_object('automation_rule_id',rule.id,'automation_run_id',run_uuid),actor_uuid);
        elsif action_value->>'type'='update_field' and entity_name='opportunity' and action_value->>'field' in('priority','next_action','health','forecast_category') then
          execute format('update public.opportunities set %I=$1,updated_by=$2,updated_at=now() where id=$3 and company_id=$4',action_value->>'field')
          using action_value->>'value',actor_uuid,entity_uuid,company_uuid;
        elsif action_value->>'type'='send_email' then
          skipped_external:=true;
        end if;
      end loop;
      update public.crm_automation_runs set status='completed',output=jsonb_build_object('external_connector_required',skipped_external),finished_at=now() where id=run_uuid;
      update public.crm_automation_rules set last_run_at=now(),run_count=run_count+1,updated_at=now() where id=rule.id;
    exception when others then
      update public.crm_automation_runs set status='failed',error_code=sqlstate,error_message=left(sqlerrm,1000),finished_at=now() where id=run_uuid;
    end;
  end loop;
  return new;
end
$$;
drop trigger if exists opportunities_crm_automations on public.opportunities;
drop trigger if exists activities_crm_automations on public.activities;
drop trigger if exists documents_crm_automations on public.documents;
create trigger opportunities_crm_automations after insert or update of pipeline_stage_id,forecast_category on public.opportunities for each row execute function public.run_crm_automation_event();
create trigger activities_crm_automations after update of status on public.activities for each row execute function public.run_crm_automation_event();
create trigger documents_crm_automations after update of status on public.documents for each row execute function public.run_crm_automation_event();

-- Permissions : les historiques append-only ne sont lisibles que via RLS ou les RPC.
grant select,insert,update,delete on public.crm_pipelines,public.crm_sources,public.crm_loss_reasons,
  public.crm_opportunity_products,public.crm_activity_participants,public.crm_activity_links,public.crm_notes,
  public.crm_tags,public.crm_tag_assignments,public.crm_custom_fields,public.crm_custom_field_values,
  public.crm_automation_rules,public.crm_sequences,public.crm_sequence_steps,public.crm_sequence_enrollments,
  public.crm_saved_views,public.crm_segments,public.crm_score_rules,public.company_dashboard_defaults to authenticated;
grant select on public.crm_automation_runs,public.crm_score_history,public.crm_timeline_events to authenticated;
grant select(crm_status,crm_score,crm_score_label,crm_score_override,crm_score_override_reason,crm_source_id,crm_conversion_source_id,assigned_user_id,crm_last_activity_at,next_activity_at,converted_at,converted_from_prospect_id,crm_tags_cache) on public.clients to authenticated;
grant select(pipeline_id,pipeline_stage_id,source_id,primary_contact_id,forecast_category,opportunity_type,score,actual_amount,recurring_amount,recurrence,competitors,won_at,lost_at,lost_reason_id,success_reason,close_comment,reopened_at,next_action,updated_by) on public.opportunities to authenticated;
grant select(contact_id,location,meeting_url,external_calendar,external_event_id,recurrence_rule,outcome_code,next_action) on public.activities to authenticated;

revoke all on function public._crm_context() from public,anon;
revoke all on function public._crm_seed_company(uuid,uuid) from public,anon,authenticated;
revoke all on function public.run_crm_automation_event() from public,anon,authenticated;
revoke all on function public.create_crm_pipeline(text,text,text,text) from public,anon;
revoke all on function public.duplicate_crm_pipeline(uuid,text) from public,anon;
revoke all on function public.create_crm_prospect(jsonb) from public,anon;
revoke all on function public.convert_crm_prospect(uuid,uuid) from public,anon;
revoke all on function public.create_crm_opportunity(jsonb) from public,anon;
revoke all on function public.move_crm_opportunity(uuid,uuid) from public,anon;
revoke all on function public.close_crm_opportunity(uuid,text,numeric,uuid,text,timestamptz) from public,anon;
revoke all on function public.create_crm_activity(jsonb) from public,anon;
revoke all on function public.complete_crm_activity(uuid,text,text) from public,anon;
revoke all on function public.recalculate_crm_score(uuid,text) from public,anon;
revoke all on function public.get_crm_pipeline_workspace(uuid,text,jsonb,integer,integer) from public,anon;
revoke all on function public.get_crm_prospect_directory(text,text,uuid,integer,integer) from public,anon;
revoke all on function public.get_crm_activity_workspace(text,text,uuid,date,date,integer,integer) from public,anon;
revoke all on function public.get_crm_opportunity_detail(uuid) from public,anon;
revoke all on function public.get_crm_prospect_detail(uuid) from public,anon;
revoke all on function public.get_crm_configuration() from public,anon;
revoke all on function public.get_crm_forecast(date,date,uuid) from public,anon;
revoke all on function public.get_crm_priority_actions(integer) from public,anon;
revoke all on function public.get_crm_reports(date,date,uuid,uuid) from public,anon;
revoke all on function public.get_crm_dashboard_summary() from public,anon;
revoke all on function public.get_dashboard_command_center(text,date,date,text) from public,anon;

grant execute on function public._crm_context() to authenticated;
grant execute on function public.create_crm_pipeline(text,text,text,text),public.duplicate_crm_pipeline(uuid,text),
  public.create_crm_prospect(jsonb),public.convert_crm_prospect(uuid,uuid),public.create_crm_opportunity(jsonb),
  public.move_crm_opportunity(uuid,uuid),public.close_crm_opportunity(uuid,text,numeric,uuid,text,timestamptz),
  public.create_crm_activity(jsonb),public.complete_crm_activity(uuid,text,text),public.recalculate_crm_score(uuid,text),
  public.get_crm_pipeline_workspace(uuid,text,jsonb,integer,integer),public.get_crm_prospect_directory(text,text,uuid,integer,integer),
  public.get_crm_activity_workspace(text,text,uuid,date,date,integer,integer),public.get_crm_opportunity_detail(uuid),public.get_crm_prospect_detail(uuid),public.get_crm_configuration(),
  public.get_crm_forecast(date,date,uuid),public.get_crm_priority_actions(integer),public.get_crm_reports(date,date,uuid,uuid),
  public.get_crm_dashboard_summary(),public.get_dashboard_command_center(text,date,date,text) to authenticated;

commit;
