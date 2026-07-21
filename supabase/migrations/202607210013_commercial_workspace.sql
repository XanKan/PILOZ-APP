begin;

-- Dossiers commerciaux collaboratifs. Migration strictement additive : les
-- opportunités, documents, activités et paiements existants restent les sources.
-- Ces ajouts idempotents rendent aussi la migration autonome si le complément
-- fonctionnel 010 n'a pas encore été exécuté sur l'environnement hébergé.
alter table public.user_preferences
  add column if not exists first_name text,
  add column if not exists last_name text,
  add column if not exists display_name text;

alter table public.company_settings
  add column if not exists company_type text,
  add column if not exists description text,
  add column if not exists secondary_phone text,
  add column if not exists primary_contact_name text,
  add column if not exists rcs_number text,
  add column if not exists social_capital numeric(15,2),
  add column if not exists registry_court text,
  add column if not exists legal_mentions text,
  add column if not exists vat_frequency text,
  add column if not exists fiscal_year_start text,
  add column if not exists vat_franchise text;

alter table public.company_document_settings
  add column if not exists mandate_reference text;

alter table public.documents add column if not exists sent_at timestamptz;
grant select(sent_at) on public.documents to authenticated;

alter table public.opportunities
  add column if not exists source text,
  add column if not exists need_subject text,
  add column if not exists description text,
  add column if not exists priority text not null default 'normal',
  add column if not exists health text not null default 'watch',
  add column if not exists stage_entered_at timestamptz not null default now(),
  add column if not exists archived_at timestamptz,
  add column if not exists collaborator_user_ids uuid[] not null default '{}';

alter table public.opportunities drop constraint if exists opportunities_priority_check;
alter table public.opportunities add constraint opportunities_priority_check
  check(priority in ('low','normal','high','urgent')) not valid;
alter table public.opportunities drop constraint if exists opportunities_health_check;
alter table public.opportunities add constraint opportunities_health_check
  check(health in ('good','watch','blocked','late','won','lost')) not valid;

alter table public.activities
  add column if not exists document_id uuid references public.documents(id) on delete set null,
  add column if not exists due_at timestamptz,
  add column if not exists duration_minutes integer,
  add column if not exists priority text not null default 'normal',
  add column if not exists status text not null default 'todo',
  add column if not exists reminder_at timestamptz,
  add column if not exists result text,
  add column if not exists comment text,
  add column if not exists updated_by uuid;

alter table public.activities drop constraint if exists activities_activity_type_check;
alter table public.activities add constraint activities_activity_type_check check(activity_type in(
  'call','email','meeting','video','task','note','reminder','demo','quote_followup','other'
)) not valid;
alter table public.activities drop constraint if exists activities_priority_check;
alter table public.activities add constraint activities_priority_check
  check(priority in ('low','normal','high','urgent')) not valid;
alter table public.activities drop constraint if exists activities_status_check;
alter table public.activities add constraint activities_status_check
  check(status in ('todo','in_progress','completed','postponed','cancelled')) not valid;
update public.activities set status='completed' where completed_at is not null and status='todo';

create table if not exists public.opportunity_contacts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  opportunity_id uuid not null references public.opportunities(id) on delete cascade,
  contact_id uuid not null references public.client_contacts(id) on delete cascade,
  role text,
  is_primary boolean not null default false,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(opportunity_id,contact_id)
);

create table if not exists public.opportunity_stage_history(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  opportunity_id uuid not null references public.opportunities(id) on delete cascade,
  from_stage text,
  to_stage text not null,
  changed_at timestamptz not null default now(),
  changed_by uuid default auth.uid(),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.activity_assignments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  user_id uuid not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(activity_id,user_id)
);

create table if not exists public.notifications(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  notification_type text not null,
  title text not null,
  message text,
  entity_type text,
  entity_id uuid,
  action_url text,
  read_at timestamptz,
  dismissed_at timestamptz,
  metadata jsonb not null default '{}',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notification_preferences(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  channels jsonb not null default '{"in_app":true,"email":false}'::jsonb,
  event_preferences jsonb not null default '{}',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,user_id)
);

create table if not exists public.client_preferences(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  payment_method text,
  payment_terms text,
  payment_delay_days integer,
  language text,
  currency text,
  usual_discount_rate numeric(5,2) check(usual_discount_rate between 0 and 100),
  assigned_user_id uuid,
  quote_template_id uuid references public.document_templates(id) on delete set null,
  invoice_template_id uuid references public.document_templates(id) on delete set null,
  preferred_contact_method text,
  marketing_consent boolean,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(client_id)
);

