const fs=require('node:fs');

const onboarding=fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js','utf8');
const styles=fs.readFileSync('assets/css/phase1-foundation.css','utf8');
const stepOneSection=onboarding.slice(onboarding.indexOf('if(step===1)'),onboarding.indexOf('if(step===2)'));

const checks={
  step_one_only_saves_company_identity:stepOneSection.includes('legal_name:')&&stepOneSection.includes('siret:')&&!stepOneSection.includes('company_document_settings')&&!stepOneSection.includes('document_sequences')&&!stepOneSection.includes('company_addresses'),
  address_saved_only_on_step_two:onboarding.includes("if(step===2){const payload={company_id:companyId,kind:'registered'")&&onboarding.includes("PilozERP.insert('company_addresses',payload)"),
  document_configuration_saved_only_on_step_six:onboarding.includes("if(step===6){await PilozERP.request('/rest/v1/company_document_settings"),
  inline_accessible_error:onboarding.includes('class="phase1-setup-error" role="alert" aria-live="assertive"'),
  form_data_preserved_on_failure:onboarding.includes("showSetupError(error?.status===403")&&!onboarding.includes('location.reload()'),
  double_submission_blocked:onboarding.includes('if(setupBusy)return;')&&onboarding.includes("setupBusy?'Enregistrement…'"),
  toast_above_onboarding:styles.includes('.toast{z-index:10000!important}'),
};

console.log(JSON.stringify(checks,null,2));
if(Object.values(checks).some(value=>!value))process.exit(1);
