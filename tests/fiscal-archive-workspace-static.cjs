const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const assert=(value,message)=>{if(!value)throw new Error(message);};

const app=read('assets/js/modules/erp/erp-app.js');
const nav=read('assets/js/modules/erp/erp-modern.js');
const access=read('assets/js/modules/erp/erp-access-control.js');
const accounting=read('assets/js/modules/erp/erp-accounting-extensions.js');
const css=read('assets/css/accounting-extensions.css');
const onboarding=read('assets/js/modules/onboarding/professional-onboarding.js');

assert(app.includes("'accounting/fiscal-archives':'accounting-fiscal-archives'"),'route des archives fiscales absente');
assert(nav.includes("['accounting/fiscal-archives','Archives fiscales']"),'entrée Archives fiscales absente du menu Comptabilité');
assert(access.includes("'accounting/fiscal-archives':['accounting.exports.manage']"),'permission comptable des archives absente');
assert(accounting.includes("api().rpc('create_fiscal_archive'"),'création serveur de l’archive non raccordée');
assert(accounting.includes("api().invoke('export-fiscal-archive',{archiveId})"),'signature et export KMS non raccordés');
assert(accounting.includes("bundle?.signature?.status!=='valid'"),'validation de signature KMS non bloquante');
assert(accounting.includes('target_allow_incomplete:false'),'une archive incomplète peut être créée depuis l’interface');
assert(accounting.includes('Archive créée, signée, vérifiée et téléchargée.'),'parcours complet non confirmé');
assert(accounting.includes('À la fin de chaque mois')&&accounting.includes('avant de changer de logiciel'),'moments d’utilisation non expliqués');
assert(accounting.includes('Elle ne remplace ni votre logiciel comptable, ni une plateforme agréée'),'limite fonctionnelle non expliquée');
assert(css.includes('.ops-archive-create')&&css.includes('.ops-archive-guidance'),'interface des archives non stylée');
assert(!onboarding.toLowerCase().includes('archive fiscale'),'l’archive fiscale a été ajoutée à tort à l’onboarding');

console.log(JSON.stringify({ok:true,route:true,permissions:true,kms:true,download:true,onboarding_unchanged:true}));
