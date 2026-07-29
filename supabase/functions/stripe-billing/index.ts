import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@20.4.0";

const allowedOrigins=new Set(["https://app.piloz.fr","http://localhost:4173","http://localhost:5173"]);
const PILOZ_TAX_CODE="txcd_10103001";
function cors(req:Request){const origin=req.headers.get("origin")||"";return{
 "Access-Control-Allow-Origin":allowedOrigins.has(origin)?origin:"https://app.piloz.fr",
 "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
 "Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store"
};}
function response(req:Request,data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});}
function text(value:unknown,max=160){return String(value??"").trim().slice(0,max);}
function uuid(value:unknown){const result=text(value,40);return/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result)?result:"";}
function objectId(value:unknown){return typeof value==="string"?value:(value&&typeof value==="object"&&"id" in value?String((value as {id:unknown}).id):"");}
function iso(seconds:unknown){const value=Number(seconds);return Number.isFinite(value)&&value>0?new Date(value*1000).toISOString():null;}
function subscriptionStatus(value:string){if(value==="trialing")return"trialing";if(value==="active")return"active";if(["past_due","unpaid","incomplete"].includes(value))return"past_due";if(value==="paused")return"suspended";return"canceled";}
function safeAppUrl(req:Request){const origin=req.headers.get("origin")||"";if(origin.startsWith("http://localhost:"))return origin;const configured=(Deno.env.get("APP_URL")||"https://app.piloz.fr").replace(/\/$/,"");return configured.startsWith("https://")?configured:"https://app.piloz.fr";}

async function currentPlanVersion(admin:SupabaseClient,planKey:string){
 const {data:plan,error:planError}=await admin.from("plans").select("key,name,price_monthly_cents,price_annual_cents").eq("key",planKey).maybeSingle();
 if(planError)throw planError;
 const {data:versions,error:versionError}=await admin.from("subscription_plan_versions").select("id,plan_key,version,name,price_monthly_cents,price_annual_cents,effective_from,effective_to").eq("plan_key",planKey).lte("effective_from",new Date().toISOString()).order("version",{ascending:false}).limit(10);
 if(versionError)throw versionError;
 const version=(versions||[]).find(row=>!row.effective_to||new Date(row.effective_to)>new Date());
 return plan&&version?version:null;
}

async function ensurePrice(admin:SupabaseClient,stripe:Stripe,planVersion:any,billingInterval:string,livemode:boolean){
 let {data:mapping,error:readError}=await admin.from("subscription_provider_prices").select("*").eq("provider","stripe").eq("plan_version_id",planVersion.id).eq("billing_interval",billingInterval).eq("currency","eur").eq("livemode",livemode).eq("active",true).maybeSingle();
 if(readError)throw readError;if(mapping){await stripe.products.update(mapping.external_product_id,{tax_code:PILOZ_TAX_CODE});return mapping;}
 const amount=Number(billingInterval==="annual"?planVersion.price_annual_cents:planVersion.price_monthly_cents);
 if(!Number.isInteger(amount)||amount<=0)throw Object.assign(new Error("invalid_plan_amount"),{code:"invalid_plan_amount"});
 const {data:sibling}=await admin.from("subscription_provider_prices").select("external_product_id").eq("provider","stripe").eq("plan_version_id",planVersion.id).eq("livemode",livemode).eq("active",true).limit(1).maybeSingle();
 let productId=sibling?.external_product_id||"";
 if(!productId){const product=await stripe.products.create({name:`Piloz ${planVersion.name}`,description:`Abonnement Piloz ${planVersion.name}`,tax_code:PILOZ_TAX_CODE,metadata:{piloz_plan_key:planVersion.plan_key,piloz_plan_version_id:planVersion.id}},{idempotencyKey:`piloz-product-${planVersion.id}-${livemode?"live":"test"}`});productId=product.id;}
 else await stripe.products.update(productId,{tax_code:PILOZ_TAX_CODE});
 const price=await stripe.prices.create({product:productId,currency:"eur",unit_amount:amount,recurring:{interval:billingInterval==="annual"?"year":"month"},lookup_key:`piloz_${planVersion.plan_key}_${billingInterval}_v${planVersion.version}_${livemode?"live":"test"}`,metadata:{piloz_plan_key:planVersion.plan_key,piloz_plan_version_id:planVersion.id,billing_interval:billingInterval}},{idempotencyKey:`piloz-price-${planVersion.id}-${billingInterval}-${livemode?"live":"test"}`});
 const {data:created,error:createError}=await admin.from("subscription_provider_prices").upsert({provider:"stripe",plan_version_id:planVersion.id,billing_interval:billingInterval,currency:"eur",livemode,external_product_id:productId,external_price_id:price.id,active:true,updated_at:new Date().toISOString()},{onConflict:"provider,plan_version_id,billing_interval,currency,livemode"}).select("*").single();
 if(createError)throw createError;return created;
}

