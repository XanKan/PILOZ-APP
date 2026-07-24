begin;

-- Le profil de facturation Stripe est conservé sans jamais stocker le numéro
-- complet de carte. Ces champs alimentent la page Abonnement de l'entreprise.
alter table public.subscriptions
  add column if not exists billing_name text,
  add column if not exists billing_email text,
  add column if not exists billing_address_line1 text,
  add column if not exists billing_address_line2 text,
  add column if not exists billing_postal_code text,
  add column if not exists billing_city text,
  add column if not exists billing_country text,
  add column if not exists billing_tax_id text,
  add column if not exists billing_profile_updated_at timestamptz;

alter table public.platform_billing_invoices
  add column if not exists currency text not null default 'EUR',
  add column if not exists hosted_invoice_url text,
  add column if not exists invoice_pdf_url text,
  add column if not exists billing_reason text;

alter table public.platform_billing_invoices drop constraint if exists platform_billing_invoices_currency_check;
alter table public.platform_billing_invoices add constraint platform_billing_invoices_currency_check
  check(currency ~ '^[A-Z]{3}$') not valid;

-- Checkout réalisé avant la création du compte. Le jeton brut n'est jamais
-- conservé : seule son empreinte SHA-256 permet de réclamer le paiement après
-- authentification et de le rattacher à une entreprise.
create table if not exists public.stripe_checkout_claims(
  id uuid primary key default gen_random_uuid(),
  checkout_session_id text not null unique,
  claim_token_hash text not null unique check(claim_token_hash ~ '^[a-f0-9]{64}$'),
  plan_version_id uuid not null references public.subscription_plan_versions(id) on delete restrict,
  billing_interval text not null check(billing_interval in('monthly','annual')),
  livemode boolean not null,
  status text not null default 'pending' check(status in('pending','completed','claimed','expired','canceled')),
  checkout_email text,
  external_customer_id text,
  external_subscription_id text,
  claimed_company_id uuid references public.companies(id) on delete set null,
  claimed_user_id uuid references auth.users(id) on delete set null,
  request_fingerprint text,
  expires_at timestamptz not null default (now()+interval '14 days'),
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists stripe_checkout_claims_status_idx
  on public.stripe_checkout_claims(status,expires_at);
create index if not exists stripe_checkout_claims_fingerprint_idx
  on public.stripe_checkout_claims(request_fingerprint,created_at desc);

alter table public.stripe_checkout_claims enable row level security;
revoke all on table public.stripe_checkout_claims from public,anon,authenticated;

-- Une offre ne doit plus pouvoir être changée directement depuis le navigateur.
-- Le choix définitif est désormais écrit uniquement par Stripe (webhook/claim)
-- ou par l'administration de plateforme avec traçabilité.
revoke execute on function public.choose_plan(uuid,text,text) from public,anon,authenticated;
grant execute on function public.choose_plan(uuid,text,text) to service_role;

commit;
