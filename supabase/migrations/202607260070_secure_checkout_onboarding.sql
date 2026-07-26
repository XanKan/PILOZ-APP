begin;

-- A validated Stripe webhook creates a short lived onboarding right.  The
-- browser only keeps the Checkout Session identifier; no bearer secret or
-- claim token is transported in the return URL.
create table if not exists public.stripe_onboarding_grants(
  id uuid primary key default gen_random_uuid(),
  checkout_claim_id uuid not null unique references public.stripe_checkout_claims(id) on delete cascade,
  checkout_session_id text not null unique,
  checkout_email text not null check(checkout_email=lower(checkout_email)),
  status text not null default 'ready' check(status in('ready','consumed','expired','revoked')),
  expires_at timestamptz not null default (now()+interval '24 hours'),
  consumed_by_user_id uuid references auth.users(id) on delete set null,
  consumed_by_company_id uuid references public.companies(id) on delete set null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists stripe_onboarding_grants_ready_idx
  on public.stripe_onboarding_grants(status,expires_at);

create table if not exists public.stripe_checkout_audit_events(
  id bigint generated always as identity primary key,
  checkout_claim_id uuid references public.stripe_checkout_claims(id) on delete set null,
  event_key text not null,
  event_type text not null,
  outcome text not null check(outcome in('accepted','rejected','ignored','failed')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(event_key,event_type,outcome)
);

alter table public.stripe_onboarding_grants enable row level security;
alter table public.stripe_checkout_audit_events enable row level security;
revoke all on public.stripe_onboarding_grants,public.stripe_checkout_audit_events from public,anon,authenticated;
grant select,insert,update on public.stripe_onboarding_grants to service_role;
grant select,insert on public.stripe_checkout_audit_events to service_role;

create or replace function public.expire_stripe_onboarding_grants(check_time timestamptz default now())
returns integer
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare affected integer;
begin
  if auth.role()<>'service_role' then
    raise exception 'forbidden' using errcode='42501';
  end if;
  update public.stripe_onboarding_grants
     set status='expired',updated_at=check_time
   where status='ready' and expires_at<=check_time;
  get diagnostics affected=row_count;
  return affected;
end;
$$;
revoke all on function public.expire_stripe_onboarding_grants(timestamptz) from public,anon,authenticated;
grant execute on function public.expire_stripe_onboarding_grants(timestamptz) to service_role;

commit;
