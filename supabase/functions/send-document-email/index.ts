import { createClient } from "npm:@supabase/supabase-js@2";
import sanitizeHtml from "npm:sanitize-html@2.17.0";
import { corsHeaders, json } from "../_shared/http.ts";
function cleanText(value:string){return sanitizeHtml(String(value||''),{allowedTags:[],allowedAttributes:{}}).slice(0,200);}
function cleanHtml(value:string){return sanitizeHtml(String(value||''),{allowedTags:['p','br','h1','h2','h3','strong','b','em','i','small','ul','ol','li','table','thead','tbody','tfoot','tr','th','td','a'],allowedAttributes:{a:['href','title'],td:['colspan','rowspan'],th:['colspan','rowspan']},allowedSchemes:['https','mailto'],allowProtocolRelative:false,enforceHtmlBoundary:true});}
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:corsHeaders});if(req.method!=='POST')return json({error:'Méthode non autorisée'},405);
 const auth=req.headers.get('authorization');if(!auth)return json({error:'Authentification requise'},401);
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,resend=Deno.env.get('RESEND_API_KEY');if(!resend)return json({error:"L'envoi d'e-mails n'est pas configuré."},503);
 const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}}),{data:{user}}=await userClient.auth.getUser();if(!user)return json({error:'Session invalide'},401);
 const body=await req.json(),admin=createClient(url,secret),{data:doc}=await admin.from('documents').select('id,company_id,number,status').eq('id',body.documentId).single();if(!doc)return json({error:'Document introuvable'},404);
 const {data:member}=await admin.from('company_members').select('role').eq('company_id',doc.company_id).eq('user_id',user.id).maybeSingle();if(!member)return json({error:'Accès refusé'},403);
 const {count:recent}=await admin.from('activity_logs').select('id',{head:true,count:'exact'}).eq('company_id',doc.company_id).eq('actor_user_id',user.id).eq('action','document.emailed').gte('created_at',new Date(Date.now()-60_000).toISOString());if((recent||0)>=10)return json({error:'Trop d’envois. Réessayez dans une minute.'},429,{'Retry-After':'60'});
 const to=String(body.to||'').trim().toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to))return json({error:'Destinataire invalide'},400);
 const sent=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json'},body:JSON.stringify({from:Deno.env.get('EMAIL_FROM')||'PILOZ <noreply@piloz.fr>',to:[to],subject:cleanText(body.subject||`Document ${doc.number||''}`),html:cleanHtml(body.html||'')})});if(!sent.ok)return json({error:"Le document n'a pas pu être envoyé."},502);
 const {error:sentAtError}=await admin.from('documents').update({sent_at:new Date().toISOString()}).eq('id',doc.id);if(sentAtError)console.error('document.sent_at update failed',{code:sentAtError.code});
 await admin.from('activity_logs').insert({company_id:doc.company_id,actor_user_id:user.id,created_by:user.id,action:'document.emailed',entity_type:'document',entity_id:doc.id,new_data:{to}});
 return json({sent:true});
});