create table if not exists public.reminder_history(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  reminder_id uuid references public.reminders(id) on delete set null,
  document_id uuid references public.documents(id) on delete set null,
  client_id uuid references public.clients(id) on delete set null,
  action text not null,
  subject text,
  message text,
  recipient text,
  scheduled_at timestamptz,
  sent_at timestamptz,
  metadata jsonb not null default '{}',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists opportunity_contacts_company_idx on public.opportunity_contacts(company_id,opportunity_id);
create index if not exists opportunity_stage_history_timeline_idx on public.opportunity_stage_history(company_id,opportunity_id,changed_at desc);
create index if not exists activity_assignments_user_idx on public.activity_assignments(company_id,user_id,activity_id);
create index if not exists notifications_user_unread_idx on public.notifications(company_id,user_id,created_at desc) where read_at is null and dismissed_at is null;
create index if not exists client_preferences_company_idx on public.client_preferences(company_id,client_id);
create index if not exists reminder_history_document_idx on public.reminder_history(company_id,document_id,created_at desc);
create index if not exists opportunities_filters_idx on public.opportunities(company_id,stage,assigned_user_id,expected_close_date) where archived_at is null;
create index if not exists activities_due_idx on public.activities(company_id,status,due_at,assigned_user_id);

do $rls$
declare table_name text;
begin
  foreach table_name in array array['opportunity_contacts','opportunity_stage_history','activity_assignments','client_preferences','reminder_history'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check(public.is_company_member(company_id) and created_by=auth.uid())',table_name||'_insert',table_name);
    execute format('create policy %I on public.%I for update to authenticated using(public.is_company_member(company_id)) with check(public.is_company_member(company_id))',table_name||'_update',table_name);
    execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete',table_name);
  end loop;
end
$rls$;

-- L'historique des étapes est alimenté uniquement par le trigger atomique.
drop policy if exists opportunity_stage_history_insert on public.opportunity_stage_history;
drop policy if exists opportunity_stage_history_update on public.opportunity_stage_history;
drop policy if exists opportunity_stage_history_delete on public.opportunity_stage_history;

alter table public.notifications enable row level security;
drop policy if exists notifications_select_own on public.notifications;
drop policy if exists notifications_update_own on public.notifications;
drop policy if exists notifications_insert_company on public.notifications;
create policy notifications_select_own on public.notifications for select to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid());
create policy notifications_update_own on public.notifications for update to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid())
  with check(public.is_company_member(company_id) and user_id=auth.uid());
create policy notifications_insert_company on public.notifications for insert to authenticated
  with check(
    public.is_company_member(company_id)
    and created_by=auth.uid()
    and exists(select 1 from public.company_members member where member.company_id=notifications.company_id and member.user_id=notifications.user_id)
  );

alter table public.notification_preferences enable row level security;
drop policy if exists notification_preferences_own on public.notification_preferences;
create policy notification_preferences_own on public.notification_preferences for all to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid())
  with check(public.is_company_member(company_id) and user_id=auth.uid() and created_by=auth.uid());

drop policy if exists activity_logs_select_admin on public.activity_logs;
drop policy if exists activity_logs_select_company on public.activity_logs;
create policy activity_logs_select_company on public.activity_logs for select to authenticated
  using(public.is_company_member(company_id));

do $updated$
declare table_name text;
begin
  foreach table_name in array array['opportunity_contacts','activity_assignments','notifications','notification_preferences','client_preferences','reminder_history'] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_set_updated_at',table_name);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
  end loop;
end
$updated$;

create or replace function public.set_opportunity_stage_entered_at()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if old.stage is distinct from new.stage then new.stage_entered_at:=now(); end if;
  return new;
end
$$;
drop trigger if exists opportunities_set_stage_entered_at on public.opportunities;
create trigger opportunities_set_stage_entered_at before update of stage on public.opportunities
for each row execute function public.set_opportunity_stage_entered_at();

create or replace function public.log_opportunity_stage_transition()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' or old.stage is distinct from new.stage then
    insert into public.opportunity_stage_history(company_id,opportunity_id,from_stage,to_stage,changed_by,created_by)
    values(new.company_id,new.id,case when tg_op='UPDATE' then old.stage else null end,new.stage,auth.uid(),coalesce(auth.uid(),new.created_by));
  end if;
  return new;
end
$$;
drop trigger if exists opportunities_stage_transition on public.opportunities;
create trigger opportunities_stage_transition after insert or update of stage on public.opportunities
for each row execute function public.log_opportunity_stage_transition();

create or replace function public.audit_commercial_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare payload jsonb; previous jsonb; cid uuid; eid uuid;
begin
  payload:=case when tg_op='DELETE' then null else to_jsonb(new) end;
  previous:=case when tg_op='INSERT' then null else to_jsonb(old) end;
  cid:=coalesce((payload->>'company_id')::uuid,(previous->>'company_id')::uuid);
  eid:=coalesce((payload->>'id')::uuid,(previous->>'id')::uuid);
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(cid,auth.uid(),lower(tg_table_name||'.'||tg_op),tg_table_name,eid,previous,payload,coalesce(auth.uid(),(payload->>'created_by')::uuid));
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists opportunities_commercial_audit on public.opportunities;
drop trigger if exists activities_commercial_audit on public.activities;
drop trigger if exists payments_commercial_audit on public.payments;
drop trigger if exists reminders_commercial_audit on public.reminders;
create trigger opportunities_commercial_audit after insert or update or delete on public.opportunities for each row execute function public.audit_commercial_change();
create trigger activities_commercial_audit after insert or update or delete on public.activities for each row execute function public.audit_commercial_change();
create trigger payments_commercial_audit after insert or update or delete on public.payments for each row execute function public.audit_commercial_change();
create trigger reminders_commercial_audit after insert or update or delete on public.reminders for each row execute function public.audit_commercial_change();

