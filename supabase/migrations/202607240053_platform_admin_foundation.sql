begin;

-- PILOZ-ADMIN utilise les tables plans/subscriptions existantes comme source
-- de vérité. Cette migration est additive : aucun abonnement ni prix historique
-- n'est supprimé ou remplacé.

alter table public.companies
  add column if not exists platform_status text not null default 'active',
  add column if not exists suspension_level text,
  add column if not exists suspended_at timestamptz,
  add column if not exists suspension_reason text,
  add column if not exists internal_admin_notes text,
  add column if not exists admin_tags text[] not null default '{}';

alter table public.company_members
  add column if not exists platform_status text not null default 'active',
  add column if not exists suspended_at timestamptz,
  add column if not exists suspension_reason text;
alter table public.company_members drop constraint if exists company_members_platform_status_check;
alter table public.company_members add constraint company_members_platform_status_check
  check(platform_status in('active','suspended')) not valid;
create index if not exists company_members_platform_status_idx on public.company_members(platform_status,company_id,user_id);

alter table public.companies drop constraint if exists companies_platform_status_check;
alter table public.companies add constraint companies_platform_status_check
  check(platform_status in('active','suspended','deletion_pending','anonymized')) not valid;
alter table public.companies drop constraint if exists companies_suspension_level_check;
alter table public.companies add constraint companies_suspension_level_check
  check(suspension_level is null or suspension_level in('read_only','creation_blocked','full')) not valid;

alter table public.plans
  add column if not exists description text,
  add column if not exists availability text not null default 'available',
  add column if not exists recommended boolean not null default false,
  add column if not exists public_plan boolean not null default true,
  add column if not exists effective_from timestamptz not null default now();

create table if not exists public.platform_admins(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null check(role in('super_admin','support_admin','billing_admin','compliance_admin','read_only_admin')),
  status text not null default 'active' check(status in('invited','active','suspended')),
  first_name text,
  last_name text,
  email text not null,
  mfa_required boolean not null default true check(mfa_required),
  timezone text not null default 'Europe/Paris',
  language text not null default 'fr',
  theme text not null default 'light',
  notification_preferences jsonb not null default '{}'::jsonb,
  allowed_ip_ranges cidr[] not null default '{}',
  last_login_at timestamptz,
  last_activity_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  suspended_at timestamptz,
  suspended_by uuid,
  updated_at timestamptz not null default now()
);

create unique index if not exists platform_admins_email_idx on public.platform_admins(lower(email));
create index if not exists platform_admins_status_role_idx on public.platform_admins(status,role);

create table if not exists public.platform_admin_permissions(
  role text not null,
  permission text not null,
  allowed boolean not null default true,
  created_at timestamptz not null default now(),
  primary key(role,permission),
  check(role in('super_admin','support_admin','billing_admin','compliance_admin','read_only_admin'))
);

insert into public.platform_admin_permissions(role,permission)
select role_name,permission_name from unnest(array[
  'super_admin','support_admin','billing_admin','compliance_admin','read_only_admin'
]::text[]) role_name
cross join unnest(array[
  'profile.read','admin.read','admin.write','audit.read','audit.write','companies.read','companies.write',
  'companies.suspend','users.read','users.write','users.revoke_sessions','subscriptions.read',
  'subscriptions.write','plans.read','plans.write','revenue.read','billing.read','billing.write',
  'support.read','support.write','support.session','compliance.read','compliance.run',
  'system.read','system.run','privacy.read','privacy.write','notifications.read'
]::text[]) permission_name
where role_name='super_admin'
on conflict do nothing;

insert into public.platform_admin_permissions(role,permission) values
  ('support_admin','profile.read'),('billing_admin','profile.read'),
  ('compliance_admin','profile.read'),('read_only_admin','profile.read'),
  ('support_admin','companies.read'),('support_admin','users.read'),('support_admin','support.read'),
  ('support_admin','support.write'),('support_admin','support.session'),('support_admin','audit.read'),
  ('support_admin','notifications.read'),('billing_admin','companies.read'),('billing_admin','users.read'),
  ('billing_admin','subscriptions.read'),('billing_admin','subscriptions.write'),('billing_admin','plans.read'),
  ('billing_admin','revenue.read'),('billing_admin','billing.read'),('billing_admin','billing.write'),
  ('billing_admin','audit.read'),('billing_admin','notifications.read'),('compliance_admin','companies.read'),
  ('compliance_admin','users.read'),('compliance_admin','compliance.read'),('compliance_admin','compliance.run'),
  ('compliance_admin','privacy.read'),('compliance_admin','privacy.write'),('compliance_admin','system.read'),
  ('compliance_admin','audit.read'),('compliance_admin','notifications.read'),('read_only_admin','companies.read'),
  ('read_only_admin','users.read'),('read_only_admin','subscriptions.read'),('read_only_admin','plans.read'),
  ('read_only_admin','revenue.read'),('read_only_admin','billing.read'),('read_only_admin','support.read'),
  ('read_only_admin','compliance.read'),('read_only_admin','system.read'),('read_only_admin','audit.read'),
  ('read_only_admin','notifications.read')
on conflict do nothing;

create or replace function public.is_platform_admin(target_permission text default null,require_mfa boolean default true)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select exists(
    select 1 from public.platform_admins admin
    where admin.user_id=auth.uid() and admin.status='active'
      and (not require_mfa or coalesce(auth.jwt()->>'aal','')='aal2')
      and (target_permission is null or exists(
        select 1 from public.platform_admin_permissions permission
        where permission.role=admin.role and permission.permission=target_permission and permission.allowed
      ))
  )
$$;

create or replace function public.platform_admin_recent_auth(max_age_seconds integer default 300)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.is_platform_admin(null,true)
    and coalesce((auth.jwt()->>'iat')::bigint,0)>=extract(epoch from now())::bigint-greatest(60,least(max_age_seconds,900))
$$;

create table if not exists public.platform_admin_sessions(
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references public.platform_admins(id) on delete cascade,
  auth_session_id text,
  started_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  expires_at timestamptz not null default(now()+interval '30 minutes'),
  revoked_at timestamptz,
  revoked_by uuid references public.platform_admins(id),
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default now()
);
create index if not exists platform_admin_sessions_active_idx on public.platform_admin_sessions(admin_id,expires_at) where revoked_at is null;
create unique index if not exists platform_admin_sessions_auth_uidx on public.platform_admin_sessions(admin_id,auth_session_id)
  where auth_session_id is not null;

create table if not exists public.platform_admin_audit_events(
  id uuid primary key default gen_random_uuid(),
  sequence_number bigint generated always as identity unique,
  admin_id uuid references public.platform_admins(id),
  admin_role text,
  action text not null,
  target_type text not null,
  target_id text,
  company_id uuid references public.companies(id) on delete set null,
  previous_state jsonb,
  new_state jsonb,
  reason text,
  ip_address inet,
  user_agent text,
  occurred_at timestamptz not null default now(),
  request_id uuid not null default gen_random_uuid(),
  result text not null default 'success' check(result in('success','failure','denied')),
  error_code text,
  previous_hash text,
  event_hash text not null default ''
);
create index if not exists platform_admin_audit_time_idx on public.platform_admin_audit_events(occurred_at desc);
create index if not exists platform_admin_audit_target_idx on public.platform_admin_audit_events(target_type,target_id,occurred_at desc);
create index if not exists platform_admin_audit_company_idx on public.platform_admin_audit_events(company_id,occurred_at desc);

create or replace function public.chain_platform_admin_audit_event()
returns trigger language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare prior text;
begin
  perform pg_advisory_xact_lock(hashtextextended('platform_admin_audit_chain',0));
  select event_hash into prior from public.platform_admin_audit_events order by sequence_number desc limit 1;
  new.previous_hash:=coalesce(prior,'GENESIS');
  new.event_hash:=encode(extensions.digest(convert_to(concat_ws('|',new.sequence_number::text,new.id::text,new.admin_id::text,new.action,
    new.target_type,coalesce(new.target_id,''),coalesce(new.company_id::text,''),coalesce(new.previous_state::text,''),
    coalesce(new.new_state::text,''),coalesce(new.reason,''),new.occurred_at::text,new.result,coalesce(new.error_code,''),
    new.previous_hash),'UTF8'),'sha256'),'hex');
  return new;
end $$;
drop trigger if exists platform_admin_audit_chain on public.platform_admin_audit_events;
create trigger platform_admin_audit_chain before insert on public.platform_admin_audit_events
for each row execute function public.chain_platform_admin_audit_event();

create or replace function public.prevent_platform_ledger_mutation()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'append_only_ledger' using errcode='55000'; end $$;
drop trigger if exists platform_admin_audit_immutable on public.platform_admin_audit_events;
create trigger platform_admin_audit_immutable before update or delete on public.platform_admin_audit_events
for each row execute function public.prevent_platform_ledger_mutation();

