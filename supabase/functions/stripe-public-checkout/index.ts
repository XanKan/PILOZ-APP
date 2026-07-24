import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@20.4.0";

const origins=new Set(["https://piloz.fr","https://www.piloz.fr","http://localhost:4173","http://localhost:5173"]);
const plans=new Set(["essential","pro","business"]),intervals=new Set(["monthly","annual"]);
function cors(req:Request){const origin=req.headers.get("origin")||"";return{
 "Access-Control-Allow-Origin":origins.has(origin)?origin:"https://piloz.fr",
 "Access-Control-Allow-Headers":"content-type",
 "Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store"
};}
function json(req:Request,data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});}
function clean(value:unknown,max=80){return String(value??"").trim().toLowerCase().slice(0,max);}
async function hashHex(value:string){const bytes=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));return[...new Uint8Array(bytes)].map(byte=>byte.toString(16).padStart(2,"0")).join("");}

Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
 if(req.method!=="POST")return json(req,{error:"Méthode non autorisée"},405);
 const origin=req.headers.get("origin")||"";
 if(origin&&!origins.has(origin))return json(req,{error:"Origine non autorisée"},403);
 const stripeKey=Deno.env.get("STRIPE_SECRET_KEY"),supabaseUrl=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!stripeKey||!supabaseUrl||!serviceKey)return json(req,{error:"Le paiement est temporairement indisponible.",code:"server_not_configured"},503);
 let body:Record<string,unknown>;
 try{body=await req.json();}catch{return json(req,{error:"Requête invalide"},400);}
 const planKey=clean(body.plan,40),billingInterval=clean(body.billing,20)||"monthly";
 if(!plans.has(planKey)||!intervals.has(billingInterval))return json(req,{error:"Offre invalide"},400);
 const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}}),stripe=new Stripe(stripeKey,{httpClient:Stripe.createFetchHttpClient()}),livemode=stripeKey.startsWith("sk_live_");
 const forwarded=(req.headers.get("x-forwarded-for")||req.headers.get("cf-connecting-ip")||"").split(",")[0].trim(),agent=(req.headers.get("user-agent")||"").slice(0,200);
 const fingerprint=await hashHex(`${forwarded}|${agent}|${serviceKey.slice(-24)}`),oneHourAgo=new Date(Date.now()-3600000).toISOString();
 const {count}=await admin.from("stripe_checkout_claims").select("id",{count:"exact",head:true}).eq("request_fingerprint",fingerprint).gte("created_at",oneHourAgo);
 if(Number(count||0)>=10)return json(req,{error:"Trop de tentatives. Réessayez dans une heure.",code:"rate_limited"},429);
 try{
  const now=new Date().toISOString(),{data:versions,error:versionError}=await admin.from("subscription_plan_versions").select("id,plan_key,version,name,price_monthly_cents,price_annual_cents,effective_from,effective_to").eq("plan_key",planKey).lte("effective_from",now).order("version",{ascending:false}).limit(10);
  if(versionError)throw versionError;
  const version=(versions||[]).find(row=>!row.effective_to||new Date(row.effective_to)>new Date());
  if(!version)return json(req,{error:"Cette offre n’est pas disponible."},404);
  let {data:mapping,error:mappingReadError}=await admin.from("subscription_provider_prices").select("*").eq("provider","stripe").eq("plan_version_id",version.id).eq("billing_interval",billingInterval).eq("currency","eur").eq("livemode",livemode).eq("active",true).maybeSingle();
  if(mappingReadError)throw mappingReadError;
  if(!mapping){
   const amount=Number(billingInterval==="annual"?version.price_annual_cents:version.price_monthly_cents);
   if(!Number.isInteger(amount)||amount<=0)throw Object.assign(new Error("invalid_plan_amount"),{code:"invalid_plan_amount"});
   const {data:sibling}=await admin.from("subscription_provider_prices").select("external_product_id").eq("provider","stripe").eq("plan_version_id",version.id).eq("livemode",livemode).eq("active",true).limit(1).maybeSingle();
   let productId=sibling?.external_product_id||"";
   if(!productId){const product=await stripe.products.create({name:`Piloz ${version.name}`,description:`Abonnement Piloz ${version.name}`,metadata:{piloz_plan_key:planKey,piloz_plan_version_id:version.id}},{idempotencyKey:`piloz-product-${version.id}-${livemode?"live":"test"}`});productId=product.id;}
   const price=await stripe.prices.create({product:productId,currency:"eur",unit_amount:amount,recurring:{interval:billingInterval==="annual"?"year":"month"},lookup_key:`piloz_${planKey}_${billingInterval}_v${version.version}_${livemode?"live":"test"}`,metadata:{piloz_plan_key:planKey,piloz_plan_version_id:version.id,billing_interval:billingInterval}},{idempotencyKey:`piloz-price-${version.id}-${billingInterval}-${livemode?"live":"test"}`});
   const {data:created,error:createError}=await admin.from("subscription_provider_prices").upsert({provider:"stripe",plan_version_id:version.id,billing_interval:billingInterval,currency:"eur",livemode,external_product_id:productId,external_price_id:price.id,active:true,updated_at:new Date().toISOString()},{onConflict:"provider,plan_version_id,billing_interval,currency,livemode"}).select("*").single();
   if(createError)throw createError;mapping=created;
  }
  const claimId=crypto.randomUUID(),claimToken=`${crypto.randomUUID().replaceAll("-","")}${crypto.randomUUID().replaceAll("-","")}`,claimHash=await hashHex(claimToken);
  const success=new URL("https://app.piloz.fr/");
  success.searchParams.set("mode","signup");success.searchParams.set("stripe","checkout_success");success.searchParams.set("session_id","{CHECKOUT_SESSION_ID}");success.searchParams.set("claim",claimToken);success.searchParams.set("plan",planKey);success.searchParams.set("billing",billingInterval);success.searchParams.set("source","stripe-checkout");
  const checkout=await stripe.checkout.sessions.create({
   mode:"subscription",payment_method_collection:"always",client_reference_id:claimId,
   line_items:[{price:mapping.external_price_id,quantity:1}],success_url:success.toString(),cancel_url:"https://piloz.fr/#tarifs",
   billing_address_collection:"required",tax_id_collection:{enabled:true},
   subscription_data:{trial_period_days:14,trial_settings:{end_behavior:{missing_payment_method:"cancel"}},metadata:{piloz_checkout_claim_id:claimId,piloz_plan_key:planKey,piloz_plan_version_id:version.id,billing_interval:billingInterval}},
   metadata:{piloz_checkout_claim_id:claimId,piloz_plan_key:planKey,piloz_plan_version_id:version.id,billing_interval:billingInterval}
  },{idempotencyKey:`piloz-public-checkout-${claimId}`});
  if(!checkout.url)throw new Error("checkout_url_missing");
  const {error:claimError}=await admin.from("stripe_checkout_claims").insert({id:claimId,checkout_session_id:checkout.id,claim_token_hash:claimHash,plan_version_id:version.id,billing_interval:billingInterval,livemode,status:"pending",request_fingerprint:fingerprint});
  if(claimError){await stripe.checkout.sessions.expire(checkout.id).catch(()=>null);throw claimError;}
  return json(req,{url:checkout.url});
 }catch(error){
  const cause=error as {type?:string;code?:string;statusCode?:number};
  console.error("[PILOZ Stripe] public checkout failed",{type:cause.type||"unknown",code:cause.code||"unknown",status:cause.statusCode||500,planKey,billingInterval});
  return json(req,{error:"Le paiement est temporairement indisponible. Réessayez dans quelques instants.",code:"stripe_checkout_failed"},cause.statusCode&&cause.statusCode<500?400:502);
 }
});
