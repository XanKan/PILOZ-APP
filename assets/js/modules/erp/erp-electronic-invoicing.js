(function(global){
 'use strict';
 const api=()=>global.PilozERP;
 const app=()=>global.PilozApp;
 const modern=global.PilozModern;
 if(!modern)return;
 const baseRender=modern.renderRoute;
 const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
 const path=()=>location.hash.slice(1).split('?')[0]||'dashboard';
 const state=()=>app()?.getState?.()||{};
 const button=(label,handler,kind='btn-o',extra='')=>`<button class="btn ${kind}" onclick="${handler}" ${extra}>${esc(label)}</button>`;
 const badge=(label,tone='info')=>`<span class="phase1-badge phase1-badge-${tone}">${esc(label)}</span>`;
 const date=value=>value?new Intl.DateTimeFormat('fr-FR',{dateStyle:'short',timeStyle:'short'}).format(new Date(value)):'Jamais';
 const statusLabel=value=>({verified:'Vérifiée',needs_review:'Vérification en cours',not_verified:'Identité à vérifier',pending:'En cours',created:'Active',not_started:'À faire',failed:'À corriger',active:'Active',not_requested:'Non demandée',error:'Erreur',rejected:'Refusée',validation_required:'Vérification requise',configured:'Configurée',suspended:'Déconnectée',unconfigured:'Non configurée'}[String(value||'')]||String(value||'À faire'));
 const statusTone=value=>['verified','active','created'].includes(String(value))?'success':['needs_review','not_verified','pending','validation_required','configured'].includes(String(value))?'warning':['failed','error','rejected'].includes(String(value))?'danger':'muted';
 let view={busy:false,connector:null,transmissions:[],production:null,events:[],confirmOpen:false,disconnectConfirm:false,error:'',success:''};

 function notify(message,tone='info'){
  if(global.PilozOps?.notify)global.PilozOps.notify(message,tone);
  else if(global.toast)global.toast(message);
 }
 function header(){
  return `<header class="modern-page-header"><div><h1>Facturation électronique</h1><p>Testez SUPER PDP dans le bac à sable, puis autorisez séparément chaque entreprise en production.</p></div><div class="actions">${button('Retour aux paramètres',"PilozApp.go('settings/overview')")}</div></header>`;
 }
 function productionCard(){
  const p=view.production||{},configured=Boolean(p.configured),active=Boolean(p.production_enabled),directory=p.directory_status||'not_requested';
  return `<section class="phase1-card"><div class="erp-card-heading"><div><h2>SUPER PDP · Production</h2><p>Autorisation OAuth propre à cette entreprise. Aucun mot de passe ni jeton n’est enregistré dans le navigateur.</p></div>${badge(active?'Production active':configured?'Activation en cours':'À activer',active?'success':configured?'warning':'muted')}</div>
   <div class="phase1-grid">
    <div class="phase1-field"><span>Entreprise SUPER PDP</span><strong>${esc(p.provider_company_name||'—')}</strong><small>${esc(p.provider_company_number||'')}</small></div>
    <div class="phase1-field"><span>Entreprise vérifiée</span><strong>${badge(statusLabel(p.company_verification_status),statusTone(p.company_verification_status))}</strong></div>
    <div class="phase1-field"><span>Identité du représentant</span><strong>${badge(statusLabel(p.user_identity_verification_status),statusTone(p.user_identity_verification_status))}</strong></div>
    <div class="phase1-field"><span>Annuaire de réception</span><strong>${badge(statusLabel(directory),statusTone(directory))}</strong></div>
    <div class="phase1-field"><span>Dernière vérification</span><strong>${date(p.last_verified_at)}</strong></div>
    <div class="phase1-field"><span>Dernière réception</span><strong>${date(p.last_incoming_sync_at)}</strong></div>
   </div>
   ${configured&&!active?`<aside class="phase1-alert phase1-alert-warning"><strong>Vérification à terminer</strong><span>SUPER PDP doit confirmer l’entreprise et, selon le dossier, l’identité de son représentant. Cliquez sur « Continuer la vérification » pour reprendre le parcours sécurisé.</span></aside>`:''}
   ${active&&directory!=='active'?`<aside class="ops-info-callout"><strong>Activer la réception</strong><span>L’inscription dans l’annuaire PPF est nécessaire pour que cette entreprise reçoive automatiquement ses factures fournisseurs.</span></aside>`:''}
   <div class="actions">
    ${!configured?button(view.busy?'Ouverture…':'Activer SUPER PDP','PilozElectronicInvoicing.startProduction()','btn-p',view.busy?'disabled':''):''}
    ${configured&&!active?button(view.busy?'Vérification…':'Continuer la vérification','PilozElectronicInvoicing.startProduction()','btn-p',view.busy?'disabled':''):''}
    ${configured?button('Actualiser le statut','PilozElectronicInvoicing.refreshProduction()','btn-o',view.busy?'disabled':''):''}
    ${active&&directory!=='active'?button(view.busy?'Activation…':'Activer la réception','PilozElectronicInvoicing.activateDirectory()','btn-p',view.busy?'disabled':''):''}
    ${configured&&!view.disconnectConfirm?button('Déconnecter','PilozElectronicInvoicing.askDisconnect()','btn-o',view.busy?'disabled':''):''}
   </div>
   ${view.disconnectConfirm?`<aside class="phase1-alert phase1-alert-danger"><strong>Déconnecter cette entreprise ?</strong><span>Les jetons seront effacés et les envois automatiques suspendus. Les factures et le journal d’audit restent conservés.</span><div class="actions">${button('Annuler','PilozElectronicInvoicing.cancelDisconnect()')}${button('Confirmer la déconnexion','PilozElectronicInvoicing.disconnect()','btn-p',view.busy?'disabled':'')}</div></aside>`:''}
   ${active?`<aside class="ops-info-callout"><strong>Automatisation active</strong><span>Les factures finalisées sont mises en file d’envoi sans intervention. Les factures reçues, statuts et événements sont synchronisés par le connecteur serveur.</span></aside>`:''}
  </section>`;
 }
 function sandboxCard(){
  const connector=view.connector,config=connector?.non_secret_configuration||{},connected=Boolean(connector),latest=view.transmissions[0];
  return `<section class="phase1-card"><div class="erp-card-heading"><div><h2>Bac à sable</h2><p>Environnement de test isolé. Les données de test ne sont jamais envoyées en production.</p></div>${badge(connected?'Connecté':'À connecter',connected?'success':'warning')}</div>
   <div class="phase1-grid"><div class="phase1-field"><span>Entreprise de test</span><strong>${esc(config.external_company_name||'—')}</strong></div><div class="phase1-field"><span>Dernière vérification</span><strong>${date(config.verified_at)}</strong></div><div class="phase1-field"><span>Dernier test</span><strong>${latest?date(latest.completed_at||latest.created_at):'Jamais'}</strong></div></div>
   ${view.confirmOpen?`<aside class="ops-info-callout"><strong>Confirmer l’envoi de test</strong><span>Une facture synthétique sera transmise uniquement au bac à sable SUPER PDP.</span><div class="actions">${button('Annuler','PilozElectronicInvoicing.closeConfirmation()')}${button(view.busy?'Envoi…':'Envoyer le test','PilozElectronicInvoicing.sendTestInvoice()','btn-p',view.busy?'disabled':'')}</div></aside>`:`<div class="actions">${button(view.busy?'Connexion…':'Tester la connexion','PilozElectronicInvoicing.testConnection()','btn-o',view.busy?'disabled':'')}${button('Envoyer une facture de test','PilozElectronicInvoicing.openConfirmation()','btn-o',!connected||view.busy?'disabled':'')}</div>`}
  </section>`;
 }
 function auditCard(){
  if(!view.events.length)return '';
  return `<section class="phase1-card"><div class="erp-card-heading"><div><h2>Journal d’activation</h2><p>Consentements, vérifications et inscription à l’annuaire, sans aucune donnée secrète.</p></div></div><div class="modern-list">${view.events.map(event=>`<div class="modern-list-row"><div><strong>${esc({authorization_started:'Autorisation démarrée',authorization_granted:'Autorisation accordée',authorization_failed:'Autorisation refusée',verification_refreshed:'Vérification actualisée',directory_requested:'Inscription à l’annuaire demandée',directory_activated:'Annuaire activé',directory_failed:'Inscription à l’annuaire refusée',authorization_revoked:'Autorisation révoquée',token_refreshed:'Autorisation renouvelée'}[event.event_type]||event.event_type)}</strong><small>${date(event.occurred_at)}</small></div>${badge(event.event_type.includes('failed')?'À corriger':'Journalisé',event.event_type.includes('failed')?'danger':'muted')}</div>`).join('')}</div></section>`;
 }
 function draw(){
  if(path()!=='settings/einvoicing')return;
  const main=document.getElementById('main');if(!main)return;
  main.innerHTML=header()+`${view.error?`<div class="phase1-alert phase1-alert-danger">${esc(view.error)}</div>`:''}${view.success?`<div class="phase1-alert phase1-alert-success">${esc(view.success)}</div>`:''}${productionCard()}${sandboxCard()}${auditCard()}`;
 }
 function callbackNotice(){
  const query=new URLSearchParams(location.hash.split('?')[1]||''),result=query.get('superpdp'),code=query.get('code');
  if(!result)return;
  if('BroadcastChannel'in window){const channel=new BroadcastChannel('piloz-superpdp-oauth');channel.postMessage({type:'piloz:superpdp-oauth',status:result,code:code||''});channel.close();}
  if(result==='connected')view.success='L’entreprise a autorisé Piloz dans SUPER PDP. Son état de vérification a été chargé.';
  else view.error=`L’autorisation SUPER PDP n’a pas abouti${code?` (${code})`:''}.`;
  history.replaceState(null,'',location.pathname+location.search+'#settings/einvoicing');
  if(window.name==='piloz-superpdp-authorization')setTimeout(()=>window.close(),80);
 }
 async function companyId(){return state().companyId||await api().companyContext();}
 async function productionStatus(){
  const id=await companyId(),status=await api().invoke('superpdp-oauth',{action:'status',companyId:id});
  view.production=status||null;global.PilozSuperPdpStatus=view.production;return view.production;
 }
 async function ensureDirectory(status){
  const current=status||await productionStatus();
  if(!current?.production_enabled||['active','pending'].includes(String(current.directory_status||'')))return current;
  await api().invoke('superpdp-oauth',{action:'activate_directory',companyId:await companyId()});
  return productionStatus();
 }
 function oauthPopup(){
  const width=620,height=760,left=Math.max(0,Math.round((screen.width-width)/2)),top=Math.max(0,Math.round((screen.height-height)/2));
  const popup=window.open('about:blank','piloz-superpdp-authorization',`popup=yes,width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes`);
  if(!popup)throw new Error('Autorisez les fenêtres contextuelles pour terminer l’activation sécurisée.');
  popup.document.title='Activation de la facturation électronique';
  popup.document.body.innerHTML='<main style="font:16px system-ui;padding:32px;text-align:center;color:#102a43"><strong>Ouverture de la vérification sécurisée…</strong><p>Cette fenêtre se fermera automatiquement.</p></main>';
  return popup;
 }
 function waitForOauth(popup){
  const expectedOrigin=(()=>{try{return new URL(global.PilozRuntime?.config?.url||'https://hpxcbemezvynofxiffzs.supabase.co').origin;}catch{return'https://hpxcbemezvynofxiffzs.supabase.co';}})();
  return new Promise((resolve,reject)=>{
   let finished=false,closedAt=0;
   const channel='BroadcastChannel'in window?new BroadcastChannel('piloz-superpdp-oauth'):null;
   const finish=(callback,value)=>{if(finished)return;finished=true;clearInterval(closedTimer);clearTimeout(timeout);window.removeEventListener('message',onMessage);channel?.close();callback(value);};
   const accept=data=>{if(data?.type!=='piloz:superpdp-oauth')return;if(data.status==='connected')finish(resolve,data);else finish(reject,new Error(`L’autorisation SUPER PDP n’a pas abouti${data.code?` (${data.code})`:''}.`));};
   const onMessage=event=>{
    if(event.source!==popup||event.origin!==expectedOrigin||event.data?.type!=='piloz:superpdp-oauth')return;
    accept(event.data);
   };
   if(channel)channel.onmessage=event=>accept(event.data);
   const closedTimer=setInterval(()=>{if(!popup.closed)return;closedAt=closedAt||Date.now();if(Date.now()-closedAt>1200)finish(reject,new Error('La vérification a été fermée avant sa validation.'));},300);
   const timeout=setTimeout(()=>{try{popup.close();}catch{}finish(reject,new Error('La vérification a expiré. Recommencez l’activation.'));},10*60*1000);
   window.addEventListener('message',onMessage);
  });
 }
 async function load(){
  const s=state();view.error='';
  try{
   const [connectors,production,events]=await Promise.all([
    api().query('platform_connectors',`select=id,status,environment,provider_name,non_secret_configuration,updated_at&company_id=eq.${encodeURIComponent(s.companyId)}&connector_code=eq.SUPERPDP&environment=eq.sandbox&order=updated_at.desc&limit=1`),
    api().invoke('superpdp-oauth',{action:'status',companyId:s.companyId}).catch(error=>{if(['PGRST202','status_unavailable'].includes(error?.code))return null;throw error;}),
    api().query('superpdp_consent_events',`select=id,event_type,occurred_at,evidence&company_id=eq.${encodeURIComponent(s.companyId)}&order=occurred_at.desc&limit=12`).catch(()=>[]),
   ]);
   view.connector=connectors[0]||null;view.production=production||null;view.events=events||[];global.PilozSuperPdpStatus=view.production;
   view.transmissions=view.connector?await api().query('platform_transmissions',`select=id,idempotency_key,external_transmission_id,status,created_at,completed_at,metadata&company_id=eq.${encodeURIComponent(s.companyId)}&connector_id=eq.${encodeURIComponent(view.connector.id)}&order=created_at.desc&limit=5`):[];
  }catch(error){view.error=error?.message||'Impossible de charger le connecteur.';}
  callbackNotice();draw();
 }
 async function run(action,success){
  if(view.busy)return;view.busy=true;view.error='';view.success='';draw();
  try{await api().invoke('superpdp-oauth',{action,companyId:state().companyId});await load();view.success=success;notify(success,'success');}
  catch(error){view.error=error?.message||'L’opération SUPER PDP a échoué.';}
  finally{view.busy=false;draw();}
 }
 async function startProduction(options={}){
  if(view.busy)return view.production;view.busy=true;view.error='';view.success='';draw();
  let popup;
  try{
   popup=oauthPopup();
   const result=await api().invoke('superpdp-oauth',{action:'start',companyId:await companyId()});
   if(!result?.url)throw new Error('SUPER PDP n’a pas fourni de page d’autorisation.');
   popup.location.replace(result.url);
   await waitForOauth(popup);
   let status=await productionStatus();
   status=await ensureDirectory(status);
   await load();
   view.success=status?.production_enabled?'Facturation électronique activée. Les échanges sont désormais gérés dans Piloz.':'Autorisation enregistrée. La vérification de l’entreprise reste en cours.';
   if(!options.silent)notify(view.success,'success');
   return status;
  }catch(error){
   try{if(popup&&!popup.closed)popup.close();}catch{}
   view.error=error?.message||'Impossible d’ouvrir SUPER PDP.';
   if(options.throwOnError)throw error;
   return null;
  }finally{view.busy=false;draw();}
 }
 const refreshProduction=()=>run('refresh','État SUPER PDP actualisé.');
 const activateDirectory=()=>run('activate_directory','Demande d’inscription dans l’annuaire enregistrée.');
 function askDisconnect(){view.disconnectConfirm=true;draw();}
 function cancelDisconnect(){view.disconnectConfirm=false;draw();}
 async function disconnect(){await run('disconnect','L’entreprise a été déconnectée de SUPER PDP.');view.disconnectConfirm=false;draw();}
 async function testConnection(){if(view.busy)return;view.busy=true;view.error='';draw();try{await api().invoke('platform-connector',{action:'superpdp_test',companyId:state().companyId});await load();view.success='Connexion du bac à sable validée.';notify(view.success,'success');}catch(error){view.error=error?.message||'La connexion au bac à sable a échoué.';}finally{view.busy=false;draw();}}
 function openConfirmation(){if(!view.connector||view.busy)return;view.confirmOpen=true;view.error='';draw();}
 function closeConfirmation(){view.confirmOpen=false;draw();}
 async function sendTestInvoice(){if(view.busy||!view.connector)return;view.busy=true;view.error='';draw();try{await api().invoke('platform-connector',{action:'superpdp_send_test_invoice',companyId:state().companyId,confirmation:'SEND_SUPERPDP_SANDBOX_TEST'});view.confirmOpen=false;await load();view.success='Facture Factur-X de test transmise au bac à sable.';notify(view.success,'success');}catch(error){view.error=error?.message||'L’envoi de test a échoué.';}finally{view.busy=false;draw();}}
 function renderRoute(route,s){if(route==='settings'&&path()==='settings/einvoicing'){const main=document.getElementById('main');if(main)main.innerHTML=header()+'<section class="phase1-card"><p>Chargement du connecteur…</p></section>';load();return true;}return baseRender.call(modern,route,s);}
 modern.renderRoute=renderRoute;
 global.PilozElectronicInvoicing={startProduction,productionStatus,ensureDirectory,refreshProduction,activateDirectory,askDisconnect,cancelDisconnect,disconnect,testConnection,openConfirmation,closeConfirmation,sendTestInvoice,reload:load};
})(window);