create or replace function public.append_platform_admin_audit(
  target_action text,target_type text,target_id text default null,target_company_id uuid default null,
  old_state jsonb default null,new_state jsonb default null,target_reason text default null,
  target_result text default 'success',target_error_code text default null,target_request_id uuid default gen_random_uuid()
) returns uuid language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; event_id uuid;
begin
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  if admin.id is null or coalesce(auth.jwt()->>'aal','')<>'aal2' then raise exception 'platform_admin_mfa_required' using errcode='42501'; end if;
  if nullif(trim(target_action),'') is null or nullif(trim(target_type),'') is null then raise exception 'invalid_audit_event'; end if;
  insert into public.platform_admin_audit_events(admin_id,admin_role,action,target_type,target_id,company_id,
    previous_state,new_state,reason,request_id,result,error_code)
  values(admin.id,admin.role,trim(target_action),trim(target_type),target_id,target_company_id,old_state,new_state,
    nullif(trim(target_reason),''),target_request_id,target_result,target_error_code) returning id into event_id;
  return event_id;
end $$;

create table if not exists public.subscription_plan_versions(
  id uuid primary key default gen_random_uuid(),
  plan_key text not null references public.plans(key),
  version integer not null,
  name text not null,
  description text,
  price_monthly_cents integer not null check(price_monthly_cents>=0),
  price_annual_cents integer not null check(price_annual_cents>=0),
  max_users integer not null check(max_users>0),
  features jsonb not null default '[]'::jsonb,
  limits jsonb not null default '{}'::jsonb,
  availability text not null default 'available',
  recommended boolean not null default false,
  public_plan boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid references public.platform_admins(id),
  unique(plan_key,version)
);
create index if not exists subscription_plan_versions_effective_idx on public.subscription_plan_versions(plan_key,effective_from desc);

insert into public.subscription_plan_versions(plan_key,version,name,description,price_monthly_cents,price_annual_cents,max_users,features,availability,recommended,public_plan,effective_from)
select p.key,1,p.name,p.description,p.price_monthly_cents,p.price_annual_cents,p.max_users,p.features,p.availability,p.recommended,p.public_plan,p.effective_from
from public.plans p on conflict(plan_key,version) do nothing;

alter table public.subscriptions
  add column if not exists plan_version_id uuid references public.subscription_plan_versions(id),
  add column if not exists contract_monthly_cents integer,
  add column if not exists contract_annual_cents integer,
  add column if not exists discount_type text,
  add column if not exists discount_value numeric(12,2),
  add column if not exists discount_ends_at timestamptz,
  add column if not exists renewal_at timestamptz,
  add column if not exists payment_status text not null default 'not_configured',
  add column if not exists provider text not null default 'manual',
  add column if not exists max_users_override integer,
  add column if not exists feature_overrides jsonb not null default '{}'::jsonb,
  add column if not exists scheduled_plan_version_id uuid references public.subscription_plan_versions(id),
  add column if not exists scheduled_effective_at timestamptz,
  add column if not exists pre_suspension_status text,
  add column if not exists internal_note text;

alter table public.subscriptions drop constraint if exists subscriptions_discount_type_check;
alter table public.subscriptions add constraint subscriptions_discount_type_check
  check(discount_type is null or discount_type in('fixed','percent')) not valid;
alter table public.subscriptions drop constraint if exists subscriptions_provider_check;
alter table public.subscriptions add constraint subscriptions_provider_check
  check(provider in('manual','stripe')) not valid;

update public.subscriptions subscription set
  plan_version_id=coalesce(subscription.plan_version_id,version.id),
  contract_monthly_cents=coalesce(subscription.contract_monthly_cents,version.price_monthly_cents),
  contract_annual_cents=coalesce(subscription.contract_annual_cents,version.price_annual_cents)
from public.subscription_plan_versions version
where version.plan_key=subscription.plan_key and version.version=1
  and (subscription.plan_version_id is null or subscription.contract_monthly_cents is null or subscription.contract_annual_cents is null);

create or replace function public.provision_trial_subscription()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare version public.subscription_plan_versions%rowtype;
begin
  select plan_version.* into version from public.subscription_plan_versions plan_version where plan_version.plan_key='essential'
    and plan_version.effective_from<=now() and (plan_version.effective_to is null or plan_version.effective_to>now()) order by plan_version.version desc limit 1;
  insert into public.subscriptions(company_id,plan_key,plan_version_id,billing_interval,status,trial_started_at,trial_ends_at,
    contract_monthly_cents,contract_annual_cents,provider,payment_status)
  values(new.id,'essential',version.id,'monthly','trialing',now(),now()+interval '14 days',
    version.price_monthly_cents,version.price_annual_cents,'manual','not_configured')
  on conflict(company_id) do nothing;
  return new;
end $$;

create table if not exists public.subscription_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  event_type text not null,
  previous_state jsonb,
  new_state jsonb,
  reason text,
  financial_impact_cents integer,
  effective_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references public.platform_admins(id)
);
create index if not exists subscription_events_company_idx on public.subscription_events(company_id,created_at desc);
drop trigger if exists subscription_events_immutable on public.subscription_events;
create trigger subscription_events_immutable before update or delete on public.subscription_events
for each row execute function public.prevent_platform_ledger_mutation();

create table if not exists public.subscription_discounts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  discount_type text not null check(discount_type in('fixed','percent')),
  value numeric(12,2) not null check(value>=0),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  reason text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.platform_admins(id)
);

create table if not exists public.company_feature_overrides(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  feature_key text not null,
  enabled boolean not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  reason text not null,
  created_at timestamptz not null default now(),
  created_by uuid references public.platform_admins(id),
  unique(company_id,feature_key,starts_at)
);
create index if not exists company_feature_overrides_lookup_idx on public.company_feature_overrides(company_id,feature_key,starts_at desc);

create table if not exists public.platform_billing_invoices(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  number text not null unique,period_start date,period_end date,plan_version_id uuid references public.subscription_plan_versions(id),
  amount_excl_tax_cents integer not null default 0,tax_cents integer not null default 0,amount_incl_tax_cents integer not null default 0,
  paid_cents integer not null default 0,status text not null default 'draft',issued_at timestamptz,due_at timestamptz,
  provider text not null default 'manual',external_invoice_id text,idempotency_key text,created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),created_by uuid references public.platform_admins(id)
);
create index if not exists platform_billing_invoices_company_status_idx on public.platform_billing_invoices(company_id,status,due_at);
create unique index if not exists platform_billing_invoices_external_idx on public.platform_billing_invoices(provider,external_invoice_id) where external_invoice_id is not null;

create table if not exists public.platform_billing_payments(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  invoice_id uuid references public.platform_billing_invoices(id) on delete restrict,amount_cents integer not null check(amount_cents>0),
  currency text not null default 'EUR',status text not null,payment_method text,paid_at timestamptz,provider text not null default 'manual',
  external_payment_id text,idempotency_key text,created_at timestamptz not null default now(),created_by uuid references public.platform_admins(id)
);
create index if not exists platform_billing_payments_company_time_idx on public.platform_billing_payments(company_id,paid_at desc);
create unique index if not exists platform_billing_payments_external_idx on public.platform_billing_payments(provider,external_payment_id) where external_payment_id is not null;

create table if not exists public.platform_billing_refunds(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  payment_id uuid not null references public.platform_billing_payments(id) on delete restrict,amount_cents integer not null check(amount_cents>0),
  reason text not null,status text not null,refunded_at timestamptz,provider text not null default 'manual',external_refund_id text,
  created_at timestamptz not null default now(),created_by uuid references public.platform_admins(id)
);

create table if not exists public.support_sessions(
  id uuid primary key default gen_random_uuid(),admin_id uuid not null references public.platform_admins(id),
  company_id uuid not null references public.companies(id) on delete cascade,reason text not null,mode text not null default 'read_only'
    check(mode in('read_only','limited_write')),started_at timestamptz not null default now(),expires_at timestamptz not null,
  ended_at timestamptz,ended_by uuid references public.platform_admins(id),created_at timestamptz not null default now()
);
create index if not exists support_sessions_active_idx on public.support_sessions(admin_id,expires_at) where ended_at is null;

create table if not exists public.support_cases(
  id uuid primary key default gen_random_uuid(),company_id uuid references public.companies(id) on delete set null,
  user_id uuid,subject text not null,description text,priority text not null default 'normal',status text not null default 'new',
  assigned_admin_id uuid references public.platform_admins(id),internal_notes text,created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),created_by uuid references public.platform_admins(id)
);
create index if not exists support_cases_status_idx on public.support_cases(status,priority,created_at desc);

create table if not exists public.platform_notifications(
  id uuid primary key default gen_random_uuid(),event_type text not null,severity text not null default 'info',title text not null,
  message text not null,target_role text,company_id uuid references public.companies(id) on delete set null,action_url text,
  read_by uuid[] not null default '{}',created_at timestamptz not null default now(),expires_at timestamptz
);
create index if not exists platform_notifications_time_idx on public.platform_notifications(created_at desc);

