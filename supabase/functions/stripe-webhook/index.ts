import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@20.4.0";

function json(data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store"}});}
function objectId(value:unknown){return typeof value==="string"?value:(value&&typeof value==="object"&&"id" in value?String((value as {id:unknown}).id):"");}
function iso(seconds:unknown){const value=Number(seconds);return Number.isFinite(value)&&value>0?new Date(value*1000).toISOString():null;}
function day(seconds:unknown){return iso(seconds)?.slice(0,10)||null;}
function status(value:string){if(value==="trialing")return"trialing";if(value==="active")return"active";if(["past_due","unpaid","incomplete"].includes(value))return"past_due";if(value==="paused")return"suspended";return"canceled";}
function invoiceStatus(value:string,forced?:string){if(forced)return forced;if(value==="paid")return"paid";if(value==="open")return"open";if(value==="void")return"void";if(value==="uncollectible")return"uncollectible";return"draft";}
function errorCode(error:unknown){const candidate=error as {code?:unknown;type?:unknown};return String(candidate?.code||candidate?.type||"webhook_processing_failed").replace(/[^a-z0-9_.-]/gi,"").slice(0,120);}

async function companyFromObject(admin:SupabaseClient,object:Record<string,unknown>){
 const metadata=(object.metadata&&typeof object.metadata==="object"?object.metadata:{}) as Record<string,unknown>,direct=String(metadata.piloz_company_id||"");
 if(/^[0-9a-f-]{36}$/i.test(direct))return direct;
 const subscriptionId=objectId(object.subscription),customerId=objectId(object.customer);
 if(subscriptionId){const {data}=await admin.from("subscriptions").select("company_id").eq("external_subscription_id",subscriptionId).maybeSingle();if(data?.company_id)return data.company_id;}
 if(customerId){const {data}=await admin.from("subscriptions").select("company_id").eq("external_customer_id",customerId).maybeSingle();if(data?.company_id)return data.company_id;}
 return"";
}

async function syncSubscription(admin:SupabaseClient,stripe:Stripe,raw:Stripe.Subscription,eventCreated:number){
 const subscription=raw.status==="canceled"?raw:await stripe.subscriptions.retrieve(raw.id,{expand:["default_payment_method","items.data.price"]});
 const source=subscription as unknown as Record<string,any>,companyId=await companyFromObject(admin,source);
 if(!companyId)throw Object.assign(new Error("company_not_resolved"),{code:"company_not_resolved"});
 const priceId=objectId(source.items?.data?.[0]?.price),{data:mapping}=priceId?await admin.from("subscription_provider_prices").select("plan_version_id,billing_interval").eq("provider","stripe").eq("external_price_id",priceId).maybeSingle():{data:null};
 let planVersion:any=null;
 if(mapping?.plan_version_id){const {data}=await admin.from("subscription_plan_versions").select("id,plan_key,price_monthly_cents,price_annual_cents").eq("id",mapping.plan_version_id).maybeSingle();planVersion=data;}
 const metadata=(source.metadata||{}) as Record<string,string>;
 if(!planVersion&&metadata.piloz_plan_version_id){const {data}=await admin.from("subscription_plan_versions").select("id,plan_key,price_monthly_cents,price_annual_cents").eq("id",metadata.piloz_plan_version_id).maybeSingle();planVersion=data;}
 const {data:before}=await admin.from("subscriptions").select("*").eq("company_id",companyId).maybeSingle();
 const previousEvent=before?.provider_event_created_at?Date.parse(before.provider_event_created_at)/1000:0;
 if(previousEvent>eventCreated)return companyId;
 let method:any=source.default_payment_method;
 if(typeof method==="string")try{method=await stripe.paymentMethods.retrieve(method);}catch{method=null;}
 const paymentDetails=method?.card||method?.sepa_debit||method?.us_bank_account||null,card=method?.card||null,periodEnd=source.current_period_end||source.items?.data?.[0]?.current_period_end,periodStart=source.current_period_start||source.items?.data?.[0]?.current_period_start;
 const patch:Record<string,unknown>={
  provider:"stripe",external_customer_id:objectId(source.customer),external_subscription_id:source.id,
  status:status(String(source.status||"canceled")),billing_interval:mapping?.billing_interval||metadata.billing_interval||before?.billing_interval||"monthly",
  payment_status:["active","trialing"].includes(source.status)?"paid":source.status==="past_due"?"past_due":"not_configured",
  subscription_started_at:iso(source.start_date||periodStart),subscription_ends_at:iso(periodEnd),renewal_at:iso(periodEnd),
  cancellation_at_period_end:Boolean(source.cancel_at_period_end),provider_event_created_at:iso(eventCreated),provider_updated_at:new Date().toISOString(),
  payment_method_brand:card?.brand||method?.type||null,payment_method_last4:paymentDetails?.last4||null,
  payment_method_exp_month:card?.exp_month||null,payment_method_exp_year:card?.exp_year||null
 };
 if(planVersion){Object.assign(patch,{plan_key:planVersion.plan_key,plan_version_id:planVersion.id,contract_monthly_cents:planVersion.price_monthly_cents,contract_annual_cents:planVersion.price_annual_cents});}
 const {data:after,error}=await admin.from("subscriptions").update(patch).eq("company_id",companyId).select("*").single();
 if(error)throw error;
 if(before&&JSON.stringify(before)!==JSON.stringify(after))await admin.from("subscription_events").insert({company_id:companyId,event_type:`stripe.subscription.${source.status}`,previous_state:before,new_state:after,reason:"Synchronisation Stripe",effective_at:iso(eventCreated)});
 return companyId;
}

async function syncInvoice(admin:SupabaseClient,invoice:Stripe.Invoice,forcedStatus?:string){
 const source=invoice as unknown as Record<string,any>,companyId=await companyFromObject(admin,source);
 if(!companyId)throw Object.assign(new Error("company_not_resolved"),{code:"company_not_resolved"});
 const subscriptionId=objectId(source.subscription),{data:subscription}=subscriptionId?await admin.from("subscriptions").select("plan_version_id,payment_method_brand").eq("external_subscription_id",subscriptionId).maybeSingle():{data:null};
 const tax=Array.isArray(source.total_tax_amounts)?source.total_tax_amounts.reduce((sum:number,row:any)=>sum+Number(row.amount||0),0):Math.max(0,Number(source.total||0)-Number(source.subtotal_excluding_tax??source.subtotal??0));
 const invoiceNumber=String(source.number||`STRIPE-${source.id}`),payload={company_id:companyId,number:source.livemode===false?`TEST-${invoiceNumber}`:invoiceNumber,period_start:day(source.period_start),period_end:day(source.period_end),plan_version_id:subscription?.plan_version_id||null,amount_excl_tax_cents:Number(source.subtotal_excluding_tax??source.subtotal??0),tax_cents:tax,amount_incl_tax_cents:Number(source.total||0),paid_cents:Number(source.amount_paid||0),status:invoiceStatus(String(source.status||"draft"),forcedStatus),issued_at:iso(source.status_transitions?.finalized_at||source.created),due_at:iso(source.due_date),provider:"stripe",external_invoice_id:source.id,idempotency_key:`stripe-invoice-${source.id}`,updated_at:new Date().toISOString()};
 const {data:stored,error}=await admin.from("platform_billing_invoices").upsert(payload,{onConflict:"provider,external_invoice_id"}).select("id").single();
 if(error)throw error;
 const paymentId=objectId(source.payment_intent)||objectId(source.charge)||objectId(source.payments?.data?.[0]?.payment?.payment_intent)||objectId(source.payments?.data?.[0]?.payment?.charge)||source.id;
 if(Number(source.amount_paid)>0&&["paid","succeeded"].includes(payload.status)){
  const {error:paymentError}=await admin.from("platform_billing_payments").upsert({company_id:companyId,invoice_id:stored.id,amount_cents:Number(source.amount_paid),currency:String(source.currency||"eur").toUpperCase(),status:"succeeded",payment_method:subscription?.payment_method_brand||null,paid_at:iso(source.status_transitions?.paid_at||source.created),provider:"stripe",external_payment_id:paymentId,idempotency_key:`stripe-payment-${paymentId}`},{onConflict:"provider,external_payment_id"});
  if(paymentError)throw paymentError;
 }
 return companyId;
}

async function syncRefunds(admin:SupabaseClient,charge:Stripe.Charge){
 const source=charge as unknown as Record<string,any>,paymentIntent=objectId(source.payment_intent),{data:payment}=paymentIntent?await admin.from("platform_billing_payments").select("id,company_id").eq("provider","stripe").eq("external_payment_id",paymentIntent).maybeSingle():{data:null};
 if(!payment)return"";
 for(const refund of source.refunds?.data||[]){if(Number(refund.amount)<=0)continue;const {error}=await admin.from("platform_billing_refunds").upsert({company_id:payment.company_id,payment_id:payment.id,amount_cents:Number(refund.amount),reason:String(refund.reason||"requested_by_customer"),status:String(refund.status||"succeeded"),refunded_at:iso(refund.created),provider:"stripe",external_refund_id:refund.id},{onConflict:"provider,external_refund_id"});if(error)throw error;}
 return payment.company_id;
}

Deno.serve(async req=>{
 if(req.method!=="POST")return json({error:"Méthode non autorisée"},405);
 const stripeKey=Deno.env.get("STRIPE_SECRET_KEY"),webhookSecret=Deno.env.get("STRIPE_WEBHOOK_SECRET"),supabaseUrl=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!stripeKey||!webhookSecret||!supabaseUrl||!serviceKey)return json({error:"Webhook non configuré"},503);
 const signature=req.headers.get("stripe-signature");if(!signature)return json({error:"Signature manquante"},400);
 const rawBody=await req.text(),stripe=new Stripe(stripeKey,{httpClient:Stripe.createFetchHttpClient()});
 let event:Stripe.Event;
 try{event=await stripe.webhooks.constructEventAsync(rawBody,signature,webhookSecret,undefined,Stripe.createSubtleCryptoProvider());}
 catch{console.warn("[PILOZ Stripe] invalid webhook signature");return json({error:"Signature invalide"},400);}
 const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}}),source=event.data.object as unknown as Record<string,unknown>,objectIdValue=String(source.id||"");
 const {data:existing}=await admin.from("stripe_webhook_events").select("status,attempts").eq("event_id",event.id).maybeSingle();
 if(existing?.status==="processed"||existing?.status==="ignored")return json({received:true,duplicate:true});
 if(existing)await admin.from("stripe_webhook_events").update({status:"processing",attempts:Number(existing.attempts||0)+1,updated_at:new Date().toISOString(),last_error_code:null}).eq("event_id",event.id);
 else{const {error}=await admin.from("stripe_webhook_events").insert({event_id:event.id,event_type:event.type,object_id:objectIdValue,livemode:event.livemode,event_created_at:iso(event.created),status:"processing"});if(error?.code==="23505")return json({received:true,duplicate:true});if(error)return json({error:"Journal webhook indisponible"},500);}
 let companyId="",handled=true;
 try{
  if(event.type==="checkout.session.completed"){
   const subscriptionId=objectId(source.subscription);companyId=await companyFromObject(admin,source);
   if(subscriptionId){const subscription=await stripe.subscriptions.retrieve(subscriptionId,{expand:["default_payment_method","items.data.price"]});companyId=await syncSubscription(admin,stripe,subscription,event.created);}
  }else if(["customer.subscription.created","customer.subscription.updated","customer.subscription.deleted","customer.subscription.paused","customer.subscription.resumed"].includes(event.type))companyId=await syncSubscription(admin,stripe,event.data.object as Stripe.Subscription,event.created);
  else if(["invoice.finalized","invoice.paid","invoice.payment_succeeded"].includes(event.type))companyId=await syncInvoice(admin,event.data.object as Stripe.Invoice);
  else if(event.type==="invoice.payment_failed")companyId=await syncInvoice(admin,event.data.object as Stripe.Invoice,"past_due");
  else if(event.type==="charge.refunded")companyId=await syncRefunds(admin,event.data.object as Stripe.Charge);
  else handled=false;
  await admin.from("stripe_webhook_events").update({company_id:companyId||null,status:handled?"processed":"ignored",processed_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("event_id",event.id);
  return json({received:true,handled});
 }catch(error){
  const code=errorCode(error);await admin.from("stripe_webhook_events").update({company_id:companyId||null,status:"failed",last_error_code:code,updated_at:new Date().toISOString()}).eq("event_id",event.id);
  console.error("[PILOZ Stripe] webhook processing failed",{eventId:event.id,eventType:event.type,objectId:objectIdValue,code});return json({error:"Traitement temporairement impossible"},500);
 }
});
