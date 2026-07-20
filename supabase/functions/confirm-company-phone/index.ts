import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";
const encoder=new TextEncoder();async function hash(v:string){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(v)))).map(x=>x.toString(16).padStart(2,'0')).join('');}
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:corsHeaders});if(req.method!=='POST')return json({error:'Méthode non autorisée'},405);const auth=req.headers.get('authorization');if(!auth)return json({error:'Authentification requise'},401);
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}}),{data:{user}}=await userClient.auth.getUser();if(!user)return json({error:'Session invalide'},401);
 const {companyId,code}=await req.json(),tokenHash=await hash(String(code||'')),{data:destination,error}=await userClient.rpc('confirm_company_phone_code',{target_company_id:companyId,target_token_hash:tokenHash});
 if(error)return json({error:error.code==='42501'?'Accès refusé':'Vérification impossible'},error.code==='42501'?403:400);if(!destination)return json({error:'Code invalide, expiré ou nombre de tentatives dépassé'},400);return json({confirmed:true,phone:destination});
});
