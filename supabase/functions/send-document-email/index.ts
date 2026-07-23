import { createClient } from "npm:@supabase/supabase-js@2";
import sanitizeHtml from "npm:sanitize-html@2.17.0";
import { corsHeaders, json } from "../_shared/http.ts";

const EMAIL=/^[^\s@]+@[^\s@]+\.[^\s@]+$/i;
function cleanText(value:unknown,max=200){return sanitizeHtml(String(value||''),{allowedTags:[],allowedAttributes:{}}).trim().slice(0,max);}
function cleanHtml(value:unknown){return sanitizeHtml(String(value||''),{allowedTags:['p','br','h1','h2','h3','strong','b','em','i','small','ul','ol','li','table','thead','tbody','tfoot','tr','th','td','a'],allowedAttributes:{a:['href','title'],td:['colspan','rowspan'],th:['colspan','rowspan']},allowedSchemes:['https','mailto'],allowProtocolRelative:false,enforceHtmlBoundary:true});}
function emails(value:unknown){
 const source=Array.isArray(value)?value:String(value||'').split(/[;,]/);
 return[...new Set(source.map(item=>String(item||'').trim().toLowerCase()).filter(Boolean))];
}
function toBase64(bytes:Uint8Array){
 let binary='';
 for(let offset=0;offset<bytes.length;offset+=0x8000)binary+=String.fromCharCode(...bytes.subarray(offset,offset+0x8000));
 return btoa(binary);
}

Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:corsHeaders});
 if(req.method!=='POST')return json({error:'Méthode non autorisée'},405);
 const auth=req.headers.get('authorization');
 if(!auth)return json({error:'Authentification requise'},401);
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
 const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}});
 const {data:{user}}=await userClient.auth.getUser();
 if(!user)return json({error:'Session invalide'},401);

 let body:Record<string,unknown>;
 try{body=await req.json();}catch{return json({error:'Requête invalide'},400);}
 const admin=createClient(url,secret),documentId=String(body.documentId||'');
 const {data:doc}=await admin.from('documents').select('id,company_id,client_id,number,document_type,status,finalized_at,final_pdf_path,final_pdf_sha256').eq('id',documentId).maybeSingle();
 if(!doc)return json({error:'Document introuvable'},404);
 const {data:permitted}=await userClient.rpc('has_company_permission',{target_company_id:doc.company_id,target_permission:'resend_invoice'});
 if(!permitted)return json({error:'Accès refusé'},403);
 if(!['invoice','deposit_invoice','balance_invoice'].includes(doc.document_type)||!doc.finalized_at||['draft','cancelled','archived'].includes(doc.status))return json({error:'Seule une facture finalisée peut être envoyée.'},409);

 const to=emails(body.to),cc=emails(body.cc);
 if(!to.length||to.length>20||cc.length>20||[...to,...cc].some(address=>!EMAIL.test(address)))return json({error:'Destinataire invalide'},400);
 const subject=cleanText(body.subject||`Facture ${doc.number||''}`),html=cleanHtml(body.html||''),templateKey=cleanText(body.templateKey||'invoice-resend-default',100)||'invoice-resend-default';
 if(!subject||!html)return json({error:'L’objet et le message sont obligatoires.'},400);
 if(!doc.final_pdf_path)return json({error:'Le PDF final doit être généré avant l’envoi.',code:'final_pdf_required'},409);
 if(!String(doc.final_pdf_path).startsWith(`${doc.company_id}/documents/${doc.id}/`))return json({error:'Chemin du PDF final invalide.'},409);

 const {count:recent}=await admin.from('document_email_deliveries').select('id',{head:true,count:'exact'}).eq('company_id',doc.company_id).eq('created_by',user.id).eq('delivery_mode','provider').gte('created_at',new Date(Date.now()-60_000).toISOString());
 if((recent||0)>=10)return json({error:'Trop d’envois. Réessayez dans une minute.'},429,{'Retry-After':'60'});

 const resend=Deno.env.get('RESEND_API_KEY');
 if(!resend)return json({error:"L’envoi automatique n’est pas configuré. Vous pouvez télécharger le PDF, copier le message ou ouvrir votre messagerie.",code:'email_provider_not_configured',configured:false},503);
 const {data:file,error:fileError}=await admin.storage.from('company-files').download(doc.final_pdf_path);
 if(fileError||!file)return json({error:'Le PDF final est temporairement indisponible.',code:'final_pdf_unavailable'},409);
 const bytes=new Uint8Array(await file.arrayBuffer());
 if(!bytes.length)return json({error:'Le PDF final est vide.',code:'empty_final_pdf'},409);

 const sent=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json'},body:JSON.stringify({
   from:Deno.env.get('EMAIL_FROM')||'PILOZ <noreply@piloz.fr>',to,cc,subject,html,
   attachments:[{filename:`Facture-${cleanText(doc.number||doc.id,80).replace(/[^a-z0-9._-]+/gi,'-')}.pdf`,content:toBase64(bytes)}]
  })});
 let providerResult:Record<string,unknown>={};
 try{providerResult=await sent.json();}catch{/* Le statut HTTP reste la source de vérité. */}
 if(!sent.ok){
  await admin.from('document_email_deliveries').insert({company_id:doc.company_id,document_id:doc.id,client_id:doc.client_id,delivery_mode:'provider',delivery_status:'failed',recipient_to:to,recipient_cc:cc,subject,template_key:templateKey,message_preview:cleanText(html,1000),pdf_storage_path:doc.final_pdf_path,pdf_sha256:doc.final_pdf_sha256,provider:'resend',technical_code:String(providerResult?.name||sent.status),created_by:user.id});
  console.error('[PILOZ Email] provider rejected request',{status:sent.status,documentId:doc.id,companyId:doc.company_id});
  return json({error:"La facture n’a pas pu être envoyée. Le PDF et votre message sont conservés dans la fenêtre.",code:'provider_rejected'},502);
 }

 const sentAt=new Date().toISOString(),providerMessageId=cleanText(providerResult?.id||'',200)||null;
 const {data:delivery,error:deliveryError}=await admin.from('document_email_deliveries').insert({company_id:doc.company_id,document_id:doc.id,client_id:doc.client_id,delivery_mode:'provider',delivery_status:'sent',recipient_to:to,recipient_cc:cc,subject,template_key:templateKey,message_preview:cleanText(html,1000),pdf_storage_path:doc.final_pdf_path,pdf_sha256:doc.final_pdf_sha256,provider:'resend',provider_message_id:providerMessageId,sent_at:sentAt,created_by:user.id}).select('id').single();
 if(deliveryError){console.error('[PILOZ Email] delivery history failed',{code:deliveryError.code,documentId:doc.id});return json({error:"L’e-mail a été accepté par le fournisseur mais son historique n’a pas pu être enregistré. Contactez le support avec le numéro de facture.",code:'delivery_history_failed'},500);}
 await admin.from('activity_logs').insert({company_id:doc.company_id,actor_user_id:user.id,created_by:user.id,action:'document.emailed',entity_type:'document',entity_id:doc.id,new_data:{delivery_id:delivery.id,recipient_count:to.length+cc.length,provider:'resend'}});
 if(doc.client_id)await admin.from('client_activity_events').insert({company_id:doc.company_id,client_id:doc.client_id,event_type:'invoice.email_sent',summary:'Facture envoyée par e-mail',entity_type:'document_email_delivery',entity_id:delivery.id,metadata:{document_id:doc.id,provider:'resend'},actor_user_id:user.id,created_by:user.id});
 return json({sent:true,deliveryId:delivery.id,providerMessageId});
});
