begin;

-- Complete the activity workspace without replacing the historical CRM model.
-- Every public entry point derives the company from the authenticated session.

alter table public.activity_types
  add column if not exists default_status text not null default 'todo',
  add column if not exists default_reminder_minutes integer,
  add column if not exists field_schema jsonb not null default '{}'::jsonb;

alter table public.activity_types drop constraint if exists activity_types_default_status_check;
alter table public.activity_types add constraint activity_types_default_status_check
  check(default_status in('draft','todo','scheduled','in_progress','completed','cancelled','missed','postponed')) not valid;

alter table public.activities
  add column if not exists source text not null default 'manual',
  add column if not exists summary text,
  add column if not exists next_step text,
  add column if not exists next_activity_id uuid references public.activities(id) on delete set null;

alter table public.activities drop constraint if exists activities_source_check;
alter table public.activities add constraint activities_source_check check(source in(
  'manual','gmail','outlook','google_calendar','microsoft_calendar','automation','conversion','api','pilo','system'
)) not valid;

alter table public.activities drop constraint if exists activities_confidentiality_check;
alter table public.activities add constraint activities_confidentiality_check
  check(confidentiality in('standard','company','team','private')) not valid;

create index if not exists activities_next_activity_idx on public.activities(company_id,next_activity_id) where next_activity_id is not null;
create index if not exists activities_source_idx on public.activities(company_id,source,created_at desc);
create index if not exists crm_activity_links_lookup_idx on public.crm_activity_links(company_id,entity_type,entity_id,activity_id);

-- The aliases below are exposed to the role editor. Existing canonical CRM
-- permissions remain the enforcement source so there is no second role model.
insert into public.permission_definitions(
  permission_key,canonical_key,module_key,category_key,category_label,label,description,
  allowed_scopes,sensitive,editor_visible,position
) values
('activities.read','crm.activities.read','crm','crm','Suivi commercial','Consulter les activites','Consulter les activites de la portee autorisee.',array['own','team','company'],false,true,135),
('activities.create','crm.activities.write','crm','crm','Suivi commercial','Creer des activites','Creer une activite et ses relations.',array['own','team','company'],false,true,136),
('activities.update','crm.activities.write','crm','crm','Suivi commercial','Modifier des activites','Modifier une activite autorisee.',array['own','team','company'],false,true,137),
('activities.complete','crm.activities.write','crm','crm','Suivi commercial','Terminer des activites','Terminer une activite avec un compte rendu.',array['own','team','company'],false,true,138),
('activities.cancel','crm.activities.write','crm','crm','Suivi commercial','Annuler des activites','Annuler une activite sans la supprimer.',array['own','team','company'],true,true,139),
('activities.archive','crm.activities.archive','crm','crm','Suivi commercial','Archiver des activites','Archiver une activite sans suppression physique.',array['own','team','company'],true,true,140),
('activities.assign','crm.activities.write','crm','crm','Suivi commercial','Assigner des activites','Assigner ou reassigner une activite.',array['own','team','company'],true,true,141),
('activities.read_team','crm.team_activities.read','crm','crm','Suivi commercial','Consulter les activites de l equipe','Consulter le planning de son equipe.',array['team','company'],true,true,142),
('activities.read_company','crm.activities.read','crm','crm','Suivi commercial','Consulter toutes les activites','Consulter les activites de l entreprise hors activites privees.',array['company'],true,true,143),
('activities.manage_types','crm.activities.configure','crm','crm','Suivi commercial','Configurer les types d activite','Gerer les types, resultats et valeurs par defaut.',array['company'],true,true,144),
('activities.manage_private','crm.activities.confidential.read','crm','crm','Suivi commercial','Consulter les activites privees','Acces exceptionnel aux activites privees.',array['team','company'],true,true,145),
('activities.export','crm.activities.read','crm','crm','Suivi commercial','Exporter les activites','Exporter uniquement les activites visibles.',array['own','team','company'],true,true,146),
('activities.sync_calendar','crm.activities.write','crm','crm','Suivi commercial','Synchroniser un agenda','Synchroniser les rendez-vous avec un agenda reellement connecte.',array['own'],true,true,147),
('activities.sync_email','crm.activities.write','crm','crm','Suivi commercial','Synchroniser les e-mails','Historiser les e-mails via une messagerie reellement connectee.',array['own'],true,true,148)
on conflict(permission_key) do update set
  canonical_key=excluded.canonical_key,module_key=excluded.module_key,category_key=excluded.category_key,
  category_label=excluded.category_label,label=excluded.label,description=excluded.description,
  allowed_scopes=excluded.allowed_scopes,sensitive=excluded.sensitive,editor_visible=excluded.editor_visible,
  position=excluded.position,active=true,updated_at=now();

