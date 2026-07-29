const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const assert=(value,message)=>{if(!value)throw new Error(message);};

const index=read('index.html');
const app=read('assets/js/modules/erp/erp-app.js');
const dashboard=read('assets/js/modules/erp/erp-dashboard-cockpit.js');

assert(index.includes("return identity?`piloz_crm_v1:${identity}`:'piloz_crm_v1'"),'le cache historique reste partage entre les utilisateurs');
assert(index.includes('resetAccountScopedRuntime(null); clearPrivateShell();'),'la session expiree ne purge pas les donnees du compte');
assert(index.includes("lsSet('piloz_ses', null);\n  resetAccountScopedRuntime(null);"),'la deconnexion ne purge pas les donnees du compte');
assert(index.includes('resetAccountScopedRuntime(SES);'),'la connexion ne reinitialise pas le contexte metier');
assert(index.includes('window.PilozApp?.resetSession?.(nextSession);'),'le module ERP ne recoit pas le changement de session');

assert(app.includes("sessionKey:'',generation:0"),'le contexte ERP ne versionne pas la session active');
assert(app.includes('if(state.sessionKey!==sessionKey)resetSession(global.PilozRuntime?.session);'),'le chargement ne detecte pas un changement de compte');
assert(app.includes('if(state.sessionKey!==activeSessionKey)resetSession(global.PilozRuntime?.session);'),'le rendu peut reutiliser les donnees du compte precedent');
assert(app.includes('if(!sessionStillCurrent(generation,sessionKey)){state.loaded=false;state.data={};queueMicrotask(()=>render());return;}'),'une requete obsolete peut encore remplacer les donnees du nouveau compte');
assert(app.includes('global.PilozApp.resetSession=resetSession;'),'la purge ERP nest pas exposee au gestionnaire de session');
assert(app.includes('payload.sessionKey&&payload.sessionKey!==currentSessionKey()'),'la synchronisation inter-onglets accepte les evenements dun autre compte');
assert(dashboard.includes('global.PilozDashboardCockpit.resetForContext=resetForContext;'),'le tableau de bord conserve les indicateurs du compte precedent');

process.stdout.write(JSON.stringify({ok:true,scoped_legacy_cache:true,runtime_reset:true,stale_request_guard:true,cross_tab_guard:true})+'\n');
