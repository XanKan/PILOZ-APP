const assert=require('node:assert/strict');
const fs=require('node:fs');

const onboarding=fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js','utf8');
const settings=fs.readFileSync('assets/js/modules/erp/erp-modern.js','utf8');
const editor=fs.readFileSync('assets/js/modules/erp/erp-document-editor-v2.js','utf8');
const index=fs.readFileSync('index.html','utf8');

assert(onboarding.includes("input('Titulaire du compte','banking.accountHolder'"),'Le titulaire doit être demandé dans l’onboarding.');
assert(onboarding.includes("input('Nom de la banque','banking.bankName'"),'La banque doit être demandée dans l’onboarding.');
assert(onboarding.includes("input('IBAN','banking.iban'")&&onboarding.includes("input('BIC / SWIFT','banking.bic'"),'L’IBAN et le BIC doivent être demandés dans l’onboarding.');
assert(onboarding.includes('validOnboardingIban')&&onboarding.includes('Le BIC doit contenir 8 ou 11 caractères.'),'Les coordonnées doivent être validées avant leur enregistrement.');
assert(onboarding.includes("bank_account_holder:trim(bank.accountHolder)||null")&&onboarding.includes("bank_name:trim(bank.bankName)||null")&&onboarding.includes("mandate_reference:trim(bank.mandateReference)||null"),'Les coordonnées doivent être sérialisées dans les colonnes des paramètres documentaires.');
assert(onboarding.includes("/rest/v1/company_document_settings?on_conflict=company_id"),'L’onboarding doit persister la banque dans la source Supabase partagée.');
assert(settings.includes("field('Titulaire du compte','bank_account_holder'")&&settings.includes("field('BIC','bic'")&&settings.includes("docs.iban?maskIban(docs.iban)"),'La page Banque et règlements doit lire la même source.');
assert(editor.includes('function bankDetailsBlock')&&editor.includes('settings.bank_account_holder')&&editor.includes('settings.iban')&&editor.includes('settings.bic'),'Les modèles doivent reprendre automatiquement la source bancaire partagée.');
assert(editor.includes("methods.includes('bank_transfer')"),'Les coordonnées doivent être affichées lorsque le virement est proposé.');
assert(index.includes('professional-onboarding.js?v=20260729.9'),'Le cache du module d’onboarding doit être invalidé.');

console.log('PASS onboarding banking static');