-- Extra initial types requested by the commercial workflow.
insert into public.activity_types(company_id,slug,label,icon,color,category,default_duration_minutes,default_status,requires_result,is_system,position,created_by,updated_by)
select company.id,type_row.slug,type_row.label,type_row.icon,type_row.color,type_row.category,type_row.duration,type_row.default_status,type_row.requires_result,true,type_row.position,company.owner_user_id,company.owner_user_id
from public.companies company
cross join (values
 ('presentation','Presentation','presentation','#8b5cf6','meeting',45,'scheduled',true,75),
 ('proposal','Proposition commerciale','file-signature','#0f766e','action',30,'todo',true,105),
 ('invoice_followup','Suivi de facture','receipt','#f97316','action',20,'todo',true,112),
 ('payment_followup','Suivi de reglement','credit-card','#dc2626','action',20,'todo',true,114),
 ('administrative','Action administrative','briefcase','#64748b','action',30,'todo',false,116)
) type_row(slug,label,icon,color,category,duration,default_status,requires_result,position)
on conflict(company_id,slug) do nothing;

create or replace function public.activity_is_visible(target_activity_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1
    from public.activities activity
    join public.company_members member on member.company_id=activity.company_id and member.user_id=auth.uid()
      and member.platform_status='active' and member.access_removed_at is null
    where activity.id=target_activity_id
      and public._crm_has_scope(activity.company_id,'crm.activities.read',coalesce(activity.assigned_user_id,activity.created_by),activity.team_id)
      and (
        activity.confidentiality<>'private'
        or activity.created_by=auth.uid()
        or activity.assigned_user_id=auth.uid()
        or exists(select 1 from public.activity_assignments assignment where assignment.activity_id=activity.id and assignment.user_id=auth.uid())
        or exists(select 1 from public.crm_activity_participants participant where participant.activity_id=activity.id and participant.participant_type='user' and participant.participant_id=auth.uid())
        or public.has_company_permission(activity.company_id,'crm.activities.confidential.read')
      )
  )
$$;

create or replace function public.activity_is_writable(target_activity_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.activities activity
    where activity.id=target_activity_id
      and public.activity_is_visible(activity.id)
      and public._crm_has_scope(activity.company_id,'crm.activities.write',coalesce(activity.assigned_user_id,activity.created_by),activity.team_id)
  )
$$;

revoke all on function public.activity_is_visible(uuid) from public,anon;
revoke all on function public.activity_is_writable(uuid) from public,anon;
grant execute on function public.activity_is_visible(uuid),public.activity_is_writable(uuid) to authenticated;

-- Confidentiality is restrictive and composes with the historical tenant/scope policies.
drop policy if exists activities_confidentiality_select on public.activities;
create policy activities_confidentiality_select on public.activities as restrictive for select to authenticated
using(public.activity_is_visible(id));

do $activity_rls$
declare table_name text;
begin
  foreach table_name in array array[
    'activity_reminders','activity_checklist_items','activity_attachments','activity_events','activity_sync_links'
  ] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.activity_is_visible(activity_id))',table_name||'_select',table_name);
  end loop;
end
$activity_rls$;

alter table public.activity_types enable row level security;
alter table public.activity_outcomes enable row level security;
alter table public.activity_saved_filters enable row level security;

drop policy if exists activity_types_select on public.activity_types;
create policy activity_types_select on public.activity_types for select to authenticated using(public.is_company_member(company_id));
drop policy if exists activity_outcomes_select on public.activity_outcomes;
create policy activity_outcomes_select on public.activity_outcomes for select to authenticated using(public.is_company_member(company_id));
drop policy if exists activity_saved_filters_own on public.activity_saved_filters;
create policy activity_saved_filters_own on public.activity_saved_filters for all to authenticated
using(user_id=auth.uid() and public.is_company_member(company_id))
with check(user_id=auth.uid() and created_by=auth.uid() and public.is_company_member(company_id));

