import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins=new Set(["https://app.piloz.fr","http://localhost:4173","http://localhost:5173"]);

function cors(req:Request){
 const origin=req.headers.get("origin")||"";
 return{
  "Access-Control-Allow-Origin":allowedOrigins.has(origin)?origin:"https://app.piloz.fr",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
  "Vary":"Origin",
  "Cache-Control":"no-store"
 };
}

function response(req:Request,data:unknown,status=200){
 return new Response(JSON.stringify(data),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});
}

function afterNow(value:unknown){
 if(!value)return true;
 const date=new Date(String(value));
 return Number.isFinite(date.getTime())&&date.getTime()>Date.now();
}

function accessFor(subscription:any){
 if(!subscription)return{allowed:false,reason:"subscription_missing"};
 const status=String(subscription.status||"");
 const provider=String(subscription.provider||"manual");
 if(provider==="stripe"){
  const activeStatus=status==="active"||status==="trialing";
  const paymentReady=subscription.payment_status==="paid"&&Boolean(subscription.external_customer_id)&&Boolean(subscription.external_subscription_id);
  const periodValid=status==="trialing"?afterNow(subscription.trial_ends_at):afterNow(subscription.subscription_ends_at);
  return{allowed:activeStatus&&paymentReady&&periodValid,reason:!activeStatus?"subscription_inactive":!paymentReady?"payment_required":!periodValid?"subscription_expired":"licensed"};
 }
 // Les essais créés et bornés par Piloz Admin sont des licences manuelles valides
 // jusqu'à trial_ends_at. Une licence manuelle active reste bornée par sa date de fin.
 const activeStatus=status==="active"||status==="trialing";
 const periodValid=status==="trialing"?afterNow(subscription.trial_ends_at):afterNow(subscription.subscription_ends_at);
 return{allowed:activeStatus&&periodValid,reason:!activeStatus?"manual_license_inactive":!periodValid?"subscription_expired":"licensed"};
}

Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
 if(req.method!=="POST")return response(req,{allowed:false,reason:"method_not_allowed"},405);
 const origin=req.headers.get("origin")||"";
 if(origin&&!allowedOrigins.has(origin))return response(req,{allowed:false,reason:"origin_denied"},403);
 const authorization=req.headers.get("authorization");
 if(!authorization?.startsWith("Bearer "))return response(req,{allowed:false,reason:"authentication_required"},401);
 const supabaseUrl=Deno.env.get("SUPABASE_URL"),anonKey=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!supabaseUrl||!anonKey||!serviceKey)return response(req,{allowed:false,reason:"server_not_configured"},503);
 const userClient=createClient(supabaseUrl,anonKey,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
 const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error:userError}=await userClient.auth.getUser();
 if(userError||!user)return response(req,{allowed:false,reason:"invalid_session"},401);
 const {data:memberships,error:membershipError}=await admin.from("company_members").select("company_id,role,created_at").eq("user_id",user.id).order("created_at",{ascending:true});
 if(membershipError){console.error("[PILOZ Licence] membership lookup failed",{code:membershipError.code});return response(req,{allowed:false,reason:"license_check_failed"},503);}
 const companyIds=(memberships||[]).map(row=>row.company_id).filter(Boolean);
 if(!companyIds.length)return response(req,{allowed:false,reason:"company_missing"});
 const {data:subscriptions,error:subscriptionError}=await admin.from("subscriptions").select("company_id,plan_key,status,provider,payment_status,trial_ends_at,subscription_ends_at,external_customer_id,external_subscription_id").in("company_id",companyIds);
 if(subscriptionError){console.error("[PILOZ Licence] subscription lookup failed",{code:subscriptionError.code});return response(req,{allowed:false,reason:"license_check_failed"},503);}
 for(const membership of memberships||[]){
  const subscription=(subscriptions||[]).find(row=>row.company_id===membership.company_id),access=accessFor(subscription);
  if(access.allowed)return response(req,{allowed:true,reason:"licensed",companyId:membership.company_id,role:membership.role,planKey:subscription.plan_key,status:subscription.status,provider:subscription.provider});
 }
 const subscription=(subscriptions||[])[0],access=accessFor(subscription);
 return response(req,{allowed:false,reason:access.reason,companyId:companyIds[0]||null,status:subscription?.status||null,provider:subscription?.provider||null});
});
