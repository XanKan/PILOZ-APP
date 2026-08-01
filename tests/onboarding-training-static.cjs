const assert=require('node:assert/strict');
const fs=require('node:fs');

const onboarding=fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js','utf8');
const styles=fs.readFileSync('assets/css/phase1-foundation.css','utf8');
const index=fs.readFileSync('index.html','utf8');

assert(onboarding.includes('Étape 7 — Découvrir Piloz avec la formation guidée'),'La dernière étape doit présenter la formation Piloz.');
assert(onboarding.includes('Ouvrir la formation')&&onboarding.includes('Passer pour le moment'),'Les deux choix de fin d’onboarding doivent être disponibles.');
assert(onboarding.includes("global.PilozHelp.openTraining('demarrage','tour')")&&onboarding.includes("PilozApp?.go?.('help/training')"),'Le bouton principal doit ouvrir directement l’Académie Piloz.');
assert(onboarding.includes('onboarding_completed:true'),'Les deux choix doivent finaliser durablement l’onboarding.');
assert(!onboarding.includes('Étape 7 — Réception des factures fournisseurs'),'La facturation électronique ne doit plus être présentée pendant l’onboarding.');
assert(!onboarding.includes('professionalActivateElectronicInvoicing')&&!onboarding.includes('professionalLoadElectronicInvoicing'),'Aucune activation électronique ne doit être déclenchée depuis l’onboarding.');
assert(!onboarding.includes('electronicInvoicingDeferred'),'L’onboarding ne doit plus stocker de report de facturation électronique.');
assert(styles.includes('.onboarding-training-topics')&&styles.includes('.onboarding-training-actions'),'La nouvelle étape doit disposer de sa mise en page responsive.');
assert(index.includes('professional-onboarding.js?v=20260801.1')&&index.includes('phase1-foundation.css?v=20260731.6'),'Le cache des ressources modifiées doit être invalidé.');

console.log('PASS onboarding training static');