-- Mutations on child resources are intentionally RPC-only. Events are append-only.
revoke insert,update,delete on public.activity_events from authenticated;
revoke insert,update,delete on public.activity_sync_links from authenticated;
revoke insert,update,delete on public.activity_types,public.activity_outcomes from authenticated;
revoke insert,update,delete on public.activity_reminders,public.activity_checklist_items,public.activity_attachments from authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('activity-attachments','activity-attachments',false,15728640,array['application/pdf','image/png','image/jpeg','image/webp','text/plain','text/csv','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists activity_attachments_storage_read on storage.objects;
create policy activity_attachments_storage_read on storage.objects for select to authenticated using(
  bucket_id='activity-attachments'
  and public.activity_is_visible(nullif((storage.foldername(name))[2],'')::uuid)
);
drop policy if exists activity_attachments_storage_insert on storage.objects;
create policy activity_attachments_storage_insert on storage.objects for insert to authenticated with check(
  bucket_id='activity-attachments' and owner=auth.uid()
  and public.is_company_member(((storage.foldername(name))[1])::uuid)
);

create or replace function public.activity_relation_exists(target_company_id uuid,target_type text,target_id uuid)
returns boolean language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if target_type in('client','prospect') then
    return exists(select 1 from public.clients row where row.id=target_id and row.company_id=target_company_id);
  elsif target_type='contact' then
    return exists(select 1 from public.client_contacts row where row.id=target_id and row.company_id=target_company_id);
  elsif target_type='opportunity' then
    return exists(select 1 from public.opportunities row where row.id=target_id and row.company_id=target_company_id);
  elsif target_type in('quote','invoice','credit_note','purchase_invoice','due_date') then
    return exists(select 1 from public.documents row where row.id=target_id and row.company_id=target_company_id);
  elsif target_type='payment' then
    return exists(select 1 from public.payments row where row.id=target_id and row.company_id=target_company_id);
  elsif target_type='supplier' then
    return exists(select 1 from public.suppliers row where row.id=target_id and row.company_id=target_company_id);
  end if;
  return false;
end
$$;

create or replace function public.get_activity_workspace_v3(
  target_view text default 'list',target_quick_filter text default 'all',target_search text default null,
  target_statuses text[] default null,target_type_ids uuid[] default null,target_owner uuid default null,
  target_team uuid default null,target_start timestamptz default null,target_end timestamptz default null,
  target_include_archived boolean default false,target_page integer default 1,target_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record;page_value integer:=greatest(1,coalesce(target_page,1));size_value integer:=least(200,greatest(10,coalesce(target_page_size,50)));result jsonb;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.read') then raise exception 'activities_forbidden' using errcode='42501'; end if;
  with visible as(
    select activity.*,type_row.label type_label,type_row.icon type_icon,type_row.color type_color,
      coalesce(client.trade_name,client.legal_name,concat_ws(' ',client.first_name,client.last_name)) entity_name,
      concat_ws(' ',contact.first_name,contact.last_name) contact_name,
      opportunity.name opportunity_name,document.number document_number,document.document_type
    from public.activities activity
    left join public.activity_types type_row on type_row.id=activity.activity_type_id
    left join public.clients client on client.id=activity.client_id and client.company_id=activity.company_id
    left join public.client_contacts contact on contact.id=activity.contact_id and contact.company_id=activity.company_id
    left join public.opportunities opportunity on opportunity.id=activity.opportunity_id and opportunity.company_id=activity.company_id
    left join public.documents document on document.id=activity.document_id and document.company_id=activity.company_id
    where activity.company_id=context_row.company_id and public.activity_is_visible(activity.id)
      and (target_include_archived or activity.archived_at is null)
      and (target_owner is null or activity.assigned_user_id=target_owner)
      and (target_team is null or activity.team_id=target_team)
      and (target_view<>'my' or activity.assigned_user_id=auth.uid() or activity.created_by=auth.uid())
      and (target_statuses is null or activity.status=any(target_statuses))
      and (target_type_ids is null or activity.activity_type_id=any(target_type_ids))
      and (target_start is null or coalesce(activity.starts_at,activity.due_at,activity.scheduled_at,activity.created_at)>=target_start)
      and (target_end is null or coalesce(activity.starts_at,activity.due_at,activity.scheduled_at,activity.created_at)<target_end)
      and (target_search is null or target_search='' or to_tsvector('simple',coalesce(activity.subject,'')||' '||coalesce(activity.description,'')||' '||coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')||' '||coalesce(document.number,'')) @@ plainto_tsquery('simple',target_search))
      and case target_quick_filter
        when 'today' then coalesce(activity.starts_at,activity.due_at,activity.scheduled_at)::date=current_date
        when 'overdue' then activity.status not in('completed','cancelled') and coalesce(activity.starts_at,activity.due_at,activity.scheduled_at)<now()
        when 'upcoming' then activity.status not in('completed','cancelled') and coalesce(activity.starts_at,activity.due_at,activity.scheduled_at)>=now()
        when 'week' then coalesce(activity.starts_at,activity.due_at,activity.scheduled_at)>=date_trunc('week',now()) and coalesce(activity.starts_at,activity.due_at,activity.scheduled_at)<date_trunc('week',now())+interval '7 days'
        when 'completed' then activity.status='completed'
        when 'cancelled' then activity.status='cancelled'
        else true end
  ), counted as(select count(*)::integer total from visible), paged as(
    select * from visible order by coalesce(starts_at,due_at,scheduled_at,created_at) asc,id
    offset (page_value-1)*size_value limit size_value
  )
  select jsonb_build_object(
    'rows',coalesce((select jsonb_agg(to_jsonb(row)) from paged row),'[]'::jsonb),
    'total',coalesce((select total from counted),0),'page',page_value,'page_size',size_value,
    'counts',jsonb_build_object(
      'today',(select count(*) from public.activities a where a.company_id=context_row.company_id and a.archived_at is null and public.activity_is_visible(a.id) and coalesce(a.starts_at,a.due_at,a.scheduled_at)::date=current_date and a.status not in('completed','cancelled')),
      'overdue',(select count(*) from public.activities a where a.company_id=context_row.company_id and a.archived_at is null and public.activity_is_visible(a.id) and coalesce(a.starts_at,a.due_at,a.scheduled_at)<now() and a.status not in('completed','cancelled')),
      'week',(select count(*) from public.activities a where a.company_id=context_row.company_id and a.archived_at is null and public.activity_is_visible(a.id) and coalesce(a.starts_at,a.due_at,a.scheduled_at)>=date_trunc('week',now()) and coalesce(a.starts_at,a.due_at,a.scheduled_at)<date_trunc('week',now())+interval '7 days'),
      'completed_week',(select count(*) from public.activities a where a.company_id=context_row.company_id and public.activity_is_visible(a.id) and a.completed_at>=date_trunc('week',now())),
      'calls',(select count(*) from public.activities a where a.company_id=context_row.company_id and a.archived_at is null and public.activity_is_visible(a.id) and a.activity_type='call' and a.status not in('completed','cancelled')),
      'reminders',(select count(*) from public.activities a where a.company_id=context_row.company_id and a.archived_at is null and public.activity_is_visible(a.id) and a.activity_type in('reminder','quote_followup','invoice_followup','payment_followup') and a.status not in('completed','cancelled'))
    ),
    'types',coalesce((select jsonb_agg(to_jsonb(type_row) order by type_row.position,type_row.label) from public.activity_types type_row where type_row.company_id=context_row.company_id and type_row.active),'[]'::jsonb),
    'all_types',coalesce((select jsonb_agg(to_jsonb(type_row) order by type_row.active desc,type_row.position,type_row.label) from public.activity_types type_row where type_row.company_id=context_row.company_id),'[]'::jsonb),
    'outcomes',coalesce((select jsonb_agg(to_jsonb(outcome) order by outcome.position,outcome.label) from public.activity_outcomes outcome where outcome.company_id=context_row.company_id and outcome.active),'[]'::jsonb),
    'saved_filters',coalesce((select jsonb_agg(to_jsonb(saved_filter) order by saved_filter.is_default desc,saved_filter.name) from public.activity_saved_filters saved_filter where saved_filter.company_id=context_row.company_id and saved_filter.user_id=auth.uid()),'[]'::jsonb),
    'permissions',jsonb_build_object('write',context_row.can_write,'manage',context_row.can_manage,'view_all',context_row.can_view_all,'view_team',public.has_company_permission(context_row.company_id,'crm.team_activities.read'),'configure',public.has_company_permission(context_row.company_id,'crm.activities.configure'))
  ) into result;
  return result;
end
$$;

create or replace function public.get_activity_detail(target_activity_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare activity_row public.activities%rowtype;
begin
  if not public.activity_is_visible(target_activity_id) then raise exception 'activity_not_found' using errcode='P0002'; end if;
  select * into activity_row from public.activities where id=target_activity_id;
  return jsonb_build_object(
    'activity',to_jsonb(activity_row),
    'type',(select to_jsonb(row) from public.activity_types row where row.id=activity_row.activity_type_id),
    'assignments',coalesce((select jsonb_agg(to_jsonb(row) order by created_at) from public.activity_assignments row where row.activity_id=activity_row.id),'[]'::jsonb),
    'participants',coalesce((select jsonb_agg(to_jsonb(row) order by created_at) from public.crm_activity_participants row where row.activity_id=activity_row.id),'[]'::jsonb),
    'links',coalesce((select jsonb_agg(to_jsonb(row) order by created_at) from public.crm_activity_links row where row.activity_id=activity_row.id),'[]'::jsonb),
    'reminders',coalesce((select jsonb_agg(to_jsonb(row) order by remind_at) from public.activity_reminders row where row.activity_id=activity_row.id),'[]'::jsonb),
    'checklist',coalesce((select jsonb_agg(to_jsonb(row) order by position,id) from public.activity_checklist_items row where row.activity_id=activity_row.id),'[]'::jsonb),
    'attachments',coalesce((select jsonb_agg(to_jsonb(row) order by created_at desc) from public.activity_attachments row where row.activity_id=activity_row.id and archived_at is null),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(row) order by occurred_at desc,id desc) from(select * from public.activity_events where activity_id=activity_row.id order by occurred_at desc,id desc limit 200)row),'[]'::jsonb),
    'sync',coalesce((select jsonb_agg(to_jsonb(row) order by created_at) from public.activity_sync_links row where row.activity_id=activity_row.id),'[]'::jsonb),
    'can_write',public.activity_is_writable(activity_row.id)
  );
end
$$;

create or replace function public.save_activity_workspace(target_activity_id uuid default null,target_payload jsonb default '{}'::jsonb)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;activity_row public.activities%rowtype;type_row public.activity_types%rowtype;assigned_value uuid;team_value uuid;link jsonb;item jsonb;previous_owner uuid;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write then raise exception 'activities_forbidden' using errcode='42501'; end if;
  select * into type_row from public.activity_types where id=nullif(target_payload->>'activity_type_id','')::uuid and company_id=context_row.company_id and active;
  if type_row.id is null then select * into type_row from public.activity_types where company_id=context_row.company_id and slug=coalesce(nullif(target_payload->>'activity_type',''),'task') and active; end if;
  if type_row.id is null then raise exception 'activity_type_invalid'; end if;
  if nullif(trim(target_payload->>'subject'),'') is null then raise exception 'activity_subject_required'; end if;
  assigned_value:=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,auth.uid());
  team_value:=nullif(target_payload->>'team_id','')::uuid;
  if not public._crm_has_scope(context_row.company_id,'crm.activities.write',assigned_value,team_value) then raise exception 'activity_assignment_forbidden' using errcode='42501'; end if;
  if target_activity_id is null then
    insert into public.activities(company_id,activity_type_id,activity_type,subject,description,status,priority,starts_at,ends_at,scheduled_at,due_at,all_day,timezone,confidentiality,channel,duration_minutes,completion_percent,assigned_user_id,team_id,location,meeting_url,source,summary,next_step,parent_activity_id,metadata,created_by,updated_by)
    values(context_row.company_id,type_row.id,type_row.slug,trim(target_payload->>'subject'),nullif(target_payload->>'description',''),coalesce(nullif(target_payload->>'status',''),type_row.default_status),coalesce(nullif(target_payload->>'priority',''),'normal'),nullif(target_payload->>'starts_at','')::timestamptz,nullif(target_payload->>'ends_at','')::timestamptz,coalesce(nullif(target_payload->>'starts_at','')::timestamptz,nullif(target_payload->>'due_at','')::timestamptz),coalesce(nullif(target_payload->>'due_at','')::timestamptz,nullif(target_payload->>'starts_at','')::timestamptz),coalesce((target_payload->>'all_day')::boolean,false),coalesce(nullif(target_payload->>'timezone',''),'Europe/Paris'),coalesce(nullif(target_payload->>'confidentiality',''),'standard'),nullif(target_payload->>'channel',''),coalesce(nullif(target_payload->>'duration_minutes','')::integer,type_row.default_duration_minutes),coalesce(nullif(target_payload->>'completion_percent','')::integer,0),assigned_value,team_value,nullif(target_payload->>'location',''),nullif(target_payload->>'meeting_url',''),coalesce(nullif(target_payload->>'source',''),'manual'),nullif(target_payload->>'summary',''),nullif(target_payload->>'next_step',''),nullif(target_payload->>'parent_activity_id','')::uuid,coalesce(target_payload->'metadata','{}'::jsonb),auth.uid(),auth.uid()) returning * into activity_row;
  else
    select * into activity_row from public.activities where id=target_activity_id and company_id=context_row.company_id for update;
    if activity_row.id is null or not public.activity_is_writable(activity_row.id) then raise exception 'activity_forbidden' using errcode='42501'; end if;
    previous_owner:=activity_row.assigned_user_id;
    update public.activities set activity_type_id=type_row.id,activity_type=type_row.slug,subject=trim(target_payload->>'subject'),description=nullif(target_payload->>'description',''),status=coalesce(nullif(target_payload->>'status',''),status),priority=coalesce(nullif(target_payload->>'priority',''),'normal'),starts_at=nullif(target_payload->>'starts_at','')::timestamptz,ends_at=nullif(target_payload->>'ends_at','')::timestamptz,scheduled_at=coalesce(nullif(target_payload->>'starts_at','')::timestamptz,nullif(target_payload->>'due_at','')::timestamptz),due_at=coalesce(nullif(target_payload->>'due_at','')::timestamptz,nullif(target_payload->>'starts_at','')::timestamptz),all_day=coalesce((target_payload->>'all_day')::boolean,false),timezone=coalesce(nullif(target_payload->>'timezone',''),'Europe/Paris'),confidentiality=coalesce(nullif(target_payload->>'confidentiality',''),'standard'),channel=nullif(target_payload->>'channel',''),duration_minutes=coalesce(nullif(target_payload->>'duration_minutes','')::integer,type_row.default_duration_minutes),completion_percent=coalesce(nullif(target_payload->>'completion_percent','')::integer,completion_percent),assigned_user_id=assigned_value,team_id=team_value,location=nullif(target_payload->>'location',''),meeting_url=nullif(target_payload->>'meeting_url',''),summary=nullif(target_payload->>'summary',''),next_step=nullif(target_payload->>'next_step',''),metadata=coalesce(target_payload->'metadata',metadata),updated_by=auth.uid(),updated_at=now() where id=activity_row.id returning * into activity_row;
  end if;

  -- Preserve legacy direct columns while supporting multiple secure links.
  if target_payload ? 'links' then
    delete from public.crm_activity_links where activity_id=activity_row.id;
    for link in select value from jsonb_array_elements(coalesce(target_payload->'links','[]'::jsonb)) loop
      if nullif(link->>'entity_id','') is not null and public.activity_relation_exists(context_row.company_id,link->>'entity_type',(link->>'entity_id')::uuid) then
        insert into public.crm_activity_links(company_id,activity_id,entity_type,entity_id,created_by,updated_by)
        values(context_row.company_id,activity_row.id,link->>'entity_type',(link->>'entity_id')::uuid,auth.uid(),auth.uid()) on conflict do nothing;
      else raise exception 'activity_relation_invalid'; end if;
    end loop;
  end if;
  select entity_id into activity_row.client_id from public.crm_activity_links where activity_id=activity_row.id and entity_type in('client','prospect') order by created_at limit 1;
  select entity_id into activity_row.contact_id from public.crm_activity_links where activity_id=activity_row.id and entity_type='contact' order by created_at limit 1;
  select entity_id into activity_row.opportunity_id from public.crm_activity_links where activity_id=activity_row.id and entity_type='opportunity' order by created_at limit 1;
  select entity_id into activity_row.document_id from public.crm_activity_links where activity_id=activity_row.id and entity_type in('quote','invoice','credit_note','purchase_invoice') order by created_at limit 1;
  update public.activities set client_id=activity_row.client_id,contact_id=activity_row.contact_id,opportunity_id=activity_row.opportunity_id,document_id=activity_row.document_id where id=activity_row.id returning * into activity_row;

  if target_payload ? 'participants' then
    delete from public.crm_activity_participants where activity_id=activity_row.id;
    for item in select value from jsonb_array_elements(coalesce(target_payload->'participants','[]'::jsonb)) loop
      insert into public.crm_activity_participants(company_id,activity_id,participant_type,participant_id,display_name,email,response_status,created_by,updated_by)
      values(context_row.company_id,activity_row.id,coalesce(nullif(item->>'participant_type',''),'external'),nullif(item->>'participant_id','')::uuid,nullif(item->>'display_name',''),nullif(item->>'email',''),coalesce(nullif(item->>'response_status',''),'pending'),auth.uid(),auth.uid());
    end loop;
  end if;
  if target_payload ? 'checklist' then
    delete from public.activity_checklist_items where activity_id=activity_row.id;
    for item in select value from jsonb_array_elements(coalesce(target_payload->'checklist','[]'::jsonb)) loop
      insert into public.activity_checklist_items(company_id,activity_id,label,position,created_by)
      values(context_row.company_id,activity_row.id,trim(item->>'label'),coalesce((item->>'position')::integer,0),auth.uid());
    end loop;
  end if;
  if target_payload ? 'reminders' then
    update public.activity_reminders set status='cancelled',updated_at=now() where activity_id=activity_row.id and status='pending';
    for item in select value from jsonb_array_elements(coalesce(target_payload->'reminders','[]'::jsonb)) loop
      insert into public.activity_reminders(company_id,activity_id,channel,remind_at,recipient_user_id,created_by)
      values(context_row.company_id,activity_row.id,coalesce(nullif(item->>'channel',''),'in_app'),(item->>'remind_at')::timestamptz,coalesce(nullif(item->>'recipient_user_id','')::uuid,assigned_value),auth.uid()) on conflict do nothing;
    end loop;
  end if;
  if activity_row.assigned_user_id is not null and activity_row.assigned_user_id<>auth.uid() and (target_activity_id is null or previous_owner is distinct from activity_row.assigned_user_id) then
    insert into public.notifications(company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by)
    values(context_row.company_id,activity_row.assigned_user_id,'activity_assigned','Nouvelle activite assignee',activity_row.subject,'activity',activity_row.id,'#crm/activities',jsonb_build_object('activity_id',activity_row.id),auth.uid());
  end if;
  return activity_row;
end
$$;

create or replace function public.complete_activity_workspace(target_activity_id uuid,target_outcome_id uuid default null,target_summary text default null,target_actual_duration integer default null,target_next_payload jsonb default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.activities%rowtype;next_row public.activities%rowtype;
begin
  if not public.activity_is_writable(target_activity_id) then raise exception 'activity_forbidden' using errcode='42501'; end if;
  update public.activities set status='completed',completed_at=now(),completion_percent=100,result=coalesce((select label from public.activity_outcomes where id=target_outcome_id and company_id=activities.company_id),result),summary=coalesce(nullif(target_summary,''),summary),actual_duration_minutes=coalesce(target_actual_duration,actual_duration_minutes),updated_by=auth.uid(),updated_at=now() where id=target_activity_id returning * into row;
  if target_next_payload is not null and jsonb_typeof(target_next_payload)='object' then
    target_next_payload:=target_next_payload||jsonb_build_object('parent_activity_id',row.id);
    next_row:=public.save_activity_workspace(null,target_next_payload);
    update public.activities set next_activity_id=next_row.id,updated_at=now() where id=row.id;
  end if;
  return jsonb_build_object('activity',to_jsonb(row),'next_activity',case when next_row.id is null then null else to_jsonb(next_row) end);
end
$$;

create or replace function public.transition_activity_workspace(target_activity_id uuid,target_action text,target_value jsonb default '{}'::jsonb)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.activities%rowtype;new_start timestamptz;new_end timestamptz;
begin
  if not public.activity_is_writable(target_activity_id) then raise exception 'activity_forbidden' using errcode='42501'; end if;
  select * into row from public.activities where id=target_activity_id for update;
  if target_action='archive' then update public.activities set archived_at=now(),archived_by=auth.uid(),updated_by=auth.uid(),updated_at=now() where id=row.id returning * into row;
  elsif target_action='cancel' then update public.activities set status='cancelled',cancelled_at=now(),cancellation_reason=nullif(target_value->>'reason',''),updated_by=auth.uid(),updated_at=now() where id=row.id returning * into row;
  elsif target_action='reschedule' then
    new_start:=(target_value->>'starts_at')::timestamptz;new_end:=nullif(target_value->>'ends_at','')::timestamptz;
    if new_start is null then raise exception 'activity_start_required'; end if;
    update public.activities set starts_at=new_start,scheduled_at=new_start,due_at=new_start,ends_at=coalesce(new_end,new_start+make_interval(mins=>coalesce(duration_minutes,30))),status=case when status in('completed','cancelled') then status else 'scheduled' end,updated_by=auth.uid(),updated_at=now() where id=row.id returning * into row;
  elsif target_action='assign' then
    if not public._crm_has_scope(row.company_id,'crm.activities.write',(target_value->>'assigned_user_id')::uuid,nullif(target_value->>'team_id','')::uuid) then raise exception 'activity_assignment_forbidden' using errcode='42501'; end if;
    update public.activities set assigned_user_id=(target_value->>'assigned_user_id')::uuid,team_id=nullif(target_value->>'team_id','')::uuid,updated_by=auth.uid(),updated_at=now() where id=row.id returning * into row;
  elsif target_action='status' then
    if target_value->>'status' not in('draft','todo','scheduled','in_progress','completed','cancelled','missed','postponed') then raise exception 'activity_status_invalid'; end if;
    update public.activities set status=target_value->>'status',completed_at=case when target_value->>'status'='completed' then now() else completed_at end,completion_percent=case when target_value->>'status'='completed' then 100 else completion_percent end,updated_by=auth.uid(),updated_at=now() where id=row.id returning * into row;
  else raise exception 'activity_transition_invalid'; end if;
  return row;
end
$$;

create or replace function public.duplicate_activity_workspace(target_activity_id uuid)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare source_row public.activities%rowtype;copy_row public.activities%rowtype;
begin
  if not public.activity_is_visible(target_activity_id) then raise exception 'activity_not_found'; end if;
  select * into source_row from public.activities where id=target_activity_id;
  copy_row:=public.save_activity_workspace(null,jsonb_build_object('activity_type_id',source_row.activity_type_id,'subject',source_row.subject||' (copie)','description',source_row.description,'status','draft','priority',source_row.priority,'starts_at',source_row.starts_at,'ends_at',source_row.ends_at,'duration_minutes',source_row.duration_minutes,'assigned_user_id',source_row.assigned_user_id,'team_id',source_row.team_id,'confidentiality',source_row.confidentiality,'channel',source_row.channel,'location',source_row.location,'meeting_url',source_row.meeting_url,'source','manual','links',(select coalesce(jsonb_agg(jsonb_build_object('entity_type',entity_type,'entity_id',entity_id)),'[]'::jsonb) from public.crm_activity_links where activity_id=source_row.id)));
  return copy_row;
end
$$;

create or replace function public.register_activity_attachment(target_activity_id uuid,target_path text,target_name text,target_mime text,target_size bigint,target_sha256 text default null)
returns public.activity_attachments language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.activity_attachments%rowtype;activity_row public.activities%rowtype;
begin
  if not public.activity_is_writable(target_activity_id) then raise exception 'activity_forbidden' using errcode='42501'; end if;
  select * into activity_row from public.activities where id=target_activity_id;
  if target_path not like activity_row.company_id::text||'/'||activity_row.id::text||'/%' then raise exception 'activity_attachment_path_invalid'; end if;
  insert into public.activity_attachments(company_id,activity_id,storage_path,original_name,mime_type,size_bytes,sha256,created_by)
  values(activity_row.company_id,activity_row.id,target_path,target_name,target_mime,target_size,target_sha256,auth.uid()) returning * into row;
  return row;
end
$$;

create or replace function public.save_activity_type(target_type_id uuid default null,target_payload jsonb default '{}'::jsonb)
returns public.activity_types language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;row public.activity_types%rowtype;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.configure') then raise exception 'activity_configuration_forbidden' using errcode='42501'; end if;
  if nullif(trim(target_payload->>'label'),'') is null then raise exception 'activity_type_label_required'; end if;
  if target_type_id is null then
    insert into public.activity_types(company_id,slug,label,icon,color,category,default_duration_minutes,default_status,default_reminder_minutes,requires_result,field_schema,position,created_by,updated_by)
    values(context_row.company_id,lower(regexp_replace(trim(target_payload->>'slug'),'[^a-zA-Z0-9]+','_','g')),trim(target_payload->>'label'),coalesce(nullif(target_payload->>'icon',''),'circle'),coalesce(nullif(target_payload->>'color',''),'#14b8a6'),coalesce(nullif(target_payload->>'category',''),'action'),coalesce((target_payload->>'default_duration_minutes')::integer,30),coalesce(nullif(target_payload->>'default_status',''),'todo'),nullif(target_payload->>'default_reminder_minutes','')::integer,coalesce((target_payload->>'requires_result')::boolean,false),coalesce(target_payload->'field_schema','{}'::jsonb),coalesce((target_payload->>'position')::integer,999),auth.uid(),auth.uid()) returning * into row;
  else
    update public.activity_types set label=trim(target_payload->>'label'),icon=coalesce(nullif(target_payload->>'icon',''),icon),color=coalesce(nullif(target_payload->>'color',''),color),category=coalesce(nullif(target_payload->>'category',''),category),default_duration_minutes=coalesce((target_payload->>'default_duration_minutes')::integer,default_duration_minutes),default_status=coalesce(nullif(target_payload->>'default_status',''),default_status),default_reminder_minutes=nullif(target_payload->>'default_reminder_minutes','')::integer,requires_result=coalesce((target_payload->>'requires_result')::boolean,requires_result),field_schema=coalesce(target_payload->'field_schema',field_schema),active=coalesce((target_payload->>'active')::boolean,active),updated_by=auth.uid(),updated_at=now() where id=target_type_id and company_id=context_row.company_id returning * into row;
  end if;
  return row;
end
$$;

create or replace function public.save_activity_saved_filter(
  target_filter_id uuid default null,
  target_name text default null,
  target_view_mode text default 'list',
  target_filters jsonb default '{}'::jsonb
) returns public.activity_saved_filters language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;row public.activity_saved_filters%rowtype;normalized_view text:=lower(coalesce(nullif(target_view_mode,''),'list'));
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.read') then raise exception 'activities_forbidden' using errcode='42501'; end if;
  if nullif(trim(target_name),'') is null then raise exception 'activity_filter_name_required'; end if;
  if normalized_view not in('list','agenda','timeline','mine','team') then raise exception 'activity_filter_view_invalid'; end if;
  if target_filter_id is null then
    insert into public.activity_saved_filters(company_id,user_id,name,view_mode,filters,created_at,updated_at)
    values(context_row.company_id,auth.uid(),trim(target_name),normalized_view,coalesce(target_filters,'{}'::jsonb),now(),now()) returning * into row;
  else
    update public.activity_saved_filters set name=trim(target_name),view_mode=normalized_view,filters=coalesce(target_filters,'{}'::jsonb),updated_at=now()
    where id=target_filter_id and company_id=context_row.company_id and user_id=auth.uid() returning * into row;
    if row.id is null then raise exception 'activity_filter_not_found' using errcode='P0002'; end if;
  end if;
  return row;
end
$$;

create or replace function public.delete_activity_saved_filter(target_filter_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;deleted_count integer;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.read') then raise exception 'activities_forbidden' using errcode='42501'; end if;
  delete from public.activity_saved_filters where id=target_filter_id and company_id=context_row.company_id and user_id=auth.uid();
  get diagnostics deleted_count=row_count;
  return deleted_count=1;
end
$$;

create or replace function public.dispatch_due_activity_reminders(target_limit integer default 100)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare reminder_row record;processed integer:=0;
begin
  if current_user not in('postgres','service_role') then raise exception 'service_role_required' using errcode='42501'; end if;
  for reminder_row in select reminder.*,activity.subject from public.activity_reminders reminder join public.activities activity on activity.id=reminder.activity_id where reminder.status='pending' and reminder.remind_at<=now() order by reminder.remind_at for update skip locked limit least(500,greatest(1,target_limit)) loop
    if reminder_row.channel='in_app' then
      insert into public.notifications(company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by)
      select reminder_row.company_id,reminder_row.recipient_user_id,'activity_reminder','Rappel d activite',reminder_row.subject,'activity',reminder_row.activity_id,'#crm/activities',jsonb_build_object('reminder_id',reminder_row.id),reminder_row.created_by
      where reminder_row.recipient_user_id is not null and not exists(select 1 from public.notifications notification where notification.metadata->>'reminder_id'=reminder_row.id::text);
      update public.activity_reminders set status='sent',sent_at=now(),updated_at=now() where id=reminder_row.id;
    else
      update public.activity_reminders set status='failed',failure_code='email_delivery_requires_worker',updated_at=now() where id=reminder_row.id;
    end if;
    processed:=processed+1;
  end loop;
  return processed;
end
$$;

revoke all on function public.activity_relation_exists(uuid,text,uuid) from public,anon;
revoke all on function public.get_activity_workspace_v3(text,text,text,text[],uuid[],uuid,uuid,timestamptz,timestamptz,boolean,integer,integer) from public,anon;
revoke all on function public.get_activity_detail(uuid) from public,anon;
revoke all on function public.save_activity_workspace(uuid,jsonb) from public,anon;
revoke all on function public.complete_activity_workspace(uuid,uuid,text,integer,jsonb) from public,anon;
revoke all on function public.transition_activity_workspace(uuid,text,jsonb) from public,anon;
revoke all on function public.duplicate_activity_workspace(uuid) from public,anon;
revoke all on function public.register_activity_attachment(uuid,text,text,text,bigint,text) from public,anon;
revoke all on function public.save_activity_type(uuid,jsonb) from public,anon;
revoke all on function public.save_activity_saved_filter(uuid,text,text,jsonb) from public,anon;
revoke all on function public.delete_activity_saved_filter(uuid) from public,anon;
revoke all on function public.dispatch_due_activity_reminders(integer) from public,anon,authenticated;

grant execute on function public.get_activity_workspace_v3(text,text,text,text[],uuid[],uuid,uuid,timestamptz,timestamptz,boolean,integer,integer) to authenticated;
grant execute on function public.get_activity_detail(uuid) to authenticated;
grant execute on function public.save_activity_workspace(uuid,jsonb) to authenticated;
grant execute on function public.complete_activity_workspace(uuid,uuid,text,integer,jsonb) to authenticated;
grant execute on function public.transition_activity_workspace(uuid,text,jsonb) to authenticated;
grant execute on function public.duplicate_activity_workspace(uuid) to authenticated;
grant execute on function public.register_activity_attachment(uuid,text,text,text,bigint,text) to authenticated;
grant execute on function public.save_activity_type(uuid,jsonb) to authenticated;
grant execute on function public.save_activity_saved_filter(uuid,text,text,jsonb) to authenticated;
grant execute on function public.delete_activity_saved_filter(uuid) to authenticated;
grant execute on function public.dispatch_due_activity_reminders(integer) to service_role;

commit;
