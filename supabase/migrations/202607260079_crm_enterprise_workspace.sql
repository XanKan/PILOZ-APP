begin;

-- Final CRM workspace hardening. This migration remains additive: it enriches
-- the external mail metadata, indexes global search and exposes only atomic
-- operations that derive the current company from auth.uid().

alter table public.external_mail_links
  add column if not exists sender text,
  add column if not exists preview text,
  add column if not exists treatment_status text not null default 'new',
  add column if not exists assigned_user_id uuid;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='external_mail_links_treatment_status_check') then
    alter table public.external_mail_links add constraint external_mail_links_treatment_status_check
      check(treatment_status in('new','in_progress','processed','archived'));
  end if;
end $$;

create index if not exists external_mail_links_crm_inbox_idx
  on public.external_mail_links(company_id,treatment_status,coalesce(sent_at,created_at) desc);
create index if not exists external_mail_links_assignee_idx
  on public.external_mail_links(company_id,assigned_user_id,treatment_status);
create index if not exists crm_client_search_idx on public.clients using gin(
  to_tsvector('simple',coalesce(legal_name,'')||' '||coalesce(trade_name,'')||' '||coalesce(first_name,'')||' '||coalesce(last_name,'')||' '||coalesce(email,'')||' '||coalesce(phone_e164,''))
);
create index if not exists crm_contact_search_idx on public.client_contacts using gin(
  to_tsvector('simple',coalesce(first_name,'')||' '||coalesce(last_name,'')||' '||coalesce(email,'')||' '||coalesce(phone_e164,'')||' '||coalesce(mobile_e164,''))
);
create index if not exists crm_opportunity_search_idx on public.opportunities using gin(
  to_tsvector('simple',coalesce(name,'')||' '||coalesce(description,'')||' '||coalesce(next_action,''))
);
create index if not exists crm_activity_search_idx on public.activities using gin(
  to_tsvector('simple',coalesce(subject,'')||' '||coalesce(description,'')||' '||coalesce(result,''))
);

-- Permission flags are calculated from the same role/permission matrix as the
-- rest of Piloz. A generic member is no longer implicitly a CRM editor.
create or replace function public._crm_context()
returns table(company_id uuid,role text,can_manage boolean,can_view_all boolean,can_write boolean,can_margin boolean)
language sql stable security definer set search_path=public,pg_temp as $$
  select member.company_id,member.role,
    member.role in('owner','admin'),
    member.role in('owner','admin','accounting','auditor','read_only'),
    (public.has_company_permission(member.company_id,'manage_customer')
      or public.has_company_permission(member.company_id,'manage_opportunity')
      or public.has_company_permission(member.company_id,'manage_reminder')),
    public.has_company_permission(member.company_id,'view_margins')
  from public.company_members member
  left join public.user_preferences preference on preference.user_id=member.user_id
  where member.user_id=auth.uid() and (preference.company_id is null or preference.company_id=member.company_id)
  order by case when preference.company_id=member.company_id then 0 else 1 end,member.created_at
  limit 1
$$;

-- Replace the broad policies introduced with the CRM foundation. Business
-- records follow the granular CRM permissions, while shared configuration is
-- restricted to company administrators. Private saved views keep their own
-- author-based policies from migration 077.
do $crm_business_rls$
declare table_name text;
begin
  foreach table_name in array array[
    'crm_opportunity_products','crm_activity_participants','crm_activity_links',
    'crm_notes','crm_tag_assignments','crm_custom_field_values','crm_sequence_enrollments'
  ] loop
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format(
      'create policy %I on public.%I for insert to authenticated with check((public.has_company_permission(company_id,''manage_customer'') or public.has_company_permission(company_id,''manage_opportunity'') or public.has_company_permission(company_id,''manage_reminder'')) and created_by=auth.uid())',
      table_name||'_insert',table_name
    );
    execute format(
      'create policy %I on public.%I for update to authenticated using(public.has_company_permission(company_id,''manage_customer'') or public.has_company_permission(company_id,''manage_opportunity'') or public.has_company_permission(company_id,''manage_reminder'')) with check(public.has_company_permission(company_id,''manage_customer'') or public.has_company_permission(company_id,''manage_opportunity'') or public.has_company_permission(company_id,''manage_reminder''))',
      table_name||'_update',table_name
    );
    execute format(
      'create policy %I on public.%I for delete to authenticated using(public.has_company_permission(company_id,''manage_customer'') or public.has_company_permission(company_id,''manage_opportunity'') or public.has_company_permission(company_id,''manage_reminder''))',
      table_name||'_delete',table_name
    );
  end loop;
