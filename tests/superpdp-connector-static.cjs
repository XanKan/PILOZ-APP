const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const edge=read('supabase/functions/platform-connector/index.ts');
const migration=read('supabase/migrations/202607270097_superpdp_sandbox_connector.sql');
const ui=read('assets/js/modules/erp/erp-electronic-invoicing.js');
const app=read('assets/js/modules/erp/erp-app.js');
const modern=read('assets/js/modules/erp/erp-modern.js');
const html=read('index.html');

const checks={
  credentials_are_server_secrets:edge.includes('Deno.env.get("SUPERPDP_CLIENT_ID")')&&edge.includes('Deno.env.get("SUPERPDP_CLIENT_SECRET")'),
  client_credentials_flow:edge.includes('grant_type: "client_credentials"')&&edge.includes('/oauth2/token'),
  confidential_client_auth:edge.includes('Authorization: `Basic ${basic}`'),
  sandbox_company_verified:edge.includes('/v1.beta/companies/me')&&edge.includes('company.environment !== "sandbox"'),
  facturx_test_generated:edge.includes('/v1.beta/invoices/generate_test_invoice?format=factur-x'),
  sandbox_invoice_queued:edge.includes('/v1.beta/invoices?external_id='),
  explicit_confirmation:edge.includes('SEND_SUPERPDP_SANDBOX_TEST'),
  production_locked:edge.includes('environment !== "sandbox"')&&/production_enabled[\s\S]{0,500}false/.test(migration),
  no_service_role_in_browser:!ui.includes('SERVICE_ROLE')&&!ui.includes('SUPERPDP_CLIENT_SECRET'),
  audited_connector:migration.includes('configure_superpdp_sandbox_connector')&&migration.includes('record_superpdp_sandbox_test_transmission'),
  tenant_permission_guard:migration.includes("has_company_permission(target_company_id,'electronic_invoice_manage')"),
  rpcs_not_public:migration.includes('revoke all on function public.configure_superpdp_sandbox_connector')&&migration.includes('revoke all on function public.record_superpdp_sandbox_test_transmission'),
  settings_route:app.includes("'settings/einvoicing':'settings'")&&modern.includes("['settings/einvoicing','Facturation électronique']"),
  ui_loaded:html.includes('erp-electronic-invoicing.js'),
  ui_never_claims_production:ui.includes('Production non activée')&&ui.includes('Elle ne part jamais en production.')
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
