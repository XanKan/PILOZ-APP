const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const edge=read('supabase/functions/platform-connector/index.ts');
const oauth=read('supabase/functions/superpdp-oauth/index.ts');
const sandboxMigration=read('supabase/migrations/202607270097_superpdp_sandbox_connector.sql');
const productionMigration=read('supabase/migrations/202607280101_superpdp_production_oauth.sql');
const ui=read('assets/js/modules/erp/erp-electronic-invoicing.js');
const app=read('assets/js/modules/erp/erp-app.js');
const modern=read('assets/js/modules/erp/erp-modern.js');
const extensions=read('assets/js/modules/erp/erp-accounting-extensions.js');
const html=read('index.html');

const checks={
  sandbox_credentials_are_server_secrets:edge.includes('Deno.env.get("SUPERPDP_CLIENT_ID")')&&edge.includes('Deno.env.get("SUPERPDP_CLIENT_SECRET")'),
  production_credentials_are_server_secrets:oauth.includes('Deno.env.get("SUPERPDP_PRODUCTION_CLIENT_ID")')&&oauth.includes('Deno.env.get("SUPERPDP_PRODUCTION_CLIENT_SECRET")'),
  sandbox_client_credentials_flow:edge.includes('grant_type: "client_credentials"')&&edge.includes('/oauth2/token'),
  production_authorization_code_flow:oauth.includes('grant_type: "authorization_code"')&&oauth.includes('/oauth2/authorize?')&&oauth.includes('code_challenge_method: "S256"'),
  tokens_encrypted_at_rest:oauth.includes('AES-GCM')&&oauth.includes('SUPERPDP_TOKEN_ENCRYPTION_KEY')&&productionMigration.includes('access_token_ciphertext'),
  production_company_verified:oauth.includes('/v1.beta/oauth2_sessions/me')&&oauth.includes('companyVerification === "verified"'),
  production_company_matches_siren:oauth.includes('provider_company_mismatch')&&oauth.includes('expectedSiren'),
  facturx_test_generated:edge.includes('/v1.beta/invoices/generate_test_invoice?format=factur-x'),
  invoices_use_selected_environment:edge.includes('preferredEnvironment(')&&edge.includes('targetEnvironment === "production"'),
  explicit_sandbox_confirmation:edge.includes('SEND_SUPERPDP_SANDBOX_TEST'),
  browser_has_no_secrets:!ui.includes('SERVICE_ROLE')&&!ui.includes('SUPERPDP_CLIENT_SECRET')&&!ui.includes('TOKEN_ENCRYPTION_KEY'),
  sandbox_audited:sandboxMigration.includes('configure_superpdp_sandbox_connector')&&sandboxMigration.includes('record_superpdp_sandbox_test_transmission'),
  production_consents_audited:productionMigration.includes('superpdp_consent_events')&&productionMigration.includes('authorization_granted'),
  production_jobs_are_private:productionMigration.includes('revoke all on public.superpdp_company_authorizations,public.superpdp_oauth_states,public.superpdp_jobs from anon,authenticated'),
  settings_route:app.includes("'settings/einvoicing':'settings'")&&modern.includes("['settings/einvoicing','Réception électronique fournisseurs']"),
  extension_catalog:extensions.includes("id:'superpdp'")&&extensions.includes("internalRoute:'settings/einvoicing'"),
  ui_loaded:html.includes('erp-electronic-invoicing.js'),
  reception_only_ui:ui.includes('SUPER PDP · Réception fournisseurs')&&ui.includes('Réception automatique active')&&!ui.includes('Les factures finalisées sont mises en file'),
  no_visible_sandbox_controls:!/bac à sable|environnement de test|Envoyer une facture de test|Tester la connexion/i.test(ui),
  piloz_remains_production:edge.includes('appEnvironment: "production"')
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
