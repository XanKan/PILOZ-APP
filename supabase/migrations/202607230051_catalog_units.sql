begin;

alter table public.company_catalog_settings
  add column if not exists units text[] not null default array[
    'unité',
    'heure',
    'jour',
    'forfait',
    'mètre',
    'm²',
    'm³',
    'kilogramme',
    'litre',
    'lot',
    'mois'
  ]::text[];

update public.company_catalog_settings
set units = array[
  'unité',
  'heure',
  'jour',
  'forfait',
  'mètre',
  'm²',
  'm³',
  'kilogramme',
  'litre',
  'lot',
  'mois'
]::text[]
where cardinality(units) = 0;

alter table public.company_catalog_settings
  drop constraint if exists company_catalog_settings_units_check;
alter table public.company_catalog_settings
  add constraint company_catalog_settings_units_check
  check (cardinality(units) between 1 and 100) not valid;

grant select(units), update(units)
  on public.company_catalog_settings
  to authenticated;

commit;