end
$crm_business_rls$;

do $crm_configuration_rls$
declare table_name text;
begin
  foreach table_name in array array[
    'crm_pipelines','crm_sources','crm_loss_reasons','crm_tags','crm_custom_fields',
    'crm_automation_rules','crm_sequences','crm_sequence_steps','crm_segments',
    'crm_score_rules','company_dashboard_defaults'
  ] loop
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check(public.has_company_role(company_id,array[''owner'',''admin'']) and created_by=auth.uid())',table_name||'_insert',table_name);
    execute format('create policy %I on public.%I for update to authenticated using(public.has_company_role(company_id,array[''owner'',''admin''])) with check(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_update',table_name);
    execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete',table_name);
  end loop;
end
$crm_configuration_rls$;

drop policy if exists crm_saved_views_delete on public.crm_saved_views;
create policy crm_saved_views_delete on public.crm_saved_views for delete to authenticated
  using(public.is_company_member(company_id) and (user_id=auth.uid() or public.has_company_role(company_id,array['owner','admin'])));

create or replace function public.reschedule_crm_activity(
  target_activity_id uuid,target_due_at timestamptz,target_assigned_user_id uuid default null
) returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;activity_row public.activities%rowtype;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write or target_due_at is null then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  if target_assigned_user_id is not null and not exists(
    select 1 from public.company_members member where member.company_id=context_row.company_id and member.user_id=target_assigned_user_id
  ) then raise exception 'crm_invalid_assignee' using errcode='22023'; end if;
  update public.activities set due_at=target_due_at,
    scheduled_at=case when scheduled_at is not null then target_due_at else scheduled_at end,
    assigned_user_id=coalesce(target_assigned_user_id,assigned_user_id),
    status=case when status='postponed' then 'todo' else status end,
    updated_by=auth.uid(),updated_at=now()
  where id=target_activity_id and company_id=context_row.company_id
    and (context_row.can_view_all or assigned_user_id=auth.uid())
  returning * into activity_row;
  if activity_row.id is null then raise exception 'crm_activity_not_found' using errcode='P0002'; end if;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,created_by)
  values(activity_row.company_id,'activity',activity_row.id,'activity_rescheduled','Activité replanifiée',activity_row.subject,
    jsonb_build_object('due_at',activity_row.due_at,'assigned_user_id',activity_row.assigned_user_id),auth.uid());
  return activity_row;
end
$$;

create or replace function public.save_crm_view(
  target_view_id uuid,target_object_type text,target_name text,target_filters jsonb default '{}'::jsonb,
  target_columns jsonb default '[]'::jsonb,target_sorting jsonb default '[]'::jsonb,
  target_is_shared boolean default false,target_is_default boolean default false
) returns public.crm_saved_views language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;view_row public.crm_saved_views%rowtype;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or nullif(trim(target_name),'') is null
     or target_object_type not in('pipeline','prospects','activities','reports') then
    raise exception 'crm_invalid_view' using errcode='22023';
  end if;
  if target_is_shared and not context_row.can_manage then raise exception 'crm_shared_view_forbidden' using errcode='42501'; end if;
  if target_is_default then
    update public.crm_saved_views set is_default=false,updated_by=auth.uid(),updated_at=now()
    where company_id=context_row.company_id and user_id=auth.uid() and object_type=target_object_type and is_default;
  end if;
  if target_view_id is null then
    insert into public.crm_saved_views(company_id,user_id,object_type,name,filters,columns,sorting,is_shared,is_default,created_by,updated_by)
    values(context_row.company_id,auth.uid(),target_object_type,trim(target_name),coalesce(target_filters,'{}'),coalesce(target_columns,'[]'),coalesce(target_sorting,'[]'),coalesce(target_is_shared,false),coalesce(target_is_default,false),auth.uid(),auth.uid())
    on conflict(company_id,user_id,object_type,name) do update set filters=excluded.filters,columns=excluded.columns,sorting=excluded.sorting,is_shared=excluded.is_shared,is_default=excluded.is_default,updated_by=auth.uid(),updated_at=now()
    returning * into view_row;
  else
    update public.crm_saved_views set name=trim(target_name),filters=coalesce(target_filters,'{}'),columns=coalesce(target_columns,'[]'),sorting=coalesce(target_sorting,'[]'),is_shared=coalesce(target_is_shared,false),is_default=coalesce(target_is_default,false),updated_by=auth.uid(),updated_at=now()
    where id=target_view_id and company_id=context_row.company_id and user_id=auth.uid() returning * into view_row;
  end if;
  if view_row.id is null then raise exception 'crm_view_not_found' using errcode='P0002'; end if;
  return view_row;
