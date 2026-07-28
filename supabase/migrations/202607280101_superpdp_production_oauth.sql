begin;

-- SUPER PDP production is connected once per Piloz company through OAuth 2.0.
-- Tokens are encrypted by the Edge Function before they reach PostgreSQL and
-- are never exposed through PostgREST or a browser-readable policy.
create table if not exists public.superpdp_company_authorizations(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null unique references public.companies(id) on delete restrict,
  connector_id uuid unique references public.platform_connectors(id) on delete restrict,
  environment text not null default 'production' check(environment='production'),
  provider_company_id text,
  provider_company_number text,
  provider_company_name text,
  company_verification_status text not null default 'pending',
  user_identity_verification_status text,
  directory_status text not null default 'not_requested'
    check(directory_status in('not_requested','pending','active','rejected','error')),
  directory_entry_id text,
  access_token_ciphertext text,
  refresh_token_ciphertext text,
  token_type text,
  granted_scope text,
  access_token_expires_at timestamptz,
  authorized_by uuid,
  authorized_at timestamptz,
  revoked_by uuid,
  revoked_at timestamptz,
  last_verified_at timestamptz,
  last_token_refresh_at timestamptz,
  last_incoming_sync_at timestamptz,
  last_event_sync_at timestamptz,
  last_error_code text,
  last_error_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(
    revoked_at is not null
    or access_token_ciphertext is not null
    or authorized_at is null
  )
);

create table if not exists public.superpdp_oauth_states(
  id uuid primary key default gen_random_uuid(),
  state_hash text not null unique,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  pkce_verifier_ciphertext text not null,
  return_path text not null default 'settings/einvoicing',
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  check(expires_at>created_at)
);
create index if not exists superpdp_oauth_states_expiry_idx
  on public.superpdp_oauth_states(expires_at) where consumed_at is null;

create table if not exists public.superpdp_consent_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  authorization_id uuid references public.superpdp_company_authorizations(id) on delete restrict,
  actor_id uuid,
  event_type text not null check(event_type in(
    'authorization_started','authorization_granted','authorization_failed',
    'verification_refreshed','directory_requested','directory_activated',
    'directory_failed','authorization_revoked','token_refreshed'
  )),
  evidence jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
create index if not exists superpdp_consent_events_company_idx
  on public.superpdp_consent_events(company_id,occurred_at desc);

create table if not exists public.superpdp_jobs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  connector_id uuid references public.platform_connectors(id) on delete restrict,
  job_type text not null check(job_type in('send_document','sync_incoming','sync_events','sync_directory','sync_status')),
  document_id uuid references public.documents(id) on delete restrict,
  dedupe_key text not null,
  status text not null default 'pending' check(status in('pending','processing','retry_scheduled','succeeded','failed','dead_letter','cancelled')),
  attempt_count integer not null default 0 check(attempt_count>=0),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  completed_at timestamptz,
  last_error_code text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,job_type,dedupe_key)
);
create index if not exists superpdp_jobs_worker_idx
  on public.superpdp_jobs(status,available_at,created_at)
  where status in('pending','retry_scheduled');

alter table public.superpdp_company_authorizations enable row level security;
alter table public.superpdp_oauth_states enable row level security;
alter table public.superpdp_consent_events enable row level security;
alter table public.superpdp_jobs enable row level security;

-- The service role used by the Edge Functions bypasses RLS. Authenticated
-- users deliberately receive no direct access to tokens, OAuth states or jobs.
revoke all on public.superpdp_company_authorizations,public.superpdp_oauth_states,public.superpdp_jobs from anon,authenticated;
revoke all on public.superpdp_consent_events from anon,authenticated;
grant select on public.superpdp_consent_events to authenticated;
drop policy if exists superpdp_consent_events_select on public.superpdp_consent_events;
create policy superpdp_consent_events_select on public.superpdp_consent_events
  for select to authenticated using(public.is_company_member(company_id));

drop trigger if exists superpdp_consent_events_immutable on public.superpdp_consent_events;
create trigger superpdp_consent_events_immutable
  before update or delete on public.superpdp_consent_events
  for each row execute function public.protect_immutable_fiscal_row();

drop trigger if exists superpdp_company_authorizations_updated_at on public.superpdp_company_authorizations;
create trigger superpdp_company_authorizations_updated_at
  before update on public.superpdp_company_authorizations
  for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists superpdp_jobs_updated_at on public.superpdp_jobs;
create trigger superpdp_jobs_updated_at
  before update on public.superpdp_jobs
  for each row execute function public.set_current_timestamp_updated_at();

-- Sandbox and production exchanges share the same immutable register, while
-- remaining distinguishable and isolated by connector/environment.
alter table public.superpdp_invoice_exchanges
  drop constraint if exists superpdp_invoice_exchanges_environment_check;
alter table public.superpdp_invoice_exchanges
  add constraint superpdp_invoice_exchanges_environment_check
  check(environment in('sandbox','production')) not valid;
alter table public.superpdp_invoice_exchanges validate constraint superpdp_invoice_exchanges_environment_check;

-- Provider identifiers and Piloz idempotency keys are scoped by environment.
-- A sandbox identifier must never block the corresponding production record.
alter table public.superpdp_invoice_exchanges
  drop constraint if exists superpdp_invoice_exchanges_company_id_direction_external_id_key;
drop index if exists public.superpdp_invoice_exchanges_provider_uidx;
create unique index if not exists superpdp_invoice_exchanges_external_environment_uidx
  on public.superpdp_invoice_exchanges(company_id,direction,environment,external_id);
