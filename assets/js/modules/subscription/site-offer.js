(function(global){
 'use strict';
 const STORAGE_KEY='piloz_requested_offer_v1',PLANS=new Set(['essential','pro','business']),BILLING=new Set(['monthly','annual']);
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
 function routeAfterAuth(){
  const offer=current();if(!offer)return false;
  const params=new URLSearchParams(location.search);['mode','plan','billing','source'].forEach(key=>params.delete(key));
  const query=params.toString(),hash=`settings/subscription?offer=${encodeURIComponent(offer.plan_key)}&billing=${encodeURIComponent(offer.billing_interval)}`;
  history.replaceState(null,'',location.pathname+(query?`?${query}`:'')+`#${hash}`);return true;
 }
 captureUrl();
 global.PilozSiteOffer={normalize,current,set:write,clear,captureUrl,captureUser,routeAfterAuth};
})(window);
