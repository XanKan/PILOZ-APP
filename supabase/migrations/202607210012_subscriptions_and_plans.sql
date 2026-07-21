begin;

-- Catalogue des offres. Les capacités (features) sont la source de vérité
-- serveur ; le client dispose d'une copie statique du même contenu pour un
-- accès instantané, mais la vérité applicative reste ici et dans
-- has_feature()/is_company_onboarded-like guards côté RPC quand nécessaire.
create table if not exists public.plans(
  key text primary key,
  name text not null,
  price_monthly_cents integer not null,
  price_annual_cents integer not null,
  max_users integer not null,
  features jsonb not null default '[]'::jsonb,
  position smallint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.plans(key,name,price_monthly_cents,price_annual_cents,max_users,features,position) values
 ('essential','Essentiel',2900,29000,1,
  '["crm","quotes","invoices","credit_notes","payments","manual_reminders"]'::jsonb,1),
 ('pro','Pro',5900,59000,5,
  '["crm","quotes","invoices","credit_notes","payments","manual_reminders","automatic_reminders","recurring_invoices","deposits","sales_pipeline_automations","purchases","suppliers","purchase_orders","inventory","advanced_templates","advanced_dashboard","margin_reports"]'::jsonb,2),
 ('business','Business',9900,99000,15,
  '["crm","quotes","invoices","credit_notes","payments","manual_reminders","automatic_reminders","recurring_invoices","deposits","sales_pipeline_automations","purchases","suppliers","purchase_orders","inventory","advanced_templates","advanced_dashboard","margin_reports","multi_warehouse","roles_permissions","activity_logs","api_access"]'::jsonb,3)
on conflict(key) do update set
  name=excluded.name, price_monthly_cents=excluded.price_monthly_cents, price_annual_cents=excluded.price_annual_cents,
  max_users=excluded.max_users, features=excluded.features, position=excluded.position, updated_at=now();

-- Un abonnement par entreprise (jamais par utilisateur : plusieurs membres
-- partagent la même offre).
create table if not exists public.subscriptions(
  company_id uuid primary key references public.companies(id) on delete cascade,
  plan_key text not null references public.plans(key),
  billing_interval text not null default 'monthly' check(billing_interval in('monthly','annual')),
  status text not null default 'trialing' check(status in('trialing','active','past_due','canceled','suspended','expired')),
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  subscription_started_at timestamptz,
  subscription_ends_at timestamptz,
  external_customer_id text,
  external_subscription_id text,
  cancellation_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;

drop policy if exists plans_select on public.plans;
create policy plans_select on public.plans for select to authenticated using(true);

drop policy if exists subscriptions_select on public.subscriptions;
create policy subscriptions_select on public.subscriptions for select to authenticated
  using(public.is_company_member(company_id));

-- Le client ne peut jamais s'auto-activer un abonnement payant ou modifier
-- son statut : ces écritures passent exclusivement par les RPC ci-dessous
-- (choose_plan pour le choix d'offre en essai, cancel_subscription /
-- reactivate_subscription pour l'annulation) ou par service_role (webhook
-- de paiement futur). Aucune policy UPDATE/INSERT n'est accordée ici.

revoke all on table public.plans from anon,authenticated;
grant select on table public.plans to anon,authenticated;
revoke all on table public.subscriptions from anon,authenticated;
grant select on table public.subscriptions to authenticated;

create or replace function public.set_current_timestamp_updated_at_subscriptions()
returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end $$;
drop trigger if exists subscriptions_set_updated_at on public.subscriptions;
create trigger subscriptions_set_updated_at before update on public.subscriptions
for each row execute function public.set_current_timestamp_updated_at_subscriptions();

-- Provisionne un essai de 14 jours à la création de l'entreprise.
create or replace function public.provision_trial_subscription()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.subscriptions(company_id,plan_key,billing_interval,status,trial_started_at,trial_ends_at)
  values(new.id,'essential','monthly','trialing',now(),now()+interval '14 days')
  on conflict(company_id) do nothing;
  return new;
end $$;
drop trigger if exists companies_provision_trial on public.companies;
create trigger companies_provision_trial after insert on public.companies
for each row execute function public.provision_trial_subscription();

-- Rattrapage : toute entreprise existante sans abonnement reçoit un essai
-- (ne remplace jamais un abonnement déjà présent).
insert into public.subscriptions(company_id,plan_key,billing_interval,status,trial_started_at,trial_ends_at)
select c.id,'essential','monthly','trialing',coalesce(c.created_at,now()),coalesce(c.created_at,now())+interval '14 days'
from public.companies c
where not exists(select 1 from public.subscriptions s where s.company_id=c.id);

-- Sélection/changement d'offre pendant l'essai : le membre owner/admin peut
-- choisir l'offre visée et la périodicité. Cela ne fait jamais passer le
-- statut à 'active' — seule une confirmation manuelle (ou un futur webhook
-- Stripe côté service_role) peut le faire, pour ne jamais simuler un
-- paiement réussi.
create or replace function public.choose_plan(target_company_id uuid,target_plan_key text,target_billing_interval text default 'monthly')
returns public.subscriptions language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.subscriptions%rowtype;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_billing_interval not in('monthly','annual') then raise exception 'invalid_billing_interval'; end if;
  if not exists(select 1 from public.plans where key=target_plan_key) then raise exception 'invalid_plan'; end if;
  update public.subscriptions
     set plan_key=target_plan_key, billing_interval=target_billing_interval, updated_at=now()
   where company_id=target_company_id
   returning * into row;
  if row.company_id is null then raise exception 'subscription_not_found'; end if;
  insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data)
  values(target_company_id,'subscription.plan_selected','subscription',target_company_id,to_jsonb(row));
  return row;
end $$;

create or replace function public.cancel_subscription(target_company_id uuid)
returns public.subscriptions language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.subscriptions%rowtype;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  update public.subscriptions
     set cancellation_at_period_end=true, updated_at=now()
   where company_id=target_company_id
   returning * into row;
  if row.company_id is null then raise exception 'subscription_not_found'; end if;
  insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data)
  values(target_company_id,'subscription.cancellation_requested','subscription',target_company_id,to_jsonb(row));
  return row;