end
$$;

create or replace function public.update_crm_mail_link(target_link_id uuid,target_patch jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;mail_row public.external_mail_links%rowtype;client_uuid uuid;opportunity_uuid uuid;assignee_uuid uuid;status_value text;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write then raise exception 'crm_forbidden' using errcode='42501'; end if;
  client_uuid:=nullif(target_patch->>'client_id','')::uuid;
  opportunity_uuid:=nullif(target_patch->>'opportunity_id','')::uuid;
  assignee_uuid:=nullif(target_patch->>'assigned_user_id','')::uuid;
  status_value:=coalesce(nullif(target_patch->>'treatment_status',''),'new');
  if status_value not in('new','in_progress','processed','archived') then raise exception 'crm_invalid_mail_status' using errcode='22023'; end if;
  if client_uuid is not null and not exists(select 1 from public.clients where id=client_uuid and company_id=context_row.company_id) then raise exception 'crm_invalid_client'; end if;
  if opportunity_uuid is not null and not exists(select 1 from public.opportunities where id=opportunity_uuid and company_id=context_row.company_id) then raise exception 'crm_invalid_opportunity'; end if;
  if assignee_uuid is not null and not exists(select 1 from public.company_members where company_id=context_row.company_id and user_id=assignee_uuid) then raise exception 'crm_invalid_assignee'; end if;
  update public.external_mail_links link set
    client_id=case when target_patch ? 'client_id' then client_uuid else link.client_id end,
    opportunity_id=case when target_patch ? 'opportunity_id' then opportunity_uuid else link.opportunity_id end,
    assigned_user_id=case when target_patch ? 'assigned_user_id' then assignee_uuid else link.assigned_user_id end,
    treatment_status=case when target_patch ? 'treatment_status' then status_value else link.treatment_status end
  where link.id=target_link_id and link.company_id=context_row.company_id and exists(
    select 1 from public.external_connections connection where connection.id=link.connection_id and(
      connection.user_id=auth.uid() or (
        connection.connection_scope in('shared','company')
        and public.has_company_permission(connection.company_id,'extensions_manage_global')
      )
    )
  ) returning * into mail_row;
  if mail_row.id is null then raise exception 'crm_mail_not_found' using errcode='P0002'; end if;
  return to_jsonb(mail_row);
end
$$;

create or replace function public.search_crm_global(target_query text,target_limit integer default 20)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;needle text;query_value tsquery;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501'; end if;
  if length(trim(coalesce(target_query,'')))<2 then return '[]'::jsonb;end if;
  needle:='%'||lower(trim(target_query))||'%';query_value:=plainto_tsquery('simple',trim(target_query));
  return coalesce((with results as(
    select 1 rank,client.id,case when client.relationship_type='prospect' then 'prospect' else 'client' end entity_type,
      coalesce(client.legal_name,client.trade_name,client.first_name||' '||client.last_name) title,coalesce(client.email,client.phone_e164,'') subtitle,
      case when client.relationship_type='prospect' then 'crm/prospects/'||client.id else 'sales/clients' end path
    from public.clients client where client.company_id=context_row.company_id and client.active
      and (to_tsvector('simple',coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')||' '||coalesce(client.first_name,'')||' '||coalesce(client.last_name,'')||' '||coalesce(client.email,'')||' '||coalesce(client.phone_e164,'')) @@ query_value
        or lower(coalesce(client.email,'')||' '||coalesce(client.phone_e164,'')) like needle)
      and(context_row.can_view_all or client.assigned_user_id=auth.uid())
    union all
    select 2,contact.id,'contact',trim(contact.first_name||' '||contact.last_name),coalesce(contact.email,contact.mobile_e164,contact.phone_e164,''),
      case when client.relationship_type='prospect' then 'crm/prospects/'||client.id else 'sales/clients' end
    from public.client_contacts contact join public.clients client on client.id=contact.client_id and client.company_id=contact.company_id
    where contact.company_id=context_row.company_id and contact.active and client.active
      and (to_tsvector('simple',coalesce(contact.first_name,'')||' '||coalesce(contact.last_name,'')||' '||coalesce(contact.email,'')||' '||coalesce(contact.phone_e164,'')||' '||coalesce(contact.mobile_e164,'')) @@ query_value
        or lower(coalesce(contact.email,'')||' '||coalesce(contact.phone_e164,'')||' '||coalesce(contact.mobile_e164,'')) like needle)
      and(context_row.can_view_all or client.assigned_user_id=auth.uid())
    union all
    select 3,opportunity.id,'opportunity',opportunity.name,coalesce(opportunity.next_action,''),'crm/pipeline/'||opportunity.id
    from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.archived_at is null
      and to_tsvector('simple',coalesce(opportunity.name,'')||' '||coalesce(opportunity.description,'')||' '||coalesce(opportunity.next_action,'')) @@ query_value
      and(context_row.can_view_all or opportunity.assigned_user_id=auth.uid())
    union all
    select 4,document.id,'document',coalesce(document.number,'Brouillon'),coalesce(client.legal_name,document.subject,''),case when document.document_type='quote' then 'sales/quotes' else 'sales/invoices' end
    from public.documents document left join public.clients client on client.id=document.client_id and client.company_id=document.company_id
    where document.company_id=context_row.company_id and lower(coalesce(document.number,'')||' '||coalesce(document.subject,'')||' '||coalesce(client.legal_name,'')) like needle
    union all
    select 5,activity.id,'activity',activity.subject,coalesce(activity.description,''),'crm/activities'
    from public.activities activity where activity.company_id=context_row.company_id
      and to_tsvector('simple',coalesce(activity.subject,'')||' '||coalesce(activity.description,'')||' '||coalesce(activity.result,'')) @@ query_value
      and(context_row.can_view_all or activity.assigned_user_id=auth.uid())
  ) select jsonb_agg(jsonb_build_object('id',id,'type',entity_type,'title',title,'subtitle',subtitle,'path',path) order by rank,title)
    from(select * from results order by rank,title limit least(50,greatest(1,target_limit)))limited),'[]'::jsonb);
end
$$;

-- An explicit retry replays only transaction-safe actions. E-mail remains
-- connector-gated and is never reported as sent by the database.
create or replace function public.retry_crm_automation_run(target_run_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  context_row record; previous_run public.crm_automation_runs%rowtype;
  rule_row public.crm_automation_rules%rowtype; retry_run public.crm_automation_runs%rowtype;
  row_value jsonb; action_value jsonb; actor_uuid uuid:=auth.uid(); skipped_external boolean:=false;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_manage then
    raise exception 'crm_manage_permission_required' using errcode='42501';
  end if;
  select * into previous_run from public.crm_automation_runs
  where id=target_run_id and company_id=context_row.company_id and status='failed';
  if previous_run.id is null then raise exception 'crm_failed_run_not_found' using errcode='P0002'; end if;
  select * into rule_row from public.crm_automation_rules
  where id=previous_run.rule_id and company_id=context_row.company_id and status<>'archived';
  if rule_row.id is null then raise exception 'crm_automation_rule_not_found' using errcode='P0002'; end if;
  row_value:=coalesce(previous_run.input->'row','{}'::jsonb);
  insert into public.crm_automation_runs(
    company_id,rule_id,entity_type,entity_id,status,attempt,input,idempotency_key,created_by,started_at
  ) values(
    context_row.company_id,rule_row.id,previous_run.entity_type,previous_run.entity_id,'running',previous_run.attempt+1,
    previous_run.input,md5(previous_run.id::text||':'||(previous_run.attempt+1)::text||':'||clock_timestamp()::text),actor_uuid,now()
  ) returning * into retry_run;
  begin
    for action_value in select value from jsonb_array_elements(coalesce(rule_row.actions,'[]'::jsonb)) loop
      if action_value->>'type'='create_activity' then
        insert into public.activities(
          company_id,opportunity_id,client_id,activity_type,subject,due_at,priority,status,assigned_user_id,metadata,created_by,updated_by
        ) values(
          context_row.company_id,case when previous_run.entity_type='opportunity' then previous_run.entity_id else null end,
          case when previous_run.entity_type in('opportunity','activity') then nullif(row_value->>'client_id','')::uuid else null end,
          coalesce(nullif(action_value->>'activity_type',''),'task'),coalesce(nullif(action_value->>'subject',''),rule_row.name),
          now()+make_interval(days=>coalesce(nullif(action_value->>'due_days','')::integer,1)),
          coalesce(nullif(action_value->>'priority',''),'normal'),'todo',
          coalesce(nullif(action_value->>'assigned_user_id','')::uuid,nullif(row_value->>'assigned_user_id','')::uuid,actor_uuid),
          jsonb_build_object('automation_rule_id',rule_row.id,'automation_run_id',retry_run.id,'retry_of',previous_run.id),actor_uuid,actor_uuid
        );
      elsif action_value->>'type'='notify_user' then
        insert into public.notifications(
          company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by
        ) values(
          context_row.company_id,coalesce(nullif(action_value->>'user_id','')::uuid,nullif(row_value->>'assigned_user_id','')::uuid,actor_uuid),
          'crm_automation',coalesce(nullif(action_value->>'title',''),rule_row.name),nullif(action_value->>'message',''),
          previous_run.entity_type,previous_run.entity_id,
          case when previous_run.entity_type='opportunity' then '#crm/pipeline/'||previous_run.entity_id::text else '#crm/activities' end,
          jsonb_build_object('automation_rule_id',rule_row.id,'automation_run_id',retry_run.id,'retry_of',previous_run.id),actor_uuid
        );
      elsif action_value->>'type'='update_field' and previous_run.entity_type='opportunity'
        and action_value->>'field' in('priority','next_action','health','forecast_category') then
        execute format('update public.opportunities set %I=$1,updated_by=$2,updated_at=now() where id=$3 and company_id=$4',action_value->>'field')
        using action_value->>'value',actor_uuid,previous_run.entity_id,context_row.company_id;
      elsif action_value->>'type'='send_email' then
        skipped_external:=true;
      end if;
    end loop;
    update public.crm_automation_runs set status='completed',
      output=jsonb_build_object('retry_of',previous_run.id,'external_connector_required',skipped_external),finished_at=now()
    where id=retry_run.id returning * into retry_run;
    update public.crm_automation_rules set last_run_at=now(),run_count=run_count+1,updated_at=now() where id=rule_row.id;
  exception when others then
    update public.crm_automation_runs set status='failed',error_code=sqlstate,error_message=left(sqlerrm,1000),finished_at=now()
    where id=retry_run.id returning * into retry_run;
  end;
  return to_jsonb(retry_run);
end
$$;

-- Direct browser access is still read-only for mail metadata; all treatment
-- mutations go through update_crm_mail_link.
grant select(sender,preview,treatment_status,assigned_user_id) on public.external_mail_links to authenticated;
revoke all on function public.reschedule_crm_activity(uuid,timestamptz,uuid) from public,anon;
revoke all on function public.save_crm_view(uuid,text,text,jsonb,jsonb,jsonb,boolean,boolean) from public,anon;
revoke all on function public.update_crm_mail_link(uuid,jsonb) from public,anon;
revoke all on function public.search_crm_global(text,integer) from public,anon;
revoke all on function public.retry_crm_automation_run(uuid) from public,anon;
grant execute on function public.reschedule_crm_activity(uuid,timestamptz,uuid),
  public.save_crm_view(uuid,text,text,jsonb,jsonb,jsonb,boolean,boolean),
  public.update_crm_mail_link(uuid,jsonb),public.search_crm_global(text,integer),
  public.retry_crm_automation_run(uuid) to authenticated;

commit;
