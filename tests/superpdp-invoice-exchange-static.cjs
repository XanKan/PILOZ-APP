const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const edge=read('supabase/functions/platform-connector/index.ts');
const migration=read('supabase/migrations/202607270098_superpdp_sandbox_invoice_exchange.sql');
const viewer=read('assets/js/modules/erp/erp-document-viewer-v2.js');
const supplier=read('assets/js/modules/erp/erp-superpdp-workspace.js');
const app=read('assets/js/modules/erp/erp-app.js');
const html=read('index.html');

const checks={
  sandbox_hard_lock:edge.includes('SUPERPDP_ENVIRONMENT')&&edge.includes('superpdp_sandbox_required')&&migration.includes("check(environment='sandbox')"),
  provider_environment_verified:edge.includes('/v1.beta/companies/me')&&edge.includes('company.environment !== "sandbox"'),
  piloz_stays_in_production:edge.includes('appEnvironment: "production"')&&supplier.includes('PILOZ reste en production'),
  production_action_rejected:edge.includes('if (action === "production")')&&edge.includes('volontairement verrouillé sur le bac à sable'),
  facturx_conversion:edge.includes('to === "factur-x"')&&edge.includes('new FormData()')&&edge.includes('application/pdf'),
  cii_conversion:edge.includes('to: "cii"')&&edge.includes('format: "cii"'),
  outgoing_send_action:edge.includes('superpdp_send_document')&&edge.includes('create_canonical_invoice_record'),
  incoming_sync_action:edge.includes('superpdp_sync_incoming')&&edge.includes('direction=in&limit=100')&&edge.includes('document_type: "purchase_invoice"'),
  provider_direction_values:!edge.includes('direction=incoming&')&&!edge.includes('direction=outgoing&'),
  incoming_error_is_actionable:edge.includes('superpdp_incoming_list_failed')&&edge.includes('entreprise sandbox est bien valid'),
  customer_pdf_xml_tabs:viewer.includes("setPreviewFormat('pdf')")&&viewer.includes("setPreviewFormat('xml')")&&viewer.includes('downloadElectronicXml')&&viewer.includes('Télécharger'),
  customer_send_and_status:viewer.includes('sendElectronicInvoice')&&viewer.includes('syncElectronicStatus'),
  supplier_pdf_xml_tabs:supplier.includes("setMode('pdf')")&&supplier.includes("setMode('xml')")&&supplier.includes('downloadXml'),
  supplier_workspace_loaded:html.includes('erp-superpdp-workspace.js')&&html.includes('document-viewer-v2.css'),
  exchange_tables:migration.includes('public.superpdp_invoice_exchanges')&&migration.includes('public.superpdp_invoice_events'),
  immutable_event_log:migration.includes('superpdp_invoice_events_immutable')&&migration.includes('protect_immutable_fiscal_row'),
  tenant_rls:migration.includes('enable row level security')&&migration.includes('public.is_company_member(company_id)'),
  private_artifact_bucket:migration.includes("where id='company-files'")&&migration.includes('public=false')&&migration.includes("'application/xml'"),
  exchange_data_loaded:app.includes('superpdpInvoiceExchanges')&&app.includes('superpdpInvoiceEvents')&&app.includes('electronicInvoiceRecords'),
  no_browser_secret:!viewer.includes('SUPERPDP_CLIENT_SECRET')&&!supplier.includes('SUPERPDP_CLIENT_SECRET')&&!html.includes('SUPERPDP_CLIENT_SECRET'),
  no_browser_service_role:!viewer.includes('SUPABASE_SERVICE_ROLE_KEY')&&!supplier.includes('SUPABASE_SERVICE_ROLE_KEY')
};

const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
