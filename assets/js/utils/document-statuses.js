(function(global){
 'use strict';

 const invoiceTypes=new Set(['invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice','recurring_invoice']);
 const accountingInvoiceTypes=new Set(['invoice','deposit_invoice','balance_invoice']);
 const meta={
  draft:{label:'Brouillon',tone:'neutral'},sent:{label:'Envoyé',tone:'info'},pending:{label:'En attente',tone:'warning'},accepted:{label:'Accepté',tone:'positive'},
  rejected:{label:'Refusé',tone:'danger'},invoiced:{label:'Facturé',tone:'positive'},expired:{label:'Expiré',tone:'danger'},
  finalized:{label:'Finalisée',tone:'info'},overdue:{label:'En retard',tone:'danger'},paid:{label:'Encaissée',tone:'positive'},
  partially_paid:{label:'Partiellement encaissée',tone:'warning'},cancelled:{label:'Annulée',tone:'neutral'},archived:{label:'Archivé',tone:'neutral'}
 };

 const isoToday=()=>new Date().toISOString().slice(0,10);
 const confirmed=row=>!row?.status||['confirmed','completed','paid'].includes(row.status);
 const paymentsFor=(data,id)=>(data?.payments||[]).filter(row=>row.document_id===id&&confirmed(row));
 const paidFor=(data,id)=>paymentsFor(data,id).reduce((sum,row)=>sum+Number(row.amount||0),0);
 const remainingFor=(data,doc)=>doc?.status==='cancelled'?0:Math.max(0,Number(doc?.total_incl_tax||0)-paidFor(data,doc?.id));
 const linkedDocuments=(data,doc)=>{
  const ids=new Set();
  (data?.documentLinks||[]).forEach(link=>{
   if(link.source_document_id===doc?.id)ids.add(link.target_document_id);
   if(link.target_document_id===doc?.id)ids.add(link.source_document_id);
  });
  (data?.documents||[]).forEach(row=>{if(row.source_document_id===doc?.id||doc?.source_document_id===row.id)ids.add(row.id);});
  return(data?.documents||[]).filter(row=>ids.has(row.id));
 };
 const quoteHasInvoice=(data,doc)=>linkedDocuments(data,doc).some(row=>accountingInvoiceTypes.has(row.document_type));
 const quoteStatus=(data,doc,today=isoToday())=>{
  if(doc?.status==='archived')return'archived';
  if(quoteHasInvoice(data,doc))return'invoiced';
  if(['accepted','rejected'].includes(doc?.status))return doc.status;
  if(doc?.validity_date&&doc.validity_date<today)return'expired';
  if(['sent','viewed'].includes(doc?.status))return'sent';
  return doc?.status==='draft'?'draft':'pending';
 };
 const invoiceStatus=(data,doc,today=isoToday())=>{
  if(['cancelled','archived'].includes(doc?.status))return doc.status;
  const finalized=!!(doc?.finalized_at||doc?.validated_at||doc?.locked_at)||['finalized','validated','sent','overdue','partially_paid','paid'].includes(doc?.status);
  if(!finalized)return'draft';
  const paid=paidFor(data,doc?.id),remaining=Math.max(0,Number(doc?.total_incl_tax||0)-paid);
  if(remaining<=0.005)return'paid';
  if(paid>0)return'partially_paid';
  if(doc?.due_date&&doc.due_date<today)return'overdue';
  return'finalized';
 };
 const effective=(data,doc,today)=>doc?.document_type==='quote'?quoteStatus(data,doc,today):invoiceTypes.has(doc?.document_type)?invoiceStatus(data,doc,today):(doc?.status||'draft');
 const statusMeta=status=>meta[status]||{label:String(status||'Brouillon').replaceAll('_',' '),tone:'neutral'};

 global.PilozDocumentStatus={invoiceTypes,accountingInvoiceTypes,meta,statusMeta,confirmed,paymentsFor,paidFor,remainingFor,linkedDocuments,quoteHasInvoice,quoteStatus,invoiceStatus,effective};
})(window);
