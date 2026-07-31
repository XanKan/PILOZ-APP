-- PILOZ - Activites enterprise scale
-- Additive migration: preferences, relation autocomplete and atomic bulk actions.

create table if not exists public.activity_workspace_preferences (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  default_view text not null default 'list' check (default_view in ('list','agenda','timeline','mine','team')),
  page_size integer not null default 50 check (page_size in (25,50,100,200)),
  density text not null default 'comfortable' check (density in ('comfortable','compact')),
  show_metrics boolean not null default true,
  visible_columns jsonb not null default '["type","subject","relation","owner","date","duration","priority","status"]'::jsonb,
  sort_key text not null default 'activity_at' check (sort_key in ('activity_at','subject','priority','status','owner')),
  sort_direction text not null default 'asc' check (sort_direction in ('asc','desc')),
  updated_at timestamptz not null default now(),
  primary key (company_id,user_id)
);

alter table public.activity_workspace_preferences enable row level security;
drop policy if exists activity_workspace_preferences_read on public.activity_workspace_preferences;
create policy activity_workspace_preferences_read on public.activity_workspace_preferences
for select to authenticated using (user_id=auth.uid() and public.is_company_member(company_id));
drop policy if exists activity_workspace_preferences_write on public.activity_workspace_preferences;
create policy activity_workspace_preferences_write on public.activity_workspace_preferences
for all to authenticated using (user_id=auth.uid() and public.is_company_member(company_id))
with check (user_id=auth.uid() and public.is_company_member(company_id));

create index if not exists activities_workspace_company_date_idx
  on public.activities(company_id,(coalesce(starts_at,due_at,scheduled_at,created_at)),id)
  where archived_at is null;
create index if not exists activities_workspace_company_owner_date_idx
  on public.activities(company_id,assigned_user_id,(coalesce(starts_at,due_at,scheduled_at,created_at)),id)
  where archived_at is null;
create index if not exists clients_activity_lookup_idx
  on public.clients(company_id,active,relationship_type,legal_name,trade_name,id);
create index if not exists documents_activity_lookup_idx
  on public.documents(company_id,document_type,status,number,id);
create index if not exists opportunities_activity_lookup_idx
  on public.opportunities(company_id,stage,name,id);
create index if not exists suppliers_activity_lookup_idx
  on public.suppliers(company_id,active,legal_name,id);
create index if not exists activity_assignments_activity_user_idx
  on public.activity_assignments(activity_id,user_id);
create index if not exists crm_activity_participants_user_activity_idx
  on public.crm_activity_participants(activity_id,participant_id)
  where participant_type='user';
create index if not exists company_team_members_team_user_idx
  on public.company_team_members(company_id,team_id,user_id);

create or replace function public.save_activity_workspace_preferences(target_preferences jsonb default '{}'::jsonb)
returns public.activity_workspace_preferences
language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record; result public.activity_workspace_preferences%rowtype;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.read') then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;
  insert into public.activity_workspace_preferences(
    company_id,user_id,default_view,page_size,density,show_metrics,visible_columns,sort_key,sort_direction,updated_at
  ) values(
    context_row.company_id,auth.uid(),
    coalesce(nullif(target_preferences->>'default_view',''),'list'),
    coalesce(nullif(target_preferences->>'page_size','')::integer,50),
    coalesce(nullif(target_preferences->>'density',''),'comfortable'),
    coalesce((target_preferences->>'show_metrics')::boolean,true),
    coalesce(target_preferences->'visible_columns','["type","subject","relation","owner","date","duration","priority","status"]'::jsonb),
    coalesce(nullif(target_preferences->>'sort_key',''),'activity_at'),
    coalesce(nullif(target_preferences->>'sort_direction',''),'asc'),now()
  ) on conflict(company_id,user_id) do update set
    default_view=excluded.default_view,page_size=excluded.page_size,density=excluded.density,
    show_metrics=excluded.show_metrics,visible_columns=excluded.visible_columns,
    sort_key=excluded.sort_key,sort_direction=excluded.sort_direction,updated_at=now()
  returning * into result;
  return result;
