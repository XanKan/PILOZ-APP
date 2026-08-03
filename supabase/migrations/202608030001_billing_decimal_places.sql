alter table public.company_document_settings
  add column if not exists billing_decimal_places smallint not null default 2;

alter table public.company_document_settings
  drop constraint if exists company_document_settings_billing_decimal_places_check;

alter table public.company_document_settings
  add constraint company_document_settings_billing_decimal_places_check
  check (billing_decimal_places between 0 and 2);

comment on column public.company_document_settings.billing_decimal_places is
  'Nombre de decimales maximum utilisees par defaut dans les montants de facturation Piloz. Valeur par defaut : 2.';
