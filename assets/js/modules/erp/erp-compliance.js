(function(global){
 'use strict';
 const modern=global.PilozModern;
 if(!modern)return;
 const baseRender=modern.renderRoute;
 const cache=new Map();
 const inflight=new Set();
 const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
 const path=()=>location.hash.slice(1).split('?')[0]||'dashboard';
 const datetime=value=>value?new Intl.DateTimeFormat('fr-FR',{dateStyle:'medium',timeStyle:'short'}).format(new Date(value)):'Jamais';
 const header=(title,description,actions='')=>`<header class="modern-page-header"><div><h1>${esc(title)}</h1><p>${esc(description)}</p></div><div class="actions">${actions}</div></header><div id="compliance-live" class="sr-only" aria-live="polite"></div>`;
 const button=(label,handler,kind='btn-o',attrs='')=>`<button type="button" class="btn ${kind}" onclick="${handler}" ${attrs}>${esc(label)}</button>`;
 const status=(label,tone='info')=>`<span class="modern-status ${tone}">${esc(label)}</span>`;
 const state=()=>global.PilozApp?.getState?.();
 const member=s=>(s?.data?.members||[]).find(row=>row.user_id===global.PilozRuntime?.session?.user_id);
 const isAdmin=s=>['owner','admin'].includes(member(s)?.role);
 const normalize=value=>value&&typeof value==='object'&&!Array.isArray(value)?value:{};
 function notify(message,kind='info'){
  global.toast?.(message);
  const node=document.getElementById('compliance-live');
  if(node){node.textContent=message;node.dataset.kind=kind;}
 }
 function safeError(error){
  console.error('[PILOZ Conformité] Opération impossible',{status:error?.status||0,code:error?.code||'',message:error?.message||String(error)});
  return error?.message||'Opération impossible.';
 }
 function honestMode(config){
  if(config.mode==='production'&&config.activation_status==='production_active')return status('Opérationnel','success');
  if(config.mode==='test'&&config.activation_status==='test_active')return status('Mode test','warning');
  return status('Non configuré','info');
 }
 function configurationGrid(summary){
  const config=normalize(summary.configuration),check=normalize(summary.last_integrity_check),activation=normalize(summary.activation);
  const chainCount=Number(summary.event_head?.last_sequence_number||0),anomalyCount=(summary.unresolved_anomalies||[]).length;
  return `<div class="modern-kpis">
    <article class="modern-kpi"><span>Moteur fiscal</span><strong>${honestMode(config)}</strong><small>${esc(config.activation_status||'not_ready')}</small></article>
    <article class="modern-kpi"><span>Journal fiscal</span><strong>${chainCount.toLocaleString('fr-FR')}</strong><small>événements chaînés</small></article>
    <article class="modern-kpi"><span>Dernier contrôle</span><strong>${check.status==='valid'?status('Opérationnel','success'):check.status==='anomaly'?status('Erreur','danger'):status('À vérifier','warning')}</strong><small>${datetime(check.checked_at)}</small></article>
    <article class="modern-kpi"><span>Anomalies ouvertes</span><strong>${anomalyCount}</strong><small>${anomalyCount?'action requise':'aucune enregistrée'}</small></article>
    <article class="modern-kpi"><span>E-invoicing bloqué</span><strong>${Number(summary.blocked_electronic_documents||0)}</strong><small>${Number(summary.verified_format_profiles||0)} profil officiel vérifié</small></article>
    <article class="modern-kpi"><span>E-reporting en attente</span><strong>${Number(summary.pending_e_reporting_records||0)}</strong><small>${Number(summary.production_connectors||0)} connecteur production actif</small></article>
  </div>`;
 }
 function blockersCard(summary){
  const activation=normalize(summary.activation),blockers=Array.isArray(activation.blockers)?activation.blockers:[];
  return `<section class="phase1-card" style="grid-column:span 2"><h2>Activation contrôlée</h2>
    <p class="modern-card-desc">Le mode production n’est jamais activé automatiquement. Cette vérification technique ne vaut ni certification, ni homologation, ni avis juridique.</p>
    <div>${activation.ready?status('Prérequis techniques satisfaits','success'):status('Validation externe requise','warning')}</div>
    ${blockers.length?`<ul style="margin:0;padding-left:20px;display:grid;gap:7px">${blockers.map(item=>`<li>${esc(item)}</li>`).join('')}</ul>`:'<p>Aucun blocage technique détecté par cette version. Une revue humaine reste obligatoire.</p>'}
    ${activation.ready&&member(state())?.role==='owner'?button('Activer le mode production','PilozCompliance.activateProduction()','btn-p'):''}
  </section>`;
 }
 function historyCard(title,row,emptyText){
  const value=normalize(row);
  return `<section class="phase1-card"><h2>${esc(title)}</h2>${Object.keys(value).length?
    `<p><b>${esc(value.closure_number||value.archive_number||value.status||'Enregistré')}</b></p><p class="modern-card-desc">${datetime(value.created_at||value.checked_at)}</p>`:
    `<p class="modern-card-desc">${esc(emptyText)}</p>`}</section>`;
 }
 function maintenanceCard(entry){
  const preview=normalize(entry.maintenance),policy=normalize(entry.automationPolicy),due=Number(preview.due_count||0),enabled=!!(policy.daily_closure_enabled||policy.monthly_closure_enabled||policy.annual_closure_enabled);
  return `<section class="phase1-card"><h2>Clôtures automatiques</h2><p>${enabled?status('Planification activée','success'):status('Désactivée par défaut','warning')}</p><strong>${due} période(s) à clôturer</strong><p class="modern-card-desc">Les archives automatiques restent bloquées jusqu’à validation du KMS et du stockage.</p><div class="actions">${!enabled&&member(state())?.role==='owner'?button('Activer les clôtures','PilozCompliance.enableMaintenance()','btn-o'):''}${enabled&&due?button('Générer maintenant','PilozCompliance.runMaintenance()','btn-p'):''}</div></section>`;
 }
 function privacyCard(entry){
  const rows=Array.isArray(entry.requests)?entry.requests:[],open=rows.filter(row=>!['fulfilled','refused','cancelled'].includes(row.status));
  return `<section class="phase1-card" style="grid-column:span 2"><h2>Droits des personnes</h2><p><strong>${open.length} demande(s) ouverte(s)</strong></p><p class="modern-card-desc">L’identité doit être contrôlée avant toute remise de données. Les décisions d’effacement, d’anonymisation ou de conservation restent motivées et traçables.</p>${button('Nouvelle demande','PilozCompliance.createPrivacyRequest()','btn-o')}${rows.length?`<div class="phase1-table-wrap"><table class="phase1-table"><thead><tr><th>Reçue</th><th>Type</th><th>Sujet</th><th>Échéance</th><th>État</th><th>Actions</th></tr></thead><tbody>${rows.slice(0,10).map(row=>`<tr><td>${datetime(row.received_at)}</td><td>${esc(row.request_type)}</td><td>${esc(row.subject_kind)}</td><td>${datetime(row.due_at)}</td><td>${status(row.status,['fulfilled'].includes(row.status)?'success':['refused','cancelled'].includes(row.status)?'danger':'warning')}</td><td>${row.request_type==='access'||row.request_type==='portability'?button('Exporter',`PilozCompliance.exportPrivacyRequest('${row.id}')`,'btn-o'):''}${row.status==='received'||row.status==='identity_check'?button('Démarrer',`PilozCompliance.startPrivacyRequest('${row.id}')`,'btn-o'):''}${['in_progress','partially_fulfilled'].includes(row.status)?button('Clôturer',`PilozCompliance.completePrivacyRequest('${row.id}')`,'btn-p'):''}</td></tr>`).join('')}</tbody></table></div>`:'<p class="modern-card-desc">Aucune demande enregistrée.</p>'}</section>`;
 }
 function anomalyCard(summary){
  const rows=Array.isArray(summary.unresolved_anomalies)?summary.unresolved_anomalies:[];
  return `<section class="phase1-card" style="grid-column:span 2"><h2>Anomalies critiques et contrôles</h2>
    ${rows.length?`<div class="phase1-table-wrap"><table class="phase1-table"><thead><tr><th>Date</th><th>Sévérité</th><th>Type</th><th>Source</th></tr></thead><tbody>${rows.map(row=>`<tr><td>${datetime(row.detected_at)}</td><td>${status(row.severity,row.severity==='critical'?'danger':'warning')}</td><td>${esc(row.anomaly_type)}</td><td>${esc(row.source)}</td></tr>`).join('')}</tbody></table></div>`:
    '<p class="modern-card-desc">Aucune anomalie non résolue enregistrée. Lancez un contrôle pour produire une preuve datée.</p>'}
  </section>`;
 }
 function renderLoading(){
  document.getElementById('main').innerHTML=header('Conformité et fiscalité','Contrôles techniques, preuves et prérequis d’activation.')+
    '<section class="phase1-card"><h2>Chargement des contrôles…</h2><p class="modern-card-desc">Lecture sécurisée des registres de votre entreprise.</p></section>';
 }
 function renderFailure(message){
  document.getElementById('main').innerHTML=header('Conformité et fiscalité','Contrôles techniques, preuves et prérequis d’activation.',button('Réessayer','PilozCompliance.refresh()'))+
    `<section class="phase1-card"><h2>Configuration non disponible</h2><p>${esc(message)}</p><p class="modern-card-desc">La migration Supabase 202607220045 doit être déployée avant d’utiliser cet écran. Aucun statut positif n’est déduit de cette absence.</p></section>`;
 }
 function renderCompliance(s){
  if(!isAdmin(s)){
   document.getElementById('main').innerHTML=header('Conformité et fiscalité','Accès réservé aux propriétaires et administrateurs.')+
    '<section class="phase1-card"><h2>Accès non autorisé</h2><p class="modern-card-desc">Votre rôle ne permet pas de consulter les preuves et réglages fiscaux.</p></section>';
   return;
  }
  const entry=cache.get(s.companyId);
  if(!entry){renderLoading();load(s.companyId);return;}
  if(entry.error){renderFailure(entry.error);return;}
  const summary=normalize(entry.summary),actions=button('Lancer un contrôle d’intégrité','PilozCompliance.runIntegrity()','btn-p')+button('Actualiser','PilozCompliance.refresh()','btn-o');
  document.getElementById('main').innerHTML=header('Conformité et fiscalité','État réel du moteur fiscal, des archives et de la facturation électronique.',actions)+
    `<section class="phase1-card" style="margin-bottom:12px;border-left:4px solid #d89a24!important"><h2>Démarche de conformité en cours</h2><p>Aucune certification NF 525 ou NF 203, homologation, conformité AFNOR ou qualité de plateforme agréée n’est revendiquée.</p></section>`+
    configurationGrid(summary)+`<div class="modern-settings-grid" style="margin-top:12px">${blockersCard(summary)}
      ${historyCard('Dernière clôture',summary.last_closure,'Aucune clôture enregistrée.')}
      ${historyCard('Dernière archive',summary.last_archive,'Aucune archive enregistrée.')}
      ${maintenanceCard(entry)}
      ${anomalyCard(summary)}
      ${privacyCard(entry)}
      <section class="phase1-card"><h2>Preuves et procédures</h2><p class="modern-card-desc">Les preuves manuelles restent « déclarées » tant qu’elles ne sont pas validées hors navigateur.</p>${button('À propos et conformité',"PilozApp.go('settings/about-compliance')",'btn-o')}</section>
    </div>`;
 }
 function certificationBlock(summary){
  const rows=Array.isArray(summary?.certifications)?summary.certifications:[];
  if(!rows.length)return '<p class="modern-card-desc">Aucune certification enregistrée. Piloz n’est pas présenté comme certifié.</p>';
  return `<div class="phase1-table-wrap"><table class="phase1-table"><thead><tr><th>Type</th><th>Organisme</th><th>Numéro</th><th>État</th></tr></thead><tbody>${rows.map(row=>`<tr><td>${esc(row.certification_type)}</td><td>${esc(row.certification_body)}</td><td>${esc(row.certificate_number)}</td><td>${status(row.status,row.status==='verified'?'success':'warning')}</td></tr>`).join('')}</tbody></table></div>`;
 }
 function renderAbout(s){
  const summary=cache.get(s.companyId)?.summary||{};
  document.getElementById('main').innerHTML=header('À propos et conformité','Version, périmètre de preuve et validations externes restantes.')+
   `<div class="modern-settings-grid">
    <section class="phase1-card"><h2>Version de Piloz</h2><dl class="company-summary-list"><div><dt>Application</dt><dd>0.9.0-compliance.5</dd></div><div><dt>Schéma attendu</dt><dd>202607230049</dd></div><div><dt>Moteur de calcul</dt><dd>financial-v1</dd></div><div><dt>Générateur PDF</dt><dd>pdf-v2</dd></div><div><dt>Déploiement</dt><dd>23 juillet 2026</dd></div></dl></section>
    <section class="phase1-card"><h2>Formats électroniques</h2><p>${Number(summary.verified_format_profiles||0)} profil officiel vérifié.</p><p class="modern-card-desc">UBL, CII et Factur-X restent bloqués tant que les artefacts officiels et validateurs ne sont pas installés.</p></section>
    <section class="phase1-card"><h2>Plateforme agréée</h2><p>${Number(summary.production_connectors||0)} connecteur de production actif.</p><p class="modern-card-desc">Connexion prévue; aucune qualité de plateforme agréée n’est revendiquée par Piloz.</p></section>
    <section class="phase1-card" style="grid-column:1/-1"><h2>Certifications obtenues</h2>${certificationBlock(summary)}</section>
    <section class="phase1-card" style="grid-column:1/-1"><h2>Limites et validations requises</h2><ul style="margin:0;padding-left:20px;display:grid;gap:7px"><li>Référentiels officiels complets NF 525, NF 203 et XP à confronter à la matrice.</li><li>Revue juridique des règles de facturation, TVA, conservation et RGPD.</li><li>Audit technique, KMS, signature, restauration réelle et test d’intrusion.</li><li>Profils électroniques officiels et plateforme agréée à sélectionner puis homologuer.</li></ul></section>
   </div>`;
  if(!cache.has(s.companyId))load(s.companyId,false);
 }
 async function load(companyId,rerender=true){
  if(inflight.has(companyId))return;
  inflight.add(companyId);
  try{
   const [summary,maintenance,requests,policies]=await Promise.all([
    global.PilozERP.rpc('get_company_compliance_summary',{target_company_id:companyId}),
    global.PilozERP.rpc('preview_fiscal_maintenance',{target_company_id:companyId,target_at:new Date().toISOString()}).catch(()=>({})),
    global.PilozERP.query('data_subject_requests',`select=id,request_type,subject_kind,received_at,due_at,status,closed_at&company_id=eq.${encodeURIComponent(companyId)}&order=received_at.desc&limit=20`).catch(()=>[]),
    global.PilozERP.query('fiscal_automation_policies',`select=*&company_id=eq.${encodeURIComponent(companyId)}&limit=1`).catch(()=>[])
   ]);
   cache.set(companyId,{summary:normalize(summary),maintenance:normalize(maintenance),requests:Array.isArray(requests)?requests:[],automationPolicy:normalize(policies?.[0])});
  }catch(error){cache.set(companyId,{error:safeError(error)});}
  finally{
   inflight.delete(companyId);
   if(rerender&&path()==='settings/compliance')renderCompliance(state());
   else if(path()==='settings/about-compliance')renderAbout(state());
  }
 }
 async function refresh(){const s=state();if(!s)return;cache.delete(s.companyId);renderCompliance(s);}
 async function runIntegrity(){
  const s=state();if(!s||!isAdmin(s))return;
  try{
   await global.PilozERP.rpc('run_company_integrity_check',{target_company_id:s.companyId});
   notify('Contrôle d’intégrité terminé et preuve enregistrée.','success');
   cache.delete(s.companyId);await load(s.companyId);
  }catch(error){notify(safeError(error),'error');}
 }
 async function enableMaintenance(){
  const s=state();if(!s||member(s)?.role!=='owner')return;
  if(!global.confirm('Activer la détection et la génération des clôtures journalières, mensuelles et annuelles ? Les archives resteront désactivées.'))return;
  try{await global.PilozERP.rpc('configure_fiscal_automation',{target_company_id:s.companyId,target_timezone:'Europe/Paris',enable_daily:true,enable_monthly:true,enable_annual:true,enable_archives:false});notify('Planification des clôtures activée. Configurez ensuite le job Supabase décrit dans la procédure.','success');cache.delete(s.companyId);await load(s.companyId);}catch(error){notify(safeError(error),'error');}
 }
 async function runMaintenance(){
  const s=state();if(!s||!isAdmin(s))return;
  if(!global.confirm('Générer maintenant toutes les clôtures dues détectées ?'))return;
  try{const result=await global.PilozERP.rpc('run_company_fiscal_maintenance',{target_company_id:s.companyId,target_at:new Date().toISOString(),target_dry_run:false,target_source:'manual'});notify(`${Number(result?.created_count||0)} clôture(s) créée(s), ${Number(result?.failed_count||0)} échec(s).`,result?.failed_count?'error':'success');cache.delete(s.companyId);await load(s.companyId);}catch(error){notify(safeError(error),'error');}
 }
 async function createPrivacyRequest(){
  const s=state();if(!s||!isAdmin(s))return;
  const requestType=String(global.prompt('Type : access, rectification, erasure, restriction, portability, objection ou other','access')||'').trim();
  if(!['access','rectification','erasure','restriction','portability','objection','other'].includes(requestType))return notify('Type de demande invalide.','error');
  const subjectKind=String(global.prompt('Sujet : user, client, prospect, supplier, contact ou other','client')||'').trim();
  if(!['user','client','prospect','supplier','contact','other'].includes(subjectKind))return notify('Type de sujet invalide.','error');
  const reference=String(global.prompt('Identifiant UUID ou e-mail exact de la personne concernée','')||'').trim();if(!reference)return;
  try{await global.PilozERP.rpc('create_data_subject_request',{target_company_id:s.companyId,target_request_type:requestType,target_subject_kind:subjectKind,target_subject_reference:reference,target_received_at:new Date().toISOString(),target_metadata:{source:'compliance_ui'}});notify('Demande enregistrée avec une échéance calculée.','success');cache.delete(s.companyId);await load(s.companyId);}catch(error){notify(safeError(error),'error');}
 }
 async function startPrivacyRequest(id){
  if(!global.confirm('Confirmez-vous avoir vérifié l’identité du demandeur ?'))return;
  try{await global.PilozERP.rpc('transition_data_subject_request',{target_request_id:id,target_status:'in_progress',target_reason:'Identité vérifiée depuis l’interface de conformité',target_legal_basis:null,target_response_summary:null,target_identity_verified_at:new Date().toISOString()});notify('Demande mise en traitement.','success');const s=state();cache.delete(s.companyId);await load(s.companyId);}catch(error){notify(safeError(error),'error');}
 }
 async function exportPrivacyRequest(id){
  try{const result=await global.PilozERP.rpc('generate_data_subject_export',{target_request_id:id}),blob=new Blob([JSON.stringify(result?.payload||{},null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download=`piloz-demande-${id}.json`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notify('Export généré localement et empreinte enregistrée.','success');const s=state();cache.delete(s.companyId);await load(s.companyId);}catch(error){notify(safeError(error),'error');}
 }
 async function completePrivacyRequest(id){
  const summary=String(global.prompt('Résumé de la réponse remise à la personne','')||'').trim();if(!summary)return;
  try{await global.PilozERP.rpc('transition_data_subject_request',{target_request_id:id,target_status:'fulfilled',target_reason:'Réponse remise',target_legal_basis:null,target_response_summary:summary,target_identity_verified_at:null});notify('Demande clôturée avec traçabilité.','success');const s=state();cache.delete(s.companyId);await load(s.companyId);}catch(error){notify(safeError(error),'error');}
 }
 async function activateProduction(){
  const s=state(),activation=cache.get(s?.companyId)?.summary?.activation;
  if(!s||member(s)?.role!=='owner'||!activation?.ready)return;
  if(!global.confirm('Activer le moteur fiscal de production pour les nouvelles opérations ? Cette action doit suivre une validation humaine formelle.'))return;
  try{
   await global.PilozERP.rpc('activate_fiscal_engine',{target_company_id:s.companyId,target_mode:'production'});
   notify('Moteur fiscal de production activé.','success');cache.delete(s.companyId);await load(s.companyId);
  }catch(error){notify(safeError(error),'error');}
 }
 function renderRoute(route,s){
  const current=path();
  if(route==='settings'&&current==='settings/compliance'){renderCompliance(s);return true;}
  if(route==='settings'&&current==='settings/about-compliance'){renderAbout(s);return true;}
  return baseRender(route,s);
 }
 modern.renderRoute=renderRoute;
 global.PilozCompliance={renderCompliance,renderAbout,refresh,runIntegrity,activateProduction,enableMaintenance,runMaintenance,createPrivacyRequest,startPrivacyRequest,exportPrivacyRequest,completePrivacyRequest};
})(window);
