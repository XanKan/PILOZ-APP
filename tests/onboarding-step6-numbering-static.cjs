const fs=require('node:fs');

const onboarding=fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js','utf8');
const settings=fs.readFileSync('assets/js/modules/erp/erp-modern.js','utf8');
const migration=fs.readFileSync('supabase/migrations/202607290104_onboarding_numbering_controls.sql','utf8');

const checks={
  onboarding_payment_method_is_select:/<label>Mode de paiement préféré \*<\/label><select/.test(onboarding),
  onboarding_payment_term_is_select:/<label>Conditions de paiement \*<\/label><select/.test(onboarding),
  configured_payment_options_loaded:onboarding.includes("PilozERP.query('payment_methods'")&&onboarding.includes("PilozERP.query('payment_terms'"),
  onboarding_uses_atomic_rpc:onboarding.includes("PilozERP.rpc('save_company_onboarding_document_configuration'")&&!onboarding.includes('/rest/v1/document_sequences?on_conflict'),
  production_compatibility_path_is_safe:onboarding.includes("PilozERP.rpc('save_company_numbering_configuration'")&&onboarding.includes("company_document_settings?company_id=eq.")&&!onboarding.includes('/rest/v1/document_sequences?on_conflict'),
  prefixes_are_fixed:onboarding.includes("quotePrefix='DEV'")&&onboarding.includes("invoicePrefix='FAC'")&&onboarding.includes("creditPrefix='AV'")&&onboarding.includes("orderPrefix='CMD'"),
  year_month_are_independent:onboarding.includes("if(includeMonth)return'prefix_month'")&&onboarding.includes("return'prefix_number'"),
  settings_prefixes_are_readonly:settings.includes("field('Préfixe devis','quote_prefix',quotePrefix,'text','readonly aria-readonly=\"true\"')")&&settings.includes("field('Préfixe factures','invoice_prefix',invoicePrefix,'text','readonly aria-readonly=\"true\"')"),
  settings_show_same_checkboxes:settings.includes('name="${family}_include_year"')&&settings.includes('name="${family}_include_month"'),
  settings_preview_updates:settings.includes("updateNumberingPreview('quote')")&&settings.includes('global.PilozModern={')&&settings.includes(',updateNumberingPreview,saveSalesNumbering'),
  database_accepts_all_combinations:migration.includes("'prefix_year_month','prefix_year','prefix_month','prefix_number','year_prefix'"),
  database_generates_month_only:migration.includes("when 'prefix_month' then sequence_row.prefix||'-'||target_month||'-'||number_value"),
  database_generates_prefix_only:migration.includes("when 'prefix_number' then sequence_row.prefix||'-'||number_value"),
  onboarding_rpc_authorizes_company_owner:migration.includes('company.owner_user_id=auth.uid()'),
  onboarding_rpc_is_atomic:migration.includes('create or replace function public.save_company_onboarding_document_configuration')&&migration.includes("default_payment_method=nullif(trim(target_default_payment_method),'')"),
};

console.log(JSON.stringify(checks,null,2));
if(Object.values(checks).some(value=>!value))process.exit(1);