end $$;

create or replace function public.search_activity_relations(
  target_kind text default 'all',target_search text default null,target_limit integer default 20
) returns table(entity_type text,entity_id uuid,label text,subtitle text,relation_meta jsonb)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; search_value text:=trim(coalesce(target_search,'')); limit_value integer:=least(50,greatest(5,coalesce(target_limit,20)));
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.read') then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;
  if length(search_value)<2 then return; end if;
  return query
  with candidates as (
    select case when coalesce(client.relationship_type,'client')='prospect' then 'prospect' else 'client' end entity_type,
      client.id entity_id,
      coalesce(nullif(client.trade_name,''),nullif(client.legal_name,''),nullif(concat_ws(' ',client.first_name,client.last_name),''),'Client') label,
      concat_ws(' · ',nullif(client.city,''),nullif(client.email,''),nullif(client.siret,'')) subtitle,
      jsonb_build_object('relationship_type',client.relationship_type) relation_meta,
      case when lower(coalesce(client.trade_name,client.legal_name,concat_ws(' ',client.first_name,client.last_name))) like lower(search_value)||'%' then 0 else 1 end rank
    from public.clients client
    where client.company_id=context_row.company_id and client.active
      and target_kind in('all','client','prospect')
      and (target_kind not in('client','prospect') or coalesce(client.relationship_type,'client')=target_kind)
      and concat_ws(' ',client.trade_name,client.legal_name,client.first_name,client.last_name,client.email,client.phone_e164,client.siren,client.siret,client.city) ilike '%'||search_value||'%'
    union all
    select 'contact',contact.id,coalesce(nullif(concat_ws(' ',contact.first_name,contact.last_name),''),contact.email,'Contact'),
      concat_ws(' · ',client.trade_name,client.legal_name,contact.email,contact.phone_e164),jsonb_build_object('client_id',contact.client_id),
      case when lower(concat_ws(' ',contact.first_name,contact.last_name)) like lower(search_value)||'%' then 0 else 1 end
    from public.client_contacts contact left join public.clients client on client.id=contact.client_id
    where contact.company_id=context_row.company_id and contact.active and target_kind in('all','contact')
      and concat_ws(' ',contact.first_name,contact.last_name,contact.email,contact.phone_e164,client.trade_name,client.legal_name) ilike '%'||search_value||'%'
    union all
    select 'opportunity',opportunity.id,opportunity.name,
      concat_ws(' · ',client.trade_name,client.legal_name,opportunity.stage),jsonb_build_object('client_id',opportunity.client_id,'stage',opportunity.stage),
      case when lower(opportunity.name) like lower(search_value)||'%' then 0 else 1 end
    from public.opportunities opportunity left join public.clients client on client.id=opportunity.client_id
    where opportunity.company_id=context_row.company_id and target_kind in('all','opportunity')
      and concat_ws(' ',opportunity.name,client.trade_name,client.legal_name) ilike '%'||search_value||'%'
    union all
    select case document.document_type when 'quote' then 'quote' when 'credit_note' then 'credit_note' else 'invoice' end,
      document.id,coalesce(document.number,'Brouillon'),
      concat_ws(' · ',case document.document_type when 'quote' then 'Devis' when 'credit_note' then 'Avoir' else 'Facture' end,client.trade_name,client.legal_name),
      jsonb_build_object('document_type',document.document_type,'client_id',document.client_id),
      case when lower(coalesce(document.number,'')) like lower(search_value)||'%' then 0 else 1 end
    from public.documents document left join public.clients client on client.id=document.client_id
    where document.company_id=context_row.company_id and document.document_type in('quote','invoice','credit_note')
      and target_kind in('all','document','quote','invoice','credit_note')
      and concat_ws(' ',document.number,document.subject,client.trade_name,client.legal_name) ilike '%'||search_value||'%'
    union all
    select 'supplier',supplier.id,supplier.legal_name,concat_ws(' · ',supplier.city,supplier.email,supplier.siret),
      '{}'::jsonb,case when lower(supplier.legal_name) like lower(search_value)||'%' then 0 else 1 end
    from public.suppliers supplier
    where supplier.company_id=context_row.company_id and supplier.active and target_kind in('all','supplier')
      and concat_ws(' ',supplier.legal_name,supplier.email,supplier.siret,supplier.city) ilike '%'||search_value||'%'
  ) select candidate.entity_type,candidate.entity_id,candidate.label,candidate.subtitle,candidate.relation_meta
    from candidates candidate order by candidate.rank,candidate.label,candidate.entity_id limit limit_value;