async function ensurePortalConfiguration(admin:SupabaseClient,stripe:Stripe,livemode:boolean,returnUrl:string){
 const {data:mappings,error}=await admin.from("subscription_provider_prices").select("external_product_id,external_price_id").eq("provider","stripe").eq("livemode",livemode).eq("active",true);
 if(error)throw error;
 const grouped=new Map<string,string[]>();for(const row of mappings||[]){if(!grouped.has(row.external_product_id))grouped.set(row.external_product_id,[]);grouped.get(row.external_product_id)?.push(row.external_price_id);}
 const products=[...grouped].slice(0,10).map(([product,prices])=>({product,prices:[...new Set(prices)]}));
 const features:any={customer_update:{enabled:true,allowed_updates:["name","email","address","tax_id"]},invoice_history:{enabled:true},payment_method_update:{enabled:true},subscription_cancel:{enabled:true,mode:"at_period_end",proration_behavior:"none",cancellation_reason:{enabled:true,options:["too_expensive","missing_features","switched_service","unused","other"]}},subscription_update:{enabled:products.length>0,default_allowed_updates:["price"],proration_behavior:"always_invoice",products}};
 const listed=await stripe.billingPortal.configurations.list({limit:100}),environment=livemode?"live":"test";
 const existing=listed.data.find(item=>item.active&&item.metadata?.piloz_managed==="true"&&item.metadata?.piloz_environment===environment);
 if(existing)return stripe.billingPortal.configurations.update(existing.id,{features,default_return_url:returnUrl});
 return stripe.billingPortal.configurations.create({name:`Piloz ${environment}`,features,default_return_url:returnUrl,metadata:{piloz_managed:"true",piloz_environment:environment}} as any);
}

async function customerProfile(stripe:Stripe,customerId:string){
 const raw=await stripe.customers.retrieve(customerId),customer=raw.deleted?null:raw;
 let taxId="";if(customer)try{const taxes=await stripe.customers.listTaxIds(customer.id,{limit:1});taxId=taxes.data[0]?.value||"";}catch{/* Le profil reste utilisable sans numéro fiscal. */}
 return customer?{name:customer.name||null,email:customer.email||null,line1:customer.address?.line1||null,line2:customer.address?.line2||null,postal:customer.address?.postal_code||null,city:customer.address?.city||null,country:customer.address?.country||null,taxId:taxId||null,defaultPaymentMethod:objectId(customer.invoice_settings?.default_payment_method)}:null;
}

