import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

const encoder=new TextEncoder();
async function hash(value:string){const bytes=await crypto.subtle.digest('SHA-256',encoder.encode(value));return Array.from(new Uint8Array(bytes)).map(v=>v.toString(16).padStart(2,'0')).join('');}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:corsHeaders});
 if(req.method!=='POST')return json({error:'Méthode non autorisée'},405);
 const auth=req.headers.get('authorization');if(!auth)return json({error:'Authentification requise'},401);
 const url=Deno.env.get('SUPABASE_URL')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,resend=Deno.env.get('RESEND_API_KEY');
 const userClient=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:auth}}});
 const {data:{user}}=await userClient.auth.getUser();if(!user)return json({error:'Session invalide'},401);
 const {companyId,email}=await req.json();const normalized=String(email||'').trim().toLowerCase();
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(normalized))return json({error:'Adresse e-mail invalide'},400);
 const admin=createClient(url,secret),{data:member}=await admin.from('company_members').select('role').eq('company_id',companyId).eq('user_id',user.id).maybeSingle();
 if(!member||!['owner','admin'].includes(member.role))return json({error:'Accès refusé'},403);if(!resend)return json({error:"L'envoi d'e-mails n'est pas encore configuré."},503);
 const token=crypto.randomUUID()+crypto.randomUUID(),tokenHash=await hash(token),expires=new Date(Date.now()+30*60_000).toISOString();
 const {data:recent}=await admin.from('company_contact_verifications').select('created_at').eq('company_id',companyId).eq('channel','email').order('created_at',{ascending:false}).limit(1).maybeSingle();
 if(recent&&Date.now()-new Date(recent.created_at).getTime()<60_000)return json({error:'Patientez une minute avant un nouvel envoi.'},429,{"Retry-After":"60"});
 await admin.from('company_contact_verifications').delete().eq('company_id',companyId).eq('channel','email').eq('destination',normalized).is('consumed_at',null);
 const {error}=await admin.from('company_contact_verifications').insert({company_id:companyId,channel:'email',destination:normalized,token_hash:tokenHash,expires_at:expires,created_by:user.id});if(error)return json({error:'Impossible de préparer la confirmation.'},500);
 const confirmUrl=`https://app.piloz.fr/?verify_company_email=${encodeURIComponent(token)}&company=${encodeURIComponent(companyId)}`;
 const sent=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json'},body:JSON.stringify({from:Deno.env.get('EMAIL_FROM')||'PILOZ <noreply@piloz.fr>',to:[normalized],subject:'Confirmez votre e-mail professionnel',html:`<p>Confirmez votre adresse professionnelle pour PILOZ.</p><p><a href="${confirmUrl}">Confirmer mon adresse</a></p><p>Ce lien expire dans 30 minutes.</p>`})});
 if(!sent.ok)return json({error:"L'e-mail n'a pas pu être envoyé."},502);return json({sent:true,expiresAt:expires});
});
