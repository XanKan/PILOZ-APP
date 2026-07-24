begin;

-- Connexion additive de la facturation Piloz à Stripe. Les identifiants
-- externes ne sont jamais exposés au navigateur et aucun secret n'est stocké
-- dans PostgreSQL.
alter table public.subscriptions
  add column if not exists payment_method_brand text,
  add column if not exists payment_method_last4 text,
  add column if not exists payment_method_exp_month smallint,
  add column if not exists payment_method_exp_year smallint,
  add column if not exists provider_event_created_at timestamptz,
  add column if not exists provider_updated_at timestamptz;

alter table public.subscriptions drop constraint if exists subscriptions_payment_method_last4_check;
alter table public.subscriptions add constraint subscriptions_payment_method_last4_check
  check(payment_method_last4 is null or payment_method_last4 ~ '^[0-9]{4}$') not valid;
alter table public.subscriptions drop constraint if exists subscriptions_payment_method_exp_month_check;
alter table public.subscriptions add constraint subscriptions_payment_method_exp_month_check
  check(payment_method_exp_month is null or payment_method_exp_month between 1 and 12) not valid;

create table if not exists public.subscription_provider_prices(
  id uuid primary key default gen_random_uuid(),
  provider text not null check(provider in('stripe')),
  plan_version_id uuid not null references public.subscription_plan_versions(id) on delete restrict,
  billing_interval text not null check(billing_interval in('monthly','annual')),
  currency text not null default 'eur' check(currency ~ '^[a-z]{3}$'),
  livemode boolean not null,
  external_product_id text not null,
  external_price_id text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider,plan_version_id,billing_interval,currency,livemode),
  unique(provider,external_price_id)
);
create index if not exists subscription_provider_prices_lookup_idx
  on public.subscription_provider_prices(plan_version_id,billing_interval,livemode) where active;

create table if not exists public.stripe_webhook_events(
  event_id text primary key,
  event_type text not null,
  object_id text,
  company_id uuid references public.companies(id) on delete set null,
  livemode boolean not null,
  status text not null default 'processing' check(status in('processing','processed','ignored','failed')),
  attempts integer not null default 1 check(attempts>0),
  event_created_at timestamptz not null,
  processed_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists stripe_webhook_events_status_idx
  on public.stripe_webhook_events(status,event_created_at desc);
create unique index if not exists platform_billing_refunds_external_idx
  on public.platform_billing_refunds(provider,external_refund_id) where external_refund_id is not null;
-- Index complets nécessaires aux UPSERT PostgREST. PostgreSQL autorise
-- plusieurs valeurs NULL, ils restent donc compatibles avec les lignes manuelles.
create unique index if not exists platform_billing_invoices_external_upsert_uidx
  on public.platform_billing_invoices(provider,external_invoice_id);
create unique index if not exists platform_billing_payments_external_upsert_uidx
  on public.platform_billing_payments(provider,external_payment_id);
create unique index if not exists platform_billing_refunds_external_upsert_uidx
  on public.platform_billing_refunds(provider,external_refund_id);

alter table public.subscription_provider_prices enable row level security;
alter table public.stripe_webhook_events enable row level security;

drop policy if exists subscription_provider_prices_platform_admin_select on public.subscription_provider_prices;
create policy subscription_provider_prices_platform_admin_select on public.subscription_provider_prices
  for select to authenticated using(public.is_platform_admin('plans.read',true));
drop policy if exists stripe_webhook_events_platform_admin_select on public.stripe_webhook_events;
create policy stripe_webhook_events_platform_admin_select on public.stripe_webhook_events
  for select to authenticated using(public.is_platform_admin('billing.read',true));

-- Un propriétaire ou administrateur d'entreprise peut consulter son propre
-- historique de facturation, jamais celui d'une autre entreprise.
drop policy if exists platform_billing_invoices_company_select on public.platform_billing_invoices;
create policy platform_billing_invoices_company_select on public.platform_billing_invoices
  for select to authenticated using(public.has_company_role(company_id,array['owner','admin']));
drop policy if exists platform_billing_payments_company_select on public.platform_billing_payments;
create policy platform_billing_payments_company_select on public.platform_billing_payments
  for select to authenticated using(public.has_company_role(company_id,array['owner','admin']));
drop policy if exists platform_billing_refunds_company_select on public.platform_billing_refunds;
create policy platform_billing_refunds_company_select on public.platform_billing_refunds
  for select to authenticated using(public.has_company_role(company_id,array['owner','admin']));

revoke all on table public.subscription_provider_prices,public.stripe_webhook_events from anon,authenticated;
grant select on table public.subscription_provider_prices,public.stripe_webhook_events to authenticated;
grant select on table public.platform_billing_invoices,public.platform_billing_payments,public.platform_billing_refunds to authenticated;

commit;
