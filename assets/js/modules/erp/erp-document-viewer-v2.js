(function(global){
 'use strict';

 const modern=global.PilozModern;
 if(!modern)return;
 const previousRender=modern.renderRoute;
 const app=()=>global.PilozApp;
 const api=()=>global.PilozERP;
 const calc=()=>global.PilozCalculations;
 const invoiceTypes=new Set(['invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice','recurring_invoice']);
 const statusMeta={
  draft:['Brouillon','neutral'],to_finalize:['À finaliser','neutral'],finalized:['Finalisé','info'],validated:['Finalisé','info'],
  to_send:['À envoyer','warning'],sent:['Envoyé','info'],viewed:['Consulté','info'],pending:['En attente','warning'],
  accepted:['Accepté','positive'],rejected:['Refusé','danger'],expired:['Expiré','danger'],invoiced:['Facturé','positive'],
  partially_invoiced:['Partiellement facturé','warning'],partially_paid:['Partiellement encaissée','warning'],paid:['Encaissée','positive'],
  overdue:['En retard','danger'],cancelled:['Annulé','neutral'],archived:['Archivé','neutral']
 };
 const typeLabels={quote:'Devis',invoice:'Facture',deposit_invoice:'Facture d’acompte',balance_invoice:'Facture de solde',credit_note:'Avoir',proforma_invoice:'Facture pro forma',recurring_invoice:'Facture récurrente'};
 const linkLabels={invoice:'Facture',deposit:'Acompte',progress:'Situation',balance:'Solde',credit_note:'Avoir',proforma:'Pro forma',version:'Version',related:'Document lié'};
 const ui={id:'',kind:'quote',query:'',tab:'all',status:'all',zoom:95,page:1,listCollapsed:false,infoOpen:true,mobileDocument:false,editingComment:'',busy:false,modal:null,pdfUrls:new Map(),pdfLoading:new Set(),pdfGenerating:new Set(),pdfTried:new Set(),pdfAttempts:new Map(),pdfRetryTimers:new Map(),draftPdfUrls:new Map(),draftPdfLoading:new Set(),draftPdfErrors:new Map()};

 const state=()=>app()?.getState?.();
 const esc=value=>global.PilozCommercialV2?.esc?.(value)??String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
 const money=(value,currency='EUR')=>{try{return new Intl.NumberFormat('fr-FR',{style:'currency',currency:currency||'EUR'}).format(Number(value)||0);}catch{return`${Number(value||0).toFixed(2)} €`;}};
 const date=value=>{if(!value)return'—';const parsed=new Date(String(value).length===10?value+'T12:00:00':value);return Number.isNaN(parsed.valueOf())?'—':new Intl.DateTimeFormat('fr-FR').format(parsed);};
 const datetime=value=>{if(!value)return'—';const parsed=new Date(value);return Number.isNaN(parsed.valueOf())?'—':new Intl.DateTimeFormat('fr-FR',{dateStyle:'medium',timeStyle:'short'}).format(parsed);};
 const userId=()=>global.PilozRuntime?.session?.user_id||'';
 const notify=(message,kind='info')=>{global.toast?.(message);const live=document.getElementById('document-viewer-live');if(live){live.textContent=message;live.dataset.kind=kind;}};
 const isMissingRpc=error=>['PGRST202','42883'].includes(String(error?.code||''))||/function .* does not exist|schema cache/i.test(String(error?.message||''));
 const documentKind=doc=>doc?.document_type==='quote'?'quote':invoiceTypes.has(doc?.document_type)?'invoice':'quote';
 const documentNumber=doc=>doc?.number||'Brouillon';
 const isFinalized=doc=>!!(doc?.finalized_at||doc?.validated_at||doc?.locked_at)||['finalized','validated','sent','overdue','partially_paid','paid'].includes(doc?.status);
 const clientName=client=>client?.legal_name||client?.trade_name||[client?.first_name,client?.last_name].filter(Boolean).join(' ')||'Client non renseigné';
 const clientFor=(data,id)=>data.clients?.find(client=>client.id===id)||null;
 const statusBadge=value=>{const [label,tone]=statusMeta[value]||[String(value||'Brouillon').replaceAll('_',' '),'neutral'];return`<span class="document-viewer-status ${tone}">${esc(label)}</span>`;};
 const iconButton=(label,icon,handler,attrs='')=>`<button type="button" class="document-viewer-icon-button" aria-label="${esc(label)}" title="${esc(label)}" onclick="${handler}" ${attrs}>${icon}</button>`;
 const actionButton=(label,handler,kind='secondary',attrs='')=>`<button type="button" class="document-viewer-action ${kind}" onclick="${handler}" ${attrs}>${esc(label)}</button>`;
 const hashPath=()=>String(location.hash||'').slice(1).split('?')[0];
 const hashParams=()=>new URLSearchParams(String(location.hash||'').split('?')[1]||'');

 function documentsFor(data,kind=ui.kind){
  return(data.documents||[]).filter(doc=>kind==='quote'?doc.document_type==='quote':invoiceTypes.has(doc.document_type));
 }
 function paymentIsConfirmed(row){return!row.status||['confirmed','completed','paid'].includes(row.status);}
 function paymentRows(data,id){return(data.payments||[]).filter(row=>row.document_id===id&&paymentIsConfirmed(row)).sort((a,b)=>String(b.paid_at).localeCompare(String(a.paid_at)));}
 function paymentHistory(data,id){return(data.payments||[]).filter(row=>row.document_id===id).sort((a,b)=>String(b.paid_at||b.created_at).localeCompare(String(a.paid_at||a.created_at)));}
 function paidFor(data,id){return paymentRows(data,id).reduce((total,row)=>total+Number(row.amount||0),0);}
 function remainingFor(data,doc){return Math.max(0,Number(doc?.total_incl_tax||0)-paidFor(data,doc?.id));}
 function latestSnapshot(data,doc){
  const rows=(data.documentSnapshots||[]).filter(row=>row.document_id===doc?.id).sort((a,b)=>Number(b.snapshot_version||0)-Number(a.snapshot_version||0)||String(b.created_at).localeCompare(String(a.created_at)));
  return rows.find(row=>row.id===doc?.snapshot_id)||rows[0]||null;
 }
 function snapshotContext(data,doc){
  const snapshot=latestSnapshot(data,doc),payload=snapshot?.public_payload&&typeof snapshot.public_payload==='string'?safeJson(snapshot.public_payload):snapshot?.public_payload;
  if(payload&&typeof payload==='object')return{snapshot,document:payload.document||doc,lines:Array.isArray(payload.lines)?payload.lines:[],issuer:payload.issuer||{},client:payload.client||clientFor(data,doc.client_id)||{},settings:payload.document_settings||{},frozen:true};
  return{snapshot,document:doc,lines:(data.lines||[]).filter(line=>line.document_id===doc.id).sort((a,b)=>Number(a.position)-Number(b.position)),issuer:data.settings?.[0]||{},client:clientFor(data,doc.client_id)||{},settings:data.docSettings?.[0]||{},frozen:false};
 }
 function safeJson(value){try{return JSON.parse(value);}catch{return null;}}
 function activeDocument(data){return(data.documents||[]).find(doc=>doc.id===ui.id)||null;}
 function ensureActive(data){
   const params=hashParams(),requested=params.get('id');
   if(requested&&(data.documents||[]).some(doc=>doc.id===requested)){if(ui.id!==requested)ui.mobileDocument=true;ui.id=requested;}
   let doc=activeDocument(data);
   if(doc)ui.kind=documentKind(doc);
   if(!doc){const requestedKind=params.get('type');if(['quote','invoice'].includes(requestedKind))ui.kind=requestedKind;ui.id='';}
   return doc;
  }
 function updateHash(id,replace=true){
  const doc=(state()?.data?.documents||[]).find(row=>row.id===id),kind=documentKind(doc),target=`#document-viewer?id=${encodeURIComponent(id)}&type=${kind}`;
  if(location.hash===target)return;
  if(replace)history.replaceState(null,'',target);else location.hash=target;
 }

 function quoteTab(doc,tab){
  if(tab==='all')return true;
  if(tab==='pending')return['draft','to_finalize','finalized','validated','to_send','sent','viewed','pending'].includes(doc.status);
  if(tab==='accepted')return['accepted','invoiced','partially_invoiced'].includes(doc.status);
  if(tab==='rejected')return doc.status==='rejected';
  return['expired','archived','cancelled'].includes(doc.status);
 }
 function invoiceTab(data,doc,tab){
  const remaining=remainingFor(data,doc),today=new Date().toISOString().slice(0,10);
  if(tab==='all')return true;
  if(tab==='todo')return['draft','to_finalize','finalized','validated','to_send','sent'].includes(doc.status)&&remaining>0;
  if(tab==='upcoming')return remaining>0&&!!doc.due_date&&doc.due_date>=today;
  if(tab==='overdue')return remaining>0&&((doc.due_date&&doc.due_date<today)||doc.status==='overdue');
  return remaining<=0||doc.status==='paid';
 }
 function filteredDocuments(data){
  const query=ui.query.trim().toLocaleLowerCase('fr'),rows=documentsFor(data).filter(doc=>{
   const client=clientFor(data,doc.client_id),matchesTab=ui.kind==='quote'?quoteTab(doc,ui.tab):invoiceTab(data,doc,ui.tab),matchesStatus=ui.status==='all'||doc.status===ui.status;
   const haystack=[documentNumber(doc),doc.subject,clientName(client),client?.email,doc.status].join(' ').toLocaleLowerCase('fr');
   return matchesTab&&matchesStatus&&(!query||haystack.includes(query));
  });
  return rows.sort((a,b)=>String(b.issue_date||b.created_at).localeCompare(String(a.issue_date||a.created_at)));
 }
 function tabDefinitions(data){
  return ui.kind==='quote'?[['all','Tous'],['pending','En attente'],['accepted','Acceptés'],['rejected','Refusés'],['more','Plus']]:[['all','Toutes'],['todo','À traiter'],['upcoming','À venir'],['overdue','En retard'],['paid','Encaissées']];
 }
 function tabCount(data,key){return documentsFor(data).filter(doc=>ui.kind==='quote'?quoteTab(doc,key):invoiceTab(data,doc,key)).length;}
 function setTab(tab){ui.tab=tab;renderViewer(state());}
 function setStatus(status){ui.status=status;renderViewer(state());}
 function search(value){ui.query=value;renderViewer(state());requestAnimationFrame(()=>{const input=document.querySelector('[data-document-viewer-search]');if(input){input.focus();input.setSelectionRange(value.length,value.length);}});}
 function renderList(data){
  const rows=filteredDocuments(data),all=documentsFor(data),statuses=[...new Set(all.map(row=>row.status).filter(Boolean))];
  return`<aside class="document-viewer-list" aria-label="Liste des ${ui.kind==='quote'?'devis':'factures'}">
   <header><div><h1>${ui.kind==='quote'?'Devis':'Factures clients'}</h1><span>${all.length} document${all.length>1?'s':''}</span></div>${actionButton(ui.kind==='quote'?'Créer un devis':'Créer une facture',`PilozDocumentViewerV2.create('${ui.kind}')`,'primary')}</header>
   <div class="document-viewer-search-row"><label><span class="sr-only">Rechercher</span><b aria-hidden="true">⌕</b><input data-document-viewer-search type="search" value="${esc(ui.query)}" placeholder="Rechercher…" oninput="PilozDocumentViewerV2.search(this.value)"></label><select aria-label="Filtrer par statut" onchange="PilozDocumentViewerV2.setStatus(this.value)"><option value="all">Tous les statuts</option>${statuses.map(value=>`<option value="${esc(value)}" ${ui.status===value?'selected':''}>${esc(statusMeta[value]?.[0]||value)}</option>`).join('')}</select></div>
   <nav class="document-viewer-tabs" aria-label="Filtres principaux">${tabDefinitions(data).map(([key,label])=>`<button type="button" class="${ui.tab===key?'active':''}" aria-pressed="${ui.tab===key}" onclick="PilozDocumentViewerV2.setTab('${key}')"><span>${esc(label)}</span><small>${tabCount(data,key)}</small></button>`).join('')}</nav>
   <div class="document-viewer-list-scroll">${rows.length?rows.map(doc=>renderListItem(data,doc)).join(''):`<div class="document-viewer-list-empty"><b>Aucun document</b><span>Modifiez les filtres ou créez un nouveau ${ui.kind==='quote'?'devis':'document'}.</span></div>`}</div>
   <footer><span>${rows.length} sur ${all.length}</span><span>Données Supabase</span></footer>
  </aside>`;
 }
  function renderListItem(data,doc){
   const client=clientFor(data,doc.client_id),active=doc.id===ui.id,remaining=ui.kind==='invoice'?remainingFor(data,doc):null;
   return`<button type="button" class="document-viewer-list-item ${active?'active':''}" aria-current="${active?'true':'false'}" onclick="PilozDocumentViewerV2.select('${doc.id}')"><span class="document-viewer-list-item-number">${esc(documentNumber(doc))}</span><span class="document-viewer-list-item-top"><b>${esc(clientName(client))}</b><strong>${money(doc.total_incl_tax,doc.currency)}</strong></span><span class="document-viewer-list-item-sub"><span>${date(ui.kind==='quote'?(doc.validity_date||doc.issue_date):(doc.due_date||doc.issue_date))}</span>${statusBadge(doc.status)}</span>${remaining!==null&&remaining>0&&remaining<Number(doc.total_incl_tax||0)?`<small>Reste ${money(remaining,doc.currency)}</small>`:''}<i aria-hidden="true"></i></button>`;
  }

 function lineAmount(line){if(line.total_excl_tax!==null&&line.total_excl_tax!==undefined)return Number(line.total_excl_tax)||0;return(Number(line.quantity)||0)*(Number(line.unit_price)||0)*(1-(Number(line.discount_rate)||0)/100);}
 function pageCount(context){const content=context.lines.filter(line=>line.line_type!=='page_break'),breaks=context.lines.filter(line=>line.line_type==='page_break').length;return Math.max(1,Math.ceil(content.length/18)+breaks);}
 function publicLineRows(lines){
  return lines.map(line=>{
   if(line.line_type==='page_break')return'';
   if(['title','subtitle','section','text','comment','subtotal'].includes(line.line_type))return`<tr class="document-snapshot-structural ${esc(line.line_type)}"><td colspan="5"><b>${esc(line.name||line.description||'')}</b></td></tr>`;
   return`<tr><td><b>${esc(line.name||'Désignation')}</b>${line.description?`<small>${esc(line.description)}</small>`:''}${line.optional?'<em>Option</em>':''}</td><td>${Number(line.quantity||0).toLocaleString('fr-FR')} ${esc(line.unit||'')}</td><td>${money(line.unit_price)}</td><td>${Number(line.tax_rate||0).toLocaleString('fr-FR')} %</td><td>${money(lineAmount(line))}</td></tr>`;
  }).join('');
 }
 function renderFallbackPage(context,page){
  const d=context.document||{},issuer=context.issuer||{},client=context.client||{},lines=context.lines.filter(line=>line.line_type!=='page_break'),count=pageCount(context),start=(page-1)*18,pageLines=lines.slice(start,start+18),isLast=page>=count;
  const issuerAddress=[issuer.address_line1||issuer.address_line_1,issuer.address_line2||issuer.address_line_2,issuer.postal_code,issuer.city].filter(Boolean).join(', '),clientAddress=[client.address_line_1,client.address_line_2,client.postal_code,client.city].filter(Boolean).join(', ');
  return`<article class="document-snapshot-paper" aria-label="Aperçu ${context.frozen?'figé':'HTML'} page ${page}">
   <header class="document-snapshot-head"><div>${context.frozen?'<span>Aperçu figé</span>':'<span>Aperçu de travail</span>'}<h2>${esc(typeLabels[d.document_type]||'Document')}</h2><b>${esc(d.number||'Brouillon')}</b></div><address><strong>${esc(issuer.legal_name||issuer.trade_name||'Votre entreprise')}</strong><span>${esc(issuerAddress)}</span><span>${esc(issuer.email||'')}</span><span>${esc(issuer.phone_e164||'')}</span>${issuer.siret?`<span>SIRET ${esc(issuer.siret)}</span>`:''}</address></header>
   <section class="document-snapshot-meta"><dl><dt>Date d’émission</dt><dd>${date(d.issue_date)}</dd><dt>${d.document_type==='quote'?'Date de validité':'Date d’échéance'}</dt><dd>${date(d.document_type==='quote'?d.validity_date:d.due_date)}</dd>${d.subject?`<dt>Objet</dt><dd>${esc(d.subject)}</dd>`:''}</dl><address><small>Destinataire</small><strong>${esc(clientName(client))}</strong><span>${esc(clientAddress)}</span>${client.siret?`<span>SIRET ${esc(client.siret)}</span>`:''}${client.vat_number?`<span>TVA ${esc(client.vat_number)}</span>`:''}</address></section>
   <table class="document-snapshot-lines"><thead><tr><th>Désignation</th><th>Qté</th><th>Prix u. HT</th><th>TVA</th><th>Total HT</th></tr></thead><tbody>${publicLineRows(pageLines)}</tbody></table>
   ${isLast?`<section class="document-snapshot-total"><dl><dt>Total HT</dt><dd>${money(d.total_excl_tax,d.currency)}</dd><dt>TVA</dt><dd>${money(d.total_tax,d.currency)}</dd><dt>Total TTC</dt><dd>${money(d.total_incl_tax,d.currency)}</dd></dl></section><footer><p>${esc(d.public_notes||context.settings.visible_mention||'')}</p><small>${esc(d.payment_terms||'')} ${d.payment_method?'· '+esc(d.payment_method):''}</small></footer>`:''}
   <span class="document-snapshot-page-number">${page} / ${count}</span>
  </article>`;
 }
 function pdfPath(doc,snapshot){return snapshot?.pdf_storage_path||doc?.final_pdf_path||'';}
 async function ensurePdfUrl(doc,snapshot){
  const path=pdfPath(doc,snapshot);if(!path||ui.pdfUrls.has(path)||ui.pdfLoading.has(path))return;
  ui.pdfLoading.add(path);
  try{const result=await api().signedUrl('company-files',path,3600),url=result?.signedURL||result?.signedUrl||result?.url;if(url)ui.pdfUrls.set(path,url);}
  catch(error){console.error('[PILOZ Documents] PDF final indisponible',{code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});}
  finally{ui.pdfLoading.delete(path);if(activeDocument(state()?.data||{})?.id===doc.id)renderViewer(state());}
 }
 function schedulePdfRetry(key,doc,snapshot,retryAt){const attempts=ui.pdfAttempts.get(key)||1;if(attempts>=3){ui.pdfTried.add(key);return;}ui.pdfTried.add(key);const requested=Date.parse(retryAt||''),delay=Number.isFinite(requested)?Math.min(60000,Math.max(2000,requested-Date.now())):3000;clearTimeout(ui.pdfRetryTimers.get(key));ui.pdfRetryTimers.set(key,setTimeout(()=>{ui.pdfRetryTimers.delete(key);ui.pdfTried.delete(key);if(activeDocument(state()?.data||{})?.id===doc.id)ensurePdfGenerated(doc,snapshot);},delay));}
 async function ensurePdfGenerated(doc,snapshot){
  const key=snapshot?.id;if(!key||pdfPath(doc,snapshot)||ui.pdfGenerating.has(key)||ui.pdfTried.has(key)||!(doc?.finalized_at||doc?.validated_at||doc?.locked_at||doc?.document_type==='quote'))return;
  ui.pdfGenerating.add(key);ui.pdfAttempts.set(key,(ui.pdfAttempts.get(key)||0)+1);let retry=false;
  try{const result=await api().invoke('generate-document-pdf',{documentId:doc.id});if(result?.ready){ui.pdfTried.add(key);ui.pdfAttempts.delete(key);await app().refresh();}else{retry=true;schedulePdfRetry(key,doc,snapshot,result?.retryAt);}}
  catch(error){console.warn('[PILOZ PDF] Génération différée',{code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});retry=true;schedulePdfRetry(key,doc,snapshot,error?.retryAt);}
  finally{ui.pdfGenerating.delete(key);if(!retry)ui.pdfTried.add(key);if(activeDocument(state()?.data||{})?.id===doc.id)renderViewer(state());}
 }
 function draftPdfFingerprint(data,doc){const lines=(data.lines||[]).filter(line=>line.document_id===doc.id),lastLine=lines.reduce((latest,line)=>String(line.updated_at||'')>latest?String(line.updated_at):latest,'');return[doc.updated_at||'',doc.template_id||'',doc.total_incl_tax||0,lines.length,lastLine].join('|');}
 async function ensureDraftPdf(doc){const current=state(),data=current?.data||{};if(!doc?.id||!invoiceTypes.has(doc.document_type)||isFinalized(doc)||ui.draftPdfLoading.has(doc.id))return;const fingerprint=draftPdfFingerprint(data,doc),cached=ui.draftPdfUrls.get(doc.id);if(cached?.fingerprint===fingerprint)return;ui.draftPdfLoading.add(doc.id);ui.draftPdfErrors.delete(doc.id);try{const context=snapshotContext(data,doc),totals=calc().document(context.lines,doc.discount_rate),lines=context.lines.map((line,index)=>{const amounts=calc().line(line);return{position:index+1,line_type:line.line_type||'item',reference:line.reference||null,name:line.name||null,description:line.description||null,quantity:Number(line.quantity)||0,unit:line.unit||null,unit_price:Number(line.unit_price)||0,discount_rate:Number(line.discount_rate)||0,tax_rate:Number(line.tax_rate)||0,optional:!!line.optional,total_excl_tax:amounts.ht,total_tax:amounts.tax,total_incl_tax:amounts.ttc};}),documentPayload={document_type:doc.document_type,number:doc.number||null,issue_date:doc.issue_date||null,due_date:doc.due_date||null,validity_date:doc.validity_date||null,subject:doc.subject||null,currency:doc.currency||'EUR',language:doc.language||'fr',payment_terms:doc.payment_terms||null,payment_method:doc.payment_method||null,public_notes:doc.public_notes||null,discount_rate:Number(doc.discount_rate)||0,total_excl_tax:totals.ht,total_tax:totals.tax,total_incl_tax:totals.ttc,metadata:doc.metadata||{}},blob=await api().invokeBlob('generate-document-pdf',{preview:{companyId:current.companyId,clientId:doc.client_id||null,templateId:doc.template_id||null,document:documentPayload,lines}}),latest=activeDocument(state()?.data||{});if(!latest||latest.id!==doc.id||draftPdfFingerprint(state().data,latest)!==fingerprint)return;const previous=ui.draftPdfUrls.get(doc.id);if(previous?.url)URL.revokeObjectURL(previous.url);ui.draftPdfUrls.set(doc.id,{fingerprint,url:URL.createObjectURL(blob)});}catch(error){ui.draftPdfErrors.set(doc.id,error?.message||'Aperçu PDF indisponible.');console.error('[PILOZ Documents] Aperçu PDF du brouillon indisponible',{code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});}finally{ui.draftPdfLoading.delete(doc.id);if(activeDocument(state()?.data||{})?.id===doc.id)renderViewer(state());}}
  function renderPreview(data,doc){
   const context=snapshotContext(data,doc),path=pdfPath(doc,context.snapshot),finalPdfUrl=path?ui.pdfUrls.get(path):'',draftPdf=!context.frozen&&!isFinalized(doc)?ui.draftPdfUrls.get(doc.id):null,pdfUrl=finalPdfUrl||draftPdf?.url||'',pages=pageCount(context);ui.page=Math.min(Math.max(1,ui.page),pages);
  if(path&&!pdfUrl&&!ui.pdfLoading.has(path))setTimeout(()=>ensurePdfUrl(doc,context.snapshot),0);
  if(!path&&context.frozen&&!ui.pdfGenerating.has(context.snapshot?.id)&&!ui.pdfTried.has(context.snapshot?.id))setTimeout(()=>ensurePdfGenerated(doc,context.snapshot),0);
  if(!path&&!context.frozen&&invoiceTypes.has(doc.document_type)&&!draftPdf&&!ui.draftPdfLoading.has(doc.id)&&!ui.draftPdfErrors.has(doc.id))setTimeout(()=>ensureDraftPdf(doc),0);
  const template=(data.templates||[]).find(row=>row.id===doc.template_id),status=finalPdfUrl?'PDF final':draftPdf?`PDF d’aperçu · ${template?.name||'modèle facture'}`:context.frozen?(path?'Chargement du PDF final…':'Aperçu figé — PDF en attente'):ui.draftPdfErrors.has(doc.id)?'Aperçu PDF indisponible':'Génération de l’aperçu PDF…';
   return`<main class="document-viewer-preview" aria-label="Aperçu du document"><header class="document-viewer-preview-head"><div class="document-viewer-preview-identity">${iconButton('Replier ou afficher la liste','☰','PilozDocumentViewerV2.toggleList()')}<button type="button" class="document-viewer-mobile-back" onclick="PilozDocumentViewerV2.clearSelection()">← Liste</button><b>${esc(documentNumber(doc))}</b><span>${esc(status)}</span></div><nav class="document-viewer-pdf-controls" aria-label="Contrôles PDF">${iconButton('Page précédente','←','PilozDocumentViewerV2.changePage(-1)',ui.page<=1?'disabled':'')}<span><b>${ui.page}</b> / ${pages}</span>${iconButton('Page suivante','→','PilozDocumentViewerV2.changePage(1)',ui.page>=pages?'disabled':'')}${iconButton('Zoom arrière','−','PilozDocumentViewerV2.changeZoom(-10)',ui.zoom<=50?'disabled':'')}<span>${ui.zoom} %</span>${iconButton('Zoom avant','+','PilozDocumentViewerV2.changeZoom(10)',ui.zoom>=200?'disabled':'')}${iconButton('Télécharger','⇩','PilozDocumentViewerV2.download()')}${iconButton('Imprimer','⎙','PilozDocumentViewerV2.print()')}${iconButton('Plein écran','⛶','PilozDocumentViewerV2.fullscreen()')}</nav><div class="document-viewer-preview-actions">${actionButton('Informations','PilozDocumentViewerV2.toggleInfo()','secondary')}${iconButton('Fermer le document','×','PilozDocumentViewerV2.clearSelection()')}</div></header>
    <div class="document-viewer-stage" id="document-viewer-stage">${pdfUrl?`<iframe title="${finalPdfUrl?'PDF final':'Aperçu PDF'} ${esc(documentNumber(doc))}" src="${esc(pdfUrl)}#page=${ui.page}&zoom=${ui.zoom}&toolbar=0&navpanes=0"></iframe>`:`<div class="document-viewer-fallback-notice ${context.frozen?'frozen':''}"><b>${context.frozen?'Le contenu figé reste consultable.':ui.draftPdfErrors.has(doc.id)?'Aperçu temporairement indisponible':'Préparation du PDF avec le modèle sélectionné'}</b><span>${context.frozen?'Le PDF final sera utilisé automatiquement dès qu’il sera disponible.':ui.draftPdfErrors.get(doc.id)||'Le document va apparaître automatiquement.'}</span></div>${context.frozen?`<div class="document-viewer-zoom-wrap" style="--viewer-scale:${ui.zoom/100}"><div>${renderFallbackPage(context,ui.page)}</div></div>`:''}`}</div>
   </main>`;
  }

 function linkedDocuments(data,doc){
  const map=new Map(),links=(data.documentLinks||[]).filter(link=>link.source_document_id===doc.id||link.target_document_id===doc.id);
  links.forEach(link=>{const id=link.source_document_id===doc.id?link.target_document_id:link.source_document_id,target=(data.documents||[]).find(row=>row.id===id);if(target)map.set(id,{doc:target,label:linkLabels[link.link_type]||typeLabels[target.document_type]||'Document'});});
  (data.documents||[]).filter(row=>row.source_document_id===doc.id||doc.source_document_id===row.id).forEach(target=>map.set(target.id,{doc:target,label:typeLabels[target.document_type]||'Document'}));
  return[...map.values()];
 }
 function quoteInvoiced(data,doc){return linkedDocuments(data,doc).filter(item=>invoiceTypes.has(item.doc.document_type)&&item.doc.document_type!=='credit_note').reduce((sum,item)=>sum+Number(item.doc.total_incl_tax||0),0);}
 function quoteHasActiveInvoice(data,doc){return(data.documentLinks||[]).some(link=>link.source_document_id===doc.id&&['invoice','deposit','progress','balance'].includes(link.link_type)&&(data.documents||[]).some(row=>row.id===link.target_document_id&&!['cancelled','archived'].includes(row.status)));}
 function renderLinks(data,doc){
  const rows=linkedDocuments(data,doc),payments=paymentRows(data,doc.id);
  return`<section class="document-viewer-side-section"><header><h3>Documents liés</h3><span>${rows.length+payments.length}</span></header><div class="document-viewer-related">${rows.map(({doc:target,label})=>`<button type="button" onclick="PilozDocumentViewerV2.select('${target.id}')"><span><small>${esc(label)}</small><b>${esc(documentNumber(target))}</b></span><strong>${money(target.total_incl_tax,target.currency)}</strong></button>`).join('')}${payments.map(row=>`<div><span><small>Paiement · ${date(row.paid_at)}</small><b>${esc(row.reference||row.payment_method||'Paiement')}</b></span><strong>${money(row.amount,row.currency||doc.currency)}</strong></div>`).join('')}${!rows.length&&!payments.length?'<p>Aucun document lié.</p>':''}</div></section>`;
 }
 function memberName(data,id){const member=(data.members||[]).find(row=>row.user_id===id);if(id===userId())return'Vous';return member?.profile?.first_name||member?.first_name||member?.email||`Utilisateur ${String(id||'').slice(0,8)}`;}
 function canEditComment(data,row){const role=(data.members||[]).find(member=>member.user_id===userId())?.role;return row.created_by===userId()||['owner','admin'].includes(role);}
 function commentsFor(data,id){return(data.documentComments||[]).filter(row=>row.document_id===id).sort((a,b)=>String(a.created_at).localeCompare(String(b.created_at)));}
 function renderComments(data,doc){
  const comments=commentsFor(data,doc.id),editing=comments.find(row=>row.id===ui.editingComment),members=data.members||[];
  return`<section class="document-viewer-side-section document-viewer-comments"><header><h3>Commentaires internes</h3><span>${comments.filter(row=>!row.deleted_at).length}</span></header><p class="document-viewer-private-hint">Visibles uniquement par votre équipe. Jamais inclus dans le PDF.</p><div class="document-viewer-comment-list">${comments.map(row=>`<article class="${row.deleted_at?'deleted':''}"><header><b>${esc(memberName(data,row.created_by))}</b><time>${datetime(row.created_at)}</time></header><p>${esc(row.body)}</p>${row.mentioned_user_ids?.length?`<small>${row.mentioned_user_ids.map(id=>'@'+memberName(data,id)).map(esc).join(' ')}</small>`:''}${row.edited_at?'<em>modifié</em>':''}${canEditComment(data,row)&&!row.deleted_at?`<footer><button type="button" onclick="PilozDocumentViewerV2.editComment('${row.id}')">Modifier</button><button type="button" onclick="PilozDocumentViewerV2.deleteComment('${row.id}')">Supprimer</button></footer>`:''}</article>`).join('')||'<p class="document-viewer-comment-empty">Aucun commentaire interne.</p>'}</div><form id="document-viewer-comment-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.saveComment()"><label><span>${editing?'Modifier le commentaire':'Ajouter une note'}</span><textarea name="body" maxlength="4000" required placeholder="Note interne, décision, information utile…">${esc(editing?.body||'')}</textarea></label><details><summary>Mentionner un membre</summary><div>${members.map(member=>`<label><input type="checkbox" name="mentioned_user_ids" value="${member.user_id}" ${(editing?.mentioned_user_ids||[]).includes(member.user_id)?'checked':''}><span>@${esc(memberName(data,member.user_id))}</span></label>`).join('')||'<span>Aucun autre membre.</span>'}</div></details><footer>${editing?`<button type="button" onclick="PilozDocumentViewerV2.cancelCommentEdit()">Annuler</button>`:''}<button type="submit" ${ui.busy?'disabled':''}>${editing?'Enregistrer':'Publier'}</button></footer></form></section>`;
 }
 function renderPayments(data,doc){
  const rows=paymentHistory(data,doc.id),paid=paidFor(data,doc.id),remaining=remainingFor(data,doc);
  return`<section class="document-viewer-side-section document-viewer-payment"><header><h3>Paiement</h3>${statusBadge(remaining<=0?'paid':paid>0?'partially_paid':doc.status)}</header><dl><dt>Montant encaissé</dt><dd>${money(paid,doc.currency)}</dd><dt>Reste à payer</dt><dd>${money(remaining,doc.currency)}</dd></dl><div class="document-viewer-payment-actions">${remaining>0?actionButton('Enregistrer un paiement partiel',`PilozDocumentViewerV2.openPayment('partial')`,'secondary')+actionButton('Enregistrer le paiement total',`PilozDocumentViewerV2.openPayment('total')`,'primary'):''}</div><div class="document-viewer-payment-history">${rows.map(row=>{const cancelled=['cancelled','reversed','void'].includes(row.status),confirmed=paymentIsConfirmed(row);return`<article class="${cancelled?'cancelled':''}"><span><b>${money(row.amount,row.currency||doc.currency)}</b><small>${date(row.paid_at)} · ${esc(row.payment_method||'Mode non renseigné')}</small>${row.comment?`<small>${esc(row.comment)}</small>`:''}${row.cancellation_reason?`<small>Motif : ${esc(row.cancellation_reason)}</small>`:''}</span><em>${cancelled?'Annulé':esc(row.reference||'Confirmé')}</em>${confirmed?`<button type="button" onclick="PilozDocumentViewerV2.openPaymentCancellation('${row.id}')">Annuler</button>`:''}</article>`;}).join('')||'<p>Aucun paiement enregistré.</p>'}</div></section>`;
 }
 function renderQuoteActions(data,doc){
  const invoiced=quoteInvoiced(data,doc),remaining=Math.max(0,Number(doc.total_incl_tax||0)-invoiced),locked=quoteHasActiveInvoice(data,doc);
  return`<section class="document-viewer-primary-actions"><details><summary class="document-viewer-action primary">Convertir en…</summary><div><button type="button" onclick="PilozDocumentViewerV2.convert('invoice')">Facture standard</button><button type="button" onclick="PilozDocumentViewerV2.convert('deposit_invoice')">Facture d’acompte</button><button type="button" onclick="PilozDocumentViewerV2.convert('progress_invoice')">Facture de situation</button><button type="button" onclick="PilozDocumentViewerV2.convert('balance_invoice')">Facture de solde</button></div></details>${locked?actionButton('Modifier via une nouvelle version','PilozDocumentViewerV2.appAction(\'newDocumentVersion\')','secondary'):actionButton('Modifier','PilozDocumentViewerV2.appAction(\'edit\')','secondary')}${actionButton('Envoyer','PilozDocumentViewerV2.appAction(\'openSendDocument\')','secondary')}<dl><dt>Déjà facturé</dt><dd>${money(invoiced,doc.currency)}</dd><dt>Reste à facturer</dt><dd>${money(remaining,doc.currency)}</dd></dl></section>`;
 }
  function renderInvoiceActions(data,doc){
   const remaining=remainingFor(data,doc);
   if(!isFinalized(doc))return`<section class="document-viewer-primary-actions document-viewer-draft-actions">${actionButton('Modifier le brouillon','PilozDocumentViewerV2.appAction(\'edit\')','secondary')}${actionButton('Finaliser la facture','PilozDocumentViewerV2.openFinalization()','primary')}${actionButton('Télécharger l’aperçu','PilozDocumentViewerV2.download()','secondary')}${actionButton('Dupliquer','PilozDocumentViewerV2.appAction(\'duplicateDocument\')','secondary')}${actionButton('Supprimer le brouillon','PilozDocumentViewerV2.deleteDraft()','danger')}</section>`;
   return`<section class="document-viewer-primary-actions">${actionButton('Envoyer','PilozDocumentViewerV2.appAction(\'openSendDocument\')','primary')}${remaining>0?actionButton('Enregistrer un paiement partiel',`PilozDocumentViewerV2.openPayment('partial')`,'secondary')+actionButton('Enregistrer le paiement total',`PilozDocumentViewerV2.openPayment('total')`,'secondary'):''}${actionButton('Relancer le client','PilozDocumentViewerV2.appAction(\'createReminder\')','secondary')}${actionButton('Créer un avoir','PilozDocumentViewerV2.openCredit()','secondary')}</section>`;
  }
  function renderSide(data,doc){
   const client=clientFor(data,doc.client_id),isQuote=doc.document_type==='quote',finalized=isFinalized(doc),paid=paidFor(data,doc.id),remaining=isQuote?Math.max(0,Number(doc.total_incl_tax||0)-quoteInvoiced(data,doc)):remainingFor(data,doc),utility=isQuote||finalized?`<div class="document-viewer-utility-actions">${actionButton('Télécharger','PilozDocumentViewerV2.download()','ghost')}${actionButton('Imprimer','PilozDocumentViewerV2.print()','ghost')}${actionButton('Dupliquer','PilozDocumentViewerV2.appAction(\'duplicateDocument\')','ghost')}${actionButton('Archiver','PilozDocumentViewerV2.archive()','ghost')}</div>`:'';
   return`<aside class="document-viewer-side" aria-label="Informations et actions"><header><div><small>${esc(typeLabels[doc.document_type]||'Document')}</small><b>${esc(documentNumber(doc))}</b></div>${iconButton('Fermer le panneau','×','PilozDocumentViewerV2.toggleInfo()')}</header><section class="document-viewer-side-summary"><strong>${money(doc.total_incl_tax,doc.currency)}</strong><span>dont ${money(doc.total_tax,doc.currency)} de TVA</span><dl><dt>Client</dt><dd>${esc(clientName(client))}</dd><dt>Date d’émission</dt><dd>${date(doc.issue_date)}</dd><dt>${isQuote?'Date de validité':'Date d’échéance'}</dt><dd>${date(isQuote?doc.validity_date:doc.due_date)}</dd><dt>Numéro</dt><dd>${esc(documentNumber(doc))}</dd><dt>Statut</dt><dd>${statusBadge(doc.status)}</dd>${!isQuote?`<dt>Encaissé</dt><dd>${money(paid,doc.currency)}</dd>`:''}<dt>${isQuote?'Reste à facturer':'Reste à payer'}</dt><dd>${money(remaining,doc.currency)}</dd></dl></section>${isQuote?renderQuoteActions(data,doc):renderInvoiceActions(data,doc)}${utility}${!isQuote&&finalized?renderPayments(data,doc):''}${renderLinks(data,doc)}${renderComments(data,doc)}</aside>`;
  }

 function progressRows(data,doc){
  const targetIds=new Set((data.documentLinks||[]).filter(link=>link.source_document_id===doc.id&&link.link_type==='progress').map(link=>link.target_document_id)),previous=new Map();
  (data.lines||[]).filter(line=>targetIds.has(line.document_id)&&line.source_line_id).forEach(line=>previous.set(line.source_line_id,Math.max(previous.get(line.source_line_id)||0,Number(line.cumulative_progress_percent)||0)));
  return(data.lines||[]).filter(line=>line.document_id===doc.id&&['item','free_item','discount'].includes(line.line_type)&&!line.optional).sort((a,b)=>Number(a.position)-Number(b.position)).map(line=>({line,previous:previous.get(line.id)||0}));
 }

  function renderModal(data,doc){
   if(!ui.modal)return'';
   if(ui.modal.type==='finalize')return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal compact" role="dialog" aria-modal="true" aria-labelledby="document-viewer-finalize-title"><header><div><h2 id="document-viewer-finalize-title">Finaliser cette facture ?</h2><p>Vous êtes sur le point de finaliser votre facture <b>${esc(doc.number||'F-XXXX')}</b>.</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form onsubmit="event.preventDefault();PilozDocumentViewerV2.finalizeDraft()"><div class="document-viewer-finalize-warning"><b>Une facture finalisée n’est plus modifiable.</b><h3>Et si vous devez l’annuler ou la corriger ?</h3><p>Vous devrez émettre un avoir, conformément à la législation.</p></div><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Annuler</button><button type="submit" ${ui.busy?'disabled':''}>Finaliser la facture</button></footer></form></section></div>`;
   if(ui.modal.type==='payment'){
   const remaining=remainingFor(data,doc),methods=(data.paymentMethods||[]).filter(row=>row.active!==false),selected=doc.payment_method||methods.find(row=>row.is_default)?.code||methods[0]?.code||'';
   return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal" role="dialog" aria-modal="true" aria-labelledby="document-viewer-modal-title"><header><div><h2 id="document-viewer-modal-title">Enregistrer un paiement</h2><p>Le paiement sera lié à ${esc(documentNumber(doc))} et conservé dans l’historique.</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form id="document-viewer-payment-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.savePayment()"><label><span>Montant *</span><input name="amount" type="number" min="0.01" max="${remaining}" step="0.01" value="${ui.modal.mode==='total'?remaining:''}" required></label><label><span>Date *</span><input name="paid_at" type="date" value="${new Date().toISOString().slice(0,10)}" required></label><label><span>Mode de paiement *</span><select name="payment_method" required>${methods.length?methods.map(row=>`<option value="${esc(row.code||row.label)}" ${(row.code||row.label)===selected?'selected':''}>${esc(row.label||row.code)}</option>`).join(''):`<option value="${esc(selected||'Autre')}">${esc(selected||'Autre')}</option>`}</select></label><label><span>Référence</span><input name="reference" autocomplete="off"></label><label class="full"><span>Commentaire interne</span><textarea name="comment" maxlength="1000"></textarea></label><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Annuler</button><button type="submit" ${ui.busy?'disabled':''}>Enregistrer le paiement</button></footer></form></section></div>`;
  }
  if(ui.modal.type==='payment-cancellation')return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal compact" role="dialog" aria-modal="true"><header><div><h2>Annuler ce paiement ?</h2><p>Le paiement restera dans l’historique avec son motif d’annulation.</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form id="document-viewer-payment-cancellation-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.cancelPayment()"><label class="full"><span>Motif de l’annulation *</span><textarea name="reason" maxlength="1000" required></textarea></label><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Conserver le paiement</button><button type="submit">Annuler avec traçabilité</button></footer></form></section></div>`;
  if(ui.modal.type==='deposit'){
   const remaining=Math.max(0,Number(doc.total_incl_tax||0)-quoteInvoiced(data,doc));
   return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal compact" role="dialog" aria-modal="true"><header><div><h2>Créer une facture d’acompte</h2><p>Reste à facturer : ${money(remaining,doc.currency)}</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form id="document-viewer-conversion-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.saveConversion()"><label><span>Calcul de l’acompte</span><select name="deposit_mode" onchange="PilozDocumentViewerV2.setDepositMode(this.value)"><option value="percent">Pourcentage du devis</option><option value="amount">Montant TTC</option></select></label><label data-deposit-field="percent"><span>Pourcentage *</span><input name="deposit_percent" type="number" min="0.01" max="100" step="0.01" value="30"></label><label data-deposit-field="amount" hidden><span>Montant TTC *</span><input name="deposit_amount" type="number" min="0.01" max="${remaining}" step="0.01"></label><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Annuler</button><button type="submit">Créer le brouillon d’acompte</button></footer></form></section></div>`;
  }
  if(ui.modal.type==='progress'){
   const rows=progressRows(data,doc);
   return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal wide" role="dialog" aria-modal="true"><header><div><h2>Créer une facture de situation</h2><p>Indiquez l’avancement cumulé de chaque ligne à facturer.</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form id="document-viewer-conversion-form" class="document-viewer-progress-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.saveConversion()"><div class="document-viewer-progress-lines">${rows.map(({line,previous})=>`<label><span><b>${esc(line.name||'Ligne')}</b><small>Déjà facturé : ${previous.toLocaleString('fr-FR')} %</small></span><input name="progress_${line.id}" type="number" min="${Math.min(100,previous+.01)}" max="100" step="0.01" placeholder="${previous<100?'Nouveau %':'Terminé'}" ${previous>=100?'disabled':''}></label>`).join('')||'<p>Aucune ligne éligible.</p>'}</div><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Annuler</button><button type="submit" ${rows.every(row=>row.previous>=100)?'disabled':''}>Créer la facture de situation</button></footer></form></section></div>`;
  }
  if(ui.modal.type==='balance')return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal compact" role="dialog" aria-modal="true"><header><div><h2>Créer la facture de solde ?</h2><p>Le brouillon reprendra automatiquement le montant restant non facturé du devis.</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form id="document-viewer-conversion-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.saveConversion()"><div class="document-viewer-conversion-summary"><span>Montant du devis <b>${money(doc.total_incl_tax,doc.currency)}</b></span><span>Déjà facturé <b>${money(quoteInvoiced(data,doc),doc.currency)}</b></span><span>Solde estimé <b>${money(Math.max(0,Number(doc.total_incl_tax||0)-quoteInvoiced(data,doc)),doc.currency)}</b></span></div><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Annuler</button><button type="submit">Créer le brouillon de solde</button></footer></form></section></div>`;
  if(ui.modal.type==='credit')return`<div class="document-viewer-modal-backdrop" role="presentation" onclick="if(event.target===this)PilozDocumentViewerV2.closeModal()"><section class="document-viewer-modal compact" role="dialog" aria-modal="true"><header><div><h2>Créer un avoir</h2><p>La facture originale reste intacte. Un nouveau brouillon d’avoir sera créé et lié.</p></div>${iconButton('Fermer','×','PilozDocumentViewerV2.closeModal()')}</header><form id="document-viewer-credit-form" onsubmit="event.preventDefault();PilozDocumentViewerV2.saveCredit()"><label class="full"><span>Motif de l’avoir *</span><textarea name="reason" maxlength="1000" required placeholder="Erreur de facturation, annulation, geste commercial…"></textarea></label><p class="document-viewer-modal-help">L’avoir total reprend toutes les lignes. Vous pourrez ajuster son brouillon avant de le finaliser.</p><footer><button type="button" onclick="PilozDocumentViewerV2.closeModal()">Annuler</button><button type="submit">Créer l’avoir total</button></footer></form></section></div>`;
  return'';
 }
 function renderEmpty(kind){return`<section class="document-viewer-v2 empty"><div><h1>Aucun ${kind==='quote'?'devis':'document de facturation'}</h1><p>Créez un document pour utiliser la consultation en trois colonnes.</p>${actionButton(kind==='quote'?'Créer un devis':'Créer une facture',`PilozDocumentViewerV2.create('${kind}')`,'primary')}</div></section>`;}
  function renderViewer(runtimeState){
   const current=runtimeState||state(),data=current?.data||{},doc=ensureActive(data),main=document.getElementById('main');if(!main)return true;
   if(!doc){if(!documentsFor(data).length){main.innerHTML=renderEmpty(ui.kind);return true;}main.innerHTML=`<section class="document-viewer-v2 list-only"><div id="document-viewer-live" class="sr-only" aria-live="polite"></div><div class="document-viewer-shell">${renderList(data)}</div></section>`;return true;}
  if(!['all','pending','accepted','rejected','more','todo','upcoming','overdue','paid'].includes(ui.tab))ui.tab='all';
  main.innerHTML=`<section class="document-viewer-v2 ${ui.listCollapsed?'list-collapsed':''} ${ui.infoOpen?'info-open':''} ${ui.mobileDocument?'mobile-document':''}"><header class="document-viewer-topbar"><button type="button" onclick="PilozDocumentViewerV2.close()">← Retour aux ${ui.kind==='quote'?'devis':'factures'}</button><div><button type="button" onclick="PilozDocumentViewerV2.previousDocument()">← Précédent</button><b>${esc(documentNumber(doc))}</b><button type="button" onclick="PilozDocumentViewerV2.nextDocument()">Suivant →</button></div><div>${actionButton('Historique','PilozDocumentViewerV2.showHistory()','ghost')}${actionButton('Actions','PilozDocumentViewerV2.toggleInfo()','ghost')}</div></header><div id="document-viewer-live" class="sr-only" aria-live="polite"></div><div class="document-viewer-shell">${renderList(data)}${renderPreview(data,doc)}${renderSide(data,doc)}</div>${renderModal(data,doc)}</section>`;
  return true;
 }

 function select(id){const doc=(state()?.data?.documents||[]).find(row=>row.id===id);if(!doc)return;ui.id=id;ui.kind=documentKind(doc);ui.tab='all';ui.status='all';ui.page=1;ui.zoom=95;ui.mobileDocument=true;ui.infoOpen=true;updateHash(id);renderViewer(state());}
 function open(id){const data=state()?.data||{},doc=(data.documents||[]).find(row=>row.id===id);ui.id=id||'';if(doc)ui.kind=documentKind(doc);ui.mobileDocument=!!id;ui.infoOpen=true;ui.page=1;updateHash(id,false);if(hashPath()==='document-viewer')renderViewer(state());}
 function close(){app()?.go?.(ui.kind==='quote'?'sales/quotes':'sales/invoices');}
 function create(kind){app()?.newDocument?.(kind==='quote'?'quote':'invoice');}
 function toggleList(){ui.listCollapsed=!ui.listCollapsed;renderViewer(state());}
  function toggleInfo(){ui.infoOpen=!ui.infoOpen;renderViewer(state());}
  function clearSelection(){ui.id='';ui.mobileDocument=false;ui.infoOpen=false;history.replaceState(null,'',`#document-viewer?type=${ui.kind}`);renderViewer(state());}
  function backToList(){clearSelection();}
 function previousDocument(){const rows=filteredDocuments(state().data),index=rows.findIndex(row=>row.id===ui.id);if(index>0)select(rows[index-1].id);}
 function nextDocument(){const rows=filteredDocuments(state().data),index=rows.findIndex(row=>row.id===ui.id);if(index>=0&&index<rows.length-1)select(rows[index+1].id);}
 function changeZoom(delta){ui.zoom=Math.max(50,Math.min(200,ui.zoom+Number(delta||0)));renderViewer(state());}
 function changePage(delta){const doc=activeDocument(state().data),pages=pageCount(snapshotContext(state().data,doc));ui.page=Math.max(1,Math.min(pages,ui.page+Number(delta||0)));renderViewer(state());}
 function currentPdf(){const data=state().data,doc=activeDocument(data),snapshot=latestSnapshot(data,doc),path=pdfPath(doc,snapshot),draftUrl=doc&&!isFinalized(doc)?ui.draftPdfUrls.get(doc.id)?.url||'':'';return{doc,snapshot,path,url:ui.pdfUrls.get(path)||draftUrl,isDraftPreview:!!draftUrl};}
 function download(){const current=currentPdf();if(current.url){const link=document.createElement('a');link.href=current.url;link.download=`${documentNumber(current.doc)}${current.isDraftPreview?'-apercu':''}.pdf`;link.rel='noopener';document.body.appendChild(link);link.click();link.remove();return;}if(current.doc&&!isFinalized(current.doc)&&invoiceTypes.has(current.doc.document_type)){ensureDraftPdf(current.doc);notify('Le PDF d’aperçu est en cours de génération.','info');return;}notify('Le PDF final n’est pas encore disponible. L’aperçu imprimable a été ouvert.','info');print();}
 function printableHtml(context){return`<!doctype html><html lang="fr"><meta charset="utf-8"><title>${esc(documentNumber(context.document))}</title><style>body{margin:0;background:#fff;font:14px Arial;color:#111}.document-snapshot-paper{box-sizing:border-box;width:210mm;min-height:297mm;padding:18mm;margin:auto}address{font-style:normal;display:grid;gap:3px}.document-snapshot-head,.document-snapshot-meta{display:flex;justify-content:space-between;gap:30px}.document-snapshot-lines{width:100%;border-collapse:collapse;margin-top:28px}.document-snapshot-lines th,.document-snapshot-lines td{border-bottom:1px solid #ddd;padding:8px;text-align:right}.document-snapshot-lines th:first-child,.document-snapshot-lines td:first-child{text-align:left}.document-snapshot-lines small{display:block}.document-snapshot-total{display:flex;justify-content:flex-end}.document-snapshot-total dl{display:grid;grid-template-columns:130px 100px;gap:8px;text-align:right}@media print{.document-snapshot-paper{break-after:page}}</style>${Array.from({length:pageCount(context)},(_,index)=>renderFallbackPage(context,index+1)).join('')}</html>`;}
 function print(){
  const current=currentPdf();if(current.url){const frame=document.querySelector('.document-viewer-stage iframe');try{frame?.contentWindow?.print();return;}catch{const win=open(current.url,'_blank','noopener');win?.focus();return;}}
  const context=snapshotContext(state().data,current.doc),win=open('','_blank','width=1000,height=900');if(!win){notify('Autorisez les fenêtres contextuelles pour imprimer.','error');return;}win.document.open();win.document.write(printableHtml(context));win.document.close();setTimeout(()=>{win.focus();win.print();},250);
 }
 async function fullscreen(){const target=document.getElementById('document-viewer-stage');if(!target)return;try{if(document.fullscreenElement)await document.exitFullscreen();else await target.requestFullscreen();}catch{target.classList.toggle('document-viewer-pseudo-fullscreen');}}
 function openPayment(mode='partial'){ui.modal={type:'payment',mode};renderViewer(state());requestAnimationFrame(()=>document.querySelector('#document-viewer-payment-form input[name="amount"]')?.focus());}
 function openPaymentCancellation(id){ui.modal={type:'payment-cancellation',paymentId:id};renderViewer(state());requestAnimationFrame(()=>document.querySelector('#document-viewer-payment-cancellation-form textarea')?.focus());}
  function closeModal(){ui.modal=null;renderViewer(state());}
  function openFinalization(){const doc=activeDocument(state().data);if(!doc||doc.document_type==='quote'||isFinalized(doc))return;ui.modal={type:'finalize'};renderViewer(state());}
  async function finalizeDraft(){if(ui.busy)return;const doc=activeDocument(state().data);if(!doc||isFinalized(doc))return;ui.busy=true;try{ui.modal=null;app().editDocument(doc.id);const result=await app().finalizeCurrentDocument();if(!result)throw new Error('La finalisation a échoué. Le brouillon reste modifiable.');await app().refresh();open(result.id||doc.id);notify('Facture finalisée et PDF définitif demandé.','success');}catch(error){console.error('[PILOZ Documents] Finalisation depuis la consultation impossible',{code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});notify(error.message||'La finalisation a échoué. Le brouillon reste modifiable.','error');open(doc.id);}finally{ui.busy=false;}}
  async function deleteDraft(){const current=state(),doc=activeDocument(current.data);if(!doc||doc.document_type==='quote'||isFinalized(doc)||doc.status!=='draft')return;if(!confirm(`Supprimer définitivement le brouillon ${documentNumber(doc)} ?`))return;ui.busy=true;try{await api().request(`/rest/v1/documents?id=eq.${encodeURIComponent(doc.id)}&company_id=eq.${encodeURIComponent(current.companyId)}&status=eq.draft`,{method:'DELETE',headers:{Prefer:'return=minimal'}});await app().refresh();clearSelection();notify('Brouillon supprimé.','success');}catch(error){notify(error.message||'Ce brouillon ne peut pas être supprimé.','error');}finally{ui.busy=false;}}
 async function savePayment(){
  if(ui.busy)return;const form=document.getElementById('document-viewer-payment-form');if(!form?.reportValidity())return;const data=Object.fromEntries(new FormData(form)),doc=activeDocument(state().data),amount=Number(data.amount),remaining=remainingFor(state().data,doc);
  if(!doc||amount<=0||amount>remaining+0.01){notify('Le montant doit être positif et ne pas dépasser le reste à payer.','error');return;}
  ui.busy=true;form.querySelector('button[type="submit"]')?.setAttribute('disabled','');
  try{const params={target_document_id:doc.id,payment_amount:amount,payment_method:data.payment_method||null,payment_reference:data.reference||null,payment_date:new Date(data.paid_at+'T12:00:00').toISOString(),payment_comment:data.comment||null};let paymentId;try{paymentId=await api().rpc('record_document_payment_v2',params);}catch(error){if(!isMissingRpc(error))throw error;delete params.payment_comment;paymentId=await api().rpc('record_document_payment',params);}ui.modal=null;await app().refresh();notify('Paiement enregistré et solde recalculé.','success');return paymentId;}
  catch(error){console.error('[PILOZ Paiements] Enregistrement impossible',{code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});notify(error.message||'Le paiement n’a pas pu être enregistré.','error');}
  finally{ui.busy=false;}
 }
 async function cancelPayment(){if(ui.busy)return;const form=document.getElementById('document-viewer-payment-cancellation-form');if(!form?.reportValidity())return;const reason=String(new FormData(form).get('reason')||'').trim(),paymentId=ui.modal?.paymentId;if(!reason||!paymentId)return;ui.busy=true;try{await api().rpc('cancel_document_payment',{target_payment_id:paymentId,cancellation_reason:reason});ui.modal=null;await app().refresh();notify('Paiement annulé avec traçabilité.','success');}catch(error){notify(error.message||'Le paiement n’a pas pu être annulé.','error');}finally{ui.busy=false;}}
 function editComment(id){ui.editingComment=id;renderViewer(state());requestAnimationFrame(()=>document.querySelector('#document-viewer-comment-form textarea')?.focus());}
 function cancelCommentEdit(){ui.editingComment='';renderViewer(state());}
 async function saveComment(){
  if(ui.busy)return;const form=document.getElementById('document-viewer-comment-form');if(!form?.reportValidity())return;const fd=new FormData(form),body=String(fd.get('body')||'').trim(),mentions=fd.getAll('mentioned_user_ids'),doc=activeDocument(state().data);if(!body||!doc)return;
  ui.busy=true;
  try{if(ui.editingComment){try{await api().rpc('update_document_comment',{target_comment_id:ui.editingComment,comment_body:body,mentioned_user_ids:mentions});}catch(error){if(!isMissingRpc(error))throw error;await api().update('document_comments',ui.editingComment,{body,mentioned_user_ids:mentions,edited_at:new Date().toISOString(),updated_by:userId()});}}else await api().rpc('save_document_comment',{target_document_id:doc.id,comment_body:body,mentioned_user_ids:mentions});ui.editingComment='';await app().refresh();notify('Commentaire interne enregistré.','success');}
  catch(error){console.error('[PILOZ Documents] Commentaire non enregistré',{code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});notify(error.message||'Le commentaire n’a pas pu être enregistré.','error');}
  finally{ui.busy=false;}
 }
 async function deleteComment(id){if(!confirm('Supprimer ce commentaire interne ?'))return;try{await api().rpc('delete_document_comment',{target_comment_id:id});if(ui.editingComment===id)ui.editingComment='';await app().refresh();notify('Commentaire supprimé.','success');}catch(error){notify(error.message||'Le commentaire n’a pas pu être supprimé.','error');}}
 async function convert(type){
  const doc=activeDocument(state().data);if(!doc||doc.document_type!=='quote'||ui.busy)return;
  if(type==='deposit_invoice'){ui.modal={type:'deposit'};renderViewer(state());return;}
  if(type==='progress_invoice'){ui.modal={type:'progress'};renderViewer(state());return;}
  if(type==='balance_invoice'){ui.modal={type:'balance'};renderViewer(state());return;}
  await runConversion('convert_quote_to_invoice',{target_quote_id:doc.id,target_invoice_type:type});
 }
 function setDepositMode(mode){document.querySelectorAll('[data-deposit-field]').forEach(node=>node.hidden=node.dataset.depositField!==mode);}
 async function saveConversion(){
  const doc=activeDocument(state().data),form=document.getElementById('document-viewer-conversion-form');if(!doc||!form||ui.busy)return;
  if(ui.modal?.type==='deposit'){
   const fd=new FormData(form),mode=fd.get('deposit_mode'),value=Number(fd.get(mode==='percent'?'deposit_percent':'deposit_amount'));if(value<=0){notify('Saisissez un acompte supérieur à zéro.','error');return;}
   await runConversion('create_deposit_invoice',{target_quote_id:doc.id,deposit_percent:mode==='percent'?value:null,deposit_amount:mode==='amount'?value:null});return;
  }
  if(ui.modal?.type==='progress'){
   const fd=new FormData(form),line_progress=progressRows(state().data,doc).flatMap(({line,previous})=>{const value=Number(fd.get('progress_'+line.id));return value>previous?[{line_id:line.id,progress_percent:value}]:[];});if(!line_progress.length){notify('Saisissez un nouvel avancement pour au moins une ligne.','error');return;}
   await runConversion('create_progress_invoice',{target_quote_id:doc.id,line_progress});return;
  }
  if(ui.modal?.type==='balance')await runConversion('create_balance_invoice',{target_quote_id:doc.id});
 }
  async function runConversion(rpcName,params){
   ui.busy=true;try{const id=await api().rpc(rpcName,params);ui.modal=null;await app().refresh();if(id)app().editDocument(id);notify('Brouillon de facturation créé et lié au devis.','success');return id;}
  catch(error){console.error('[PILOZ Documents] Conversion impossible',{rpc:rpcName,code:error?.code||'',status:error?.status||0,message:error?.message||String(error)});notify(error.message||'La conversion n’a pas pu être réalisée.','error');return null;}
  finally{ui.busy=false;}
 }
 function openCredit(){ui.modal={type:'credit'};renderViewer(state());requestAnimationFrame(()=>document.querySelector('#document-viewer-credit-form textarea')?.focus());}
 async function saveCredit(){if(ui.busy)return;const form=document.getElementById('document-viewer-credit-form'),doc=activeDocument(state().data);if(!form?.reportValidity()||!doc)return;const reason=String(new FormData(form).get('reason')||'').trim();if(!reason)return;ui.busy=true;try{const id=await api().rpc('create_credit_note',{target_invoice_id:doc.id,credit_reason:reason,line_adjustments:null});ui.modal=null;await app().refresh();if(id)select(id);notify('Brouillon d’avoir créé et lié à la facture.','success');}catch(error){notify(error.message||'L’avoir n’a pas pu être créé.','error');}finally{ui.busy=false;}}
 function appAction(action){
  const doc=activeDocument(state().data);if(!doc)return;if(action==='edit'){app().editDocument(doc.id);return;}app().editDocument(doc.id);setTimeout(()=>app()[action]?.(),0);
 }
 async function archive(){const doc=activeDocument(state().data);if(!doc||!confirm(`Archiver ${documentNumber(doc)} ?`))return;try{try{await api().rpc('transition_document_status',{target_document_id:doc.id,target_status:'archived'});}catch(error){if(!isMissingRpc(error))throw error;await api().update('documents',doc.id,{status:'archived',archived_at:new Date().toISOString()});}await app().refresh();notify('Document archivé.','success');}catch(error){notify(error.message||'Le document n’a pas pu être archivé.','error');}}
 function showHistory(){const doc=activeDocument(state().data),logs=(state().data.activityLogs||[]).filter(row=>row.entity_id===doc?.id).sort((a,b)=>String(b.created_at).localeCompare(String(a.created_at)));if(!logs.length){notify('Aucun événement historisé pour ce document.');return;}const text=logs.slice(0,8).map(row=>`${datetime(row.created_at)} — ${String(row.action||'Action').replaceAll('.',' · ')}`).join('\n');alert(text);}
 function renderRoute(route,runtimeState){const path=hashPath();if(route==='document-viewer'||path==='document-viewer')return renderViewer(runtimeState);return previousRender?.(route,runtimeState)||false;}

 Object.assign(modern,{renderRoute});
 global.PilozDocumentViewerV2={open,close,create,select,clearSelection,search,setTab,setStatus,toggleList,toggleInfo,backToList,previousDocument,nextDocument,changeZoom,changePage,download,print,fullscreen,openFinalization,finalizeDraft,deleteDraft,openPayment,openPaymentCancellation,closeModal,savePayment,cancelPayment,editComment,cancelCommentEdit,saveComment,deleteComment,convert,setDepositMode,saveConversion,openCredit,saveCredit,appAction,archive,showHistory,renderViewer,snapshotContext,filteredDocuments,remainingFor};
})(window);
