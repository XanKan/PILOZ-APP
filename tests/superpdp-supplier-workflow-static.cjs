const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const edge=read('supabase/functions/platform-connector/index.ts');
const supplier=read('assets/js/modules/erp/erp-superpdp-workspace.js');
const css=read('assets/css/document-viewer-v2.css');
const migration=read('supabase/migrations/202607270098_superpdp_sandbox_invoice_exchange.sql');

const lifecycleStatuses=['fr:204','fr:205','fr:206','fr:207','fr:208','fr:209','fr:210'];
const checks={
  lifecycle_action_routed:edge.includes('superpdp_create_invoice_event')&&edge.includes('createIncomingLifecycleEvent('),
  provider_event_api:edge.includes('superPdpRequest("/v1.beta/invoice_events", token')&&edge.includes('method: "POST"'),
  provider_event_sync:edge.includes('/v1.beta/invoice_events?invoice_id=')&&edge.includes('recordProviderEvents('),
  buyer_statuses_complete:lifecycleStatuses.every(code=>edge.includes(`"${code}"`)),
  sensitive_reason_required:edge.includes('["fr:206", "fr:207", "fr:208", "fr:210"].includes(statusCode)')&&edge.includes('superpdp_lifecycle_note_required'),
  purchase_invoice_only:edge.includes('document?.document_type !== "purchase_invoice"')&&edge.includes('.eq("direction", "incoming")'),
  tenant_permission_guard:edge.includes('target_permission: "purchases.invoices.write"')&&edge.includes('target_permission: "electronic_invoice_manage"'),
  immutable_provider_audit:edge.includes('event_type: "provider_lifecycle_event"')&&edge.includes('ignoreDuplicates: true')&&migration.includes('superpdp_invoice_events_immutable'),
  no_fake_local_status:supplier.includes("action: 'superpdp_create_invoice_event'")&&!supplier.includes('exchange.status = statusCode'),
  standard_review_actions:['Prendre en charge','Approuver','Refuser','Approuver partiellement','Mettre en litige','Suspendre','Terminer le traitement'].every(label=>supplier.includes(label)),
  reason_modal:supplier.includes('Motif transmis au fournisseur *')&&supplier.includes('required maxlength="1200"'),
  workflow_history:supplier.includes('Historique du traitement')&&supplier.includes('eventNote(event)'),
  automated_inbox_sync:supplier.includes('scheduleAutoSync()')&&supplier.includes('Date.now() - ui.lastAutoSyncAt < 120000'),
  accounting_separation:supplier.includes('ne comptabilise pas la facture')&&supplier.includes('aucun paiement'),
  workflow_styles:css.includes('.superpdp-workflow-badge')&&css.includes('.superpdp-workflow-modal-backdrop')&&css.includes('.superpdp-workflow-history'),
  desktop_review_panel:css.includes('@media(max-width:1280px) and (min-width:981px)')&&css.includes('.superpdp-supplier-side{display:block}')
};

const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
