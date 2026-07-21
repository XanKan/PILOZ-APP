begin;

-- Les premières migrations avaient créé les entreprises depuis l'état historique,
-- sans recopier leurs paramètres. Ce backfill ne remplace jamais une valeur déjà
-- saisie dans les tables normalisées.
do $migration$
begin
  if to_regclass('public.etat') is null then
    return;
  end if;

  insert into public.company_settings (
    company_id, legal_name, trade_name, legal_form, siret, ape_code,
    address_line1, address_line2, postal_code, city, country, country_code,
    phone_e164, email, subject_to_vat, vat_number, vat_regime,
    default_vat_rate, currency, language, onboarding_completed_at
  )
  select
    c.id,
    coalesce(nullif(e.data #>> '{entreprise,identity,legalName}', ''), nullif(e.data #>> '{factu,societe,nom}', '')),
    nullif(e.data #>> '{entreprise,identity,tradeName}', ''),
    nullif(e.data #>> '{entreprise,identity,legalForm}', ''),
    nullif(regexp_replace(coalesce(e.data #>> '{entreprise,identity,siret}', e.data #>> '{factu,societe,siret}', ''), '\D', '', 'g'), ''),
    nullif(e.data #>> '{entreprise,identity,apeCode}', ''),
    nullif(e.data #>> '{entreprise,identity,addressLine1}', ''),
    nullif(e.data #>> '{entreprise,identity,addressLine2}', ''),
    nullif(e.data #>> '{entreprise,identity,postalCode}', ''),
    nullif(e.data #>> '{entreprise,identity,city}', ''),
    coalesce(nullif(e.data #>> '{entreprise,identity,country}', ''), 'France'),
    'FR',
    nullif(e.data #>> '{entreprise,identity,phone}', ''),
    coalesce(nullif(e.data #>> '{entreprise,identity,email}', ''), nullif(e.data #>> '{factu,societe,email}', '')),
    case when e.data #>> '{entreprise,fiscality,subjectToVat}' in ('true', 'false') then (e.data #>> '{entreprise,fiscality,subjectToVat}')::boolean end,
    coalesce(nullif(e.data #>> '{entreprise,fiscality,vatNumber}', ''), nullif(e.data #>> '{factu,societe,tvaIntra}', '')),
    nullif(e.data #>> '{entreprise,fiscality,vatRegime}', ''),
    case when e.data #>> '{entreprise,fiscality,defaultVatRate}' ~ '^\d+(\.\d+)?$' then (e.data #>> '{entreprise,fiscality,defaultVatRate}')::numeric else 20 end,
    coalesce(nullif(e.data #>> '{entreprise,fiscality,currency}', ''), 'EUR'),
    coalesce(nullif(e.data #>> '{entreprise,fiscality,language}', ''), 'fr'),
    case when e.data #>> '{entreprise,setup,completed}' = 'true' then coalesce(nullif(e.data #>> '{entreprise,setup,completedAt}', '')::timestamptz, now()) end
  from public.companies c
  join public.etat e on e.user_id = c.owner_user_id
  on conflict (company_id) do update set
    legal_name = coalesce(nullif(public.company_settings.legal_name, ''), excluded.legal_name),
    trade_name = coalesce(nullif(public.company_settings.trade_name, ''), excluded.trade_name),
    legal_form = coalesce(nullif(public.company_settings.legal_form, ''), excluded.legal_form),
    siret = coalesce(nullif(public.company_settings.siret, ''), excluded.siret),
    ape_code = coalesce(nullif(public.company_settings.ape_code, ''), excluded.ape_code),
    address_line1 = coalesce(nullif(public.company_settings.address_line1, ''), excluded.address_line1),
    address_line2 = coalesce(nullif(public.company_settings.address_line2, ''), excluded.address_line2),
    postal_code = coalesce(nullif(public.company_settings.postal_code, ''), excluded.postal_code),
    city = coalesce(nullif(public.company_settings.city, ''), excluded.city),
    country = coalesce(nullif(public.company_settings.country, ''), excluded.country),
    country_code = coalesce(nullif(public.company_settings.country_code, ''), excluded.country_code),
    phone_e164 = coalesce(nullif(public.company_settings.phone_e164, ''), excluded.phone_e164),
    email = coalesce(nullif(public.company_settings.email, ''), excluded.email),
    subject_to_vat = coalesce(public.company_settings.subject_to_vat, excluded.subject_to_vat),
    vat_number = coalesce(nullif(public.company_settings.vat_number, ''), excluded.vat_number),
    vat_regime = coalesce(nullif(public.company_settings.vat_regime, ''), excluded.vat_regime),
    currency = coalesce(nullif(public.company_settings.currency, ''), excluded.currency),
    language = coalesce(nullif(public.company_settings.language, ''), excluded.language),
    onboarding_completed_at = coalesce(public.company_settings.onboarding_completed_at, excluded.onboarding_completed_at);

  insert into public.company_document_settings (
    company_id, quote_prefix, quote_next_number, invoice_prefix,
    invoice_next_number, credit_prefix, credit_next_number,
    quote_validity_days, default_payment_terms, default_payment_method,
    bank_account_holder, bank_name, iban, bic, accepted_payment_methods,
    legal_notice, collection_fee_notice, visible_mention
  )
  select
    c.id,
    coalesce(nullif(e.data #>> '{entreprise,documents,quotePrefix}', ''), 'DEV'),
    case when e.data #>> '{entreprise,documents,quoteNextNumber}' ~ '^\d+$' then (e.data #>> '{entreprise,documents,quoteNextNumber}')::integer else 1 end,
    coalesce(nullif(e.data #>> '{entreprise,documents,invoicePrefix}', ''), 'FAC'),
    case when e.data #>> '{entreprise,documents,invoiceNextNumber}' ~ '^\d+$' then (e.data #>> '{entreprise,documents,invoiceNextNumber}')::integer else 1 end,
    coalesce(nullif(e.data #>> '{entreprise,documents,creditPrefix}', ''), 'AV'),
    case when e.data #>> '{entreprise,documents,creditNextNumber}' ~ '^\d+$' then (e.data #>> '{entreprise,documents,creditNextNumber}')::integer else 1 end,
    case when e.data #>> '{entreprise,documents,quoteValidityDays}' ~ '^\d+$' then (e.data #>> '{entreprise,documents,quoteValidityDays}')::integer else 30 end,
    coalesce(nullif(e.data #>> '{entreprise,documents,defaultPaymentTerms}', ''), '30 jours'),
    coalesce(nullif(e.data #>> '{entreprise,documents,defaultPaymentMethod}', ''), 'Virement bancaire'),
    nullif(e.data #>> '{entreprise,banking,accountHolder}', ''),
    nullif(e.data #>> '{entreprise,banking,bankName}', ''),
    nullif(e.data #>> '{entreprise,banking,iban}', ''),
    nullif(e.data #>> '{entreprise,banking,bic}', ''),
    coalesce(e.data #> '{entreprise,banking,acceptedPaymentMethods}', '["Virement bancaire"]'::jsonb),
    nullif(e.data #>> '{entreprise,documents,legalNotice}', ''),
    nullif(e.data #>> '{entreprise,documents,collectionFeeNotice}', ''),
    nullif(e.data #>> '{entreprise,documents,visibleMention}', '')
  from public.companies c
  join public.etat e on e.user_id = c.owner_user_id
  on conflict (company_id) do update set
    quote_prefix = coalesce(nullif(public.company_document_settings.quote_prefix, ''), excluded.quote_prefix),
    invoice_prefix = coalesce(nullif(public.company_document_settings.invoice_prefix, ''), excluded.invoice_prefix),
    credit_prefix = coalesce(nullif(public.company_document_settings.credit_prefix, ''), excluded.credit_prefix),
    default_payment_terms = coalesce(nullif(public.company_document_settings.default_payment_terms, ''), excluded.default_payment_terms),
    default_payment_method = coalesce(nullif(public.company_document_settings.default_payment_method, ''), excluded.default_payment_method),
    bank_account_holder = coalesce(nullif(public.company_document_settings.bank_account_holder, ''), excluded.bank_account_holder),
    bank_name = coalesce(nullif(public.company_document_settings.bank_name, ''), excluded.bank_name),
    iban = coalesce(nullif(public.company_document_settings.iban, ''), excluded.iban),
    bic = coalesce(nullif(public.company_document_settings.bic, ''), excluded.bic),
    legal_notice = coalesce(nullif(public.company_document_settings.legal_notice, ''), excluded.legal_notice),
    collection_fee_notice = coalesce(nullif(public.company_document_settings.collection_fee_notice, ''), excluded.collection_fee_notice),
    visible_mention = coalesce(nullif(public.company_document_settings.visible_mention, ''), excluded.visible_mention);
end
$migration$;

commit;
