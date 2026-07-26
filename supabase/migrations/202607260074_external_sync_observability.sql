begin;

-- Public webhook metadata never contains an OAuth token or a provider secret.
-- Provider validation values are retained only as SHA-256 digests.
create table if not exists public.external_webhook_subscriptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  provider text not null check(provider in('google_calendar','microsoft_calendar','gmail','outlook_mail')),
  resource_type text not null check(resource_type in('calendar','mail')),
  resource_id text not null default 'primary',
  external_subscription_id text not null,
  provider_resource_id text,
  callback_token_hash text check(callback_token_hash is null or callback_token_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz not null,
  status text not null default 'active' check(status in('active','renewal_due','expired','error','stopped')),
  last_notification_at timestamptz,
  last_renewed_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(connection_id,resource_type,resource_id)
);

create table if not exists public.external_sync_errors(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  job_id uuid references public.external_sync_jobs(id) on delete set null,
  operation text not null,
  error_code text not null,
  attempt integer not null default 1 check(attempt>0),
  retryable boolean not null default true,
  next_attempt_at timestamptz,
  context jsonb not null default '{}'::jsonb,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists external_webhook_renewal_idx
  on public.external_webhook_subscriptions(status,expires_at);
create index if not exists external_sync_errors_connection_idx
  on public.external_sync_errors(connection_id,created_at desc);

alter table public.external_webhook_subscriptions enable row level security;
alter table public.external_sync_errors enable row level security;

create policy external_webhook_subscriptions_select on public.external_webhook_subscriptions
  for select to authenticated using(
    public.is_company_member(company_id)
    and exists(select 1 from public.external_connections c where c.id=external_webhook_subscriptions.connection_id and (
      c.user_id=auth.uid()
      or (c.connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
    ))
  );
create policy external_sync_errors_select on public.external_sync_errors
  for select to authenticated using(
    public.is_company_member(company_id)
    and exists(select 1 from public.external_connections c where c.id=external_sync_errors.connection_id and (
      c.user_id=auth.uid()
      or (c.connection_scope in('shared','company') and public.has_company_permission(company_id,'extensions_manage_global'))
    ))
  );

revoke all on public.external_webhook_subscriptions,public.external_sync_errors from public,anon;
grant select on public.external_webhook_subscriptions,public.external_sync_errors to authenticated;
grant select,insert,update,delete on public.external_webhook_subscriptions,public.external_sync_errors to service_role;

create or replace function public.configure_external_connection(target_connection_id uuid,target_settings jsonb)
returns public.external_connections
language plpgsql security definer set search_path=public,pg_temp as $$
declare connection_row public.external_connections; clean_settings jsonb;
begin
  select * into connection_row from public.external_connections where id=target_connection_id for update;
  if connection_row.id is null or connection_row.user_id<>auth.uid() or not public.is_company_member(connection_row.company_id) then
    raise exception 'connection_not_found' using errcode='P0002';
  end if;
  clean_settings:=jsonb_strip_nulls(jsonb_build_object(
    'calendar_id',left(coalesce(target_settings->>'calendar_id','primary'),500),
    'calendar_ids',coalesce(target_settings->'calendar_ids','[]'::jsonb),
    'sync_mode',case when target_settings->>'sync_mode' in('read_only','bidirectional') then target_settings->>'sync_mode' else 'read_only' end,
    'import_events',coalesce((target_settings->>'import_events')::boolean,true),
    'export_activities',coalesce((target_settings->>'export_activities')::boolean,false),
    'private_mode',case when target_settings->>'private_mode' in('busy_only','details') then target_settings->>'private_mode' else 'busy_only' end,
    'past_days',least(730,greatest(0,coalesce((target_settings->>'past_days')::integer,365))),
    'future_days',least(1095,greatest(1,coalesce((target_settings->>'future_days')::integer,365))),
    'timezone',left(coalesce(nullif(target_settings->>'timezone',''),'Europe/Paris'),100),
    'conflict_strategy',case when target_settings->>'conflict_strategy' in('latest','piloz','external','manual') then target_settings->>'conflict_strategy' else 'latest' end,
    'default_activity_type',case when target_settings->>'default_activity_type' in('call','email','meeting','task','note','other') then target_settings->>'default_activity_type' else 'meeting' end
  ));
  update public.external_connections set settings=clean_settings,updated_at=now() where id=connection_row.id returning * into connection_row;
  insert into public.external_sync_jobs(company_id,connection_id,job_type,idempotency_key,payload)
  values(connection_row.company_id,connection_row.id,'full_sync','settings-'||extract(epoch from date_trunc('minute',now()))::bigint,jsonb_build_object('reason','settings_changed'))
  on conflict(connection_id,idempotency_key) do nothing;
  return connection_row;
end;
$$;

revoke all on function public.configure_external_connection(uuid,jsonb) from public,anon;
grant execute on function public.configure_external_connection(uuid,jsonb) to authenticated;

create or replace function public.enqueue_external_sync_maintenance(target_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare sync_count integer:=0; renewal_count integer:=0;
begin
  if auth.uid() is not null then raise exception 'server_only' using errcode='42501'; end if;
  insert into public.external_sync_jobs(company_id,connection_id,job_type,idempotency_key,payload,next_attempt_at)
  select c.company_id,c.id,'incremental_sync','scheduled-'||to_char(target_now at time zone 'UTC','YYYYMMDDHH24MI'),
         jsonb_build_object('scheduled_at',target_now),target_now
  from public.external_connections c
  where c.status='connected' and c.provider in('google_calendar','microsoft_calendar')
    and coalesce(c.last_attempt_at,'epoch'::timestamptz)<target_now-interval '10 minutes'
  on conflict(connection_id,idempotency_key) do nothing;
  get diagnostics sync_count=row_count;

  insert into public.external_sync_jobs(company_id,connection_id,job_type,idempotency_key,payload,next_attempt_at)
  select s.company_id,s.connection_id,'renew_webhook','renew-'||s.id||'-'||to_char(s.expires_at at time zone 'UTC','YYYYMMDDHH24'),
         jsonb_build_object('subscription_id',s.id),target_now
  from public.external_webhook_subscriptions s
  where s.status in('active','renewal_due','error') and s.expires_at<target_now+interval '12 hours'
  on conflict(connection_id,idempotency_key) do nothing;
  get diagnostics renewal_count=row_count;

  update public.external_sync_jobs set status='dead_letter',completed_at=target_now
  where status='retry' and attempt_count>=8;
  delete from public.external_oauth_states where expires_at<target_now-interval '1 day';
  return jsonb_build_object('sync_jobs',sync_count,'renewal_jobs',renewal_count,'checked_at',target_now);
end;
$$;

revoke all on function public.enqueue_external_sync_maintenance(timestamptz) from public,anon,authenticated;
grant execute on function public.enqueue_external_sync_maintenance(timestamptz) to service_role;

-- Schedule database-only enqueueing when pg_cron is available. Network work
-- remains in the Edge worker and therefore no scheduler secret is stored here.
do $$
begin
  if exists(select 1 from pg_extension where extname='pg_cron')
     and not exists(select 1 from cron.job where jobname='piloz-external-sync-enqueue') then
    perform cron.schedule('piloz-external-sync-enqueue','*/10 * * * *',
      $cron$select public.enqueue_external_sync_maintenance(now());$cron$);
  end if;
exception when undefined_table or insufficient_privilege then
  raise notice 'pg_cron unavailable: schedule external-integrations process_jobs outside PostgreSQL';
end;
$$;

commit;
