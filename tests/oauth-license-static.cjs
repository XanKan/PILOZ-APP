const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const app=read('index.html');
const guard=read('assets/js/auth-guard.js');
const offer=read('assets/js/modules/subscription/site-offer.js');
const license=read('supabase/functions/license-access/index.ts');
const config=read('supabase/config.toml');
const checks={
 oauth_provider_names:app.includes("authOAuth('google')")&&app.includes("authOAuth('azure')"),
 oauth_buttons_follow_server_configuration:app.includes('const authSsoProviders=')&&app.includes('authLoadSsoProviders()')&&app.includes('if(authSsoProviders.google)')&&app.includes('if(authSsoProviders.azure)'),
 oauth_provider_preflight:app.includes("'/auth/v1/settings'")&&app.includes('settings?.external?.[provider]!==true'),
 microsoft_scopes:app.includes("openid email profile offline_access"),
 oauth_checkout_required_for_signup:app.includes("authMode==='signup'&&!window.PilozCheckoutClaim?.hasPending?.()"),
 server_license_gate:offer.includes("invoke('license-access',{})")&&license.includes('userClient.auth.getUser()'),
 all_auth_paths_gated:app.includes('verifyLicenseAccess?.()')&&guard.includes('verifyLicenseAccess?.()'),
 stripe_license_requires_payment:license.includes('subscription.payment_status==="paid"')&&license.includes('external_subscription_id'),
 unconfigured_trial_denied:license.includes('provider==="stripe"')&&license.includes('status==="active"'),
 manual_license_trial_supported:license.includes('status==="active"||status==="trialing"')&&license.includes('status==="trialing"?afterNow(subscription.trial_ends_at):afterNow(subscription.subscription_ends_at)'),
 no_legacy_auto_trial:!app.includes("toast('🎁 Votre essai gratuit")&&!app.includes("apiLic('POST', 'licences'"),
 authenticated_edge_function:/\[functions\.license-access\][\s\S]*verify_jwt\s*=\s*true/.test(config)
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
