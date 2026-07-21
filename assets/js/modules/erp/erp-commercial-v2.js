(function(global){
 'use strict';
 const modern=global.PilozModern,app=()=>global.PilozApp,api=()=>global.PilozERP;
 if(!modern)return;
 const base={renderNavigation:modern.renderNavigation,renderRoute:modern.renderRoute,openArea:modern.openArea,openOpportunity:modern.openOpportunity,openActivity:modern.openActivity};
 const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
 const money=(value,currency='EUR')=>new Intl.NumberFormat('fr-FR',{style:'currency',currency:currency||'EUR',maximumFractionDigits:2}).format(Number(value)||0);
 const date=value=>value?new Intl.DateTimeFormat('fr-FR').format(new Date(value)):'—';
 const datetime=value=>value?new Intl.DateTimeFormat('fr-FR',{dateStyle:'short',timeStyle:'short'}).format(new Date(value)):'—';
 const iso=value=>new Date(value).toISOString().slice(0,10);
 const state=()=>app().getState();
 const button=(label,handler,kind='btn-o',attrs='')=>`<button ${/\btype=/.test(attrs)?'':'type="button"'} class="btn ${kind}" onclick="${handler}" ${attrs}>${esc(label)}</button>`;
 const header=(title,description,actions='')=>`<header class="modern-page-header"><div><h1>${esc(title)}</h1><p>${esc(description)}</p></div><div class="actions">${actions}</div></header><div id="commercial-v2-live" class="sr-only" aria-live="polite"></div>`;
 const empty=(title,text,action='')=>`<div class="modern-empty"><h3>${esc(title)}</h3><p>${esc(text)}</p>${action}</div>`;
 const status=(label,tone='info')=>`<span class="modern-status ${tone}">${esc(label)}</span>`;
 const clientName=client=>client?.legal_name||client?.trade_name||[client?.first_name,client?.last_name].filter(Boolean).join(' ')||'—';
 const clientFor=(s,id)=>(s.data.clients||[]).find(row=>row.id===id);
 const opportunityFor=(s,id)=>(s.data.opportunities||[]).find(row=>row.id===id);
 const paidFor=(s,id)=>(s.data.payments||[]).filter(row=>row.document_id===id&&row.status==='confirmed').reduce((sum,row)=>sum+Number(row.amount||0),0);
 function notify(message,kind='info'){global.toast?.(message);const node=document.getElementById('commercial-v2-live');if(node){node.textContent=message;node.dataset.kind=kind;}}
 function route(){return(location.hash||'#dashboard').slice(1).split('?')[0];}

 const secondary={
  crm:{label:'Suivi commercial',items:[['crm/pipeline','Pipeline'],['crm/activities','Activités'],['crm/prospects','Prospects']]},
  sales:{label:'Ventes',items:[['sales/quotes','Devis'],['sales/invoices','Factures'],['sales/clients','Clients'],['sales/catalog','Articles & services'],['sales/due-dates','Échéances clients']]},
  purchases:{label:'Achats',items:[['purchases/suppliers','Fournisseurs'],['purchases/orders','Commandes fournisseurs'],['purchases/receipts','Réceptions'],['purchases/invoices','Factures fournisseurs']]},
  stock:{label:'Stock',items:[['stock/items','Articles en stock'],['stock/movements','Mouvements'],['stock/inventories','Inventaires'],['stock/warehouses','Entrepôts']]}
 };
 function areaFor(path){if(path.startsWith('crm/'))return'crm';if(path.startsWith('sales/'))return'sales';if(path.startsWith('purchases/'))return'purchases';if(path.startsWith('stock/'))return'stock';return'';}
 function secondaryActive(path,item){return path===item||path.startsWith(item+'/');}
 function renderNavigation(node,s,current){
  base.renderNavigation(node,s,current);
  const path=current||route(),area=areaFor(path),data=secondary[area],panel=node.querySelector('.modern-secondary-panel');
  if(!data||!panel)return;
  const body=panel.querySelector('.modern-secondary-items'),title=panel.querySelector('h2');if(title)title.textContent=data.label;
  if(body)body.innerHTML=data.items.map(([itemPath,label])=>`<button class="modern-secondary-item ${secondaryActive(path,itemPath)?'active':''}" onclick="PilozApp.go('${itemPath}')"><span>${esc(label)}</span></button>`).join('');
 }
 function openArea(area){const target={crm:'crm/pipeline',sales:'sales/quotes',purchases:'purchases/suppliers',stock:'stock/items',settings:'settings/company',dashboard:'dashboard',reports:'reports'}[area]||'dashboard';app().go(target);}

 const defaultBlocks=['revenue','collected','outstanding','overdue','quotes','activities','pipeline','recent'];
 const optionalBlocks=['topClients','topItems','margin','comparison','stock','supplierOrders','receipts'];
 const blockLabels={revenue:'Chiffre d’affaires',collected:'Montant encaissé',outstanding:'Reste à encaisser',overdue:'Factures en retard',quotes:'Devis en attente',activities:'Mes activités',pipeline:'Pipeline commercial',recent:'Activité récente',topClients:'Top clients',topItems:'Top articles',margin:'Marge brute',comparison:'Comparaison N / N-1',stock:'Stock sous seuil',supplierOrders:'Commandes fournisseurs en attente',receipts:'Réceptions attendues'};
 const dashboardUi={config:false,period:'month',customStart:'',customEnd:'',dragged:'',dropTarget:'',dropSide:'before',saving:false,pending:null,order:null,context:'',lastSaved:'',savePromise:null};
 function firstName(s){const userId=global.PilozRuntime?.session?.user_id,preference=(s.data.preferences||[]).find(row=>row.user_id===userId)||{},metadata=global.PilozCurrentUser?.user_metadata||{},profile=(s.data.members||[]).find(row=>row.user_id===userId)?.profile||{},candidates=[preference.first_name,preference.profile?.first_name,metadata.first_name,metadata.given_name,profile.first_name,metadata.full_name,metadata.name,preference.display_name];for(const candidate of candidates){const value=String(candidate??'').trim();if(value&&!value.includes('@')&&!['undefined','null'].includes(value.toLowerCase()))return value.split(/\s+/)[0];}return'';}
 function periodRange(preset,previous=false){
  const now=new Date(),start=new Date(now.getFullYear(),now.getMonth(),1),end=new Date(now.getFullYear(),now.getMonth()+1,1);
  if(preset==='quarter'){start.setMonth(Math.floor(now.getMonth()/3)*3);end.setMonth(start.getMonth()+3);}
  else if(preset==='year'){start.setMonth(0);end.setFullYear(start.getFullYear()+1,0,1);}
  else if(preset==='previous_year'){start.setFullYear(now.getFullYear()-1,0,1);end.setFullYear(now.getFullYear(),0,1);}
  else if(preset==='previous_month'){start.setMonth(start.getMonth()-1);end.setMonth(end.getMonth()-1);}
  else if(preset==='custom'){
   const customStart=dashboardUi.customStart&&new Date(`${dashboardUi.customStart}T00:00:00`),customEnd=dashboardUi.customEnd&&new Date(`${dashboardUi.customEnd}T00:00:00`);
   if(customStart&&!Number.isNaN(customStart.getTime()))start.setTime(customStart.getTime());
   if(customEnd&&!Number.isNaN(customEnd.getTime())){end.setTime(customEnd.getTime());end.setDate(end.getDate()+1);}
  }
  if(previous){const duration=Math.max(86400000,end-start);end.setTime(start.getTime());start.setTime(start.getTime()-duration);}
  return{start,end};
 }
 function inRange(value,range){if(!value)return false;const item=new Date(String(value).length===10?value+'T12:00:00':value);return item>=range.start&&item<range.end;}
 function dashboardData(s){
  const range=periodRange(dashboardUi.period),previousRange=periodRange(dashboardUi.period,true),docs=s.data.documents||[],invoiceTypes=['invoice','deposit_invoice','balance_invoice','credit_note'],valid=doc=>invoiceTypes.includes(doc.document_type)&&!['draft','cancelled','archived'].includes(doc.status),signed=doc=>doc.document_type==='credit_note'?-1:1,current=docs.filter(doc=>valid(doc)&&inRange(doc.issue_date,range)),previous=docs.filter(doc=>valid(doc)&&inRange(doc.issue_date,previousRange)),revenue=current.reduce((sum,doc)=>sum+signed(doc)*Number(doc.total_excl_tax||0),0),previousRevenue=previous.reduce((sum,doc)=>sum+signed(doc)*Number(doc.total_excl_tax||0),0),cost=current.reduce((sum,doc)=>sum+signed(doc)*Number(doc.total_cost||0),0),payments=(s.data.payments||[]).filter(row=>row.status==='confirmed'),collected=payments.filter(row=>inRange(row.paid_at,range)).reduce((sum,row)=>sum+Number(row.amount||0),0),invoices=docs.filter(doc=>['invoice','deposit_invoice','balance_invoice'].includes(doc.document_type)&&!['cancelled','archived'].includes(doc.status)),outstandingRows=invoices.map(doc=>({...doc,remaining:Math.max(0,Number(doc.total_incl_tax||0)-paidFor(s,doc.id))})).filter(doc=>doc.remaining>0),outstanding=outstandingRows.reduce((sum,doc)=>sum+doc.remaining,0),today=iso(new Date()),overdue=outstandingRows.filter(doc=>doc.due_date&&doc.due_date<today),quotes=docs.filter(doc=>doc.document_type==='quote'&&['draft','to_send','sent','viewed'].includes(doc.status)),activities=(s.data.activities||[]).filter(row=>{const meta=row.metadata||{},statusValue=row.status||meta.status||(row.completed_at?'completed':'todo'),assignees=meta.assigned_user_ids||[];return!['completed','cancelled'].includes(statusValue)&&(!row.assigned_user_id&&assignees.length===0||row.assigned_user_id===global.PilozRuntime.session.user_id||assignees.includes(global.PilozRuntime.session.user_id));}),quotePipeline=docs.filter(doc=>doc.document_type==='quote'&&!['cancelled','archived'].includes(doc.status)&&!doc.archived_at).map(quote=>global.PilozCommercialWorkspace?.quotePipelineMetrics?.(s,quote)||{quote,stage:quote.metadata?.pipeline_stage||quote.status||'draft'}),pipelineQuotes=quotePipeline.filter(row=>!['rejected','expired','collected'].includes(row.stage)),pipeline=pipelineQuotes.reduce((sum,row)=>sum+Number(row.quote.total_excl_tax||0),0),logs=(s.data.activityLogs||[]).slice(0,8),stock=(s.data.levels||[]).filter(level=>{const item=(s.data.catalog||[]).find(row=>row.id===level.item_id);return item&&Number(level.available_quantity)<Number(item.reorder_point||item.minimum_stock||0);});
  return{range,revenue,previousRevenue,cost,collected,outstanding,outstandingRows,overdue,quotes,activities,pipelineQuotes,pipeline,logs,stock};
 }
 function dashboardKeys(s){
  const context=`${s.companyId||''}:${global.PilozRuntime?.session?.user_id||''}`,aliases={overdueInvoices:'overdue',quotesPending:'quotes',todayReminders:'activities',stockAlerts:'stock',supplierOrdersPending:'supplierOrders',receiptsExpected:'receipts',comparison:'comparison'};
  if(dashboardUi.context!==context){dashboardUi.context=context;dashboardUi.order=null;}
  if(Array.isArray(dashboardUi.order))return dashboardUi.order.slice();
  const stored=(s.data.widgets||[]).slice().sort((a,b)=>a.position-b.position),rows=stored.map(row=>aliases[row.widget_key]||row.widget_key).filter(key=>blockLabels[key]);
  return stored.length?[...new Set(rows)]:defaultBlocks.slice();
 }
 function dashboardSpan(key){return['quotes','activities','pipeline','recent','topClients','topItems','stock'].includes(key)?2:1;}
 function metricCard(value,meta='',tone=''){return`<div class="modern-kpi commercial-dashboard-metric"><strong class="${tone}">${value}</strong>${meta?`<small>${esc(meta)}</small>`:''}</div>`;}
 function blockFrame(key,content){const editable=dashboardUi.config,span=dashboardSpan(key);return`<section class="commercial-dashboard-block block-${key} span-${span} ${editable?'is-editing':''}" data-dashboard-key="${key}" ondragover="PilozCommercialV2.previewDashboard(event,'${key}')" ondragleave="PilozCommercialV2.leaveDashboard(event,'${key}')" ondrop="PilozCommercialV2.dropDashboard(event,'${key}')"><header>${editable?`<button type="button" class="commercial-dashboard-handle" draggable="true" aria-label="Déplacer ${esc(blockLabels[key])}" title="Glisser pour déplacer" ondragstart="PilozCommercialV2.dragDashboard(event,'${key}')" ondragend="PilozCommercialV2.endDashboardDrag()">⋮⋮</button>`:''}<h2>${esc(blockLabels[key])}</h2>${editable?`<button type="button" class="commercial-dashboard-remove" aria-label="Retirer ${esc(blockLabels[key])}" onclick="PilozCommercialV2.toggleDashboard('${key}')">×</button>`:''}</header>${content}</section>`;}
 function dashboardBlock(key,s,d){
  if(key==='revenue')return metricCard(money(d.revenue),'Données facturées HT');
  if(key==='collected')return metricCard(money(d.collected),'Paiements confirmés','positive');
  if(key==='outstanding')return metricCard(money(d.outstanding),`${d.outstandingRows.length} facture(s)`,'warning');
  if(key==='overdue')return metricCard(d.overdue.length,money(d.overdue.reduce((sum,row)=>sum+row.remaining,0)),'danger');
  if(key==='quotes')return`<div class="commercial-list">${d.quotes.slice(0,6).map(row=>`<button onclick="PilozApp.editDocument('${row.id}')"><span><b>${esc(row.number||'Brouillon')}</b><small>${esc(row.subject||'Sans objet')}</small></span><strong>${money(row.total_incl_tax)}</strong></button>`).join('')||'<p>Aucun devis en attente.</p>'}</div>`;
  if(key==='activities')return`<div class="commercial-tabs"><span>Aujourd’hui</span><span>En retard</span><span>À venir</span></div><div class="commercial-list">${d.activities.slice(0,6).map(row=>`<button onclick="PilozCommercialV2.openActivity('${row.opportunity_id||''}','${row.activity_type}','${row.id}')"><span><b>${esc(row.subject)}</b><small>${datetime(row.due_at||row.scheduled_at||row.created_at)}</small></span>${status(row.priority||row.metadata?.priority||'Normale',(row.priority||row.metadata?.priority)==='urgent'?'danger':'info')}</button>`).join('')||'<p>Aucune activité assignée.</p>'}</div>`;
  if(key==='pipeline'){const stages=global.PilozCommercialWorkspace?.documentPipelineStages||[['draft','Brouillon'],['finalized','Finalisé'],['sent','Envoyé'],['pending','En attente'],['accepted','Accepté'],['invoicing','Facturation'],['partially_collected','Partiellement encaissé']].map(([slug,name])=>({slug,name,color:'#64748b'})),total=Math.max(1,d.pipeline);return`<div class="commercial-pipeline-summary"><strong>${money(d.pipeline)}</strong><span>${d.pipelineQuotes.length} devis en cours</span></div><div class="commercial-stage-bars">${stages.filter(stage=>!['rejected','expired','collected'].includes(stage.slug)).map(stage=>{const rows=d.pipelineQuotes.filter(row=>row.stage===stage.slug),value=rows.reduce((sum,row)=>sum+Number(row.quote.total_excl_tax||0),0);return`<button onclick="PilozApp.go('crm/pipeline')"><i style="--stage-color:${esc(stage.color||'#64748b')};--stage-width:${Math.min(100,value?Math.max(8,value/total*100):0)}%"></i><span>${esc(stage.name)}</span><b>${rows.length} · ${money(value)}</b></button>`;}).join('')}</div>`;}
  if(key==='recent')return`<div class="commercial-timeline">${d.logs.map(log=>`<article><i></i><div><b>${esc(String(log.action||'Action').replaceAll('.',' · '))}</b><small>${datetime(log.created_at)}</small></div></article>`).join('')||'<p>Aucune action récente.</p>'}</div>`;
  if(key==='margin')return metricCard(money(d.revenue-d.cost),d.cost?`${((d.revenue-d.cost)/d.cost*100).toFixed(1)} % de marge`:'Coût d’achat nul');
  if(key==='comparison'){const change=d.previousRevenue?((d.revenue-d.previousRevenue)/Math.abs(d.previousRevenue)*100):null;return metricCard(change===null?'—':`${change>=0?'+':''}${change.toFixed(1)} %`,`${money(d.revenue)} contre ${money(d.previousRevenue)}`,change>=0?'positive':'danger');}
  if(key==='topClients'){const values=new Map();(s.data.documents||[]).filter(row=>inRange(row.issue_date,d.range)&&['invoice','deposit_invoice','balance_invoice'].includes(row.document_type)).forEach(row=>values.set(row.client_id,(values.get(row.client_id)||0)+Number(row.total_excl_tax||0)));return`<div class="commercial-list">${[...values.entries()].sort((a,b)=>b[1]-a[1]).slice(0,5).map(([id,value])=>`<button onclick="PilozCommercialV2.openClient('${id}')"><span><b>${esc(clientName(clientFor(s,id)))}</b></span><strong>${money(value)}</strong></button>`).join('')||'<p>Aucune vente sur la période.</p>'}</div>`;}
  if(key==='topItems'){const values=new Map();for(const line of s.data.lines||[]){const doc=(s.data.documents||[]).find(row=>row.id===line.document_id);if(doc&&inRange(doc.issue_date,d.range)&&['invoice','deposit_invoice','balance_invoice'].includes(doc.document_type))values.set(line.name,(values.get(line.name)||0)+Number(line.total_excl_tax||0));}return`<div class="commercial-list">${[...values.entries()].sort((a,b)=>b[1]-a[1]).slice(0,5).map(([name,value])=>`<div><span><b>${esc(name||'Sans désignation')}</b></span><strong>${money(value)}</strong></div>`).join('')||'<p>Aucune ligne facturée.</p>'}</div>`;}
  if(key==='stock')return`<div class="commercial-list">${d.stock.slice(0,6).map(level=>{const item=(s.data.catalog||[]).find(row=>row.id===level.item_id);return`<div><span><b>${esc(item?.name||'Article')}</b><small>${Number(level.available_quantity)||0} disponible(s)</small></span></div>`;}).join('')||'<p>Aucun stock sous seuil.</p>'}</div>`;
  if(key==='supplierOrders')return metricCard((s.data.purchaseOrders||[]).filter(row=>['draft','sent','confirmed','partially_received'].includes(row.status)).length);
  if(key==='receipts')return metricCard((s.data.purchaseOrderLines||[]).filter(row=>Number(row.received_quantity)<Number(row.quantity)).length);
  return'';
 }
 function renderDashboard(s){
  const d=dashboardData(s),keys=dashboardKeys(s),first=firstName(s),periods=[['month','Ce mois'],['previous_month','Mois précédent'],['quarter','Trimestre'],['year','Année'],['previous_year','Année précédente'],['custom','Personnalisé']],periodControl=`<label class="commercial-dashboard-period"><span>Période</span><select aria-label="Période du tableau de bord" onchange="PilozCommercialV2.setDashboardPeriod(this.value)">${periods.map(([value,label])=>`<option value="${value}" ${dashboardUi.period===value?'selected':''}>${label}</option>`).join('')}</select></label>`,custom=dashboardUi.period==='custom'?`<div class="commercial-dashboard-custom-period"><label>Du <input type="date" value="${esc(dashboardUi.customStart)}" onchange="PilozCommercialV2.setDashboardCustom('customStart',this.value)"></label><label>Au <input type="date" value="${esc(dashboardUi.customEnd)}" onchange="PilozCommercialV2.setDashboardCustom('customEnd',this.value)"></label></div>`:'';
  document.getElementById('main').innerHTML=header(`Bonjour 👋${first?' '+first:''}`,'Voici ce qui mérite votre attention aujourd’hui.',periodControl+button(dashboardUi.config?'Terminer':'Personnaliser','PilozCommercialV2.toggleDashboardConfig()'))+custom+(dashboardUi.config?`<section class="commercial-dashboard-config"><div><h2>Blocs affichés</h2><p>Utilisez la poignée de chaque bloc pour le déplacer horizontalement ou verticalement.</p></div><div class="phase1-checks">${[...defaultBlocks,...optionalBlocks].map(key=>`<label class="phase1-check"><input type="checkbox" ${keys.includes(key)?'checked':''} onchange="PilozCommercialV2.toggleDashboard('${key}')"><span>${esc(blockLabels[key])}</span></label>`).join('')}</div>${button('Réinitialiser la disposition','PilozCommercialV2.resetDashboard()','btn-ghost')}</section>`:'')+(keys.length?`<div class="commercial-dashboard-grid">${keys.map(key=>blockFrame(key,dashboardBlock(key,s,d))).join('')}</div>`:empty('Tableau de bord vide','Cliquez sur Personnaliser pour ajouter vos premiers widgets.'));
 }
 async function saveDashboardSnapshot(keys){
  const current=state(),user=global.PilozRuntime?.session?.user_id,existing=(current.data.widgets||[]).slice(),desired=keys.length?keys:['__empty__'],wanted=new Set(desired);
  for(const row of existing)if(!wanted.has(row.widget_key))await api().remove('dashboard_widgets',row.id);
  for(let index=0;index<desired.length;index++){
   const key=desired[index],row=existing.find(item=>item.widget_key===key),payload={position:index,width:key==='__empty__'?1:dashboardSpan(key),height:1,config:key==='__empty__'?{empty:true}:{}};
   if(row)await api().update('dashboard_widgets',row.id,payload);
   else await api().insert('dashboard_widgets',{company_id:current.companyId,user_id:user,widget_key:key,...payload});
  }
  dashboardUi.lastSaved=desired.join('|');
  await app().refresh();
 }
 function persistDashboard(keys){
  dashboardUi.pending=keys.slice();
  if(dashboardUi.saving)return dashboardUi.savePromise||Promise.resolve();
  dashboardUi.saving=true;
  dashboardUi.savePromise=(async()=>{try{while(dashboardUi.pending){const next=dashboardUi.pending;dashboardUi.pending=null;await saveDashboardSnapshot(next);}notify('Disposition enregistrée.','success');}catch(error){console.error('[PILOZ Tableau de bord] Sauvegarde impossible',{status:error?.status||0,code:error?.code||'',message:error?.message||String(error)});notify('La disposition n’a pas pu être enregistrée.','error');}finally{dashboardUi.saving=false;dashboardUi.savePromise=null;}})();
  return dashboardUi.savePromise;
 }
 function applyDashboardOrder(keys){dashboardUi.order=keys.slice();renderDashboard(state());return persistDashboard(keys);}
 function toggleDashboardConfig(){dashboardUi.config=!dashboardUi.config;endDashboardDrag();renderDashboard(state());}
 function toggleDashboard(key){const keys=dashboardKeys(state()),index=keys.indexOf(key);if(index>=0)keys.splice(index,1);else keys.push(key);return applyDashboardOrder(keys);}
 function moveDashboard(key,direction){const keys=dashboardKeys(state()),index=keys.indexOf(key),target=index+direction;if(index<0||target<0||target>=keys.length)return Promise.resolve();[keys[index],keys[target]]=[keys[target],keys[index]];return applyDashboardOrder(keys);}
 function dragDashboard(event,key){if(typeof event==='string'){key=event;event=null;}dashboardUi.dragged=key||'';dashboardUi.dropTarget='';if(event?.dataTransfer){event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',dashboardUi.dragged);}event?.currentTarget?.closest('[data-dashboard-key]')?.classList.add('is-dragging');}
 function previewDashboard(event,target){event.preventDefault();if(!dashboardUi.dragged||dashboardUi.dragged===target)return;const node=event.currentTarget,rect=node.getBoundingClientRect(),sameRow=Math.abs(event.clientY-(rect.top+rect.height/2))<rect.height*.32,side=sameRow?(event.clientX<rect.left+rect.width/2?'before':'after'):(event.clientY<rect.top+rect.height/2?'before':'after');document.querySelectorAll('.commercial-dashboard-block.is-drop-before,.commercial-dashboard-block.is-drop-after').forEach(item=>item.classList.remove('is-drop-before','is-drop-after'));node.classList.add(side==='before'?'is-drop-before':'is-drop-after');dashboardUi.dropTarget=target;dashboardUi.dropSide=side;if(event.dataTransfer)event.dataTransfer.dropEffect='move';}
 function leaveDashboard(event){if(event.currentTarget.contains(event.relatedTarget))return;event.currentTarget.classList.remove('is-drop-before','is-drop-after');}
 function endDashboardDrag(){dashboardUi.dragged='';dashboardUi.dropTarget='';document.querySelectorAll('.commercial-dashboard-block.is-dragging,.commercial-dashboard-block.is-drop-before,.commercial-dashboard-block.is-drop-after').forEach(item=>item.classList.remove('is-dragging','is-drop-before','is-drop-after'));}
 function dropDashboard(event,target,forcedSide=''){event?.preventDefault?.();const dragged=dashboardUi.dragged||event?.dataTransfer?.getData('text/plain'),side=forcedSide||dashboardUi.dropTarget===target&&dashboardUi.dropSide||'before',keys=dashboardKeys(state()),from=keys.indexOf(dragged);if(from<0||dragged===target){endDashboardDrag();return Promise.resolve();}keys.splice(from,1);const targetIndex=keys.indexOf(target);if(targetIndex<0){endDashboardDrag();return Promise.resolve();}keys.splice(targetIndex+(side==='after'?1:0),0,dragged);endDashboardDrag();return applyDashboardOrder(keys);}
 function resetDashboard(){return applyDashboardOrder(defaultBlocks.slice());}
 function setDashboardPeriod(value){dashboardUi.period=value;if(value==='custom'){const now=new Date(),local=date=>`${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;dashboardUi.customStart=dashboardUi.customStart||local(new Date(now.getFullYear(),now.getMonth(),1));dashboardUi.customEnd=dashboardUi.customEnd||local(now);}renderDashboard(state());}
 function setDashboardCustom(key,value){if(!['customStart','customEnd'].includes(key))return;dashboardUi[key]=value;renderDashboard(state());}

 function renderRoute(routeName,s){if(routeName==='dashboard'){renderDashboard(s);return true;}return base.renderRoute(routeName,s);}
 Object.assign(modern,{renderNavigation,renderRoute,openArea});
 global.PilozCommercialV2={base,renderDashboard,dashboardKeys,toggleDashboardConfig,toggleDashboard,moveDashboard,dragDashboard,previewDashboard,leaveDashboard,endDashboardDrag,dropDashboard,resetDashboard,setDashboardPeriod,setDashboardCustom,notify,money,date,datetime,clientName,clientFor,opportunityFor,paidFor,header,button,empty,status,esc};
})(window);
