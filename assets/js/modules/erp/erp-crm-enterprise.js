(function crmEnterpriseModule(global){
  'use strict';

  const crm=global.PilozCRM;
  if(!crm)return;

  const api=()=>global.PilozERP;
  const app=()=>global.PilozApp;
  const ui=crm.ui;
  const nativeSetActivityView=crm.setActivityView.bind(crm);
  const enterprise={pipelineId:'',stageDragId:'',activityDragId:'',csv:null,inboxRows:[],inboxConnections:[],savedViews:[],searchTimer:null,enhanceTimer:null};
  const esc=value=>global.esc?global.esc(value):String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const number=value=>new Intl.NumberFormat('fr-FR').format(Number(value)||0);
  const money=(value,currency='EUR')=>new Intl.NumberFormat('fr-FR',{style:'currency',currency}).format(Number(value)||0);
  const state=()=>app().getState();
  const notify=(text,type='success')=>global.toast?.(text,type);
  const formObject=form=>{const value=Object.fromEntries(new FormData(form));for(const key of Object.keys(value))if(value[key]==='')value[key]=null;return value;};
  const currentPath=()=>String(location.hash||'').replace(/^#/,'').split('?')[0];
  const nameOf=row=>String(row?.trade_name||row?.legal_name||[row?.first_name,row?.last_name].filter(Boolean).join(' ')||'Non renseigné');

  function button(label,handler,kind='',attributes=''){
    return `<button class="crm-button ${kind}" onclick="${handler}" ${attributes}>${esc(label)}</button>`;
  }

  function drawer(title,subtitle,body,footer=''){
    crm.closeDrawer();
    const layer=document.createElement('div');
    layer.id='crm-drawer-layer';
    layer.className='crm-drawer-layer';
    layer.addEventListener('click',event=>{if(event.target===layer)crm.closeDrawer();});
    layer.innerHTML=`<aside class="crm-drawer crm-enterprise-drawer" role="dialog" aria-modal="true">
      <header><div><h2>${esc(title)}</h2><p>${esc(subtitle||'')}</p></div><button onclick="PilozCRM.closeDrawer()" aria-label="Fermer">×</button></header>
      <div class="crm-drawer-body">${body}</div><footer>${footer}</footer>
    </aside>`;
    document.body.appendChild(layer);
    setTimeout(()=>layer.querySelector('input,select,textarea')?.focus(),20);
  }

  function message(text='',error=true){
    const node=document.getElementById('crm-form-message');
    if(!node)return;
    node.hidden=!text;
    node.textContent=text;
    node.dataset.kind=error?'error':'success';
  }

  async function getConfiguration(force=false){
    if(force||!ui.configuration)ui.configuration=await api().rpc('get_crm_configuration');
    if(!ui.pipeline)ui.pipeline={};
    ui.pipeline.pipelines=ui.configuration.pipelines||[];
    ui.pipeline.stages=ui.configuration.stages||[];
    ui.pipeline.permissions=ui.configuration.permissions||{};
    return ui.configuration;
  }

  function memberOptions(selected=''){
    const members=state().data.members||[];
    const preferences=state().data.preferences||[];
    return members.map(member=>{
      const profile=preferences.find(row=>row.user_id===member.user_id)||{};
      const label=profile.display_name||profile.first_name||member.display_name||'Utilisateur';
      return `<option value="${esc(member.user_id)}" ${member.user_id===selected?'selected':''}>${esc(label)}</option>`;
    }).join('');
  }

  async function refreshAfterConfiguration(){
    ui.configuration=null;
    await getConfiguration(true);
    crm.closeDrawer();
    await crm.reloadPipeline();
  }

  async function openPipelineSettings(pipelineId=''){
    try{
      const configuration=await getConfiguration(true);
      enterprise.pipelineId=pipelineId||enterprise.pipelineId||ui.pipelineId||configuration.pipelines?.[0]?.id||'';
      const selected=configuration.pipelines.find(row=>row.id===enterprise.pipelineId)||configuration.pipelines[0];
      enterprise.pipelineId=selected?.id||'';
      const stages=(configuration.stages||[]).filter(row=>row.pipeline_id===enterprise.pipelineId).sort((a,b)=>Number(a.position)-Number(b.position));
      const canManage=configuration.permissions?.manage;
      const pipelineRows=(configuration.pipelines||[]).map(row=>`<article class="crm-manager-row ${row.id===enterprise.pipelineId?'selected':''}">
        <button class="crm-manager-select" onclick="PilozCRM.selectManagedPipeline('${row.id}')"><i style="--crm-item-color:${esc(row.color||'#14b8a6')}"></i><span><b>${esc(row.name)}</b><small>${row.is_default?'Par défaut':esc(row.status)}</small></span></button>
        <div class="crm-manager-actions">
          <button title="Modifier" onclick="PilozCRM.openPipelineForm('${row.id}')">✎</button>
          <button title="Dupliquer" onclick="PilozCRM.duplicateManagedPipeline('${row.id}')">⧉</button>
          <button title="Archiver" onclick="PilozCRM.archiveManagedPipeline('${row.id}')" ${row.is_default?'disabled':''}>⌫</button>
        </div>
      </article>`).join('');
      const stageRows=stages.map(row=>`<article class="crm-stage-manager-row" draggable="${canManage?'true':'false'}" data-stage-id="${row.id}" ondragstart="PilozCRM.dragManagedStage(event,'${row.id}')" ondragover="event.preventDefault()" ondrop="PilozCRM.dropManagedStage(event,'${row.id}')">
        <span class="crm-drag-handle" aria-hidden="true">⋮⋮</span><i style="--crm-item-color:${esc(row.color||'#14b8a6')}"></i>
        <span><b>${esc(row.name)}</b><small>${number(row.probability)} % · ${esc(row.stage_type)}</small></span>
        <button title="Modifier l’étape" onclick="PilozCRM.openStageForm('${row.id}','${enterprise.pipelineId}')">✎</button>
      </article>`).join('');
      drawer('Pipelines commerciaux','Configurez plusieurs cycles de vente sans perdre leur historique.',`
        <div id="crm-form-message" class="crm-form-message" hidden></div>
        <section class="crm-manager-section"><header><div><h3>Pipelines</h3><p>Vente, renouvellement ou projet.</p></div>${button('Nouveau','PilozCRM.openPipelineForm()','',canManage?'':'disabled')}</header>${pipelineRows||'<p>Aucun pipeline.</p>'}</section>
        <section class="crm-manager-section"><header><div><h3>Étapes de ${esc(selected?.name||'pipeline')}</h3><p>Glissez les étapes pour les réordonner.</p></div>${button('Ajouter','PilozCRM.openStageForm(null,\''+enterprise.pipelineId+'\')','',canManage?'':'disabled')}</header><div id="crm-stage-manager-list">${stageRows||'<p>Aucune étape active.</p>'}</div></section>
      `,button('Fermer','PilozCRM.closeDrawer()'));
    }catch(error){notify(error.message||'Configuration CRM indisponible.','error');}
  }

  function selectManagedPipeline(id){enterprise.pipelineId=id;openPipelineSettings(id);}

  async function openPipelineForm(id=''){
    const configuration=await getConfiguration();
    const row=configuration.pipelines.find(item=>item.id===id)||{};
    drawer(id?'Modifier le pipeline':'Nouveau pipeline','Les modifications sont enregistrées dans Supabase.',`
      <div id="crm-form-message" class="crm-form-message" hidden></div>
      <form id="crm-managed-pipeline-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveManagedPipeline('${esc(id)}')">
        <label class="crm-field full"><span>Nom *</span><input name="name" required maxlength="120" value="${esc(row.name||'')}"></label>
        <label class="crm-field full"><span>Description</span><textarea name="description">${esc(row.description||'')}</textarea></label>
        <label class="crm-field"><span>Type</span><select name="pipeline_type">${[['sales','Vente'],['renewal','Renouvellement'],['project','Projet']].map(([value,label])=>`<option value="${value}" ${row.pipeline_type===value?'selected':''}>${label}</option>`).join('')}</select></label>
        <label class="crm-field"><span>Statut</span><select name="status">${[['active','Actif'],['inactive','Inactif'],['draft','Brouillon']].map(([value,label])=>`<option value="${value}" ${(row.status||'active')===value?'selected':''}>${label}</option>`).join('')}</select></label>
        <label class="crm-field"><span>Couleur</span><input name="color" type="color" value="${esc(row.color||'#14b8a6')}"></label>
        <label class="crm-field"><span>Devise</span><select name="currency">${['EUR','USD','GBP','CHF'].map(value=>`<option ${row.currency===value?'selected':''}>${value}</option>`).join('')}</select></label>
        <label class="crm-check full"><input name="is_default" type="checkbox" ${row.is_default?'checked':''}><span>Utiliser comme pipeline par défaut</span></label>
      </form>
    `,`${button('Retour','PilozCRM.openPipelineSettings(\''+(id||enterprise.pipelineId)+'\')')}${button('Enregistrer',`PilozCRM.saveManagedPipeline('${esc(id)}')`,'primary')}`);
  }

  async function saveManagedPipeline(id=''){
    const form=document.getElementById('crm-managed-pipeline-form');
    if(!form?.reportValidity())return;
    const raw=formObject(form);
    const patch={...raw,is_default:Boolean(form.elements.is_default.checked)};
    try{
      let row;
      if(id)row=await api().rpc('update_crm_pipeline',{target_pipeline_id:id,target_patch:patch});
      else{
        row=await api().rpc('create_crm_pipeline',{target_name:raw.name,target_description:raw.description,target_currency:raw.currency,target_pipeline_type:raw.pipeline_type});
        row=await api().rpc('update_crm_pipeline',{target_pipeline_id:row.id,target_patch:patch});
      }
      enterprise.pipelineId=row.id;
      await refreshAfterConfiguration();
      notify('Pipeline enregistré.');
    }catch(error){message(error.message||'Le pipeline n’a pas pu être enregistré.');}
  }

  async function duplicateManagedPipeline(id){
    try{
      const row=await api().rpc('duplicate_crm_pipeline',{target_pipeline_id:id,target_name:null});
      enterprise.pipelineId=row.id;
      await refreshAfterConfiguration();
      notify('Pipeline dupliqué.');
    }catch(error){message(error.message||'Duplication impossible.');}
  }

  async function archiveManagedPipeline(id){
    if(!global.confirm('Archiver ce pipeline ? Son historique restera conservé.'))return;
    try{
      await api().rpc('update_crm_pipeline',{target_pipeline_id:id,target_patch:{status:'archived'}});
      enterprise.pipelineId='';
      await refreshAfterConfiguration();
      notify('Pipeline archivé.');
    }catch(error){message(error.message||'Archivage impossible.');}
  }

  async function openStageForm(id='',pipelineId=''){
    const configuration=await getConfiguration();
    const row=configuration.stages.find(item=>item.id===id)||{};
    const targetPipelineId=pipelineId||row.pipeline_id||enterprise.pipelineId;
    drawer(id?'Modifier l’étape':'Nouvelle étape','Probabilité, délai recommandé et issue du cycle.',`
      <div id="crm-form-message" class="crm-form-message" hidden></div>
      <form id="crm-managed-stage-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveManagedStage('${esc(id)}','${esc(targetPipelineId)}')">
        <label class="crm-field full"><span>Nom *</span><input name="name" required maxlength="120" value="${esc(row.name||'')}"></label>
        <label class="crm-field full"><span>Description</span><textarea name="description">${esc(row.description||'')}</textarea></label>
        <label class="crm-field"><span>Type d’étape</span><select name="stage_type">${[['open','Ouverte'],['won','Gagnée'],['lost','Perdue'],['suspended','Suspendue']].map(([value,label])=>`<option value="${value}" ${(row.stage_type||'open')===value?'selected':''}>${label}</option>`).join('')}</select></label>
        <label class="crm-field"><span>Probabilité (%)</span><input name="probability" type="number" min="0" max="100" step="1" value="${Number(row.probability??10)}"></label>
        <label class="crm-field"><span>Délai recommandé (jours)</span><input name="recommended_delay_days" type="number" min="0" max="365" value="${Number(row.recommended_delay_days||0)}"></label>
        <label class="crm-field"><span>Couleur</span><input name="color" type="color" value="${esc(row.color||'#14b8a6')}"></label>
        <label class="crm-check full"><input name="active" type="checkbox" ${row.active!==false?'checked':''}><span>Étape active</span></label>
      </form>
    `,`${button('Retour',`PilozCRM.openPipelineSettings('${esc(targetPipelineId)}')`)}${button('Enregistrer',`PilozCRM.saveManagedStage('${esc(id)}','${esc(targetPipelineId)}')`,'primary')}`);
  }

  async function saveManagedStage(id,pipelineId){
    const form=document.getElementById('crm-managed-stage-form');
    if(!form?.reportValidity())return;
    const raw=formObject(form);
    const payload={...raw,id:id||null,active:Boolean(form.elements.active.checked)};
    try{
      await api().rpc('upsert_crm_pipeline_stage',{target_pipeline_id:pipelineId,target_stage:payload});
      enterprise.pipelineId=pipelineId;
      ui.configuration=null;
      await openPipelineSettings(pipelineId);
      crm.reloadPipeline();
      notify('Étape enregistrée.');
    }catch(error){message(error.message||'L’étape n’a pas pu être enregistrée.');}
  }

  function dragManagedStage(event,id){enterprise.stageDragId=id;event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',id);}

  async function dropManagedStage(event,beforeId){
    event.preventDefault();
    const sourceId=enterprise.stageDragId||event.dataTransfer.getData('text/plain');
    if(!sourceId||sourceId===beforeId)return;
    const list=document.getElementById('crm-stage-manager-list');
    const source=list?.querySelector(`[data-stage-id="${CSS.escape(sourceId)}"]`);
    const target=list?.querySelector(`[data-stage-id="${CSS.escape(beforeId)}"]`);
    if(!source||!target)return;
    list.insertBefore(source,target);
    const ids=Array.from(list.querySelectorAll('[data-stage-id]')).map(row=>row.dataset.stageId);
    try{
      await api().rpc('reorder_crm_pipeline_stages',{target_pipeline_id:enterprise.pipelineId,target_stage_ids:ids});
      ui.configuration=null;
      crm.reloadPipeline();
      notify('Ordre des étapes enregistré.');
    }catch(error){notify(error.message||'Réordonnancement impossible.','error');openPipelineSettings(enterprise.pipelineId);}
  }

  const originalOpportunityForm=crm.openOpportunityForm.bind(crm);
  async function openOpportunityForm(id=''){
    await getConfiguration();
    if(id&&ui.detail?.opportunity){
      ui.pipeline=ui.pipeline||{};
      ui.pipeline.opportunities=ui.pipeline.opportunities||[];
      const index=ui.pipeline.opportunities.findIndex(row=>row.id===id);
      if(index<0)ui.pipeline.opportunities.push(ui.detail.opportunity);
      else ui.pipeline.opportunities[index]={...ui.pipeline.opportunities[index],...ui.detail.opportunity};
      ui.pipeline.stages=ui.configuration.stages||[];
    }
    return originalOpportunityForm(id);
  }

  async function saveOpportunity(id=''){
    const form=document.getElementById('crm-opportunity-form');
    if(!form?.reportValidity()||ui.busy)return;
    const payload=formObject(form);
    payload.amount=Number(payload.amount)||0;
    payload.probability=Number(payload.probability)||0;
    ui.busy=true;
    try{
      if(id)await api().rpc('update_crm_opportunity',{target_opportunity_id:id,target_payload:payload});
      else await api().rpc('create_crm_opportunity',{target_payload:payload});
      crm.closeDrawer();
      if(id&&currentPath().endsWith(id))await crm.loadOpportunityDetail(id);else await crm.reloadPipeline();
      notify('Opportunité enregistrée.');
    }catch(error){message(error.message||'L’opportunité n’a pas pu être enregistrée.');}
    finally{ui.busy=false;}
  }

  async function reopenOpportunity(id){
    try{
      await api().rpc('close_crm_opportunity',{target_opportunity_id:id,target_outcome:'reopen'});
      await crm.loadOpportunityDetail(id);
      notify('Opportunité réouverte.');
    }catch(error){notify(error.message||'Réouverture impossible.','error');}
  }

  async function openProspectForm(id=''){
    const configuration=await getConfiguration();
    const row=(id&&ui.detail?.prospect?.id===id?ui.detail.prospect:null)||(ui.prospects?.rows||[]).find(item=>item.id===id)||{};
    const statusOptions=[['new','Nouveau'],['to_qualify','À qualifier'],['qualified','Qualifié'],['in_progress','En cours'],['to_follow_up','À relancer'],['not_interested','Non intéressé']];
    drawer(id?'Modifier le prospect':'Nouveau prospect','Les doublons e-mail, téléphone, SIREN et SIRET sont contrôlés.',`
      <div id="crm-form-message" class="crm-form-message" hidden></div>
      <form id="crm-prospect-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveProspect('${esc(id)}')">
        <label class="crm-field"><span>Type</span><select name="kind"><option value="company" ${row.kind!=='person'?'selected':''}>Entreprise</option><option value="person" ${row.kind==='person'?'selected':''}>Particulier</option></select></label>
        <label class="crm-field"><span>Statut</span><select name="crm_status">${statusOptions.map(([value,label])=>`<option value="${value}" ${(row.crm_status||'new')===value?'selected':''}>${label}</option>`).join('')}</select></label>
        <label class="crm-field full"><span>Raison sociale / nom *</span><input name="legal_name" required value="${esc(row.legal_name||'')}"></label>
        <label class="crm-field"><span>Nom commercial</span><input name="trade_name" value="${esc(row.trade_name||'')}"></label>
        <label class="crm-field"><span>Contact principal</span><input name="contact_name" value="${esc(row.contact_name||'')}"></label>
        <label class="crm-field"><span>Prénom</span><input name="first_name" value="${esc(row.first_name||'')}"></label>
        <label class="crm-field"><span>Nom</span><input name="last_name" value="${esc(row.last_name||'')}"></label>
        <label class="crm-field"><span>E-mail</span><input name="email" type="email" value="${esc(row.email||'')}"></label>
        <label class="crm-field"><span>Téléphone</span><input name="phone_e164" type="tel" value="${esc(row.phone_e164||'')}"></label>
        <label class="crm-field"><span>SIREN</span><input name="siren" value="${esc(row.siren||'')}"></label>
        <label class="crm-field"><span>SIRET</span><input name="siret" value="${esc(row.siret||'')}"></label>
        <label class="crm-field full"><span>Adresse</span><input name="address_line_1" value="${esc(row.address_line_1||'')}"></label>
        <label class="crm-field"><span>Code postal</span><input name="postal_code" value="${esc(row.postal_code||'')}"></label>
        <label class="crm-field"><span>Ville</span><input name="city" value="${esc(row.city||'')}"></label>
        <label class="crm-field"><span>Source</span><select name="source_id"><option value="">Non renseignée</option>${(configuration.sources||[]).map(source=>`<option value="${source.id}" ${source.id===row.crm_source_id?'selected':''}>${esc(source.name)}</option>`).join('')}</select></label>
        <label class="crm-field"><span>Responsable</span><select name="assigned_user_id"><option value="">Moi</option>${memberOptions(row.assigned_user_id)}</select></label>
      </form>
    `,`${button('Annuler','PilozCRM.closeDrawer()')}${button('Enregistrer',`PilozCRM.saveProspect('${esc(id)}')`,'primary')}`);
  }

  async function saveProspect(id=''){
    const form=document.getElementById('crm-prospect-form');
    if(!form?.reportValidity()||ui.busy)return;
    ui.busy=true;
    try{
      const payload=formObject(form);
      const result=id
        ?await api().rpc('update_crm_prospect',{target_prospect_id:id,target_payload:payload})
        :await api().rpc('create_crm_prospect',{target_payload:payload});
      crm.closeDrawer();
      if(id&&currentPath().endsWith(id))await crm.loadProspectDetail(id);else await crm.reloadProspects();
      notify(result?.duplicates?.length?'Prospect enregistré. Des doublons potentiels ont été détectés.':'Prospect enregistré.');
    }catch(error){message(error.message||'Le prospect n’a pas pu être enregistré.');}
    finally{ui.busy=false;}
  }

  async function openContactForm(contactId=''){
    const prospect=ui.detail?.prospect;
    if(!prospect)return;
    const row=(ui.detail.contacts||[]).find(item=>item.id===contactId)||{};
    drawer(contactId?'Modifier le contact':'Nouveau contact',nameOf(prospect),`
      <div id="crm-form-message" class="crm-form-message" hidden></div>
      <form id="crm-contact-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveProspectContact('${esc(contactId)}')">
        <label class="crm-field"><span>Prénom *</span><input name="first_name" required value="${esc(row.first_name||'')}"></label>
        <label class="crm-field"><span>Nom *</span><input name="last_name" required value="${esc(row.last_name||'')}"></label>
        <label class="crm-field"><span>Fonction</span><input name="job_title" value="${esc(row.job_title||'')}"></label>
        <label class="crm-field"><span>Service</span><input name="department" value="${esc(row.department||'')}"></label>
        <label class="crm-field"><span>E-mail</span><input name="email" type="email" value="${esc(row.email||'')}"></label>
        <label class="crm-field"><span>Mobile</span><input name="mobile_e164" type="tel" value="${esc(row.mobile_e164||'')}"></label>
        <label class="crm-check full"><input name="is_primary" type="checkbox" ${row.is_primary?'checked':''}><span>Contact principal</span></label>
        <label class="crm-check"><input name="decision_maker" type="checkbox"><span>Décideur</span></label>
        <label class="crm-check"><input name="billing" type="checkbox"><span>Facturation</span></label>
      </form>
    `,`${button('Annuler','PilozCRM.closeDrawer()')}${button('Enregistrer',`PilozCRM.saveProspectContact('${esc(contactId)}')`,'primary')}`);
  }

  async function saveProspectContact(contactId=''){
    const form=document.getElementById('crm-contact-form');
    if(!form?.reportValidity())return;
    const payload=formObject(form);
    payload.id=contactId||null;
    payload.is_primary=Boolean(form.elements.is_primary.checked);
    const roles=[];
    if(payload.is_primary)roles.push('primary');
    if(form.elements.decision_maker.checked)roles.push('decision_maker');
    if(form.elements.billing.checked)roles.push('billing');
    try{
      await api().rpc('save_client_contact',{target_client_id:ui.detail.prospect.id,target_contact:payload,target_roles:roles});
      crm.closeDrawer();
      await crm.loadProspectDetail(ui.detail.prospect.id);
      notify('Contact enregistré.');
    }catch(error){message(error.message||'Le contact n’a pas pu être enregistré.');}
  }

  async function openMergeProspect(){
    const prospect=ui.detail?.prospect;
    if(!prospect)return;
    const directory=await api().rpc('get_crm_prospect_directory',{target_search:null,target_status:null,target_owner:null,target_page:1,target_page_size:100});
    const options=(directory.rows||[]).filter(row=>row.id!==prospect.id).map(row=>`<option value="${row.id}">${esc(nameOf(row))} · ${esc(row.email||row.siret||'')}</option>`).join('');
    drawer('Fusionner un doublon','Toutes les activités, opportunités, documents et contacts seront conservés.',`
      <div id="crm-form-message" class="crm-form-message" hidden></div>
      <form id="crm-merge-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.mergeProspect()">
        <label class="crm-field full"><span>Prospect à fusionner dans ${esc(nameOf(prospect))}</span><select name="merge_id" required><option value="">Sélectionner</option>${options}</select></label>
      </form>
    `,`${button('Annuler','PilozCRM.closeDrawer()')}${button('Fusionner','PilozCRM.mergeProspect()','danger',options?'':'disabled')}`);
  }

  async function mergeProspect(){
    const form=document.getElementById('crm-merge-form');
    if(!form?.reportValidity())return;
    try{
      await api().rpc('merge_crm_prospects',{target_keep_id:ui.detail.prospect.id,target_merge_id:form.elements.merge_id.value,target_fields:{}});
      crm.closeDrawer();
      await crm.loadProspectDetail(ui.detail.prospect.id);
      notify('Doublon fusionné, historique conservé.');
    }catch(error){message(error.message||'La fusion n’a pas pu être réalisée.');}
  }

  function importProspects(){
    enterprise.csv=null;
    drawer('Importer des prospects','Prévisualisez, associez les colonnes puis choisissez le traitement des doublons.',`
      <section class="crm-panel"><h2>Fichier CSV UTF-8</h2><p>Maximum 5 000 lignes. Les e-mails, téléphones, SIREN et SIRET sont contrôlés.</p>
        ${button('Télécharger le modèle CSV','PilozCRM.downloadProspectTemplate()')}
        <label class="crm-field"><span>Fichier CSV</span><input type="file" accept=".csv,text/csv" onchange="PilozCRM.previewProspectCsv(this.files[0])"></label>
        <div id="crm-csv-preview" class="crm-csv-preview"></div>
      </section>
    `,button('Fermer','PilozCRM.closeDrawer()'));
  }

  function downloadProspectTemplate(){
    const csv='Entreprise;Prénom;Nom;E-mail;Téléphone;SIREN;SIRET;Adresse;Code postal;Ville;Pays;Statut\r\n';
    const blob=new Blob(['\ufeff'+csv],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),link=document.createElement('a');
    link.href=url;link.download='modele-import-prospects-piloz.csv';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }

  function parseCsv(text,delimiter){
    const rows=[];let row=[],cell='',quoted=false;
    for(let index=0;index<text.length;index++){
      const char=text[index],next=text[index+1];
      if(char==='"'&&quoted&&next==='"'){cell+='"';index++;continue;}
      if(char==='"'){quoted=!quoted;continue;}
      if(char===delimiter&&!quoted){row.push(cell.trim());cell='';continue;}
      if((char==='\n'||char==='\r')&&!quoted){if(char==='\r'&&next==='\n')index++;row.push(cell.trim());if(row.some(Boolean))rows.push(row);row=[];cell='';continue;}
      cell+=char;
    }
    row.push(cell.trim());if(row.some(Boolean))rows.push(row);return rows;
  }

  function normalizedHeader(value){return String(value||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_|_$/g,'');}
  const csvFields=[['','Ignorer'],['legal_name','Entreprise / nom'],['first_name','Prénom'],['last_name','Nom'],['email','E-mail'],['phone_e164','Téléphone'],['siren','SIREN'],['siret','SIRET'],['address_line_1','Adresse'],['postal_code','Code postal'],['city','Ville'],['country_code','Pays'],['crm_status','Statut']];
  const aliases={raison_sociale:'legal_name',entreprise:'legal_name',societe:'legal_name',company:'legal_name',nom_entreprise:'legal_name',legal_name:'legal_name',prenom:'first_name',first_name:'first_name',nom:'last_name',last_name:'last_name',email:'email',e_mail:'email',mail:'email',telephone:'phone_e164',tel:'phone_e164',phone:'phone_e164',mobile:'phone_e164',siren:'siren',siret:'siret',adresse:'address_line_1',address:'address_line_1',code_postal:'postal_code',cp:'postal_code',postal_code:'postal_code',ville:'city',city:'city',pays:'country_code',country:'country_code',statut:'crm_status',status:'crm_status'};

  async function previewProspectCsv(file){
    const node=document.getElementById('crm-csv-preview');
    if(!file||!node)return;
    if(file.size>5*1024*1024){node.innerHTML='<p class="crm-inline-error">Le fichier dépasse 5 Mo.</p>';return;}
    const text=await file.text();
    const firstLine=text.split(/\r?\n/,1)[0]||'';
    const delimiter=(firstLine.match(/;/g)||[]).length>=(firstLine.match(/,/g)||[]).length?';':',';
    const matrix=parseCsv(text,delimiter),headers=matrix.shift()||[];
    if(!headers.length||!matrix.length){node.innerHTML='<p class="crm-inline-error">Aucune ligne exploitable.</p>';return;}
    if(matrix.length>5000){node.innerHTML='<p class="crm-inline-error">Le fichier contient plus de 5 000 lignes.</p>';return;}
    enterprise.csv={headers,rows:matrix};
    const mapping=headers.map((header,index)=>{
      const guessed=aliases[normalizedHeader(header)]||'';
      return `<label class="crm-field"><span>${esc(header)}</span><select class="crm-csv-map" data-index="${index}">${csvFields.map(([value,label])=>`<option value="${value}" ${value===guessed?'selected':''}>${label}</option>`).join('')}</select></label>`;
    }).join('');
    const preview=matrix.slice(0,5).map(row=>`<tr>${headers.map((_,index)=>`<td>${esc(row[index]||'')}</td>`).join('')}</tr>`).join('');
    node.innerHTML=`<p><b>${number(matrix.length)}</b> ligne(s) détectée(s).</p><div class="crm-csv-mapping">${mapping}</div>
      <div class="crm-table-wrap"><table class="crm-table"><thead><tr>${headers.map(header=>`<th>${esc(header)}</th>`).join('')}</tr></thead><tbody>${preview}</tbody></table></div>
      <label class="crm-field"><span>Doublons détectés</span><select id="crm-csv-duplicate"><option value="skip">Ignorer le doublon</option><option value="update">Mettre à jour la fiche existante</option><option value="create">Créer quand même</option></select></label>
      ${button('Importer maintenant','PilozCRM.executeProspectImport()','primary')}`;
  }

  async function executeProspectImport(){
    if(!enterprise.csv)return;
    const mapping=Array.from(document.querySelectorAll('.crm-csv-map')).map(select=>select.value);
    if(!mapping.some(Boolean)){notify('Associez au moins une colonne.','error');return;}
    const rows=enterprise.csv.rows.map(source=>{
      const result={};mapping.forEach((field,index)=>{if(field&&source[index]!==undefined&&source[index]!=='')result[field]=source[index];});
      if(!result.legal_name&&result.last_name)result.legal_name=[result.first_name,result.last_name].filter(Boolean).join(' ');
      result.kind=result.first_name||result.last_name?'person':'company';return result;
    });
    const action=document.getElementById('crm-csv-duplicate')?.value||'skip';
    try{
      const report=await api().rpc('import_crm_prospects',{target_rows:rows,target_duplicate_action:action});
      const node=document.getElementById('crm-csv-preview');
      node.innerHTML=`<section class="crm-import-result"><h3>Import terminé</h3><p><b>${number(report.created)}</b> créé(s) · <b>${number(report.updated)}</b> mis à jour · <b>${number(report.skipped)}</b> ignoré(s) · <b>${number(report.errors)}</b> erreur(s)</p></section>`;
      await crm.reloadProspects();
    }catch(error){notify(error.message||'Import impossible.','error');}
  }

  function openGlobalSearch(){
    drawer('Recherche CRM','Prospects, clients, opportunités, documents et activités.',`
      <label class="crm-field"><span>Recherche</span><input id="crm-global-search-input" type="search" placeholder="Saisissez au moins 2 caractères…" oninput="PilozCRM.searchCrmGlobal(this.value)"></label>
      <div id="crm-global-search-results" class="crm-search-results"><p>Saisissez un nom, un numéro ou une activité.</p></div>
    `,button('Fermer','PilozCRM.closeDrawer()'));
  }

  function searchCrmGlobal(value){
    clearTimeout(enterprise.searchTimer);
    const node=document.getElementById('crm-global-search-results');
    if(value.trim().length<2){if(node)node.innerHTML='<p>Saisissez au moins 2 caractères.</p>';return;}
    enterprise.searchTimer=setTimeout(async()=>{
      try{
        const rows=await api().rpc('search_crm_global',{target_query:value,target_limit:25});
        if(node)node.innerHTML=rows.length?rows.map(row=>`<button onclick="PilozCRM.openCrmSearchResult('${esc(row.path)}')"><span><b>${esc(row.title)}</b><small>${esc(row.subtitle||row.type)}</small></span><em>${esc(row.type)}</em></button>`).join(''):'<p>Aucun résultat.</p>';
      }catch(error){if(node)node.innerHTML=`<p class="crm-inline-error">${esc(error.message||'Recherche indisponible.')}</p>`;}
    },220);
  }

  function openCrmSearchResult(path){crm.closeDrawer();app().go(path);}

  async function openProductForm(productId=''){
    const opportunity=ui.detail?.opportunity;if(!opportunity)return;
    const row=(ui.detail.products||[]).find(item=>item.id===productId)||{};
    drawer(productId?'Modifier le produit':'Ajouter un produit prévisionnel',opportunity.name,`
      <div id="crm-form-message" class="crm-form-message" hidden></div>
      <form id="crm-product-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveOpportunityProduct('${esc(productId)}')">
        <label class="crm-field full"><span>Désignation *</span><input name="name" required value="${esc(row.name||'')}"></label>
        <label class="crm-field full"><span>Description</span><textarea name="description">${esc(row.description||'')}</textarea></label>
        <label class="crm-field"><span>Quantité</span><input name="quantity" type="number" min="0" step="0.01" value="${Number(row.quantity||1)}"></label>
        <label class="crm-field"><span>Prix unitaire HT</span><input name="unit_price" type="number" min="0" step="0.01" value="${Number(row.unit_price||0)}"></label>
        <label class="crm-field"><span>Remise (%)</span><input name="discount_rate" type="number" min="0" max="100" step="0.01" value="${Number(row.discount_rate||0)}"></label>
        <label class="crm-field"><span>Coût estimé</span><input name="estimated_cost" type="number" min="0" step="0.01" value="${Number(row.estimated_cost||0)}"></label>
      </form>
    `,`${button('Annuler','PilozCRM.closeDrawer()')}${button('Enregistrer',`PilozCRM.saveOpportunityProduct('${esc(productId)}')`,'primary')}`);
  }

  async function saveOpportunityProduct(productId=''){
    const form=document.getElementById('crm-product-form');if(!form?.reportValidity())return;
    const raw=formObject(form),payload={company_id:state().companyId,opportunity_id:ui.detail.opportunity.id,name:raw.name,description:raw.description,quantity:Number(raw.quantity)||0,unit_price:Number(raw.unit_price)||0,discount_rate:Number(raw.discount_rate)||0,estimated_cost:Number(raw.estimated_cost)||0,currency:ui.detail.opportunity.currency||'EUR',position:(ui.detail.products||[]).length*10};
    try{
      if(productId)await api().update('crm_opportunity_products',productId,payload);else await api().insert('crm_opportunity_products',payload);
      crm.closeDrawer();await crm.loadOpportunityDetail(ui.detail.opportunity.id);notify('Produit prévisionnel enregistré.');
    }catch(error){message(error.message||'Enregistrement impossible.');}
  }

  function setActivityView(view){
    ui.activityView=view;
    if(view==='inbox')openCrmInbox();else nativeSetActivityView(view);
  }

  async function openCrmInbox(){
    const node=document.getElementById('main');
    if(node)node.innerHTML='<main class="crm-shell"><section class="crm-loading"><div><span class="crm-skeleton"></span><p>Chargement de la boîte de réception CRM…</p></div></section></main>';
    try{
      const companyId=state().companyId;
      const [connections,links]=await Promise.all([
        api().query('external_connections',`select=id,provider,status,account_email,display_name,connection_scope,last_successful_sync_at,last_error_code&company_id=eq.${encodeURIComponent(companyId)}&provider=in.(gmail,outlook_mail,imap_smtp)&order=created_at.desc`),
        api().query('external_mail_links',`select=id,connection_id,client_id,opportunity_id,direction,sender,subject,preview,recipients,sent_at,status,treatment_status,assigned_user_id,created_at&company_id=eq.${encodeURIComponent(companyId)}&order=sent_at.desc.nullslast,created_at.desc&limit=200`)
      ]);
      enterprise.inboxConnections=connections||[];enterprise.inboxRows=links||[];
      const connected=enterprise.inboxConnections.filter(row=>row.status==='connected');
      const providerLabel=value=>({gmail:'Gmail',outlook_mail:'Outlook',imap_smtp:'IMAP / SMTP'}[value]||value);
      const connectionById=id=>enterprise.inboxConnections.find(row=>row.id===id)||{};
      const rows=enterprise.inboxRows.map(row=>{const connection=connectionById(row.connection_id),when=row.sent_at||row.created_at;return`<article class="crm-inbox-row ${row.treatment_status==='new'?'unread':''}">
        <button class="crm-inbox-main" onclick="PilozCRM.openCrmMailLinkForm('${row.id}')"><span class="crm-inbox-direction">${row.direction==='inbound'?'↓':'↑'}</span><span><b>${esc(row.sender||connection.account_email||'Correspondant')}</b><strong>${esc(row.subject||'Sans objet')}</strong><small>${esc(row.preview||'Aucun aperçu disponible.')}</small></span></button>
        <div class="crm-inbox-meta"><span>${esc(providerLabel(connection.provider||''))}</span><time>${when?new Date(when).toLocaleString('fr-FR'):'—'}</time><em>${esc(row.treatment_status||'new')}</em></div>
        <div class="crm-inbox-actions">${button('Rattacher',`PilozCRM.openCrmMailLinkForm('${row.id}')`)}${row.sender?button('Répondre',`PilozCRM.replyCrmMail('${row.id}')`):''}${button('Créer une activité',`PilozCRM.createActivityFromMail('${row.id}')`)}${row.treatment_status!=='processed'?button('Traité',`PilozCRM.markCrmMailProcessed('${row.id}')`):''}</div>
      </article>`;}).join('');
      if(node)node.innerHTML=`<main class="crm-shell"><header class="crm-page-head"><div><h1>Boîte de réception CRM</h1><p>E-mails réellement synchronisés depuis les connecteurs de votre entreprise.</p></div><div class="crm-head-actions">${button('Configurer les connexions',"PilozApp.go('settings/extensions')")}${button('Actualiser','PilozCRM.openCrmInbox()','primary')}</div></header>
        <section class="crm-toolbar"><div class="crm-view-switch">${[['list','Liste'],['calendar','Calendrier'],['inbox','Boîte de réception CRM']].map(([key,label])=>`<button class="${key==='inbox'?'active':''}" onclick="PilozCRM.setActivityView('${key}')">${label}</button>`).join('')}</div><span class="crm-connector-summary">${connected.length?`${connected.length} messagerie(s) connectée(s)`:'Aucune messagerie connectée'}</span></section>
        ${connected.length?rows?`<section class="crm-inbox-list">${rows}</section>`:`<section class="crm-empty"><div><h2>Aucun e-mail synchronisé</h2><p>La boîte restera vide tant que le connecteur n’aura pas confirmé une synchronisation. Aucun message fictif n’est créé.</p></div></section>`:`<section class="crm-empty"><div><h2>Connectez Gmail ou Outlook</h2><p>Autorisez une messagerie dans les extensions pour traiter les échanges depuis le CRM. Piloz ne simulera jamais un envoi ni une réception.</p>${button('Ouvrir les extensions',"PilozApp.go('settings/extensions')",'primary')}</div></section>`}</main>`;
    }catch(error){if(node)node.innerHTML=`<main class="crm-shell"><section class="crm-error"><div><h2>Boîte de réception indisponible</h2><p>${esc(error.message||'Le chargement a échoué.')}</p>${button('Réessayer','PilozCRM.openCrmInbox()','primary')}</div></section></main>`;}
  }

  function inboxRow(id){return enterprise.inboxRows.find(row=>row.id===id);}

  function replyCrmMail(id){
    const row=inboxRow(id);if(!row?.sender)return;
    const subject=String(row.subject||'').replace(/^re\s*:\s*/i,'');
    location.href=`mailto:${encodeURIComponent(row.sender)}?subject=${encodeURIComponent(`Re : ${subject}`)}`;
  }

  async function openCrmMailLinkForm(id){
    const row=inboxRow(id);if(!row)return;
    try{
      const companyId=state().companyId,[clients,opportunities]=await Promise.all([
        api().query('clients',`select=id,legal_name,trade_name,first_name,last_name,email,relationship_type&company_id=eq.${encodeURIComponent(companyId)}&active=eq.true&order=legal_name.asc.nullslast&limit=250`),
        api().query('opportunities',`select=id,name,client_id,forecast_category&company_id=eq.${encodeURIComponent(companyId)}&archived_at=is.null&order=updated_at.desc&limit=250`)
      ]);
      drawer('Traiter l’e-mail',row.subject||'Sans objet',`<div id="crm-form-message" class="crm-form-message" hidden></div><form id="crm-mail-link-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveCrmMailLink('${id}')">
        <label class="crm-field full"><span>Client ou prospect</span><select name="client_id"><option value="">Non rattaché</option>${clients.map(client=>`<option value="${client.id}" ${client.id===row.client_id?'selected':''}>${esc(nameOf(client))}${client.email?` · ${esc(client.email)}`:''}</option>`).join('')}</select></label>
        <label class="crm-field full"><span>Opportunité</span><select name="opportunity_id"><option value="">Non rattachée</option>${opportunities.map(opportunity=>`<option value="${opportunity.id}" ${opportunity.id===row.opportunity_id?'selected':''}>${esc(opportunity.name)}</option>`).join('')}</select></label>
        <label class="crm-field"><span>Responsable</span><select name="assigned_user_id"><option value="">Non assigné</option>${memberOptions(row.assigned_user_id)}</select></label>
        <label class="crm-field"><span>Traitement</span><select name="treatment_status">${[['new','Nouveau'],['in_progress','En cours'],['processed','Traité'],['archived','Archivé']].map(([value,label])=>`<option value="${value}" ${value===(row.treatment_status||'new')?'selected':''}>${label}</option>`).join('')}</select></label>
        <section class="crm-panel full"><h2>Message</h2><p><b>${esc(row.sender||'Expéditeur non disponible')}</b></p><p>${esc(row.preview||'Aucun aperçu disponible.')}</p></section>
      </form>`,`${button('Annuler','PilozCRM.closeDrawer()')}${button('Enregistrer',`PilozCRM.saveCrmMailLink('${id}')`,'primary')}`);
    }catch(error){notify(error.message||'Impossible de préparer le rattachement.','error');}
  }

  async function saveCrmMailLink(id){
    const form=document.getElementById('crm-mail-link-form');if(!form?.reportValidity())return;
    try{await api().rpc('update_crm_mail_link',{target_link_id:id,target_patch:formObject(form)});crm.closeDrawer();await openCrmInbox();notify('E-mail rattaché au CRM.');}
    catch(error){message(error.message||'Le rattachement a échoué.');}
  }

  async function markCrmMailProcessed(id){
    try{await api().rpc('update_crm_mail_link',{target_link_id:id,target_patch:{treatment_status:'processed'}});await openCrmInbox();}
    catch(error){notify(error.message||'Mise à jour impossible.','error');}
  }

  function createActivityFromMail(id){
    const row=inboxRow(id);if(!row)return;
    crm.openActivityForm('',{client_id:row.client_id||'',opportunity_id:row.opportunity_id||''});
    setTimeout(()=>{const form=document.getElementById('crm-activity-form');if(!form)return;form.elements.activity_type.value='email';form.elements.subject.value=`Suivre : ${row.subject||'échange e-mail'}`;form.elements.due_at.value=new Date(Date.now()+86400000).toISOString().slice(0,16);},30);
  }

  function dragCrmActivity(event,id){enterprise.activityDragId=id;event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',id);}

  async function dropCrmActivity(event,dateValue){
    event.preventDefault();const id=event.dataTransfer.getData('text/plain')||enterprise.activityDragId,row=(ui.activities?.rows||[]).find(item=>item.id===id);if(!id||!row)return;
    const source=String(row.due_at||row.scheduled_at||''),time=/T(\d{2}:\d{2}:\d{2})/.exec(source)?.[1]||'09:00:00',target=`${dateValue}T${time}Z`,originalParent=event.target.closest('.crm-calendar-day');
    const card=document.querySelector(`.crm-calendar-event[ondragstart*="${id}"]`);if(card&&originalParent)originalParent.appendChild(card);
    try{await api().rpc('reschedule_crm_activity',{target_activity_id:id,target_due_at:target,target_assigned_user_id:null});notify('Activité replanifiée.');await crm.reloadActivities();}
    catch(error){notify(error.message||'La replanification a échoué.','error');await crm.reloadActivities();}
    finally{enterprise.activityDragId='';}
  }

  function viewObjectType(){const path=currentPath();if(path==='crm/pipeline')return'pipeline';if(path==='crm/prospects')return'prospects';if(path==='crm/activities'||path==='crm/reminders')return'activities';if(path==='crm/reports')return'reports';return'';}

  function currentViewFilters(type){
    if(type==='pipeline')return{pipeline_id:ui.pipelineId||ui.pipeline?.pipeline?.id||'',view:ui.pipelineView,search:ui.pipelineSearch,filters:ui.pipelineFilters||{}};
    if(type==='prospects')return{search:ui.prospectSearch,status:ui.prospectStatus};
    if(type==='activities')return{view:ui.activityView,filter:ui.activityFilter};
    if(type==='reports')return{...ui.reportFilters};return{};
  }

  async function openSaveCrmView(){
    const type=viewObjectType();if(!type)return;const configuration=await getConfiguration();
    drawer('Enregistrer la vue','Conservez vos filtres et retrouvez-les en un clic.',`<div id="crm-form-message" class="crm-form-message" hidden></div><form id="crm-save-view-form" class="crm-form-grid" onsubmit="event.preventDefault();PilozCRM.saveCurrentCrmView()">
      <label class="crm-field full"><span>Nom de la vue *</span><input name="name" required maxlength="120"></label>
      <label class="crm-check full"><input name="is_default" type="checkbox"><span>Vue par défaut</span></label>
      ${configuration.permissions?.manage?'<label class="crm-check full"><input name="is_shared" type="checkbox"><span>Partager avec l’entreprise</span></label>':''}
    </form>`,`${button('Annuler','PilozCRM.closeDrawer()')}${button('Enregistrer','PilozCRM.saveCurrentCrmView()','primary')}`);
  }

  async function saveCurrentCrmView(){
    const form=document.getElementById('crm-save-view-form'),type=viewObjectType();if(!form?.reportValidity()||!type)return;
    try{await api().rpc('save_crm_view',{target_view_id:null,target_object_type:type,target_name:form.elements.name.value,target_filters:currentViewFilters(type),target_columns:[],target_sorting:[],target_is_shared:Boolean(form.elements.is_shared?.checked),target_is_default:Boolean(form.elements.is_default.checked)});crm.closeDrawer();notify('Vue enregistrée.');}
    catch(error){message(error.message||'La vue n’a pas pu être enregistrée.');}
  }

  async function openCrmSavedViews(){
    const type=viewObjectType();if(!type)return;
    try{enterprise.savedViews=await api().query('crm_saved_views',`select=id,name,object_type,filters,is_shared,is_default,user_id&company_id=eq.${encodeURIComponent(state().companyId)}&object_type=eq.${encodeURIComponent(type)}&order=is_default.desc,name.asc`);
      drawer('Vues enregistrées','Vues personnelles et vues partagées avec votre entreprise.',enterprise.savedViews.length?`<section class="crm-saved-view-list">${enterprise.savedViews.map(row=>`<article><button onclick="PilozCRM.applyCrmSavedView('${row.id}')"><span><b>${esc(row.name)}</b><small>${row.is_shared?'Partagée':'Personnelle'}${row.is_default?' · par défaut':''}</small></span></button><button title="Supprimer" onclick="PilozCRM.deleteCrmSavedView('${row.id}')">⌫</button></article>`).join('')}</section>`:`<section class="crm-empty compact"><div><h2>Aucune vue enregistrée</h2><p>Enregistrez les filtres actuellement affichés.</p></div></section>`,`${button('Fermer','PilozCRM.closeDrawer()')}${button('Enregistrer la vue','PilozCRM.openSaveCrmView()','primary')}`);
    }catch(error){notify(error.message||'Chargement des vues impossible.','error');}
  }

  function applyCrmSavedView(id){
    const row=enterprise.savedViews.find(item=>item.id===id);if(!row)return;const filters=row.filters||{};crm.closeDrawer();
    if(row.object_type==='pipeline'){ui.pipelineId=filters.pipeline_id||'';ui.pipelineView=filters.view||'kanban';ui.pipelineSearch=filters.search||'';ui.pipelineFilters=filters.filters||{};localStorage.setItem('piloz_crm_pipeline_view',ui.pipelineView);crm.reloadPipeline();}
    else if(row.object_type==='prospects'){ui.prospectSearch=filters.search||'';ui.prospectStatus=filters.status||'';crm.reloadProspects();}
    else if(row.object_type==='activities'){ui.activityFilter=filters.filter||'upcoming';setActivityView(filters.view||'list');}
    else if(row.object_type==='reports'){ui.reportFilters={...ui.reportFilters,...filters};crm.reloadReports();}
  }

  async function deleteCrmSavedView(id){
    if(!global.confirm('Supprimer cette vue enregistrée ?'))return;
    try{await api().remove('crm_saved_views',id);await openCrmSavedViews();}
    catch(error){notify(error.message||'Suppression impossible.','error');}
  }

  function enhanceWorkspaceActions(){
    const type=viewObjectType(),actions=document.querySelector('.crm-page-head .crm-head-actions');
    if(type==='activities'&&ui.activityView==='inbox'&&document.querySelector('.crm-page-head h1')?.textContent==='Activités'){openCrmInbox();return;}
    if(!type||!actions||actions.querySelector('.crm-workspace-actions'))return;
    const wrap=document.createElement('span');wrap.className='crm-workspace-actions';wrap.innerHTML=`${button('Vues','PilozCRM.openCrmSavedViews()')}${button('Enregistrer la vue','PilozCRM.openSaveCrmView()')}${button('Rechercher','PilozCRM.openGlobalSearch()')}`;actions.prepend(wrap);
  }

  function enhanceDetails(){
    const path=currentPath(),actions=document.querySelector('.crm-page-head .crm-head-actions');
    if(!actions||actions.querySelector('.crm-enterprise-actions'))return;
    const wrap=document.createElement('span');wrap.className='crm-enterprise-actions';
    if(path.startsWith('crm/pipeline/')&&ui.detail?.opportunity){
      const row=ui.detail.opportunity,closed=['won','lost'].includes(row.forecast_category);
      wrap.innerHTML=`${button('Modifier',`PilozCRM.openOpportunityForm('${row.id}')`)}${button('Créer un devis',`PilozCRM.newOpportunityDocument('${row.id}','quote')`)}${closed?button('Réouvrir',`PilozCRM.reopenOpportunity('${row.id}')`):''}${button('Ajouter un produit',`PilozCRM.openOpportunityProductForm()`)}${button('Rechercher','PilozCRM.openGlobalSearch()')}`;
    }else if(path.startsWith('crm/prospects/')&&ui.detail?.prospect){
      const row=ui.detail.prospect;
      wrap.innerHTML=`${button('Modifier',`PilozCRM.openProspectForm('${row.id}')`)}${button('Nouveau contact','PilozCRM.openProspectContactForm()')}${button('Nouvelle opportunité',`PilozCRM.openOpportunityFormForProspect('${row.id}')`)}${button('Fusionner','PilozCRM.openMergeProspect()')}${button('Rechercher','PilozCRM.openGlobalSearch()')}`;
      const layout=document.querySelector('.crm-detail-layout');
      if(layout&&!layout.querySelector('.crm-contacts-panel')){
        const contacts=document.createElement('section');contacts.className='crm-panel crm-contacts-panel';
        contacts.innerHTML=`<header><div><h2>Contacts</h2><p>Interlocuteurs liés au prospect</p></div>${button('Ajouter','PilozCRM.openProspectContactForm()')}</header>${(ui.detail.contacts||[]).map(contact=>`<button class="crm-contact-row" onclick="PilozCRM.openProspectContactForm('${contact.id}')"><span><b>${esc([contact.first_name,contact.last_name].filter(Boolean).join(' '))}</b><small>${esc(contact.job_title||contact.email||'')}</small></span>${contact.is_primary?'<em>Principal</em>':''}</button>`).join('')||'<p>Aucun contact.</p>'}`;
        layout.appendChild(contacts);
      }
    }
    if(wrap.innerHTML)actions.prepend(wrap);
  }

  crm.openPipelineSettings=openPipelineSettings;
  crm.selectManagedPipeline=selectManagedPipeline;
  crm.openPipelineForm=openPipelineForm;
  crm.saveManagedPipeline=saveManagedPipeline;
  crm.duplicateManagedPipeline=duplicateManagedPipeline;
  crm.archiveManagedPipeline=archiveManagedPipeline;
  crm.openStageForm=openStageForm;
  crm.saveManagedStage=saveManagedStage;
  crm.dragManagedStage=dragManagedStage;
  crm.dropManagedStage=dropManagedStage;
  crm.openOpportunityForm=openOpportunityForm;
  crm.saveOpportunity=saveOpportunity;
  crm.reopenOpportunity=reopenOpportunity;
  crm.openProspectForm=openProspectForm;
  crm.saveProspect=saveProspect;
  crm.openProspectContactForm=openContactForm;
  crm.saveProspectContact=saveProspectContact;
  crm.openMergeProspect=openMergeProspect;
  crm.mergeProspect=mergeProspect;
  crm.importProspects=importProspects;
  crm.downloadProspectTemplate=downloadProspectTemplate;
  crm.previewProspectCsv=previewProspectCsv;
  crm.executeProspectImport=executeProspectImport;
  crm.openGlobalSearch=openGlobalSearch;
  crm.searchCrmGlobal=searchCrmGlobal;
  crm.openCrmSearchResult=openCrmSearchResult;
  crm.openOpportunityProductForm=openProductForm;
  crm.saveOpportunityProduct=saveOpportunityProduct;
  crm.setActivityView=setActivityView;
  crm.openCrmInbox=openCrmInbox;
  crm.openCrmMailLinkForm=openCrmMailLinkForm;
  crm.saveCrmMailLink=saveCrmMailLink;
  crm.markCrmMailProcessed=markCrmMailProcessed;
  crm.replyCrmMail=replyCrmMail;
  crm.createActivityFromMail=createActivityFromMail;
  crm.dragCrmActivity=dragCrmActivity;
  crm.dropCrmActivity=dropCrmActivity;
  crm.openSaveCrmView=openSaveCrmView;
  crm.saveCurrentCrmView=saveCurrentCrmView;
  crm.openCrmSavedViews=openCrmSavedViews;
  crm.applyCrmSavedView=applyCrmSavedView;
  crm.deleteCrmSavedView=deleteCrmSavedView;

  const observer=new MutationObserver(()=>{
    clearTimeout(enterprise.enhanceTimer);
    enterprise.enhanceTimer=setTimeout(()=>{enhanceWorkspaceActions();enhanceDetails();},0);
  });
  observer.observe(document.body,{childList:true,subtree:true});
  global.addEventListener('keydown',event=>{
    if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'&&currentPath().startsWith('crm/')){
      event.preventDefault();openGlobalSearch();
    }
  });
})(window);
