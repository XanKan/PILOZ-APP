begin;
create table if not exists public.company_contact_verifications(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,
 channel text not null check(channel in('email','sms')),destination text not null,token_hash text not null,expires_at timestamptz not null,
 attempts integer not null default 0,consumed_at timestamptz,created_by uuid default auth.uid(),created_at timestamptz not null default now()
);
alter table public.company_contact_verifications enable row level security;
create policy company_contact_verifications_select on public.company_contact_verifications for select to authenticated using(public.is_company_member(company_id));
-- Insert/update is intentionally server-only. Edge Functions use the secret key.
commit;
