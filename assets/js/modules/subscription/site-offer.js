(function(global){
 'use strict';
 const STORAGE_KEY='piloz_requested_offer_v1',CLAIM_KEY='piloz_stripe_checkout_claim_v1',PLANS=new Set(['essential','pro','business']),BILLING=new Set(['monthly','annual']);
 function normalize(value){
  const plan=String(value?.plan_key||value?.plan||'').trim().toLowerCase(),billing=String(value?.billing_interval||value?.billing||'').trim().toLowerCase();
  if(!PLANS.has(plan))return null;
  return{plan_key:plan,billing_interval:BILLING.has(billing)?billing:'monthly',source:String(value?.source||'piloz-site').slice(0,40),captured_at:value?.captured_at||new Date().toISOString()};
 }
 function read(){try{return normalize(JSON.parse(localStorage.getItem(STORAGE_KEY)||'null'));}catch{return null;}}
 function write(value){const offer=normalize(value);try{if(offer)localStorage.setItem(STORAGE_KEY,JSON.stringify(offer));else localStorage.removeItem(STORAGE_KEY);}catch{}return offer;}
 function captureUrl(){const params=new URLSearchParams(location.search),plan=params.get('plan');if(!plan)return read();return write({plan,billing:params.get('billing'),source:params.get('source')||'piloz-site'});}
 function captureUser(user){if(read())return read();const metadata=user?.user_metadata||user?.raw_user_meta_data||{};return write({plan:metadata.requested_plan,billing:metadata.requested_billing_interval,source:'auth-metadata'});}
 function current(){return read();}
 function clear(){write(null);}
 function readClaim(){try{const value=JSON.parse(localStorage.getItem(CLAIM_KEY)||'null');if(!value||!/^cs_[A-Za-z0-9_]+$/.test(String(value.sessionId||'')))return null;return{sessionId:value.sessionId,capturedAt:value.capturedAt||null};}catch{return null;}}
 function writeClaim(value){try{if(value)localStorage.setItem(CLAIM_KEY,JSON.stringify(value));else localStorage.removeItem(CLAIM_KEY);}catch{}return value;}
 function captureCheckout(){
  const params=new URLSearchParams(location.search),sessionId=params.get('session_id');
  if(params.get('stripe')!=='checkout_success'||!sessionId)return readClaim();
  const offer=normalize({plan:params.get('plan'),billing:params.get('billing'),source:'stripe-checkout'});if(offer)write(offer);
  const claim=writeClaim({sessionId,capturedAt:new Date().toISOString()});
  ['stripe','session_id','claim'].forEach(key=>params.delete(key));history.replaceState(null,'',location.pathname+(params.toString()?`?${params}`:'')+location.hash);
  return claim;
 }
 async function claimAfterAuth(){
  const pending=readClaim();if(!pending)return null;
  if(!global.PilozRuntime?.session||!global.PilozERP)throw new Error('La session Piloz n’est pas encore prête.');
  const companyId=await global.PilozERP.companyContext(),result=await global.PilozERP.invoke('stripe-billing',{action:'claim',companyId,sessionId:pending.sessionId});
  if(!result?.claimed)throw new Error('La confirmation Stripe n’a pas pu être rattachée au compte.');
  writeClaim(null);clear();const params=new URLSearchParams(location.search);['mode','plan','billing','source'].forEach(key=>params.delete(key));history.replaceState(null,'',location.pathname+(params.toString()?`?${params}`:'')+location.hash);return result;
 }
 async function verifyLicenseAccess(){
  if(!global.PilozRuntime?.session||!global.PilozERP)throw Object.assign(new Error('La session Piloz n’est pas encore prête.'),{code:'session_not_ready'});
  const result=await global.PilozERP.invoke('license-access',{});
  if(!result?.allowed){
   const error=new Error('Aucune licence Piloz active n’est associée à ce compte. Souscrivez une offre ou contactez l’administrateur de votre entreprise.');
   error.code=result?.reason||'license_required';throw error;
  }
  return result;
 }
 function hasPendingCheckout(){return!!readClaim();}
 function routeAfterAuth(){
  const offer=current();if(!offer)return false;
  const params=new URLSearchParams(location.search);['mode','plan','billing','source'].forEach(key=>params.delete(key));
  const query=params.toString(),hash=`settings/subscription?offer=${encodeURIComponent(offer.plan_key)}&billing=${encodeURIComponent(offer.billing_interval)}`;
  history.replaceState(null,'',location.pathname+(query?`?${query}`:'')+`#${hash}`);return true;
 }
 captureUrl();captureCheckout();
 global.PilozSiteOffer={normalize,current,set:write,clear,captureUrl,captureUser,routeAfterAuth};
 global.PilozCheckoutClaim={current:readClaim,clear:()=>writeClaim(null),captureUrl:captureCheckout,hasPending:hasPendingCheckout,claimAfterAuth,verifyLicenseAccess};
})(window);
