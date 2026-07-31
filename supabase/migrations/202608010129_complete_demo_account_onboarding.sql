begin;

-- Demo accounts open directly on their populated workspace. These identifiers
-- are intentionally fictional and are only used inside the demo tenant.
insert into public.company_document_settings(company_id,quote_prefix,invoice_prefix)
select company.id,'DEV-DEMO','FAC-DEMO'
from public.companies company
where company.admin_tags @> array['demo']::text[]
on conflict(company_id) do nothing;

update public.company_document_settings settings set
  quote_prefix='DEV-DEMO',
  invoice_prefix='FAC-DEMO',
  updated_at=now()
from public.companies company
where company.id=settings.company_id and company.admin_tags @> array['demo']::text[];

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
  subject_to_vat=coalesce(settings.subject_to_vat,true),
  default_vat_rate=coalesce(settings.default_vat_rate,20),
  onboarding_step=7,
  onboarding_completed_at=coalesce(settings.onboarding_completed_at,now()),
  updated_at=now()
from public.companies company
where company.id=settings.company_id and company.admin_tags @> array['demo']::text[];

update public.user_preferences preferences set
  company_id=company.id,
  onboarding_completed=true,
  updated_at=now()
from public.companies company
where company.owner_user_id=preferences.user_id and company.admin_tags @> array['demo']::text[];

commit;
