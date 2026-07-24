const fs=require('node:fs');
const index=fs.readFileSync('index.html','utf8'),guard=fs.readFileSync('assets/js/auth-guard.js','utf8'),offer=fs.readFileSync('assets/js/modules/subscription/site-offer.js','utf8'),modern=fs.readFileSync('assets/js/modules/erp/erp-modern.js','utf8');
const checks={
 strict_plan_allowlist:offer.includes("new Set(['essential','pro','business'])"),
 strict_billing_allowlist:offer.includes("new Set(['monthly','annual'])"),
 signup_metadata:index.includes('requested_plan:requestedOffer?.plan_key')&&index.includes('requested_billing_interval:requestedOffer?.billing_interval'),
 login_restores_choice:index.includes('PilozSiteOffer?.captureUser?.(j.user)'),
 session_restores_choice:guard.includes('PilozSiteOffer?.captureUser(user)'),
 route_after_auth:index.includes('PilozSiteOffer?.routeAfterAuth?.()'),
 checkout_claim_captured:offer.includes("CLAIM_KEY='piloz_stripe_checkout_claim_v1'")&&offer.includes('history.replaceState')&&offer.includes("action:'claim'"),
 checkout_choice_kept_until_confirmation:!modern.includes("if(action==='checkout')global.PilozSiteOffer?.clear?.()"),
 direct_signup_requires_checkout:index.includes('href="https://piloz.fr/#tarifs"')&&index.includes('Moyen de paiement requis'),
 stripe_secret_absent:!offer.includes('STRIPE_SECRET_KEY')&&!index.includes('STRIPE_SECRET_KEY')
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);console.log(JSON.stringify({ok:!failed.length,checks,failed}));if(failed.length)process.exitCode=1;
