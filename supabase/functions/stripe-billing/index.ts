import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@20.4.0";

const allowedOrigins=new Set(["https://app.piloz.fr","http://localhost:4173","http://localhost:5173"]);
function cors(req:Request){const origin=req.headers.get("origin")||"";return{
  "Access-Control-Allow-Origin":allowedOrigins.has(origin)?origin:"https://app.piloz.fr",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store"
};}
function response(req:Request,data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});}
function text(value:unknown,max=160){return String(value??"").trim().slice(0,max);}
function uuid(value:unknown){const result=text(value,40);return/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result)?result:"";}
function safeAppUrl(req:Request){const origin=req.headers.get("origin")||"";if(origin.startsWith("http://localhost:"))return origin;const configured=(Deno.env.get("APP_URL")||"https://app.piloz.fr").replace(/\/$/,"");return configured.startsWith("https://")?configured:"https://app.piloz.fr";}

Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
 if(req.method!=="POST")return response(req,{error:"Méthode non autorisée"},405);
 const origin=req.headers.get("origin")||"";
 if(origin&&!allowedOrigins.has(origin))return response(req,{error:"Origine non autorisée"},403);
 const authorization=req.headers.get("authorization");
 if(!authorization?.startsWith("Bearer "))return response(req,{error:"Authentification requise"},401);
 const supabaseUrl=Deno.env.get("SUPABASE_URL"),anonKey=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),stripeKey=Deno.env.get("STRIPE_SECRET_KEY");
 if(!supabaseUrl||!anonKey||!serviceKey)return response(req,{error:"Configuration Supabase indisponible",code:"server_not_configured"},503);
 if(!stripeKey)return response(req,{error:"Le paiement en ligne n’est pas encore configuré.",code:"stripe_not_configured",configured:false},503);
 const userClient=createClient(supabaseUrl,anonKey,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
 const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error:userError}=await userClient.auth.getUser();
 if(userError||!user)return response(req,{error:"Session invalide"},401);
 let body:Record<string,unknown>;
 try{body=await req.json();}catch{return response(req,{error:"Requête invalide"},400);}
 const action=text(body.action,30),companyId=uuid(body.companyId),planKey=text(body.planKey,40),billingInterval=text(body.billingInterval,20)||"monthly";
 if(!companyId)return response(req,{error:"Entreprise invalide"},400);
 const {data:member}=await userClient.from("company_members").select("role").eq("company_id",companyId).eq("user_id",user.id).maybeSingle();
 if(!member||!["owner","admin"].includes(member.role))return response(req,{error:"Seul un propriétaire ou administrateur peut gérer l’abonnement."},403);
 const {data:subscription,error:subscriptionError}=await admin.from("subscriptions").select("*").eq("company_id",companyId).maybeSingle();
 if(subscriptionError||!subscription)return response(req,{error:"Abonnement introuvable"},404);
 const stripe=new Stripe(stripeKey,{httpClient:Stripe.createFetchHttpClient()});
 const livemode=stripeKey.startsWith("sk_live_"),appUrl=safeAppUrl(req),returnUrl=`${appUrl}/#settings/subscription`;
 try{
  if(action==="portal"||(subscription.provider==="stripe"&&subscription.external_subscription_id)){
   if(!subscription.external_customer_id)return response(req,{error:"Aucun compte de paiement n’est encore associé à cette entreprise.",code:"stripe_customer_missing"},409);
   const session=await stripe.billingPortal.sessions.create({customer:subscription.external_customer_id,return_url:returnUrl});
   return response(req,{url:session.url,mode:"portal"});
  }
  if(action!=="checkout")return response(req,{error:"Action inconnue"},400);
  if(!["monthly","annual"].includes(billingInterval))return response(req,{error:"Périodicité invalide"},400);
  const targetPlan=planKey||subscription.plan_key;
  const {data:plan}=await admin.from("plans").select("key,name,price_monthly_cents,price_annual_cents").eq("key",targetPlan).maybeSingle();
  const {data:versions}=await admin.from("subscription_plan_versions").select("id,plan_key,version,name,price_monthly_cents,price_annual_cents,effective_from,effective_to").eq("plan_key",targetPlan).lte("effective_from",new Date().toISOString()).order("version",{ascending:false}).limit(10);
  const planVersion=(versions||[]).find(row=>!row.effective_to||new Date(row.effective_to)>new Date());
  if(!plan||!planVersion)return response(req,{error:"Cette offre n’est pas disponible."},404);
  let {data:mapping}=await admin.from("subscription_provider_prices").select("*").eq("provider","stripe").eq("plan_version_id",planVersion.id).eq("billing_interval",billingInterval).eq("currency","eur").eq("livemode",livemode).eq("active",true).maybeSingle();
  if(!mapping){
   const product=await stripe.products.create({name:`Piloz ${planVersion.name}`,description:`Abonnement Piloz ${planVersion.name}`,metadata:{piloz_plan_key:targetPlan,piloz_plan_version_id:planVersion.id}},{idempotencyKey:`piloz-product-${planVersion.id}-${livemode?"live":"test"}`});
   const amount=billingInterval==="annual"?planVersion.price_annual_cents:planVersion.price_monthly_cents;
   const price=await stripe.prices.create({product:product.id,currency:"eur",unit_amount:amount,recurring:{interval:billingInterval==="annual"?"year":"month"},lookup_key:`piloz_${targetPlan}_${billingInterval}_v${planVersion.version}_${livemode?"live":"test"}`,metadata:{piloz_plan_key:targetPlan,piloz_plan_version_id:planVersion.id,billing_interval:billingInterval}},{idempotencyKey:`piloz-price-${planVersion.id}-${billingInterval}-${livemode?"live":"test"}`});
   const {data:created,error:mappingError}=await admin.from("subscription_provider_prices").upsert({provider:"stripe",plan_version_id:planVersion.id,billing_interval:billingInterval,currency:"eur",livemode,external_product_id:product.id,external_price_id:price.id,active:true,updated_at:new Date().toISOString()},{onConflict:"provider,plan_version_id,billing_interval,currency,livemode"}).select("*").single();
   if(mappingError)throw mappingError;mapping=created;
  }
  let customerId=subscription.external_customer_id as string|null;
  if(!customerId){
   const {data:settings}=await admin.from("company_settings").select("legal_name,trade_name,email,siret,vat_number").eq("company_id",companyId).maybeSingle();
   const customer=await stripe.customers.create({email:text(settings?.email||user.email,254)||undefined,name:text(settings?.trade_name||settings?.legal_name,160)||undefined,metadata:{piloz_company_id:companyId,piloz_siret:text(settings?.siret,20),piloz_vat_number:text(settings?.vat_number,30)}},{idempotencyKey:`piloz-customer-${companyId}-${livemode?"live":"test"}`});
   customerId=customer.id;
   await admin.from("subscriptions").update({external_customer_id:customerId,provider_updated_at:new Date().toISOString()}).eq("company_id",companyId);
  }
  const successUrl=`${returnUrl}?stripe=success&session_id={CHECKOUT_SESSION_ID}`,cancelUrl=`${returnUrl}?stripe=cancelled`;
  const checkout=await stripe.checkout.sessions.create({mode:"subscription",customer:customerId,client_reference_id:companyId,line_items:[{price:mapping.external_price_id,quantity:1}],success_url:successUrl,cancel_url:cancelUrl,billing_address_collection:"required",tax_id_collection:{enabled:true},customer_update:{address:"auto",name:"auto"},subscription_data:{metadata:{piloz_company_id:companyId,piloz_plan_key:targetPlan,piloz_plan_version_id:planVersion.id,billing_interval:billingInterval}},metadata:{piloz_company_id:companyId,piloz_plan_key:targetPlan,piloz_plan_version_id:planVersion.id,billing_interval:billingInterval}},{idempotencyKey:`piloz-checkout-${companyId}-${planVersion.id}-${billingInterval}-${Math.floor(Date.now()/300000)}`});
  if(!checkout.url)throw new Error("checkout_url_missing");
  return response(req,{url:checkout.url,mode:"checkout"});
 }catch(error){
  const stripeError=error as {type?:string;code?:string;statusCode?:number;message?:string};
  console.error("[PILOZ Stripe] billing action failed",{action,companyId,type:stripeError.type||"unknown",code:stripeError.code||"unknown",status:stripeError.statusCode||500});
  return response(req,{error:"Le service de paiement est temporairement indisponible. Réessayez dans quelques instants.",code:"stripe_request_failed"},stripeError.statusCode&&stripeError.statusCode<500?400:502);
 }
});
