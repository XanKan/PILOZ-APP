-- Exact weekly activity progress used by the Activities command centre.
-- Additive and tenant-scoped: no existing data is modified.

create or replace function public.get_activity_week_progress_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  context_row record;
  actor_id uuid:=auth.uid();
  activity_scope text;
  can_read_confidential boolean:=false;
  result jsonb;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;

  activity_scope:=public.company_permission_scope(
    context_row.company_id,
    'crm.activities.read',
    actor_id
  );
  if coalesce(activity_scope,'none')='none' then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;

  can_read_confidential:=public.has_company_permission(
    context_row.company_id,
    'crm.activities.confidential.read'
  );

  with scoped as materialized (
    select
      activity.status,
      activity.archived_at,
      coalesce(
        activity.starts_at,
        activity.due_at,
        activity.scheduled_at,
        activity.created_at
      ) as activity_at
    from public.activities activity
    where activity.company_id=context_row.company_id
      and (
        activity_scope='company'
        or coalesce(activity.assigned_user_id,activity.created_by)=actor_id
        or (activity_scope='team' and (
          exists(
            select 1
            from public.company_team_members team_member
            where team_member.company_id=context_row.company_id
              and team_member.user_id=actor_id
              and team_member.team_id=activity.team_id
          )
          or exists(
            select 1
            from public.company_team_members mine
            join public.company_team_members resource
              on resource.company_id=mine.company_id
             and resource.team_id=mine.team_id
            where mine.company_id=context_row.company_id
              and mine.user_id=actor_id
              and resource.user_id=coalesce(
                activity.assigned_user_id,
                activity.created_by
              )
          )
        ))
      )
      and (
        coalesce(activity.confidentiality,'internal')<>'private'
        or can_read_confidential
        or activity.created_by=actor_id
        or activity.assigned_user_id=actor_id
        or exists(
          select 1
          from public.activity_assignments assignment
          where assignment.activity_id=activity.id
            and assignment.user_id=actor_id
        )
        or exists(
          select 1
          from public.crm_activity_participants participant
          where participant.activity_id=activity.id
            and participant.participant_type='user'
            and participant.participant_id=actor_id
        )
      )
  )
  select jsonb_build_object(
    'week_open',count(*) filter(
      where archived_at is null
        and status not in('completed','cancelled')
        and activity_at>=date_trunc('week',now())
        and activity_at<date_trunc('week',now())+interval '7 days'
    )::integer,
    'week_completed',count(*) filter(
      where archived_at is null
        and status='completed'
        and activity_at>=date_trunc('week',now())
        and activity_at<date_trunc('week',now())+interval '7 days'
    )::integer
  ) into result
  from scoped;

  return coalesce(
    result,
    jsonb_build_object('week_open',0,'week_completed',0)
  );
end
$$;

revoke all on function public.get_activity_week_progress_v1() from public,anon;
grant execute on function public.get_activity_week_progress_v1() to authenticated;
