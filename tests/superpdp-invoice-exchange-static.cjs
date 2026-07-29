const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const edge=read('supabase/functions/platform-connector/index.ts');
const sandboxMigration=read('supabase/migrations/202607270098_superpdp_sandbox_invoice_exchange.sql');
const productionMigration=read('supabase/migrations/202607280101_superpdp_production_oauth.sql');
const viewer=read('assets/js/modules/erp/erp-document-viewer-v2.js');
const supplier=read('assets/js/modules/erp/erp-superpdp-workspace.js');
const app=read('assets/js/modules/erp/erp-app.js');
const html=read('index.html');

const checks={
  dual_environment_register:productionMigration.includes("check(environment in('sandbox','production'))")&&productionMigration.includes('superpdp_invoice_exchanges_external_environment_uidx'),
  automatic_environment_selection:edge.includes('preferredEnvironment(')&&edge.includes("return data ? \"production\" : \"sandbox\""),
  production_oauth_token:edge.includes('productionToken(')&&edge.includes('SUPERPDP_TOKEN_ENCRYPTION_KEY'),
  facturx_conversion:edge.includes('to === "factur-x"')&&edge.includes('new FormData()')&&edge.includes('application/pdf'),
  cii_conversion:edge.includes('to: "cii"')&&edge.includes('format: "cii"'),
  en16931_vat_amount_contract:edge.includes('total_vat_amount: { value: decimal(totals.tax, true)')&&!edge.includes('total_vat_amount: { amount: decimal(totals.tax, true)'),
  afnor_billing_process:edge.includes('business_process_type: processCode')&&edge.includes('billingProcessCode(invoice, invoiceLines, totals, payload.references)'),
  afnor_mandatory_notes:['PMT','PMD','AAB'].every(code=>edge.includes(`subject_code: "${code}"`)),
  french_siren_legal_identifier:edge.includes('scheme: "0002"')&&edge.includes('legal_registration_identifier: sirenIdentifier(supplier)'),
  siret_private_identifier:edge.includes('scheme: "0009"')&&edge.includes('identifiers: privatePartyIdentifiers(supplier)'),
  sandbox_party_substitution_only_in_test:edge.includes('targetEnvironment === "sandbox" ? await sandboxRoutedInvoice')&&edge.includes('sandbox_party_substitution: targetEnvironment === "sandbox"'),
  legal_pdf_not_overwritten_by_test_artifact:edge.includes('The legal Piloz PDF remains immutable')&&!edge.includes('convertInvoice(token, "en16931", "factur-x", transmittedInvoice, pdf)'),
  provider_refusal_actionable:edge.includes('Détail SUPER PDP')&&edge.includes('providerMessage'),
  outside_scope_vat_rate_omitted:edge.includes('!["O", "E"].includes(category)')&&edge.includes('BR-O-05 forbids BT-152'),
  optional_empty_values_removed:edge.includes('function compactJson(value: unknown)')&&edge.includes('return compactJson(result) as JsonObject'),
  outgoing_send_action:edge.includes('superpdp_send_document')&&edge.includes('service_create_canonical_invoice_record'),
  incoming_sync_action:edge.includes('superpdp_sync_incoming')&&edge.includes('direction=in&limit=100')&&edge.includes('document_type: "purchase_invoice"'),
  incoming_environment_reported:edge.includes('environment: targetEnvironment'),
  partial_import_reported:edge.includes('failed: results.filter')&&supplier.includes('n’ont pas pu être intégrées'),
  customer_pdf_xml_tabs:viewer.includes("setPreviewFormat('pdf')")&&viewer.includes("setPreviewFormat('xml')")&&viewer.includes('downloadElectronicXml'),
  customer_send_and_status:viewer.includes('sendElectronicInvoice')&&viewer.includes('syncElectronicStatus'),
  supplier_pdf_xml_tabs:supplier.includes("setMode('pdf')")&&supplier.includes("setMode('xml')")&&supplier.includes('downloadXml'),
  supplier_connector_label:supplier.includes('<b>SUPER PDP</b>')&&supplier.includes('Configurer SUPER PDP'),
  no_visible_test_environment_copy:![viewer,supplier].some(source=>/bac à sable|environnement de test|Échange de test|Envoyer au bac/i.test(source)),
  supplier_workspace_loaded:html.includes('erp-superpdp-workspace.js')&&html.includes('document-viewer-v2.css'),
  exchange_tables:sandboxMigration.includes('public.superpdp_invoice_exchanges')&&sandboxMigration.includes('public.superpdp_invoice_events'),
  immutable_event_log:sandboxMigration.includes('superpdp_invoice_events_immutable')&&sandboxMigration.includes('protect_immutable_fiscal_row'),
  tenant_rls:sandboxMigration.includes('enable row level security')&&sandboxMigration.includes('public.is_company_member(company_id)'),
  exchange_data_loaded:app.includes('superpdpInvoiceExchanges')&&app.includes('superpdpInvoiceEvents')&&app.includes('electronicInvoiceRecords'),
  no_browser_secret:!viewer.includes('SUPERPDP_CLIENT_SECRET')&&!supplier.includes('SUPERPDP_CLIENT_SECRET')&&!html.includes('SUPERPDP_CLIENT_SECRET')
};

const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
