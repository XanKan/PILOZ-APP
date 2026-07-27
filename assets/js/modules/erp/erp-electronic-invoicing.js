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
 let view={busy:false,connector:null,transmissions:[],confirmOpen:false,error:'',success:''};

 function notify(message,tone='info'){
  if(global.PilozOps?.notify)global.PilozOps.notify(message,tone);
  else if(global.toast)global.toast(message);
 }
 function header(){
  return `<header class="modern-page-header"><div><h1>Facturation électronique</h1><p>Connectez Piloz à SUPER PDP et validez les échanges dans son bac à sable.</p></div><div class="actions">${button('Retour aux paramètres',"PilozApp.go('settings/overview')")}</div></header>`;
 }
 function connectorCard(){
  const connector=view.connector,config=connector?.non_secret_configuration||{},connected=Boolean(connector);
  return `<section class="phase1-card"><div class="erp-card-heading"><div><h2>SUPER PDP</h2><p>Plateforme agréée · format préféré Factur-X</p></div>${badge(connected?'Bac à sable connecté':'À connecter',connected?'success':'warning')}</div>
   <div class="phase1-grid">
    <div class="phase1-field"><span>Environnement</span><strong>Bac à sable uniquement</strong></div>
    <div class="phase1-field"><span>Entreprise SUPER PDP</span><strong>${esc(config.external_company_name||'—')}</strong></div>
    <div class="phase1-field"><span>Identifiant externe</span><strong>${esc(config.external_company_number||'—')}</strong></div>
    <div class="phase1-field"><span>Dernière vérification</span><strong>${date(config.verified_at)}</strong></div>
   </div>
   <div class="actions">${button(view.busy?'Connexion en cours…':'Tester la connexion','PilozElectronicInvoicing.testConnection()','btn-p',view.busy?'disabled':'')}</div>
  </section>`;
 }
 function testCard(){
  const latest=view.transmissions[0];
  return `<section class="phase1-card"><div class="erp-card-heading"><div><h2>Test Factur-X</h2><p>SUPER PDP génère une facture synthétique puis Piloz la renvoie au bac à sable. Aucune facture client n’est utilisée.</p></div>${latest?badge('Dernier test réussi','success'):badge('Non testé','muted')}</div>
   ${latest?`<p class="phase1-note">Dernier envoi : ${date(latest.completed_at||latest.created_at)} · référence ${esc(latest.external_transmission_id||latest.idempotency_key||'—')}</p>`:''}
   ${view.confirmOpen?`<aside class="ops-info-callout"><strong>Confirmer l’envoi de test</strong><span>Cette action transmet uniquement une facture de démonstration au bac à sable SUPER PDP. Elle ne part jamais en production.</span><div class="actions">${button('Annuler','PilozElectronicInvoicing.closeConfirmation()')}${button(view.busy?'Envoi en cours…':'Envoyer la facture de test','PilozElectronicInvoicing.sendTestInvoice()','btn-p',view.busy?'disabled':'')}</div></aside>`:`<div class="actions">${button('Envoyer une facture de test','PilozElectronicInvoicing.openConfirmation()','btn-p',!view.connector||view.busy?'disabled':'')}</div>`}
  </section>`;
 }
 function productionCard(){
  return `<aside class="ops-info-callout"><strong>Production non activée</strong><span>Cette première connexion est volontairement limitée au bac à sable. Le raccordement des entreprises clientes en production utilisera ensuite une autorisation OAuth individuelle ; aucun secret SUPER PDP ne sera stocké dans leur navigateur.</span></aside>`;
 }
 function draw(){
  if(path()!=='settings/einvoicing')return;
  const main=document.getElementById('main');if(!main)return;
  main.innerHTML=header()+`${view.error?`<div class="phase1-alert phase1-alert-danger">${esc(view.error)}</div>`:''}${view.success?`<div class="phase1-alert phase1-alert-success">${esc(view.success)}</div>`:''}${connectorCard()}${testCard()}${productionCard()}`;
 }
 async function load(){
  const s=state();view.error='';view.success='';
  try{
   const connectors=await api().query('platform_connectors',`select=id,status,environment,provider_name,non_secret_configuration,updated_at&company_id=eq.${encodeURIComponent(s.companyId)}&connector_code=eq.SUPERPDP&environment=eq.sandbox&order=updated_at.desc&limit=1`);
   view.connector=connectors[0]||null;
   view.transmissions=view.connector?await api().query('platform_transmissions',`select=id,idempotency_key,external_transmission_id,status,created_at,completed_at,metadata&company_id=eq.${encodeURIComponent(s.companyId)}&connector_id=eq.${encodeURIComponent(view.connector.id)}&order=created_at.desc&limit=5`):[];
  }catch(error){view.error=error?.message||'Impossible de charger le connecteur.';}
  draw();
 }
 async function testConnection(){
  if(view.busy)return;view.busy=true;view.error='';view.success='';draw();
  try{await api().invoke('platform-connector',{action:'superpdp_test',companyId:state().companyId});view.success='Connexion SUPER PDP validée dans le bac à sable.';await load();view.success='Connexion SUPER PDP validée dans le bac à sable.';notify(view.success,'success');}
  catch(error){view.error=error?.message||'La connexion à SUPER PDP a échoué.';}
  finally{view.busy=false;draw();}
 }
 function openConfirmation(){if(!view.connector||view.busy)return;view.confirmOpen=true;view.error='';draw();}
 function closeConfirmation(){view.confirmOpen=false;draw();}
 async function sendTestInvoice(){
  if(view.busy||!view.connector)return;view.busy=true;view.error='';view.success='';draw();
  try{await api().invoke('platform-connector',{action:'superpdp_send_test_invoice',companyId:state().companyId,confirmation:'SEND_SUPERPDP_SANDBOX_TEST'});view.confirmOpen=false;await load();view.success='La facture Factur-X de test a été transmise au bac à sable SUPER PDP.';notify(view.success,'success');}
  catch(error){view.error=error?.message||'L’envoi de la facture de test a échoué.';}
  finally{view.busy=false;draw();}
 }
 function renderRoute(route,s){if(route==='settings'&&path()==='settings/einvoicing'){const main=document.getElementById('main');if(main)main.innerHTML=header()+'<section class="phase1-card"><p>Chargement du connecteur…</p></section>';load();return true;}return baseRender.call(modern,route,s);}
 modern.renderRoute=renderRoute;
 global.PilozElectronicInvoicing={testConnection,openConfirmation,closeConfirmation,sendTestInvoice,reload:load};
})(window);
