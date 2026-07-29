const fs=require('node:fs');

const onboarding=fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js','utf8');
const styles=fs.readFileSync('assets/css/phase1-foundation.css','utf8');
const stepOneSection=onboarding.slice(onboarding.indexOf('if(step===1)'),onboarding.indexOf('if(step===2)'));

const checks={
  step_one_only_saves_company_identity:stepOneSection.includes('legal_name:')&&stepOneSection.includes('siret:')&&!stepOneSection.includes('company_document_settings')&&!stepOneSection.includes('document_sequences')&&!stepOneSection.includes('company_addresses'),
  provisional_company_name_replaced:onboarding.includes("if(step===1)await PilozERP.request(`/rest/v1/companies?id=eq.${encodeURIComponent(companyId)}`")&&onboarding.includes("name:trim(identity.tradeName)||trim(identity.legalName)"),
  provisional_label_hidden:onboarding.includes("/^Entreprise à configurer\\s*[—-]/i")&&onboarding.includes("x.tradeName=''"),
  address_saved_only_on_step_two:onboarding.includes("if(step===2){const payload={company_id:companyId,kind:'registered'")&&onboarding.includes("PilozERP.insert('company_addresses',payload)"),
  document_configuration_saved_only_on_step_six:onboarding.includes("if(step===6){documents.quotePrefix='DEV'")&&onboarding.includes("PilozERP.rpc('save_company_onboarding_document_configuration'"),
  no_direct_rls_numbering_write:!onboarding.includes('/rest/v1/document_sequences?on_conflict')&&!onboarding.includes('await PilozERP.request(`/rest/v1/company_document_settings?company_id'),
  step_six_uses_select_lists:onboarding.includes('Mode de paiement préféré *')&&onboarding.includes('${paymentMethodOptions(x.defaultPaymentMethod)}')&&onboarding.includes('${paymentTermOptions(x.defaultPaymentTerms)}'),
  fixed_business_prefixes:onboarding.includes("fixedPrefix('Préfixe devis','DEV')")&&onboarding.includes("fixedPrefix('Préfixe factures','FAC')")&&onboarding.includes("fixedPrefix('Préfixe avoirs','AV')")&&onboarding.includes("fixedPrefix('Préfixe commandes','CMD')"),
  optional_year_and_month:onboarding.includes("professionalSetNumberPart('${family}','year'")&&onboarding.includes("professionalSetNumberPart('${family}','month'"),
  inline_accessible_error:onboarding.includes('class="phase1-setup-error" role="alert" aria-live="assertive"'),
  form_data_preserved_on_failure:onboarding.includes("const forbidden=String(error?.code||'')==='42501'")&&!onboarding.includes('location.reload()'),
  double_submission_blocked:onboarding.includes('if(setupBusy)return;')&&onboarding.includes("setupBusy?'Enregistrement…'"),
  toast_above_onboarding:styles.includes('.toast{z-index:10000!important}'),
};

console.log(JSON.stringify(checks,null,2));
if(Object.values(checks).some(value=>!value))process.exit(1);
