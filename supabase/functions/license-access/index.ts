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

async function demoCompanyIdentity(admin:any,companyId:string,userId:string){
 const [{data:company,error:companyError},{data:authUser,error:authUserError}]=await Promise.all([
  admin.from("companies").select("id,admin_tags").eq("id",companyId).maybeSingle(),
  admin.auth.admin.getUserById(userId)
 ]);
 if(companyError)throw companyError;
 if(authUserError)throw authUserError;
 const metadata=authUser.user?.user_metadata||{};
 const metadataDemo=metadata.demo_account===true||["true","1","yes"].includes(String(metadata.demo_account||"").toLowerCase());
 const tags=Array.isArray(company?.admin_tags)?company.admin_tags.map((tag:any)=>String(tag).toLowerCase()):[];
 return Boolean(company&&(metadataDemo||tags.includes("demo")||tags.includes("seeded")));
}

async function repairDemoCompany(admin:any,companyId:string,userId:string){
 const {data:company,error:companyError}=await admin.from("companies").select("id,admin_tags").eq("id",companyId).maybeSingle();
 if(companyError)throw companyError;
 const {data:authUser,error:authUserError}=await admin.auth.admin.getUserById(userId);
 if(authUserError)throw authUserError;
 const metadata=authUser.user?.user_metadata||{};
 const metadataDemo=metadata.demo_account===true||["true","1","yes"].includes(String(metadata.demo_account||"").toLowerCase());
 const demoTags=Array.isArray(company?.admin_tags)?company.admin_tags.map((tag:any)=>String(tag).toLowerCase()):[];
 const taggedDemo=Boolean(company&&(demoTags.includes("demo")||demoTags.includes("seeded")));
 if(!company||(!taggedDemo&&!metadataDemo))return false;
 if(!metadataDemo){
  const {error:metadataError}=await admin.auth.admin.updateUserById(userId,{user_metadata:{...metadata,demo_account:true,onboarding_completed:true}});
  if(metadataError)throw metadataError;
 }
 if(metadataDemo&&!taggedDemo){
  const repairedTags=Array.from(new Set([...(Array.isArray(company.admin_tags)?company.admin_tags:[]),"demo","seeded"]));
  const {error:tagError}=await admin.from("companies").update({admin_tags:repairedTags}).eq("id",companyId);
  if(tagError)throw tagError;
 }
 const now=new Date().toISOString();
 const {error:documentSettingsError}=await admin.from("company_document_settings").upsert(
  {company_id:companyId,quote_prefix:"DEV-DEMO",invoice_prefix:"FAC-DEMO"},
  {onConflict:"company_id"}
 );
 if(documentSettingsError)throw documentSettingsError;
 const {error:documentPrefixError}=await admin.from("company_document_settings").update({quote_prefix:"DEV-DEMO",invoice_prefix:"FAC-DEMO"}).eq("company_id",companyId);
 if(documentPrefixError)throw documentPrefixError;
 const {data:completedSettings,error:settingsError}=await admin.from("company_settings").update({
  legal_name:"Horizon Conseil (démonstration)",trade_name:"Horizon Conseil",siren:"123456789",siret:"12345678900012",
  address_line1:"18 avenue des Ateliers",postal_code:"85000",city:"La Roche-sur-Yon",country:"France",country_code:"FR",
  email:"contact@horizon-conseil.example",phone_e164:"+33100000000",currency:"EUR",language:"fr",subject_to_vat:true,
  default_vat_rate:20,onboarding_step:7,onboarding_completed_at:now
 }).eq("company_id",companyId).select("company_id,onboarding_step,onboarding_completed_at").maybeSingle();
 if(settingsError||!completedSettings)throw settingsError||new Error("demo_company_settings_missing");
 const {data:completedPreferences,error:preferencesError}=await admin.from("user_preferences").upsert({user_id:userId,company_id:companyId,onboarding_completed:true},{onConflict:"user_id"}).select("user_id,onboarding_completed").maybeSingle();
 if(preferencesError||!completedPreferences?.onboarding_completed)throw preferencesError||new Error("demo_user_preferences_incomplete");
 const {data:existingClients,error:clientsLookupError}=await admin.from("clients").select("id,legal_name,first_name,last_name").eq("company_id",companyId);
 if(clientsLookupError)throw clientsLookupError;
 const clientNames=new Set((existingClients||[]).map((client:any)=>client.legal_name||`${client.first_name||""} ${client.last_name||""}`.trim()));
 const missingClients=[
  {company_id:companyId,kind:"company",legal_name:"Nova Bâtiment",email:"contact@nova-batiment.example",phone_e164:"+33100000001",address_line_1:"12 rue du Chantier",postal_code:"75012",city:"Paris",country_code:"FR",payment_terms:"30 jours",created_by:userId},
  {company_id:companyId,kind:"company",legal_name:"Atelier Horizon",email:"bonjour@atelier-horizon.example",phone_e164:"+33100000002",address_line_1:"4 place des Artisans",postal_code:"44000",city:"Nantes",country_code:"FR",payment_terms:"À réception",created_by:userId},
  {company_id:companyId,kind:"person",first_name:"Camille",last_name:"Martin",email:"camille.martin@example.com",phone_e164:"+33100000003",postal_code:"69002",city:"Lyon",country_code:"FR",created_by:userId}
 ].filter(client=>!clientNames.has((client as any).legal_name||`${(client as any).first_name} ${(client as any).last_name}`));
 if(missingClients.length){const {error}=await admin.from("clients").insert(missingClients);if(error)throw error;}
 const {error:itemsError}=await admin.from("catalog_items").upsert([
  {company_id:companyId,item_type:"service",reference:"DEMO-SRV-001",name:"Audit organisationnel",short_description:"Diagnostic et recommandations",unit:"forfait",purchase_price:350,sale_price:750,tax_rate:20,stock_managed:false,created_by:userId},
  {company_id:companyId,item_type:"subscription",reference:"DEMO-ABO-001",name:"Accompagnement mensuel",short_description:"Suivi et pilotage mensuels",unit:"mois",purchase_price:250,sale_price:590,tax_rate:20,stock_managed:false,created_by:userId},
  {company_id:companyId,item_type:"product",reference:"DEMO-ART-001",name:"Kit de démarrage",short_description:"Matériel de démonstration",unit:"unité",purchase_price:420,sale_price:690,tax_rate:20,stock_managed:false,created_by:userId}
 ],{onConflict:"company_id,reference",ignoreDuplicates:true});
 if(itemsError)throw itemsError;
 const {data:demoActivities,error:activitiesLookupError}=await admin.from("activities").select("id").eq("company_id",companyId).contains("metadata",{demo:true}).limit(1);
 if(activitiesLookupError)throw activitiesLookupError;
 if(!(demoActivities||[]).length){
  const {data:demoClients,error:demoClientsError}=await admin.from("clients").select("id,legal_name").eq("company_id",companyId).in("legal_name",["Nova Bâtiment","Atelier Horizon"]);
  if(demoClientsError)throw demoClientsError;
  const tomorrow=new Date(Date.now()+86_400_000).toISOString(),nextWeek=new Date(Date.now()+7*86_400_000).toISOString();
  const nova=demoClients?.find((client:any)=>client.legal_name==="Nova Bâtiment"),atelier=demoClients?.find((client:any)=>client.legal_name==="Atelier Horizon");
  const {error:activitiesError}=await admin.from("activities").insert([
   {company_id:companyId,client_id:nova?.id||null,activity_type:"call",subject:"Appeler Nova Bâtiment",description:"Préparer la proposition commerciale (donnée fictive).",scheduled_at:tomorrow,assigned_user_id:userId,created_by:userId,metadata:{demo:true}},
   {company_id:companyId,client_id:atelier?.id||null,activity_type:"meeting",subject:"Rendez-vous Atelier Horizon",description:"Présentation de la solution (donnée fictive).",scheduled_at:nextWeek,assigned_user_id:userId,created_by:userId,metadata:{demo:true}}
  ]);
  if(activitiesError)throw activitiesError;
 }
 return true;
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
  if(subscription&&access.allowed){
   let demoAccount=false;
   try{
    demoAccount=await demoCompanyIdentity(admin,membership.company_id,user.id);
    if(demoAccount)await repairDemoCompany(admin,membership.company_id,user.id);
   }catch(error){console.error("[PILOZ Licence] demo repair failed",{companyId:membership.company_id,code:(error as any)?.code||"unknown"});}
   return response(req,{allowed:true,reason:"licensed",companyId:membership.company_id,role:membership.role,planKey:subscription.plan_key,status:subscription.status,provider:subscription.provider,demoAccount});
  }
 }
 const subscription=(subscriptions||[])[0],access=accessFor(subscription);
 return response(req,{allowed:false,reason:access.reason,companyId:companyIds[0]||null,status:subscription?.status||null,provider:subscription?.provider||null});
});