create table if not exists public.platform_system_events(
  id uuid primary key default gen_random_uuid(),event_type text not null,severity text not null,status text not null,
  source text not null,summary text not null,details jsonb not null default '{}'::jsonb,retry_count integer not null default 0,
  occurred_at timestamptz not null default now(),resolved_at timestamptz,created_at timestamptz not null default now()
);
create index if not exists platform_system_events_open_idx on public.platform_system_events(status,severity,occurred_at desc);

create table if not exists public.platform_revenue_snapshots(
  id uuid primary key default gen_random_uuid(),period_start date not null,period_end date not null,mrr_cents bigint not null default 0,
  arr_cents bigint not null default 0,gross_revenue_cents bigint not null default 0,net_revenue_cents bigint not null default 0,
  refunds_cents bigint not null default 0,overdue_cents bigint not null default 0,new_subscriptions integer not null default 0,
  canceled_subscriptions integer not null default 0,active_companies integer not null default 0,trials integer not null default 0,
  conversions integer not null default 0,calculated_at timestamptz not null default now(),source_hash text,
  unique(period_start,period_end)
);

create or replace function public.subscription_mrr_cents(subscription public.subscriptions,at_time timestamptz default now())
returns integer language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare base numeric; reduction numeric:=0;
begin
  if subscription.status not in('active','past_due') then return 0; end if;
  base:=case when subscription.billing_interval='annual' then coalesce(subscription.contract_annual_cents,0)/12.0
    else coalesce(subscription.contract_monthly_cents,0) end;
  if subscription.discount_type is not null and (subscription.discount_ends_at is null or subscription.discount_ends_at>at_time) then
    reduction:=case when subscription.discount_type='percent' then base*least(100,subscription.discount_value)/100
      else subscription.discount_value*100 end;
  end if;
  return greatest(0,round(base-reduction));
end $$;

create or replace function public.has_feature(target_company_id uuid,feature_key text)
returns boolean language plpgsql stable security definer set search_path=public,pg_temp as $$
declare override_value boolean; subscription public.subscriptions%rowtype; features jsonb;
begin
  if auth.uid() is not null and not public.is_company_member(target_company_id)
    and not public.is_platform_admin('companies.read',true) then return false; end if;
  select feature.enabled into override_value from public.company_feature_overrides feature
  where feature.company_id=target_company_id and feature.feature_key=feature_key and feature.starts_at<=now()
    and (feature.ends_at is null or feature.ends_at>now()) order by feature.starts_at desc limit 1;
  if override_value is not null then return override_value; end if;
  select * into subscription from public.subscriptions where company_id=target_company_id
    and status in('trialing','active','past_due');
  if subscription.company_id is null then return false; end if;
  if subscription.feature_overrides ? feature_key then return coalesce((subscription.feature_overrides->>feature_key)::boolean,false); end if;
  select version.features into features from public.subscription_plan_versions version where version.id=subscription.plan_version_id;
  if features is null then select plan.features into features from public.plans plan where plan.key=subscription.plan_key; end if;
  return coalesce(features ? feature_key,false);
end $$;

create or replace function public.platform_admin_context()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype;
begin
  select * into admin from public.platform_admins where user_id=auth.uid();
  if admin.id is null or admin.status<>'active' then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  return jsonb_build_object('id',admin.id,'user_id',admin.user_id,'role',admin.role,'status',admin.status,
    'first_name',admin.first_name,'last_name',admin.last_name,'email',admin.email,'mfa_required',admin.mfa_required,
    'aal',coalesce(auth.jwt()->>'aal','aal1'),'permissions',coalesce((select jsonb_agg(permission.permission order by permission.permission)
      from public.platform_admin_permissions permission where permission.role=admin.role and permission.allowed),'[]'::jsonb));
end $$;

create or replace function public.platform_admin_list_companies(
  search_text text default null,status_filter text default null,plan_filter text default null,page_number integer default 1,page_size integer default 25
) returns table(company_id uuid,company_name text,trade_name text,identifier text,owner_email text,phone text,plan_key text,
  subscription_status text,trial_ends_at timestamptz,user_count bigint,created_at timestamptz,last_activity_at timestamptz,
  mrr_cents integer,account_status text,total_count bigint)