end $$;

create or replace function public.bulk_transition_activities_workspace(
  target_activity_ids uuid[],target_action text,target_value jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare activity_id uuid; changed integer:=0; skipped integer:=0; failed jsonb:='[]'::jsonb;
begin
  if coalesce(array_length(target_activity_ids,1),0)=0 then return jsonb_build_object('changed',0,'skipped',0,'failed','[]'::jsonb); end if;
  if array_length(target_activity_ids,1)>500 then raise exception 'activity_bulk_limit_exceeded'; end if;
  foreach activity_id in array target_activity_ids loop
    begin
      if public.activity_is_writable(activity_id) then
        perform public.transition_activity_workspace(activity_id,target_action,target_value);
        changed:=changed+1;
      else skipped:=skipped+1; end if;
    exception when others then
      failed:=failed||jsonb_build_array(jsonb_build_object('id',activity_id,'code',sqlstate));
    end;
  end loop;
  return jsonb_build_object('changed',changed,'skipped',skipped,'failed',failed);
end $$;

create or replace function public.get_activity_workspace_v4(
  target_view text default 'list',target_quick_filter text default 'all',target_search text default null,
  target_statuses text[] default null,target_type_ids uuid[] default null,target_owner uuid default null,
  target_team uuid default null,target_start timestamptz default null,target_end timestamptz default null,
  target_include_archived boolean default false,target_page integer default 1,target_page_size integer default 50,
  target_sort_key text default 'activity_at',target_sort_direction text default 'asc'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  context_row record;
  actor_id uuid:=auth.uid();
  activity_scope text;
  can_read_confidential boolean:=false;
  page_value integer:=greatest(1,coalesce(target_page,1));
  size_value integer:=least(200,greatest(10,coalesce(target_page_size,50)));
  sort_value text:=case when target_sort_key in('activity_at','subject','priority','status','owner') then target_sort_key else 'activity_at' end;
  direction_value text:=case when lower(target_sort_direction)='desc' then 'desc' else 'asc' end;
  result jsonb;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;
  activity_scope:=public.company_permission_scope(context_row.company_id,'crm.activities.read',actor_id);
  if coalesce(activity_scope,'none')='none' then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;
  can_read_confidential:=public.has_company_permission(context_row.company_id,'crm.activities.confidential.read');
  with scope_rows as materialized (
    select activity.*,
      coalesce(activity.starts_at,activity.due_at,activity.scheduled_at,activity.created_at) activity_at
    from public.activities activity
    where activity.company_id=context_row.company_id
      and (
        activity_scope='company'
        or coalesce(activity.assigned_user_id,activity.created_by)=actor_id
        or (activity_scope='team' and (
          exists(
            select 1 from public.company_team_members team_member
            where team_member.company_id=context_row.company_id
              and team_member.user_id=actor_id and team_member.team_id=activity.team_id
          )
          or exists(
            select 1
            from public.company_team_members mine
            join public.company_team_members resource
              on resource.company_id=mine.company_id and resource.team_id=mine.team_id
            where mine.company_id=context_row.company_id and mine.user_id=actor_id
              and resource.user_id=coalesce(activity.assigned_user_id,activity.created_by)
          )
        ))
      )
      and (
        coalesce(activity.confidentiality,'internal')<>'private'
        or can_read_confidential
        or activity.created_by=actor_id
        or activity.assigned_user_id=actor_id
        or exists(
          select 1 from public.activity_assignments assignment
          where assignment.activity_id=activity.id and assignment.user_id=actor_id
        )
        or exists(
          select 1 from public.crm_activity_participants participant
          where participant.activity_id=activity.id and participant.participant_type='user'
            and participant.participant_id=actor_id
        )
      )
  ), counters as (
    select
      count(*) filter(where archived_at is null and status not in('completed','cancelled') and activity_at::date=current_date)::integer today,
      count(*) filter(where archived_at is null and status not in('completed','cancelled') and activity_at<now())::integer overdue,
      count(*) filter(where archived_at is null and activity_at>=date_trunc('week',now()) and activity_at<date_trunc('week',now())+interval '7 days')::integer week,
      count(*) filter(where completed_at>=date_trunc('week',now()))::integer completed_week,
      count(*) filter(where archived_at is null and activity_type='call' and status not in('completed','cancelled'))::integer calls,
      count(*) filter(where archived_at is null and activity_type in('reminder','quote_followup','invoice_followup','payment_followup') and status not in('completed','cancelled'))::integer reminders,
      count(*) filter(where archived_at is not null)::integer archived,
      count(*) filter(where archived_at is null and assigned_user_id is null and status not in('completed','cancelled'))::integer unassigned
    from scope_rows
  ), visible as (
    select activity.*,type_row.label type_label,type_row.icon type_icon,type_row.color type_color,
      coalesce(client.trade_name,client.legal_name,concat_ws(' ',client.first_name,client.last_name)) entity_name,
      concat_ws(' ',contact.first_name,contact.last_name) contact_name,
      opportunity.name opportunity_name,document.number document_number,document.document_type
    from scope_rows activity
    left join public.activity_types type_row on type_row.id=activity.activity_type_id
    left join public.clients client on client.id=activity.client_id and client.company_id=activity.company_id
    left join public.client_contacts contact on contact.id=activity.contact_id and contact.company_id=activity.company_id
    left join public.opportunities opportunity on opportunity.id=activity.opportunity_id and opportunity.company_id=activity.company_id
    left join public.documents document on document.id=activity.document_id and document.company_id=activity.company_id
    where
      (case when target_quick_filter='archived' then activity.archived_at is not null
        when target_include_archived then true else activity.archived_at is null end)
      and (target_owner is null or activity.assigned_user_id=target_owner)
      and (target_team is null or activity.team_id=target_team)
      and (target_view<>'my' or activity.assigned_user_id=auth.uid() or activity.created_by=auth.uid())
      and (target_statuses is null or activity.status=any(target_statuses))
      and (target_type_ids is null or activity.activity_type_id=any(target_type_ids))
      and (target_start is null or activity.activity_at>=target_start)
      and (target_end is null or activity.activity_at<target_end)
      and (target_search is null or target_search='' or
        to_tsvector('simple',concat_ws(' ',activity.subject,activity.description,client.legal_name,client.trade_name,contact.first_name,contact.last_name,opportunity.name,document.number))
        @@ plainto_tsquery('simple',target_search))
      and case target_quick_filter
        when 'today' then activity.activity_at::date=current_date and activity.status not in('completed','cancelled')
        when 'overdue' then activity.status not in('completed','cancelled') and activity.activity_at<now()
        when 'upcoming' then activity.status not in('completed','cancelled') and activity.activity_at>=now()
        when 'week' then activity.activity_at>=date_trunc('week',now()) and activity.activity_at<date_trunc('week',now())+interval '7 days'
        when 'completed' then activity.status='completed'
        when 'cancelled' then activity.status='cancelled'
        when 'unassigned' then activity.assigned_user_id is null and activity.status not in('completed','cancelled')
        else true end
  ), counted as (select count(*)::integer total from visible), paged as (
    select * from visible
    order by
      case when sort_value='activity_at' and direction_value='asc' then activity_at end asc nulls last,
      case when sort_value='activity_at' and direction_value='desc' then activity_at end desc nulls last,
      case when sort_value='subject' and direction_value='asc' then lower(subject) end asc nulls last,
      case when sort_value='subject' and direction_value='desc' then lower(subject) end desc nulls last,
      case when sort_value='priority' and direction_value='asc' then priority end asc nulls last,
      case when sort_value='priority' and direction_value='desc' then priority end desc nulls last,
      case when sort_value='status' and direction_value='asc' then status end asc nulls last,
      case when sort_value='status' and direction_value='desc' then status end desc nulls last,
      case when sort_value='owner' and direction_value='asc' then assigned_user_id end asc nulls last,
      case when sort_value='owner' and direction_value='desc' then assigned_user_id end desc nulls last,
      id asc offset (page_value-1)*size_value limit size_value
  )
  select jsonb_build_object(
    'rows',coalesce((select jsonb_agg(to_jsonb(row)) from paged row),'[]'::jsonb),
    'total',coalesce((select total from counted),0),'page',page_value,'page_size',size_value,
    'counts',coalesce((select to_jsonb(counter) from counters counter),'{}'::jsonb),
    'types',coalesce((select jsonb_agg(to_jsonb(type_row) order by type_row.position,type_row.label) from public.activity_types type_row where type_row.company_id=context_row.company_id and type_row.active),'[]'::jsonb),
    'all_types',coalesce((select jsonb_agg(to_jsonb(type_row) order by type_row.active desc,type_row.position,type_row.label) from public.activity_types type_row where type_row.company_id=context_row.company_id),'[]'::jsonb),
    'outcomes',coalesce((select jsonb_agg(to_jsonb(outcome) order by outcome.position,outcome.label) from public.activity_outcomes outcome where outcome.company_id=context_row.company_id and outcome.active),'[]'::jsonb),
    'saved_filters',coalesce((select jsonb_agg(to_jsonb(saved_filter) order by saved_filter.is_default desc,saved_filter.name) from public.activity_saved_filters saved_filter where saved_filter.company_id=context_row.company_id and saved_filter.user_id=auth.uid()),'[]'::jsonb),
    'preferences',coalesce((select to_jsonb(preference) from public.activity_workspace_preferences preference where preference.company_id=context_row.company_id and preference.user_id=auth.uid()),'{}'::jsonb),
    'permissions',jsonb_build_object('write',context_row.can_write,'manage',context_row.can_manage,'view_all',context_row.can_view_all,'view_team',public.has_company_permission(context_row.company_id,'crm.team_activities.read'),'configure',public.has_company_permission(context_row.company_id,'crm.activities.configure'))
  ) into result;
  return result;
end $$;

revoke all on table public.activity_workspace_preferences from anon;
grant select,insert,update,delete on table public.activity_workspace_preferences to authenticated;
revoke all on function public.save_activity_workspace_preferences(jsonb) from public,anon;
grant execute on function public.save_activity_workspace_preferences(jsonb) to authenticated;
revoke all on function public.search_activity_relations(text,text,integer) from public,anon;
grant execute on function public.search_activity_relations(text,text,integer) to authenticated;
revoke all on function public.bulk_transition_activities_workspace(uuid[],text,jsonb) from public,anon;
grant execute on function public.bulk_transition_activities_workspace(uuid[],text,jsonb) to authenticated;
revoke all on function public.get_activity_workspace_v4(text,text,text,text[],uuid[],uuid,uuid,timestamptz,timestamptz,boolean,integer,integer,text,text) from public,anon;
grant execute on function public.get_activity_workspace_v4(text,text,text,text[],uuid[],uuid,uuid,timestamptz,timestamptz,boolean,integer,integer,text,text) to authenticated;
