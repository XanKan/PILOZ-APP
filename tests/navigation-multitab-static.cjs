const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const assert=(value,message)=>{if(!value)throw new Error(message);};

const index=read('index.html');
const nav=read('assets/js/modules/erp/erp-modern.js');
const app=read('assets/js/modules/erp/erp-app.js');
const api=read('assets/js/api/erp-api.js');
const crm=read('assets/js/modules/erp/erp-crm-rework.js');
const premiumCss=read('assets/css/piloz-premium.css');
const crmCss=read('assets/css/crm-rework.css');

const primary=nav.match(/primary=\[([^;]+)\],withoutSecondary/)?.[1]||'';
assert(!primary.includes("['reports','Rapports']"),'Rapports est encore présent dans le menu principal');
assert(!primary.includes("['settings','Paramètres']"),'Paramètres est encore présent dans le menu principal');
const accountingPosition=index.indexOf('id="accounting-shortcut"');
const settingsPosition=index.indexOf('id="settings-shortcut"');
assert(accountingPosition>=0&&settingsPosition>accountingPosition,'Paramètres doit être placé juste après Comptabilité');

assert(nav.includes('modern-secondary-new-tab')&&nav.includes("PilozModern.openInNewTab('${path}')"),'bouton nouvel onglet absent des sous-menus');
assert(nav.includes("global.open(url.href,'_blank','noopener,noreferrer')"),'ouverture sécurisée dans un nouvel onglet absente');
assert(nav.includes('global.PilozModern.openInNewTab=openInNewTab'),'fonction nouvel onglet non exposée');
assert(premiumCss.includes('.modern-secondary-new-tab')&&premiumCss.includes('.modern-secondary-entry'),'styles du bouton nouvel onglet absents');

assert(app.includes("new BroadcastChannel('piloz-erp-sync')"),'synchronisation BroadcastChannel absente');
assert(app.includes("global.addEventListener('storage'")&&app.includes("document.addEventListener('visibilitychange'"),'repli de synchronisation inter-onglets absent');
assert(api.includes('notifySuccessfulMutation')&&api.includes('PilozTabSync?.notifyMutation'),'mutations API non diffusées aux autres onglets');

assert(crm.includes("layer.id='crm-quick-party-layer'")&&crm.includes('crm-quick-party-dialog'),'création client/prospect non rendue dans une vraie fenêtre');
assert(!crm.includes('id="crm-quick-party" class="crm-quick-party"'),'ancien formulaire écrasé encore imbriqué dans le sélecteur');
assert(crmCss.includes('.crm-quick-party-layer')&&crmCss.includes('@media(max-width:620px)'),'fenêtre de création client/prospect non responsive');

process.stdout.write(JSON.stringify({ok:true,reports_removed:true,settings_after_accounting:true,new_tab:true,multitab_sync:true,quick_party_modal:true})+'\n');