language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_platform_admin('companies.read',true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  page_number:=greatest(1,page_number);page_size:=greatest(1,least(page_size,100));
  return query select company.id,coalesce(setting.legal_name,company.name),setting.trade_name,company.id::text,
    owner.email::text,setting.phone,subscription.plan_key,subscription.status,subscription.trial_ends_at,
    (select count(*) from public.company_members member where member.company_id=company.id),company.created_at,
    greatest(company.updated_at,subscription.updated_at),public.subscription_mrr_cents(subscription),company.platform_status,count(*) over()
  from public.companies company
  left join public.company_settings setting on setting.company_id=company.id
  left join public.subscriptions subscription on subscription.company_id=company.id
  left join auth.users owner on owner.id=company.owner_user_id
  where (status_filter is null or status_filter='' or company.platform_status=status_filter or subscription.status=status_filter)
    and (plan_filter is null or plan_filter='' or subscription.plan_key=plan_filter)
    and (search_text is null or trim(search_text)='' or concat_ws(' ',company.id,company.name,setting.legal_name,setting.trade_name,
      setting.siret,setting.email,owner.email,subscription.plan_key) ilike '%'||trim(search_text)||'%')
  order by company.created_at desc offset (page_number-1)*page_size limit page_size;
end $$;

create or replace function public.platform_admin_list_users(
  search_text text default null,target_company_id uuid default null,page_number integer default 1,page_size integer default 25
) returns table(user_id uuid,email text,full_name text,company_id uuid,company_name text,company_role text,member_created_at timestamptz,
  last_sign_in_at timestamptz,mfa_enabled boolean,account_status text,total_count bigint)
language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_platform_admin('users.read',true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  page_number:=greatest(1,page_number);page_size:=greatest(1,least(page_size,100));
  return query select auth_user.id,auth_user.email::text,coalesce(auth_user.raw_user_meta_data->>'full_name',
    concat_ws(' ',auth_user.raw_user_meta_data->>'first_name',auth_user.raw_user_meta_data->>'last_name')),
    member.company_id,coalesce(setting.trade_name,setting.legal_name,company.name),member.role,member.created_at,
    auth_user.last_sign_in_at,exists(select 1 from auth.mfa_factors factor where factor.user_id=auth_user.id and factor.status='verified'),
    case when (auth_user.banned_until is not null and auth_user.banned_until>now()) or member.platform_status='suspended' then 'suspended' else 'active' end,count(*) over()
  from public.company_members member join auth.users auth_user on auth_user.id=member.user_id
  join public.companies company on company.id=member.company_id left join public.company_settings setting on setting.company_id=company.id
  where (target_company_id is null or member.company_id=target_company_id)
    and (search_text is null or trim(search_text)='' or concat_ws(' ',auth_user.email,auth_user.raw_user_meta_data->>'full_name',
      company.name,setting.legal_name,setting.trade_name,member.role) ilike '%'||trim(search_text)||'%')
  order by auth_user.created_at desc offset (page_number-1)*page_size limit page_size;
end $$;

create or replace function public.platform_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_platform_admin('companies.read',true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  return jsonb_build_object(
    'active_companies',(select count(*) from public.companies where platform_status='active'),
    'trial_companies',(select count(*) from public.subscriptions where status='trialing'),
    'active_subscriptions',(select count(*) from public.subscriptions where status='active'),
    'past_due_subscriptions',(select count(*) from public.subscriptions where status='past_due'),
    'canceled_subscriptions',(select count(*) from public.subscriptions where status in('canceled','expired')),
    'new_companies_month',(select count(*) from public.companies where created_at>=date_trunc('month',now())),
    'active_users',(select count(distinct user_id) from public.company_members),
    'mrr_cents',(select coalesce(sum(public.subscription_mrr_cents(subscription)),0) from public.subscriptions subscription),
    'arr_cents',(select coalesce(sum(public.subscription_mrr_cents(subscription)),0)*12 from public.subscriptions subscription),
    'cash_month_cents',(select coalesce(sum(amount_cents),0) from public.platform_billing_payments where status='succeeded' and paid_at>=date_trunc('month',now())),
    'cash_year_cents',(select coalesce(sum(amount_cents),0) from public.platform_billing_payments where status='succeeded' and paid_at>=date_trunc('year',now())),
    'refunds_month_cents',(select coalesce(sum(amount_cents),0) from public.platform_billing_refunds where status='succeeded' and refunded_at>=date_trunc('month',now())),
    'gross_revenue_cents',(select coalesce(sum(amount_cents),0) from public.platform_billing_payments where status='succeeded'),
    'net_revenue_cents',(select coalesce(sum(amount_cents),0) from public.platform_billing_payments where status='succeeded')-
      (select coalesce(sum(amount_cents),0) from public.platform_billing_refunds where status='succeeded'),
    'overdue_cents',(select coalesce(sum(greatest(0,amount_incl_tax_cents-paid_cents)),0) from public.platform_billing_invoices where status in('past_due','overdue')),
    'arpu_cents',case when (select count(*) from public.subscriptions where status='active')=0 then 0 else
      round((select coalesce(sum(public.subscription_mrr_cents(subscription)),0) from public.subscriptions subscription)::numeric/
        (select count(*) from public.subscriptions where status='active')) end,
    'customer_churn_month_percent',case when (select count(*) from public.subscriptions where status in('active','past_due','canceled'))=0 then 0 else
      round(100.0*(select count(*) from public.subscriptions where status='canceled' and updated_at>=date_trunc('month',now()))/
        (select count(*) from public.subscriptions where status in('active','past_due','canceled')),2) end,
    'trial_conversion_percent',case when (select count(*) from public.subscriptions where trial_started_at is not null)=0 then 0 else
      round(100.0*(select count(*) from public.subscriptions where trial_started_at is not null and subscription_started_at is not null)/
        (select count(*) from public.subscriptions where trial_started_at is not null),2) end,
    'average_trial_conversion_days',(select coalesce(round(avg(extract(epoch from(subscription_started_at-trial_started_at))/86400.0),1),0)
      from public.subscriptions where trial_started_at is not null and subscription_started_at is not null),
    'stripe_configured',exists(select 1 from public.subscriptions where provider='stripe'),
    'calculated_at',now()
  );
end $$;

create or replace function public.platform_admin_change_subscription(
  target_company_id uuid,target_plan_version_id uuid,target_billing_interval text,effective_mode text,
  target_discount_type text default null,target_discount_value numeric default null,target_discount_ends_at timestamptz default null,
  target_reason text default null,target_note text default null
) returns public.subscriptions language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; old_row public.subscriptions%rowtype; new_row public.subscriptions%rowtype;
  version public.subscription_plan_versions%rowtype; old_mrr integer; new_mrr integer;
begin
  if not public.is_platform_admin('subscriptions.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if target_billing_interval not in('monthly','annual') or effective_mode not in('immediate','renewal') then raise exception 'invalid_subscription_change'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  select * into old_row from public.subscriptions where company_id=target_company_id for update;
  select * into version from public.subscription_plan_versions where id=target_plan_version_id;
  if old_row.company_id is null or version.id is null then raise exception 'subscription_or_plan_not_found'; end if;
  old_mrr:=public.subscription_mrr_cents(old_row);
  if effective_mode='renewal' then
    update public.subscriptions set scheduled_plan_version_id=version.id,
      scheduled_effective_at=coalesce(renewal_at,subscription_ends_at,now()),internal_note=nullif(trim(target_note),''),updated_at=now()
    where company_id=target_company_id returning * into new_row;
  else
    update public.subscriptions set plan_key=version.plan_key,plan_version_id=version.id,billing_interval=target_billing_interval,
      contract_monthly_cents=version.price_monthly_cents,contract_annual_cents=version.price_annual_cents,
      discount_type=target_discount_type,discount_value=target_discount_value,discount_ends_at=target_discount_ends_at,
      scheduled_plan_version_id=null,scheduled_effective_at=null,internal_note=nullif(trim(target_note),''),updated_at=now()
    where company_id=target_company_id returning * into new_row;
  end if;
  new_mrr:=public.subscription_mrr_cents(new_row);
  insert into public.subscription_events(company_id,event_type,previous_state,new_state,reason,financial_impact_cents,effective_at,created_by)
  values(target_company_id,'subscription_changed',to_jsonb(old_row),to_jsonb(new_row),trim(target_reason),new_mrr-old_mrr,
    case when effective_mode='renewal' then new_row.scheduled_effective_at else now() end,admin.id);
  perform public.append_platform_admin_audit('subscription.change','subscription',target_company_id::text,target_company_id,
    to_jsonb(old_row),to_jsonb(new_row),target_reason);
  insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
  values('subscription_changed','info','Abonnement modifié','Le plan ou le cycle contractuel a été modifié.',target_company_id,'/companies/'||target_company_id::text);
  return new_row;
end $$;

create or replace function public.platform_admin_create_company(
  target_owner_user_id uuid,target_company jsonb,target_subscription jsonb,target_reason text
) returns public.companies language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; company_row public.companies%rowtype; version public.subscription_plan_versions%rowtype;
  plan_version_id uuid; billing_cycle text; trial_days integer; requested_status text; feature record;
begin
  if not public.is_platform_admin('companies.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if not exists(select 1 from auth.users where id=target_owner_user_id) then raise exception 'owner_user_not_found'; end if;
  if nullif(trim(coalesce(target_company->>'legal_name',target_company->>'trade_name')),'') is null then raise exception 'company_name_required'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  plan_version_id:=nullif(target_subscription->>'plan_version_id','')::uuid;
  select * into version from public.subscription_plan_versions where id=plan_version_id and effective_to is null;
  if version.id is null then raise exception 'plan_version_not_found'; end if;
  billing_cycle:=coalesce(nullif(target_subscription->>'billing_interval',''),'monthly');
  requested_status:=coalesce(nullif(target_subscription->>'status',''),'trialing');
  trial_days:=greatest(0,least(365,coalesce((target_subscription->>'trial_days')::integer,14)));
  if billing_cycle not in('monthly','annual') or requested_status not in('trialing','active') then raise exception 'invalid_subscription_configuration'; end if;
  insert into public.companies(owner_user_id,name,internal_admin_notes,admin_tags)
  values(target_owner_user_id,trim(coalesce(target_company->>'trade_name',target_company->>'legal_name')),
    nullif(trim(target_company->>'internal_admin_notes'),''),
    case when jsonb_typeof(target_company->'admin_tags')='array' then array(select jsonb_array_elements_text(target_company->'admin_tags')) else '{}'::text[] end)
  returning * into company_row;
  insert into public.company_members(company_id,user_id,role) values(company_row.id,target_owner_user_id,'owner')
    on conflict(company_id,user_id) do update set role='owner',platform_status='active',suspended_at=null,suspension_reason=null,updated_at=now();
  insert into public.user_preferences(user_id,company_id,onboarding_completed,first_name,last_name,display_name)
  values(target_owner_user_id,company_row.id,false,nullif(trim(target_company->>'owner_first_name'),''),
    nullif(trim(target_company->>'owner_last_name'),''),nullif(trim(concat_ws(' ',target_company->>'owner_first_name',target_company->>'owner_last_name')),''))
  on conflict(user_id) do update set company_id=excluded.company_id,first_name=coalesce(public.user_preferences.first_name,excluded.first_name),
    last_name=coalesce(public.user_preferences.last_name,excluded.last_name),display_name=coalesce(public.user_preferences.display_name,excluded.display_name),updated_at=now();
  insert into public.company_settings(company_id,legal_name,trade_name,company_type,siren,siret,address_line1,address_line2,postal_code,city,
    country,country_code,email,phone,currency,language,legal_form)
  values(company_row.id,nullif(trim(target_company->>'legal_name'),''),nullif(trim(target_company->>'trade_name'),''),
    nullif(trim(target_company->>'company_type'),''),nullif(trim(target_company->>'siren'),''),nullif(trim(target_company->>'siret'),''),
    nullif(trim(target_company->>'address_line1'),''),nullif(trim(target_company->>'address_line2'),''),nullif(trim(target_company->>'postal_code'),''),
    nullif(trim(target_company->>'city'),''),coalesce(nullif(trim(target_company->>'country'),''),'France'),
    coalesce(nullif(upper(trim(target_company->>'country_code')),''),'FR'),nullif(trim(target_company->>'email'),''),
    nullif(trim(target_company->>'phone'),''),coalesce(nullif(upper(trim(target_company->>'currency')),''),'EUR'),
    coalesce(nullif(lower(trim(target_company->>'language')),''),'fr'),nullif(trim(target_company->>'legal_form'),''))
  on conflict(company_id) do nothing;
  update public.subscriptions set plan_key=version.plan_key,plan_version_id=version.id,billing_interval=billing_cycle,status=requested_status,
    trial_started_at=case when requested_status='trialing' then now() else null end,
    trial_ends_at=case when requested_status='trialing' then now()+make_interval(days=>trial_days) else null end,
    subscription_started_at=case when requested_status='active' then now() else null end,
    contract_monthly_cents=version.price_monthly_cents,contract_annual_cents=version.price_annual_cents,
    max_users_override=nullif(target_subscription->>'max_users','')::integer,provider='manual',payment_status='not_configured',updated_at=now()
  where company_id=company_row.id;
  for feature in select key,value from jsonb_each(coalesce(target_subscription->'feature_overrides','{}'::jsonb)) loop
    insert into public.company_feature_overrides(company_id,feature_key,enabled,reason,created_by)
    values(company_row.id,feature.key,(feature.value #>> '{}')::boolean,'Configuration à la création',admin.id);
  end loop;
  perform public.append_platform_admin_audit('company.create','company',company_row.id::text,company_row.id,null,
    jsonb_build_object('company',to_jsonb(company_row),'subscription',target_subscription),target_reason);
  insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
  values('company_created','info','Nouvelle entreprise',company_row.name||' a été créée.',company_row.id,'/companies/'||company_row.id::text);
  return company_row;
end $$;

create or replace function public.platform_admin_update_company(target_company_id uuid,target_changes jsonb,target_reason text)
returns public.companies language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare company_row public.companies%rowtype; previous jsonb; current_settings jsonb;
begin
  if not public.is_platform_admin('companies.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  select jsonb_build_object('company',to_jsonb(company),'settings',to_jsonb(setting)) into previous
  from public.companies company left join public.company_settings setting on setting.company_id=company.id where company.id=target_company_id;
  if previous is null then raise exception 'company_not_found'; end if;
  update public.companies company set
    name=case when target_changes ? 'trade_name' or target_changes ? 'legal_name' then trim(coalesce(nullif(target_changes->>'trade_name',''),nullif(target_changes->>'legal_name',''),company.name)) else company.name end,
    internal_admin_notes=case when target_changes ? 'internal_admin_notes' then nullif(trim(target_changes->>'internal_admin_notes'),'') else company.internal_admin_notes end,
    admin_tags=case when jsonb_typeof(target_changes->'admin_tags')='array' then array(select jsonb_array_elements_text(target_changes->'admin_tags')) else company.admin_tags end,
    updated_at=now() where company.id=target_company_id returning * into company_row;
  update public.company_settings setting set
    legal_name=case when target_changes ? 'legal_name' then nullif(trim(target_changes->>'legal_name'),'') else setting.legal_name end,
    trade_name=case when target_changes ? 'trade_name' then nullif(trim(target_changes->>'trade_name'),'') else setting.trade_name end,
    company_type=case when target_changes ? 'company_type' then nullif(trim(target_changes->>'company_type'),'') else setting.company_type end,
    legal_form=case when target_changes ? 'legal_form' then nullif(trim(target_changes->>'legal_form'),'') else setting.legal_form end,
    siren=case when target_changes ? 'siren' then nullif(trim(target_changes->>'siren'),'') else setting.siren end,
    siret=case when target_changes ? 'siret' then nullif(trim(target_changes->>'siret'),'') else setting.siret end,
    address_line1=case when target_changes ? 'address_line1' then nullif(trim(target_changes->>'address_line1'),'') else setting.address_line1 end,
    address_line2=case when target_changes ? 'address_line2' then nullif(trim(target_changes->>'address_line2'),'') else setting.address_line2 end,
    postal_code=case when target_changes ? 'postal_code' then nullif(trim(target_changes->>'postal_code'),'') else setting.postal_code end,
    city=case when target_changes ? 'city' then nullif(trim(target_changes->>'city'),'') else setting.city end,
    country=case when target_changes ? 'country' then nullif(trim(target_changes->>'country'),'') else setting.country end,
    country_code=case when target_changes ? 'country_code' then nullif(upper(trim(target_changes->>'country_code')),'') else setting.country_code end,
    email=case when target_changes ? 'email' then nullif(trim(target_changes->>'email'),'') else setting.email end,
    phone=case when target_changes ? 'phone' then nullif(trim(target_changes->>'phone'),'') else setting.phone end,
    currency=case when target_changes ? 'currency' then nullif(upper(trim(target_changes->>'currency')),'') else setting.currency end,
    language=case when target_changes ? 'language' then nullif(lower(trim(target_changes->>'language')),'') else setting.language end,
    updated_at=now() where setting.company_id=target_company_id;
  select to_jsonb(setting) into current_settings from public.company_settings setting where setting.company_id=target_company_id;
  perform public.append_platform_admin_audit('company.update','company',target_company_id::text,target_company_id,previous,
    jsonb_build_object('company',to_jsonb(company_row),'settings',current_settings),target_reason);
  return company_row;
end $$;

create or replace function public.platform_admin_manage_company_user(
  target_company_id uuid,target_user_id uuid,target_role text,target_operation text,target_reason text
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare old_state jsonb; new_state jsonb; old_owner uuid;
begin
  if not public.is_platform_admin('users.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if target_role not in('owner','admin','member') then raise exception 'invalid_company_role'; end if;
  if target_operation not in('attach','change_role','suspend','reactivate','transfer_owner','remove') then raise exception 'invalid_user_operation'; end if;
  if not exists(select 1 from auth.users where id=target_user_id) or not exists(select 1 from public.companies where id=target_company_id) then
    raise exception 'company_or_user_not_found'; end if;
  select to_jsonb(member) into old_state from public.company_members member where member.company_id=target_company_id and member.user_id=target_user_id;
  if target_operation='attach' then
    insert into public.company_members(company_id,user_id,role) values(target_company_id,target_user_id,target_role)
    on conflict(company_id,user_id) do update set role=excluded.role,platform_status='active',suspended_at=null,suspension_reason=null,updated_at=now();
  elsif target_operation='change_role' then
    if target_role='owner' then raise exception 'use_transfer_owner'; end if;
    update public.company_members set role=target_role,updated_at=now() where company_id=target_company_id and user_id=target_user_id and role<>'owner';
  elsif target_operation='suspend' then
    update public.company_members set platform_status='suspended',suspended_at=now(),suspension_reason=trim(target_reason),updated_at=now()
      where company_id=target_company_id and user_id=target_user_id and role<>'owner';
  elsif target_operation='reactivate' then
    update public.company_members set platform_status='active',suspended_at=null,suspension_reason=null,updated_at=now()
      where company_id=target_company_id and user_id=target_user_id;
  elsif target_operation='transfer_owner' then
    select owner_user_id into old_owner from public.companies where id=target_company_id for update;
    insert into public.company_members(company_id,user_id,role) values(target_company_id,target_user_id,'owner')
      on conflict(company_id,user_id) do update set role='owner',platform_status='active',suspended_at=null,suspension_reason=null,updated_at=now();
    update public.company_members set role='admin',updated_at=now() where company_id=target_company_id and user_id=old_owner;
    update public.companies set owner_user_id=target_user_id,updated_at=now() where id=target_company_id;
  elsif target_operation='remove' then
    delete from public.company_members where company_id=target_company_id and user_id=target_user_id and role<>'owner';
  end if;
  select to_jsonb(member) into new_state from public.company_members member where member.company_id=target_company_id and member.user_id=target_user_id;
  if target_operation<>'remove' and new_state is null then raise exception 'user_operation_not_applied'; end if;
  perform public.append_platform_admin_audit('user.'||target_operation,'company_member',target_user_id::text,target_company_id,
    old_state,new_state,target_reason);
  return coalesce(new_state,jsonb_build_object('removed',true,'user_id',target_user_id));
end $$;

create or replace function public.platform_admin_manage_subscription(
  target_company_id uuid,target_operation text,target_parameters jsonb,target_reason text
) returns public.subscriptions language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; old_row public.subscriptions%rowtype; new_row public.subscriptions%rowtype; days integer;
begin
  if not public.is_platform_admin('subscriptions.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if target_operation not in('extend_trial','end_trial','activate_manual','suspend','reactivate','schedule_cancel','cancel_schedule','mark_past_due','offer_period') then
    raise exception 'invalid_subscription_operation'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  select * into old_row from public.subscriptions where company_id=target_company_id for update;
  if old_row.company_id is null then raise exception 'subscription_not_found'; end if;
  days:=greatest(1,least(365,coalesce((target_parameters->>'days')::integer,14)));
  if target_operation='extend_trial' then
    update public.subscriptions set status='trialing',trial_started_at=coalesce(trial_started_at,now()),
      trial_ends_at=greatest(coalesce(trial_ends_at,now()),now())+make_interval(days=>days),updated_at=now() where company_id=target_company_id;
  elsif target_operation='end_trial' then
    update public.subscriptions set status='expired',trial_ends_at=now(),updated_at=now() where company_id=target_company_id;
  elsif target_operation='activate_manual' then
    update public.subscriptions set status='active',provider='manual',subscription_started_at=coalesce(subscription_started_at,now()),
      subscription_ends_at=null,cancellation_at_period_end=false,updated_at=now() where company_id=target_company_id;
  elsif target_operation='suspend' then
    update public.subscriptions set pre_suspension_status=case when status<>'suspended' then status else pre_suspension_status end,status='suspended',updated_at=now()
      where company_id=target_company_id;
  elsif target_operation='reactivate' then
    update public.subscriptions set status=coalesce(nullif(pre_suspension_status,'suspended'),'active'),pre_suspension_status=null,updated_at=now()
      where company_id=target_company_id;
  elsif target_operation='schedule_cancel' then
    update public.subscriptions set cancellation_at_period_end=true,subscription_ends_at=coalesce(nullif(target_parameters->>'ends_at','')::timestamptz,renewal_at,subscription_ends_at),updated_at=now()
      where company_id=target_company_id;
  elsif target_operation='cancel_schedule' then
    update public.subscriptions set cancellation_at_period_end=false,subscription_ends_at=null,updated_at=now() where company_id=target_company_id;
  elsif target_operation='mark_past_due' then
    update public.subscriptions set status='past_due',payment_status='failed',updated_at=now() where company_id=target_company_id;
  elsif target_operation='offer_period' then
    update public.subscriptions set renewal_at=greatest(coalesce(renewal_at,now()),now())+make_interval(days=>days),updated_at=now() where company_id=target_company_id;
  end if;
  select * into new_row from public.subscriptions where company_id=target_company_id;
  insert into public.subscription_events(company_id,event_type,previous_state,new_state,reason,financial_impact_cents,effective_at,created_by)
  values(target_company_id,'subscription_'||target_operation,to_jsonb(old_row),to_jsonb(new_row),trim(target_reason),
    public.subscription_mrr_cents(new_row)-public.subscription_mrr_cents(old_row),now(),admin.id);
  perform public.append_platform_admin_audit('subscription.'||target_operation,'subscription',target_company_id::text,target_company_id,
    to_jsonb(old_row),to_jsonb(new_row),target_reason);
  insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
  values('subscription_'||target_operation,case when target_operation in('suspend','mark_past_due','end_trial') then 'warning' else 'info' end,
    'Événement d’abonnement','Opération '||target_operation||' enregistrée.',target_company_id,'/companies/'||target_company_id::text);
  return new_row;
end $$;

create or replace function public.platform_admin_set_feature_override(
  target_company_id uuid,target_feature_key text,target_enabled boolean,target_ends_at timestamptz,target_reason text
) returns public.company_feature_overrides language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; override_row public.company_feature_overrides%rowtype;
begin
  if not public.is_platform_admin('subscriptions.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_feature_key),'') is null or nullif(trim(target_reason),'') is null then raise exception 'feature_and_reason_required'; end if;
  if target_ends_at is not null and target_ends_at<=now() then raise exception 'invalid_override_end'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  insert into public.company_feature_overrides(company_id,feature_key,enabled,ends_at,reason,created_by)
  values(target_company_id,lower(trim(target_feature_key)),target_enabled,target_ends_at,trim(target_reason),admin.id) returning * into override_row;
  perform public.append_platform_admin_audit('feature.override','company_feature',target_feature_key,target_company_id,null,to_jsonb(override_row),target_reason);
  return override_row;
end $$;

create or replace function public.platform_admin_create_plan_version(target_plan_key text,target_values jsonb,target_reason text)
returns public.subscription_plan_versions language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; current_plan public.plans%rowtype; current_version public.subscription_plan_versions%rowtype;
  new_version public.subscription_plan_versions%rowtype; next_version integer;
begin
  if not public.is_platform_admin('plans.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  select * into current_plan from public.plans where key=target_plan_key for update;
  if current_plan.key is null then raise exception 'plan_not_found'; end if;
  select * into current_version from public.subscription_plan_versions where plan_key=target_plan_key and effective_to is null order by version desc limit 1 for update;
  next_version:=coalesce(current_version.version,0)+1;
  if current_version.id is not null then update public.subscription_plan_versions set effective_to=now() where id=current_version.id; end if;
  insert into public.subscription_plan_versions(plan_key,version,name,description,price_monthly_cents,price_annual_cents,max_users,features,limits,
    availability,recommended,public_plan,effective_from,created_by)
  values(target_plan_key,next_version,coalesce(nullif(target_values->>'name',''),current_plan.name),
    coalesce(target_values->>'description',current_plan.description),coalesce((target_values->>'price_monthly_cents')::integer,current_plan.price_monthly_cents),
    coalesce((target_values->>'price_annual_cents')::integer,current_plan.price_annual_cents),coalesce((target_values->>'max_users')::integer,current_plan.max_users),
    coalesce(target_values->'features',current_plan.features),coalesce(target_values->'limits','{}'::jsonb),
    coalesce(nullif(target_values->>'availability',''),current_plan.availability),coalesce((target_values->>'recommended')::boolean,current_plan.recommended),
    coalesce((target_values->>'public_plan')::boolean,current_plan.public_plan),coalesce(nullif(target_values->>'effective_from','')::timestamptz,now()),admin.id)
  returning * into new_version;
  update public.plans set name=new_version.name,description=new_version.description,price_monthly_cents=new_version.price_monthly_cents,
    price_annual_cents=new_version.price_annual_cents,max_users=new_version.max_users,features=new_version.features,
    availability=new_version.availability,recommended=new_version.recommended,public_plan=new_version.public_plan,
    effective_from=new_version.effective_from,updated_at=now() where key=target_plan_key;
  perform public.append_platform_admin_audit('plan.version_created','plan',target_plan_key,null,to_jsonb(current_version),to_jsonb(new_version),target_reason);
  return new_version;
end $$;

create or replace function public.platform_admin_update_profile(target_values jsonb)
returns public.platform_admins language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare old_row public.platform_admins%rowtype; new_row public.platform_admins%rowtype;
begin
  if not public.is_platform_admin(null,true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  select * into old_row from public.platform_admins where user_id=auth.uid() and status='active' for update;
  update public.platform_admins set first_name=case when target_values ? 'first_name' then nullif(trim(target_values->>'first_name'),'') else first_name end,
    last_name=case when target_values ? 'last_name' then nullif(trim(target_values->>'last_name'),'') else last_name end,
    timezone=coalesce(nullif(trim(target_values->>'timezone'),''),timezone),language=coalesce(nullif(trim(target_values->>'language'),''),language),
    theme=coalesce(nullif(trim(target_values->>'theme'),''),theme),
    notification_preferences=case when jsonb_typeof(target_values->'notification_preferences')='object' then target_values->'notification_preferences' else notification_preferences end,
    updated_at=now() where user_id=auth.uid() returning * into new_row;
  perform public.append_platform_admin_audit('admin.profile_update','platform_admin',new_row.id::text,null,to_jsonb(old_row),to_jsonb(new_row),'Mise à jour du profil');
  return new_row;
end $$;

create or replace function public.platform_admin_register_session(target_user_agent text default null)
returns uuid language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; existing_session public.platform_admin_sessions%rowtype; session_identifier text; session_id uuid; inserted boolean:=false;
begin
  if not public.is_platform_admin(null,true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  session_identifier:=nullif(auth.jwt()->>'session_id','');
  if session_identifier is null then raise exception 'admin_session_identifier_missing' using errcode='42501'; end if;
  select * into existing_session from public.platform_admin_sessions where admin_id=admin.id and auth_session_id=session_identifier;
  if existing_session.id is not null and (existing_session.revoked_at is not null or existing_session.expires_at<=now()) then
    raise exception 'admin_session_expired_or_revoked' using errcode='42501'; end if;
  session_id:=existing_session.id;
  if session_id is null then
    insert into public.platform_admin_sessions(admin_id,auth_session_id,user_agent)
    values(admin.id,session_identifier,left(target_user_agent,500)) returning id into session_id; inserted:=true;
  else update public.platform_admin_sessions set last_activity_at=now(),expires_at=now()+interval '30 minutes' where id=session_id; end if;
  update public.platform_admins set last_login_at=case when inserted then now() else last_login_at end,last_activity_at=now() where id=admin.id;
  if inserted then perform public.append_platform_admin_audit('auth.login','platform_admin',admin.id::text,null,null,
    jsonb_build_object('session_id',session_id),'Connexion MFA réussie'); end if;
  return session_id;
end $$;

create or replace function public.platform_admin_validate_and_touch_session()
returns boolean language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare target_admin_id uuid; session_identifier text; session_id uuid;
begin
  if not public.is_platform_admin(null,true) then return false; end if;
  select id into target_admin_id from public.platform_admins where user_id=auth.uid() and status='active';
  session_identifier:=nullif(auth.jwt()->>'session_id','');
  if session_identifier is null then return false; end if;
  update public.platform_admin_sessions set last_activity_at=now(),expires_at=now()+interval '30 minutes'
  where platform_admin_sessions.admin_id=target_admin_id and auth_session_id=session_identifier and revoked_at is null and expires_at>now()
  returning id into session_id;
  update public.platform_admins set last_activity_at=now() where id=target_admin_id and session_id is not null;
  return session_id is not null;
end $$;

create or replace function public.platform_admin_export_company(target_company_id uuid,target_reason text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare payload jsonb;
begin
  if not public.is_platform_admin('privacy.read',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if not exists(select 1 from public.companies where id=target_company_id) then raise exception 'company_not_found'; end if;
  select jsonb_build_object('generated_at',now(),'company',to_jsonb(company),'settings',to_jsonb(setting),
    'subscription',to_jsonb(subscription),'members',(select coalesce(jsonb_agg(jsonb_build_object('user_id',member.user_id,'role',member.role,'status',member.platform_status)),'[]'::jsonb) from public.company_members member where member.company_id=company.id),
    'record_counts',jsonb_build_object('clients',(select count(*) from public.clients where company_id=company.id),
      'documents',(select count(*) from public.documents where company_id=company.id),'payments',(select count(*) from public.payments where company_id=company.id)))
  into payload from public.companies company left join public.company_settings setting on setting.company_id=company.id
  left join public.subscriptions subscription on subscription.company_id=company.id where company.id=target_company_id;
  perform public.append_platform_admin_audit('company.export','company',target_company_id::text,target_company_id,null,
    jsonb_build_object('sha256',encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex')),target_reason);
  return payload;
end $$;

create or replace function public.platform_admin_record_auth_action(
  target_user_id uuid,target_company_id uuid,target_action text,target_reason text,target_old_state jsonb default null,target_new_state jsonb default null
) returns uuid language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_platform_admin('users.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if target_action not in('user.invite','user.invite_resend','user.password_reset_requested','user.sessions_revoked','user.auth_suspended','user.auth_reactivated')
    or nullif(trim(target_reason),'') is null then raise exception 'invalid_auth_audit_action'; end if;
  return public.append_platform_admin_audit(target_action,'auth_user',target_user_id::text,target_company_id,target_old_state,target_new_state,target_reason);
end $$;

create or replace function public.platform_admin_add_administrator(
  target_user_id uuid,target_email text,target_role text,target_first_name text,target_last_name text,target_reason text
) returns public.platform_admins language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin_row public.platform_admins%rowtype; inviter_id uuid;
begin
  if not public.is_platform_admin('admin.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if target_role not in('super_admin','support_admin','billing_admin','compliance_admin','read_only_admin')
    or nullif(trim(target_reason),'') is null or not exists(select 1 from auth.users where id=target_user_id) then
    raise exception 'invalid_administrator_invitation'; end if;
  select id into inviter_id from public.platform_admins where user_id=auth.uid();
  insert into public.platform_admins(user_id,role,status,first_name,last_name,email,created_by)
  values(target_user_id,target_role,'active',nullif(trim(target_first_name),''),nullif(trim(target_last_name),''),lower(trim(target_email)),inviter_id)
  returning * into admin_row;
  perform public.append_platform_admin_audit('admin.invite','platform_admin',admin_row.id::text,null,null,
    jsonb_build_object('user_id',target_user_id,'email',lower(trim(target_email)),'role',target_role),target_reason);
  return admin_row;
end $$;

create or replace function public.platform_admin_save_support_case(target_case_id uuid,target_values jsonb,target_reason text)
returns public.support_cases language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; old_row public.support_cases%rowtype; new_row public.support_cases%rowtype;
  target_status text; target_priority text;
begin
  if not public.is_platform_admin('support.write',true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null or nullif(trim(target_values->>'subject'),'') is null then raise exception 'subject_and_reason_required'; end if;
  target_status:=coalesce(nullif(target_values->>'status',''),'new');target_priority:=coalesce(nullif(target_values->>'priority',''),'normal');
  if target_status not in('new','in_progress','waiting_customer','resolved','closed') or target_priority not in('low','normal','high','critical') then
    raise exception 'invalid_support_case_state'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  if target_case_id is null then
    insert into public.support_cases(company_id,user_id,subject,description,priority,status,assigned_admin_id,internal_notes,created_by)
    values(nullif(target_values->>'company_id','')::uuid,nullif(target_values->>'user_id','')::uuid,trim(target_values->>'subject'),
      nullif(trim(target_values->>'description'),''),target_priority,target_status,coalesce(nullif(target_values->>'assigned_admin_id','')::uuid,admin.id),
      nullif(trim(target_values->>'internal_notes'),''),admin.id) returning * into new_row;
  else
    select * into old_row from public.support_cases where id=target_case_id for update;
    if old_row.id is null then raise exception 'support_case_not_found'; end if;
    update public.support_cases set subject=trim(target_values->>'subject'),description=nullif(trim(target_values->>'description'),''),
      priority=target_priority,status=target_status,internal_notes=nullif(trim(target_values->>'internal_notes'),''),updated_at=now()
      where id=target_case_id returning * into new_row;
  end if;
  perform public.append_platform_admin_audit(case when target_case_id is null then 'support.case_create' else 'support.case_update' end,
    'support_case',new_row.id::text,new_row.company_id,to_jsonb(old_row),to_jsonb(new_row),target_reason);
  return new_row;
end $$;

-- Les mutations de membres effectuées par le back-office sont conservées dans
-- le journal plateforme. Les mutations clientes continuent d'alimenter le
-- journal fiscal historique avec son contrôle d'appartenance habituel.
create or replace function public.log_company_access_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare company_value uuid; member_value uuid; operation_value text;
begin
  if public.is_platform_admin('users.write',true) then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;
  company_value:=coalesce(new.company_id,old.company_id);
  member_value:=coalesce(new.user_id,old.user_id);
  operation_value:=lower(tg_op);
  perform public._append_fiscal_event(company_value,'user_permission_changed','company_member',member_value,
    clock_timestamp(),jsonb_build_object(
      'operation',operation_value,
      'previous_role',case when tg_op in('UPDATE','DELETE') then old.role else null end,
      'new_role',case when tg_op in('INSERT','UPDATE') then new.role else null end,
      'previous_permissions',case when tg_op in('UPDATE','DELETE') then old.permissions else null end,
      'new_permissions',case when tg_op in('INSERT','UPDATE') then new.permissions else null end
    ),'database_trigger','{}'::jsonb);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create or replace function public.guard_company_owner_access()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if public.is_platform_admin('users.write',true) then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;
  if tg_op='DELETE' and old.role='owner' then raise exception 'owner_cannot_be_deleted' using errcode='42501'; end if;
  if tg_op='UPDATE' and old.role is distinct from new.role and (old.role='owner' or new.role='owner') then
    raise exception 'owner_role_requires_dedicated_transfer' using errcode='42501';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create or replace function public.platform_admin_set_company_suspension(
  target_company_id uuid,target_suspended boolean,target_level text default 'full',target_reason text default null
) returns public.companies language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; old_company public.companies%rowtype; new_company public.companies%rowtype; old_subscription public.subscriptions%rowtype;
begin
  if not public.is_platform_admin('companies.suspend',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if target_level not in('read_only','creation_blocked','full') then raise exception 'invalid_suspension_level'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  select * into old_company from public.companies where id=target_company_id for update;
  select * into old_subscription from public.subscriptions where company_id=target_company_id for update;
  if old_company.id is null then raise exception 'company_not_found'; end if;
  if target_suspended then
    update public.companies set platform_status='suspended',suspension_level=target_level,suspended_at=now(),suspension_reason=trim(target_reason),updated_at=now()
      where id=target_company_id returning * into new_company;
    update public.subscriptions set pre_suspension_status=case when status<>'suspended' then status else pre_suspension_status end,
      status='suspended',updated_at=now() where company_id=target_company_id;
  else
    update public.companies set platform_status='active',suspension_level=null,suspended_at=null,suspension_reason=null,updated_at=now()
      where id=target_company_id returning * into new_company;
    update public.subscriptions set status=coalesce(nullif(pre_suspension_status,'suspended'),'active'),pre_suspension_status=null,updated_at=now()
      where company_id=target_company_id and status='suspended';
  end if;
  perform public.append_platform_admin_audit(case when target_suspended then 'company.suspend' else 'company.reactivate' end,
    'company',target_company_id::text,target_company_id,to_jsonb(old_company),to_jsonb(new_company),target_reason);
  insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
  values(case when target_suspended then 'company_suspended' else 'company_reactivated' end,
    case when target_suspended then 'warning' else 'info' end,
    case when target_suspended then 'Entreprise suspendue' else 'Entreprise réactivée' end,
    coalesce(new_company.name,'Entreprise')||case when target_suspended then ' a été suspendue.' else ' a été réactivée.' end,
    target_company_id,'/companies/'||target_company_id::text);
  return new_company;
end $$;

create or replace function public.platform_admin_start_support_session(target_company_id uuid,target_reason text,target_mode text default 'read_only')
returns public.support_sessions language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; session_row public.support_sessions%rowtype;
begin
  if not public.is_platform_admin('support.session',true) or not public.platform_admin_recent_auth(300) then raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if target_mode not in('read_only','limited_write') then raise exception 'invalid_support_mode'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  if not exists(select 1 from public.companies where id=target_company_id) then raise exception 'company_not_found'; end if;
  insert into public.support_sessions(admin_id,company_id,reason,mode,expires_at)
  values(admin.id,target_company_id,trim(target_reason),target_mode,now()+interval '30 minutes') returning * into session_row;
  perform public.append_platform_admin_audit('support.session_started','support_session',session_row.id::text,target_company_id,null,to_jsonb(session_row),target_reason);
  return session_row;
end $$;

create or replace function public.platform_admin_end_support_session(target_session_id uuid)
returns public.support_sessions language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; session_row public.support_sessions%rowtype;
begin
  if not public.is_platform_admin('support.session',true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  update public.support_sessions set ended_at=now(),ended_by=admin.id where id=target_session_id and admin_id=admin.id and ended_at is null returning * into session_row;
  if session_row.id is null then raise exception 'support_session_not_found'; end if;
  perform public.append_platform_admin_audit('support.session_ended','support_session',session_row.id::text,session_row.company_id,null,to_jsonb(session_row),'Fin de session');
  return session_row;
end $$;

-- Une suspension complète retire immédiatement l'entreprise des helpers RLS
-- utilisés par l'application cliente. Les données restent intactes.
create or replace function public.current_user_company_ids()
returns table(company_id uuid) language sql stable security definer set search_path=public,pg_temp as $$
  select member.company_id from public.company_members member join public.companies company on company.id=member.company_id
  where member.user_id=auth.uid() and member.platform_status='active'
    and not(company.platform_status='suspended' and company.suspension_level='full')
$$;
create or replace function public.is_company_member(target_company_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from public.company_members member join public.companies company on company.id=member.company_id
    where member.company_id=target_company_id and member.user_id=auth.uid() and member.platform_status='active'
      and not(company.platform_status='suspended' and company.suspension_level='full'))
$$;
create or replace function public.has_company_role(target_company_id uuid,allowed_roles text[])
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from public.company_members member join public.companies company on company.id=member.company_id
    where member.company_id=target_company_id and member.user_id=auth.uid() and member.platform_status='active' and member.role=any(allowed_roles)
      and not(company.platform_status='suspended' and company.suspension_level='full'))
$$;

create index if not exists companies_platform_status_idx on public.companies(platform_status,created_at desc);
create index if not exists company_settings_admin_search_idx on public.company_settings(lower(coalesce(legal_name,'')||' '||coalesce(trade_name,'')||' '||coalesce(email,'')||' '||coalesce(siret,'')));
create index if not exists subscriptions_admin_status_idx on public.subscriptions(status,plan_key,updated_at desc);
create index if not exists subscriptions_external_customer_idx on public.subscriptions(external_customer_id) where external_customer_id is not null;
create index if not exists subscriptions_external_subscription_idx on public.subscriptions(external_subscription_id) where external_subscription_id is not null;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'platform_admins','platform_admin_permissions','platform_admin_sessions','platform_admin_audit_events',
    'subscription_plan_versions','subscription_events','subscription_discounts','company_feature_overrides',
    'platform_billing_invoices','platform_billing_payments','platform_billing_refunds','support_sessions','support_cases',
    'platform_notifications','platform_system_events','platform_revenue_snapshots'
  ] loop execute format('alter table public.%I enable row level security',table_name); end loop;
end $$;

-- Lecture globale uniquement pour un administrateur plateforme actif en AAL2.
drop policy if exists companies_platform_admin_select on public.companies;
create policy companies_platform_admin_select on public.companies for select to authenticated using(public.is_platform_admin('companies.read',true));
drop policy if exists company_settings_platform_admin_select on public.company_settings;
create policy company_settings_platform_admin_select on public.company_settings for select to authenticated using(public.is_platform_admin('companies.read',true));
drop policy if exists company_members_platform_admin_select on public.company_members;
create policy company_members_platform_admin_select on public.company_members for select to authenticated using(public.is_platform_admin('users.read',true));
drop policy if exists subscriptions_platform_admin_select on public.subscriptions;
create policy subscriptions_platform_admin_select on public.subscriptions for select to authenticated using(public.is_platform_admin('subscriptions.read',true));
drop policy if exists plans_platform_admin_select on public.plans;
create policy plans_platform_admin_select on public.plans for select to authenticated using(public.is_platform_admin('plans.read',true));
drop policy if exists company_fiscal_configurations_platform_admin_select on public.company_fiscal_configurations;
create policy company_fiscal_configurations_platform_admin_select on public.company_fiscal_configurations for select to authenticated using(public.is_platform_admin('compliance.read',true));
drop policy if exists compliance_anomalies_platform_admin_select on public.compliance_anomalies;
create policy compliance_anomalies_platform_admin_select on public.compliance_anomalies for select to authenticated using(public.is_platform_admin('compliance.read',true));
drop policy if exists data_subject_requests_platform_admin_select on public.data_subject_requests;
create policy data_subject_requests_platform_admin_select on public.data_subject_requests for select to authenticated using(public.is_platform_admin('privacy.read',true));
grant select on public.company_fiscal_configurations,public.compliance_anomalies,public.data_subject_requests to authenticated;

do $$ declare table_name text; policy_name text; permission_name text;
begin
  for table_name,permission_name in select * from(values
    ('platform_admins','admin.read'),('platform_admin_permissions','admin.read'),('platform_admin_sessions','admin.read'),
    ('platform_admin_audit_events','audit.read'),('subscription_plan_versions','plans.read'),('subscription_events','subscriptions.read'),
    ('subscription_discounts','subscriptions.read'),('company_feature_overrides','companies.read'),
    ('platform_billing_invoices','billing.read'),('platform_billing_payments','billing.read'),('platform_billing_refunds','billing.read'),
    ('support_sessions','support.read'),('support_cases','support.read'),('platform_notifications','notifications.read'),
    ('platform_system_events','system.read'),('platform_revenue_snapshots','revenue.read')
  ) policies(table_name,permission_name) loop
    policy_name:=table_name||'_platform_admin_select';
    execute format('drop policy if exists %I on public.%I',policy_name,table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_platform_admin(%L,true))',policy_name,table_name,permission_name);
  end loop;
end $$;

revoke all on table public.platform_admins,public.platform_admin_permissions,public.platform_admin_sessions,
  public.platform_admin_audit_events,public.subscription_plan_versions,public.subscription_events,public.subscription_discounts,
  public.company_feature_overrides,public.platform_billing_invoices,public.platform_billing_payments,public.platform_billing_refunds,
  public.support_sessions,public.support_cases,public.platform_notifications,public.platform_system_events,
  public.platform_revenue_snapshots from anon,authenticated;
grant select on table public.platform_admins,public.platform_admin_permissions,public.platform_admin_sessions,
  public.platform_admin_audit_events,public.subscription_plan_versions,public.subscription_events,public.subscription_discounts,
  public.company_feature_overrides,public.platform_billing_invoices,public.platform_billing_payments,public.platform_billing_refunds,
  public.support_sessions,public.support_cases,public.platform_notifications,public.platform_system_events,
  public.platform_revenue_snapshots to authenticated;

revoke all on function public.is_platform_admin(text,boolean),public.platform_admin_recent_auth(integer),
  public.append_platform_admin_audit(text,text,text,uuid,jsonb,jsonb,text,text,text,uuid),public.platform_admin_context(),
  public.platform_admin_list_companies(text,text,text,integer,integer),public.platform_admin_list_users(text,uuid,integer,integer),
  public.platform_admin_dashboard(),public.platform_admin_change_subscription(uuid,uuid,text,text,text,numeric,timestamptz,text,text),
  public.platform_admin_create_company(uuid,jsonb,jsonb,text),public.platform_admin_update_company(uuid,jsonb,text),
  public.platform_admin_manage_company_user(uuid,uuid,text,text,text),public.platform_admin_manage_subscription(uuid,text,jsonb,text),
  public.platform_admin_set_feature_override(uuid,text,boolean,timestamptz,text),public.platform_admin_create_plan_version(text,jsonb,text),
  public.platform_admin_update_profile(jsonb),public.platform_admin_register_session(text),public.platform_admin_export_company(uuid,text),
  public.platform_admin_validate_and_touch_session(),
  public.platform_admin_record_auth_action(uuid,uuid,text,text,jsonb,jsonb),
  public.platform_admin_add_administrator(uuid,text,text,text,text,text),
  public.platform_admin_save_support_case(uuid,jsonb,text),
  public.platform_admin_set_company_suspension(uuid,boolean,text,text),public.platform_admin_start_support_session(uuid,text,text),
  public.platform_admin_end_support_session(uuid) from public,anon;
grant execute on function public.is_platform_admin(text,boolean),public.platform_admin_recent_auth(integer),public.platform_admin_context(),
  public.platform_admin_list_companies(text,text,text,integer,integer),public.platform_admin_list_users(text,uuid,integer,integer),
  public.platform_admin_dashboard(),public.platform_admin_change_subscription(uuid,uuid,text,text,text,numeric,timestamptz,text,text),
  public.platform_admin_create_company(uuid,jsonb,jsonb,text),public.platform_admin_update_company(uuid,jsonb,text),
  public.platform_admin_manage_company_user(uuid,uuid,text,text,text),public.platform_admin_manage_subscription(uuid,text,jsonb,text),
  public.platform_admin_set_feature_override(uuid,text,boolean,timestamptz,text),public.platform_admin_create_plan_version(text,jsonb,text),
  public.platform_admin_update_profile(jsonb),public.platform_admin_register_session(text),public.platform_admin_export_company(uuid,text),
  public.platform_admin_validate_and_touch_session(),
  public.platform_admin_record_auth_action(uuid,uuid,text,text,jsonb,jsonb),
  public.platform_admin_add_administrator(uuid,text,text,text,text,text),
  public.platform_admin_save_support_case(uuid,jsonb,text),
  public.platform_admin_set_company_suspension(uuid,boolean,text,text),public.platform_admin_start_support_session(uuid,text,text),
  public.platform_admin_end_support_session(uuid) to authenticated;

revoke execute on function public.has_feature(uuid,text) from public,anon;
grant execute on function public.has_feature(uuid,text) to authenticated,service_role;

commit;
