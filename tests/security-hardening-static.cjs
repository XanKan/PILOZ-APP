const fs=require('node:fs');

const html=fs.readFileSync('index.html','utf8');
const csp=html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/i)?.[1]||'';
const privilegedMarkers=['SUPABASE_'+'SERVICE_ROLE_KEY','service_'+'role'];
const checks={
  private_application_not_indexed:html.includes('<meta name="robots" content="noindex, nofollow">'),
  strict_referrer_policy:html.includes('<meta name="referrer" content="strict-origin-when-cross-origin">'),
  content_security_policy_present:Boolean(csp),
  plugins_blocked:csp.includes("object-src 'none'"),
  base_uri_restricted:csp.includes("base-uri 'self'"),
  forms_restricted:csp.includes("form-action 'self' https://*.supabase.co"),
  insecure_requests_upgraded:csp.includes('upgrade-insecure-requests'),
  no_browser_privileged_marker:!privilegedMarkers.some(marker=>html.includes(marker))
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