create unique index if not exists superpdp_invoice_exchanges_provider_environment_uidx
  on public.superpdp_invoice_exchanges(company_id,direction,environment,provider_invoice_id)
  where provider_invoice_id is not null;

create or replace function public.get_superpdp_connection_status(target_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_company_member(target_company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select jsonb_build_object(
    'configured', authz.id is not null and authz.revoked_at is null,
    'connector_id', connector.id,
    'status', coalesce(connector.status,'unconfigured'),
    'production_enabled', coalesce(connector.production_enabled,false),
    'provider_company_id', authz.provider_company_id,
    'provider_company_number', authz.provider_company_number,
    'provider_company_name', authz.provider_company_name,
    'company_verification_status', coalesce(authz.company_verification_status,'not_started'),
    'user_identity_verification_status', coalesce(authz.user_identity_verification_status,'not_started'),
    'directory_status', coalesce(authz.directory_status,'not_requested'),
    'authorized_at', authz.authorized_at,
    'last_verified_at', authz.last_verified_at,
    'last_incoming_sync_at', authz.last_incoming_sync_at,
    'last_event_sync_at', authz.last_event_sync_at,
    'last_error_code', authz.last_error_code
  ) into result
  from (select 1) seed
  left join public.superpdp_company_authorizations authz
    on authz.company_id=target_company_id and authz.revoked_at is null
  left join public.platform_connectors connector on connector.id=authz.connector_id;
  return coalesce(result,'{}'::jsonb);
end $$;
revoke all on function public.get_superpdp_connection_status(uuid) from public,anon;
grant execute on function public.get_superpdp_connection_status(uuid) to authenticated;

create or replace function public.queue_finalized_invoice_for_superpdp()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare connector_row public.platform_connectors%rowtype;
begin
  if new.finalized_at is null or old.finalized_at is not null
    or new.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    return new;
  end if;
  select * into connector_row from public.platform_connectors
  where company_id=new.company_id and connector_code='SUPERPDP'
    and environment='production' and status='active' and production_enabled=true
  limit 1;
  if connector_row.id is null then return new; end if;
  insert into public.superpdp_jobs(company_id,connector_id,job_type,document_id,dedupe_key,payload)
  values(new.company_id,connector_row.id,'send_document',new.id,new.id::text,
    jsonb_build_object('source','document_finalization','queued_at',now()))
  on conflict(company_id,job_type,dedupe_key) do nothing;
  return new;
end $$;

drop trigger if exists documents_queue_superpdp_after_finalization on public.documents;
create trigger documents_queue_superpdp_after_finalization
  after update of finalized_at on public.documents
  for each row execute function public.queue_finalized_invoice_for_superpdp();

-- The regular authenticated RPC deliberately checks company membership. The
-- worker uses a real member as its audit actor, without granting browsers any
-- service-level access.
create or replace function public.service_create_canonical_invoice_record(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare target_company_id uuid; actor_id uuid;
begin
  if current_user not in('postgres','service_role','supabase_admin') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select company_id into target_company_id from public.documents where id=target_document_id;
  if target_company_id is null then raise exception 'document_not_found' using errcode='P0002'; end if;
  select coalesce(
    (select authorized_by from public.superpdp_company_authorizations where company_id=target_company_id and revoked_at is null),
    (select user_id from public.company_members where company_id=target_company_id order by case role when 'owner' then 0 when 'admin' then 1 else 2 end,created_at limit 1)
  ) into actor_id;
  if actor_id is null then raise exception 'company_actor_not_found'; end if;
  perform set_config('request.jwt.claim.sub',actor_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor_id,'role','authenticated')::text,true);
  return public.create_canonical_invoice_record(target_document_id);
end $$;
revoke all on function public.service_create_canonical_invoice_record(uuid) from public,anon,authenticated;
grant execute on function public.service_create_canonical_invoice_record(uuid) to service_role;

create or replace function public.enqueue_superpdp_recurring_jobs(target_now timestamptz default now())
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare inserted_count integer;
begin
  if current_user not in('postgres','service_role','supabase_admin') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  insert into public.superpdp_jobs(company_id,connector_id,job_type,dedupe_key,payload,available_at)
  select connector.company_id,connector.id,'sync_incoming',
    'incoming-'||to_char(target_now at time zone 'UTC','YYYYMMDDHH24MI'),
    jsonb_build_object('source','scheduled_poll','queued_at',target_now),target_now
  from public.platform_connectors connector
  where connector.connector_code='SUPERPDP' and connector.environment='production'
    and connector.status='active' and connector.production_enabled=true
  on conflict(company_id,job_type,dedupe_key) do nothing;
  get diagnostics inserted_count=row_count;
  return inserted_count;
end $$;
revoke all on function public.enqueue_superpdp_recurring_jobs(timestamptz) from public,anon,authenticated;
grant execute on function public.enqueue_superpdp_recurring_jobs(timestamptz) to service_role;

do $$
begin
  if exists(select 1 from pg_extension where extname='pg_cron')
     and not exists(select 1 from cron.job where jobname='piloz-superpdp-enqueue') then
    perform cron.schedule('piloz-superpdp-enqueue','*/5 * * * *',
      $cron$select public.enqueue_superpdp_recurring_jobs(now());$cron$);
  end if;
exception when undefined_table or insufficient_privilege or invalid_schema_name or undefined_function then
  raise notice 'pg_cron unavailable: schedule enqueue_superpdp_recurring_jobs externally';
end $$;

commit;
