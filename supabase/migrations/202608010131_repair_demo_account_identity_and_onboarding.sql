begin;

-- Older demo accounts may have been created before the demo tags and the
-- completed onboarding state were persisted reliably. Auth metadata is the
-- authoritative signal because it is written at account creation time.
update public.companies company
set
  admin_tags=array(
    select distinct tag
    from unnest(coalesce(company.admin_tags,'{}'::text[]) || array['demo','seeded']::text[]) tag
  ),
  updated_at=now()
from auth.users auth_user
where company.owner_user_id=auth_user.id
  and lower(coalesce(auth_user.raw_user_meta_data->>'demo_account','')) in ('true','1','yes');

insert into public.company_document_settings(company_id,quote_prefix,invoice_prefix)
select company.id,'DEV-DEMO','FAC-DEMO'
from public.companies company
where company.admin_tags @> array['demo']::text[]
on conflict(company_id) do update set
  quote_prefix=excluded.quote_prefix,
  invoice_prefix=excluded.invoice_prefix,
  updated_at=now();

update public.company_settings settings set
  legal_name=coalesce(nullif(trim(settings.legal_name),''),'Horizon Conseil (démonstration)'),
  trade_name=coalesce(nullif(trim(settings.trade_name),''),'Horizon Conseil'),
  siren=coalesce(nullif(trim(settings.siren),''),'123456789'),
  siret=coalesce(nullif(trim(settings.siret),''),'12345678900012'),
  address_line1=coalesce(nullif(trim(settings.address_line1),''),'18 avenue des Ateliers'),
  postal_code=coalesce(nullif(trim(settings.postal_code),''),'85000'),
  city=coalesce(nullif(trim(settings.city),''),'La Roche-sur-Yon'),
  country=coalesce(nullif(trim(settings.country),''),'France'),
  country_code=coalesce(nullif(trim(settings.country_code),''),'FR'),
  email=coalesce(nullif(trim(settings.email),''),'contact@horizon-conseil.example'),
  phone_e164=coalesce(nullif(trim(settings.phone_e164),''),'+33100000000'),
  currency=coalesce(nullif(trim(settings.currency),''),'EUR'),
  language=coalesce(nullif(trim(settings.language),''),'fr'),
  subject_to_vat=coalesce(settings.subject_to_vat,true),
  default_vat_rate=coalesce(settings.default_vat_rate,20),
  onboarding_step=7,
  onboarding_completed_at=coalesce(settings.onboarding_completed_at,now()),
  updated_at=now()
from public.companies company
where company.id=settings.company_id
  and company.admin_tags @> array['demo']::text[];

insert into public.user_preferences(user_id,company_id,onboarding_completed)
select company.owner_user_id,company.id,true
from public.companies company
where company.admin_tags @> array['demo']::text[]
on conflict(user_id) do update set
  company_id=excluded.company_id,
  onboarding_completed=true,
  updated_at=now();

commit;