create or replace function public.notify_activity_assignment()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare activity_row public.activities%rowtype;
begin
  select * into activity_row from public.activities where id=new.activity_id;
  insert into public.notifications(company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by)
  values(new.company_id,new.user_id,'activity_assigned','Nouvelle activité assignée',activity_row.subject,'activity',new.activity_id,'#crm/activities',jsonb_build_object('opportunity_id',activity_row.opportunity_id),coalesce(auth.uid(),new.created_by));
  return new;
end
$$;
drop trigger if exists activity_assignments_notify on public.activity_assignments;
create trigger activity_assignments_notify after insert on public.activity_assignments for each row execute function public.notify_activity_assignment();

create or replace function public.move_opportunity_stage(target_opportunity_id uuid,target_stage_slug text)
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.opportunities%rowtype; stage_row public.pipeline_stages%rowtype;
begin
  select * into target from public.opportunities where id=target_opportunity_id for update;
  if target.id is null or not public.is_company_member(target.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select * into stage_row from public.pipeline_stages where company_id=target.company_id and slug=target_stage_slug and active=true;
  if stage_row.id is null then raise exception 'pipeline_stage_not_found'; end if;
  update public.opportunities set stage=stage_row.slug,probability=stage_row.probability,
    closed_at=case when stage_row.is_won or stage_row.is_lost then now() else null end,
    health=case when stage_row.is_won then 'won' when stage_row.is_lost then 'lost' else health end,
    updated_at=now()
  where id=target.id returning * into target;
  return target;
end
$$;

create or replace function public.save_activity_assignments(target_activity_id uuid,target_user_ids uuid[])
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare activity_row public.activities%rowtype; target_user_id uuid;
begin
  select * into activity_row from public.activities where id=target_activity_id for update;
  if activity_row.id is null or not public.is_company_member(activity_row.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  delete from public.activity_assignments where activity_id=target_activity_id;
  foreach target_user_id in array coalesce(target_user_ids,'{}'::uuid[]) loop
    if exists(select 1 from public.company_members where company_id=activity_row.company_id and user_id=target_user_id) then
      insert into public.activity_assignments(company_id,activity_id,user_id,created_by)
      values(activity_row.company_id,target_activity_id,target_user_id,auth.uid()) on conflict do nothing;
    end if;
  end loop;
end
$$;

insert into public.pipeline_stages(company_id,name,slug,position,probability,color,is_won,is_lost,created_by)
select c.id,stage.name,stage.slug,stage.position,stage.probability,stage.color,false,false,c.owner_user_id
from public.companies c cross join(values
  ('Nouveau','new',5,5::numeric,'#64748b'),
  ('À qualifier','to_qualify',15,15::numeric,'#3b82f6'),
  ('En attente de réponse','awaiting_response',45,55::numeric,'#f59e0b'),
  ('Négociation','negotiation',48,75::numeric,'#8b5cf6')
)stage(name,slug,position,probability,color)
on conflict(company_id,slug) do nothing;

grant select,insert,update,delete on public.opportunity_contacts,public.activity_assignments,public.client_preferences,public.reminder_history to authenticated;
revoke insert,update,delete on public.opportunity_stage_history from authenticated;
grant select on public.opportunity_stage_history to authenticated;
grant select,insert,update on public.notifications,public.notification_preferences to authenticated;
grant select(document_id,due_at,duration_minutes,priority,status,reminder_at,result,comment,updated_by) on public.activities to authenticated;
grant select(source,need_subject,description,priority,health,stage_entered_at,archived_at,collaborator_user_ids) on public.opportunities to authenticated;
revoke all on function public.move_opportunity_stage(uuid,text) from public,anon;
revoke all on function public.save_activity_assignments(uuid,uuid[]) from public,anon;
grant execute on function public.move_opportunity_stage(uuid,text) to authenticated;
grant execute on function public.save_activity_assignments(uuid,uuid[]) to authenticated;

-- Un document doit pouvoir être enregistré en brouillon même si certaines mentions
-- légales de l'entreprise restent à compléter. Le contrôle est conservé dès que le
-- document quitte le brouillon, ainsi que pour les mouvements et achats concernés.
create or replace function public.require_company_onboarding()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if tg_table_name='documents' and new.status='draft' then return new; end if;
  if not public.is_company_onboarded(new.company_id) then
    raise exception 'company_onboarding_required' using errcode='42501';
  end if;
  return new;
end
$$;
drop trigger if exists documents_require_onboarding on public.documents;
create trigger documents_require_onboarding before insert or update of status on public.documents
for each row execute function public.require_company_onboarding();

commit;