async function claimCheckout(admin:SupabaseClient,stripe:Stripe,user:{id:string;email?:string|null},companyId:string,sessionId:string){
 if(!/^cs_[A-Za-z0-9_]+$/.test(sessionId))throw Object.assign(new Error("invalid_checkout_claim"),{code:"invalid_checkout_claim",statusCode:400});
 const {data:claim,error:claimError}=await admin.from("stripe_checkout_claims").select("*").eq("checkout_session_id",sessionId).maybeSingle();
 if(claimError)throw claimError;if(!claim)throw Object.assign(new Error("checkout_claim_not_found"),{code:"checkout_claim_not_found",statusCode:404});
 if(claim.status==="claimed"&&claim.claimed_company_id===companyId)return{claimed:true,idempotent:true};
 const {data:grant,error:grantError}=await admin.from("stripe_onboarding_grants").select("*").eq("checkout_claim_id",claim.id).maybeSingle();
 if(grantError)throw grantError;
 if(claim.status!=="completed"||!grant||grant.status!=="ready")throw Object.assign(new Error("checkout_webhook_pending"),{code:"checkout_webhook_pending",statusCode:409});
 if(new Date(grant.expires_at)<=new Date()||new Date(claim.expires_at)<=new Date())throw Object.assign(new Error("checkout_claim_expired"),{code:"checkout_claim_expired",statusCode:409});
 const checkout=await stripe.checkout.sessions.retrieve(sessionId,{expand:["subscription","customer"]});
 if(checkout.status!=="complete"||!checkout.subscription)throw Object.assign(new Error("checkout_not_complete"),{code:"checkout_not_complete",statusCode:409});
 const checkoutEmail=String(checkout.customer_details?.email||(typeof checkout.customer!=="string"&&!checkout.customer?.deleted?checkout.customer?.email:"")||claim.checkout_email||"").trim().toLowerCase();
 if(!checkoutEmail||checkoutEmail!==String(user.email||"").trim().toLowerCase())throw Object.assign(new Error("checkout_email_mismatch"),{code:"checkout_email_mismatch",statusCode:403});
 const {data:planVersion,error:versionError}=await admin.from("subscription_plan_versions").select("id,plan_key,price_monthly_cents,price_annual_cents").eq("id",claim.plan_version_id).maybeSingle();
 if(versionError||!planVersion)throw versionError||new Error("plan_version_missing");
 const subscriptionId=objectId(checkout.subscription),customerId=objectId(checkout.customer);
 await stripe.customers.update(customerId,{metadata:{piloz_company_id:companyId}});
 const updated=await stripe.subscriptions.update(subscriptionId,{metadata:{piloz_company_id:companyId,piloz_plan_key:planVersion.plan_key,piloz_plan_version_id:planVersion.id,billing_interval:claim.billing_interval},expand:["default_payment_method","items.data.price"]});
 const profile=await customerProfile(stripe,customerId);let method:any=updated.default_payment_method||profile?.defaultPaymentMethod;if(typeof method==="string")method=await stripe.paymentMethods.retrieve(method).catch(()=>null);
 const paymentDetails=method?.card||method?.sepa_debit||method?.us_bank_account||null,card=method?.card||null,periodEnd=(updated as any).current_period_end||(updated as any).items?.data?.[0]?.current_period_end,periodStart=(updated as any).current_period_start||(updated as any).items?.data?.[0]?.current_period_start;
 const {error:updateError}=await admin.from("subscriptions").update({provider:"stripe",external_customer_id:customerId,external_subscription_id:subscriptionId,plan_key:planVersion.plan_key,plan_version_id:planVersion.id,billing_interval:claim.billing_interval,status:subscriptionStatus(updated.status),payment_status:["trialing","active"].includes(updated.status)?"paid":"not_configured",trial_started_at:iso((updated as any).trial_start),trial_ends_at:iso((updated as any).trial_end),subscription_started_at:iso((updated as any).start_date||periodStart),subscription_ends_at:iso(periodEnd),renewal_at:iso(periodEnd),contract_monthly_cents:planVersion.price_monthly_cents,contract_annual_cents:planVersion.price_annual_cents,payment_method_brand:card?.brand||method?.type||null,payment_method_last4:paymentDetails?.last4||null,payment_method_exp_month:card?.exp_month||null,payment_method_exp_year:card?.exp_year||null,billing_name:profile?.name||null,billing_email:profile?.email||checkoutEmail,billing_address_line1:profile?.line1||null,billing_address_line2:profile?.line2||null,billing_postal_code:profile?.postal||null,billing_city:profile?.city||null,billing_country:profile?.country||null,billing_tax_id:profile?.taxId||null,billing_profile_updated_at:new Date().toISOString(),provider_updated_at:new Date().toISOString()}).eq("company_id",companyId);
 if(updateError)throw updateError;
 const {error:markError}=await admin.from("stripe_checkout_claims").update({status:"claimed",checkout_email:checkoutEmail,external_customer_id:customerId,external_subscription_id:subscriptionId,claimed_company_id:companyId,claimed_user_id:user.id,claimed_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",claim.id).in("status",["pending","completed"]);
 if(markError)throw markError;
 const {error:consumeError}=await admin.from("stripe_onboarding_grants").update({status:"consumed",consumed_by_user_id:user.id,consumed_by_company_id:companyId,consumed_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",grant.id).eq("status","ready");
 if(consumeError)throw consumeError;
 await admin.from("stripe_checkout_audit_events").insert({checkout_claim_id:claim.id,event_key:`claim:${claim.id}:${user.id}`,event_type:"onboarding.claimed",outcome:"accepted",details:{company_id:companyId}});
 return{claimed:true,planKey:planVersion.plan_key,billingInterval:claim.billing_interval,status:subscriptionStatus(updated.status)};
}

Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
 if(req.method!=="POST")return response(req,{error:"Méthode non autorisée"},405);
 const origin=req.headers.get("origin")||"";if(origin&&!allowedOrigins.has(origin))return response(req,{error:"Origine non autorisée"},403);
 const authorization=req.headers.get("authorization");if(!authorization?.startsWith("Bearer "))return response(req,{error:"Authentification requise"},401);
 const supabaseUrl=Deno.env.get("SUPABASE_URL"),anonKey=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),stripeKey=Deno.env.get("STRIPE_SECRET_KEY");
 if(!supabaseUrl||!anonKey||!serviceKey)return response(req,{error:"Configuration Supabase indisponible",code:"server_not_configured"},503);
 if(!stripeKey)return response(req,{error:"Le paiement en ligne n’est pas encore configuré.",code:"stripe_not_configured",configured:false},503);
 const userClient=createClient(supabaseUrl,anonKey,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}}),admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error:userError}=await userClient.auth.getUser();if(userError||!user)return response(req,{error:"Session invalide"},401);
 let body:Record<string,unknown>;try{body=await req.json();}catch{return response(req,{error:"Requête invalide"},400);}
 const action=text(body.action,30),companyId=uuid(body.companyId),planKey=text(body.planKey,40),billingInterval=text(body.billingInterval,20)||"monthly";
 if(!companyId)return response(req,{error:"Entreprise invalide"},400);
 const {data:member}=await userClient.from("company_members").select("role").eq("company_id",companyId).eq("user_id",user.id).maybeSingle();
 if(!member||!["owner","admin"].includes(member.role))return response(req,{error:"Seul un propriétaire ou administrateur peut gérer l’abonnement."},403);
 const stripe=new Stripe(stripeKey,{httpClient:Stripe.createFetchHttpClient()}),livemode=stripeKey.startsWith("sk_live_"),appUrl=safeAppUrl(req),returnUrl=`${appUrl}/#settings/subscription`;
 try{
  if(action==="claim")return response(req,await claimCheckout(admin,stripe,user,companyId,text(body.sessionId,180)));
  const {data:subscription,error:subscriptionError}=await admin.from("subscriptions").select("*").eq("company_id",companyId).maybeSingle();
  if(subscriptionError||!subscription)return response(req,{error:"Abonnement introuvable"},404);
  if(action==="portal"){
   if(!subscription.external_customer_id)return response(req,{error:"Aucun compte de paiement n’est encore associé à cette entreprise.",code:"stripe_customer_missing"},409);
   const configuration=await ensurePortalConfiguration(admin,stripe,livemode,returnUrl),session=await stripe.billingPortal.sessions.create({customer:subscription.external_customer_id,configuration:configuration.id,return_url:returnUrl});
   return response(req,{url:session.url,mode:"portal"});
  }
  if(action!=="checkout")return response(req,{error:"Action inconnue"},400);
  if(!["monthly","annual"].includes(billingInterval))return response(req,{error:"Périodicité invalide"},400);
  const targetPlan=planKey||subscription.plan_key,planVersion=await currentPlanVersion(admin,targetPlan);if(!planVersion)return response(req,{error:"Cette offre n’est pas disponible."},404);
  const mapping=await ensurePrice(admin,stripe,planVersion,billingInterval,livemode);
  if(subscription.external_subscription_id&&subscription.external_customer_id){
   const current=await stripe.subscriptions.retrieve(subscription.external_subscription_id,{expand:["items.data.price"]}),item=current.items.data[0];
   if(!item)throw Object.assign(new Error("subscription_item_missing"),{code:"subscription_item_missing"});
   if(objectId(item.price)===mapping.external_price_id)return response(req,{error:"Cette offre est déjà active.",code:"plan_already_active"},409);
   const configuration=await ensurePortalConfiguration(admin,stripe,livemode,returnUrl),successUrl=`${returnUrl}?stripe=success`;
   const session=await stripe.billingPortal.sessions.create({customer:subscription.external_customer_id,configuration:configuration.id,return_url:returnUrl,flow_data:{type:"subscription_update_confirm",after_completion:{type:"redirect",redirect:{return_url:successUrl}},subscription_update_confirm:{subscription:subscription.external_subscription_id,items:[{id:item.id,price:mapping.external_price_id,quantity:1}]}}} as any);
   return response(req,{url:session.url,mode:"portal_update"});
  }
  let customerId=subscription.external_customer_id as string|null;
  if(!customerId){
   const {data:settings}=await admin.from("company_settings").select("legal_name,trade_name,email,siret,vat_number").eq("company_id",companyId).maybeSingle();
   const customer=await stripe.customers.create({email:text(settings?.email||user.email,254)||undefined,name:text(settings?.trade_name||settings?.legal_name,160)||undefined,metadata:{piloz_company_id:companyId,piloz_siret:text(settings?.siret,20),piloz_vat_number:text(settings?.vat_number,30)}},{idempotencyKey:`piloz-customer-${companyId}-${livemode?"live":"test"}`});
   customerId=customer.id;await admin.from("subscriptions").update({external_customer_id:customerId,provider_updated_at:new Date().toISOString()}).eq("company_id",companyId);
  }
  const successUrl=`${returnUrl}?stripe=success&session_id={CHECKOUT_SESSION_ID}`,cancelUrl=`${returnUrl}?stripe=cancelled`,trialEnd=subscription.status==="trialing"&&subscription.trial_ends_at&&new Date(subscription.trial_ends_at).getTime()>Date.now()+3600000?Math.floor(new Date(subscription.trial_ends_at).getTime()/1000):null;
  const subscriptionData:any={metadata:{piloz_company_id:companyId,piloz_plan_key:targetPlan,piloz_plan_version_id:planVersion.id,billing_interval:billingInterval},trial_settings:{end_behavior:{missing_payment_method:"cancel"}}};if(trialEnd)subscriptionData.trial_end=trialEnd;
   const checkout=await stripe.checkout.sessions.create({mode:"subscription",payment_method_collection:"always",allow_promotion_codes:true,customer:customerId,client_reference_id:companyId,line_items:[{price:mapping.external_price_id,quantity:1}],success_url:successUrl,cancel_url:cancelUrl,billing_address_collection:"required",customer_update:{address:"auto",name:"auto"},subscription_data:subscriptionData,metadata:{piloz_company_id:companyId,piloz_plan_key:targetPlan,piloz_plan_version_id:planVersion.id,billing_interval:billingInterval}},{idempotencyKey:`piloz-checkout-${companyId}-${planVersion.id}-${billingInterval}-${Math.floor(Date.now()/300000)}`});
  if(!checkout.url)throw new Error("checkout_url_missing");return response(req,{url:checkout.url,mode:"checkout",trialEndsAt:trialEnd?new Date(trialEnd*1000).toISOString():null});
 }catch(error){
  const cause=error as {type?:string;code?:string;statusCode?:number};
  console.error("[PILOZ Stripe] billing action failed",{action,companyId,type:cause.type||"unknown",code:cause.code||"unknown",status:cause.statusCode||500});
  const messages:Record<string,string>={checkout_email_mismatch:"Utilisez la même adresse e-mail que celle saisie lors du paiement Stripe.",checkout_claim_expired:"Ce lien de paiement a expiré. Recommencez depuis piloz.fr.",checkout_claim_not_found:"Ce paiement Stripe est introuvable ou a déjà été utilisé.",checkout_not_complete:"Le moyen de paiement Stripe n’a pas encore été confirmé.",checkout_webhook_pending:"Stripe confirme encore votre paiement. Patientez quelques secondes puis réessayez.",plan_already_active:"Cette offre est déjà active."};
  const code=cause.code||"stripe_request_failed",message=messages[code]||"Le service de paiement est temporairement indisponible. Réessayez dans quelques instants.";
  return response(req,{error:message,code},cause.statusCode&&cause.statusCode<500?cause.statusCode:502);
 }
});