end $$;

create or replace function public.reactivate_subscription(target_company_id uuid)
returns public.subscriptions language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.subscriptions%rowtype;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  update public.subscriptions
     set cancellation_at_period_end=false, updated_at=now()
   where company_id=target_company_id
   returning * into row;
  if row.company_id is null then raise exception 'subscription_not_found'; end if;
  insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data)
  values(target_company_id,'subscription.reactivated','subscription',target_company_id,to_jsonb(row));
  return row;
end $$;

-- Vérité serveur pour le contrôle d'accès aux fonctions RPC sensibles ;
-- le client utilise sa propre copie de plans.features pour l'UI, mais
-- toute RPC qui a besoin de trancher réellement doit passer par ici plutôt
-- que de faire confiance à l'état du navigateur.
create or replace function public.has_feature(target_company_id uuid,feature_key text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.subscriptions s
    join public.plans p on p.key=s.plan_key
    where s.company_id=target_company_id
      and s.status in('trialing','active','past_due')
      and p.features ? feature_key
  );
$$;

revoke execute on function public.choose_plan(uuid,text,text) from public,anon;
revoke execute on function public.cancel_subscription(uuid) from public,anon;
revoke execute on function public.reactivate_subscription(uuid) from public,anon;
revoke execute on function public.has_feature(uuid,text) from public,anon;
grant execute on function public.choose_plan(uuid,text,text) to authenticated,service_role;
grant execute on function public.cancel_subscription(uuid) to authenticated,service_role;
grant execute on function public.reactivate_subscription(uuid) to authenticated,service_role;
grant execute on function public.has_feature(uuid,text) to authenticated,service_role;

commit;
