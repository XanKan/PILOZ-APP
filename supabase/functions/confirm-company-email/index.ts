import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";
const encoder=new TextEncoder();
async function hash(value:string){const bytes=await crypto.subtle.digest('SHA-256',encoder.encode(value));return Array.from(new Uint8Array(bytes)).map(v=>v.toString(16).padStart(2,'0')).join('');}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:corsHeaders});
 if(req.method!=='POST')return json({error:'Méthode non autorisée'},405);
 const auth=req.headers.get('authorization');if(!auth)return json({error:'Authentification requise'},401);
 const url=Deno.env.get('SUPABASE_URL')!,userClient=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:auth}}});const {data:{user}}=await userClient.auth.getUser();if(!user)return json({error:'Session invalide'},401);
 const {token,companyId}=await req.json(),tokenHash=await hash(String(token||''));
 const {data:destination,error}=await userClient.rpc('confirm_company_email_token',{target_company_id:companyId,target_token_hash:tokenHash});
 if(error)return json({error:error.code==='42501'?'Accès refusé':'Confirmation impossible'},error.code==='42501'?403:400);
 if(!destination)return json({error:'Lien invalide ou expiré'},400);
 return json({confirmed:true,email:destination});
});
