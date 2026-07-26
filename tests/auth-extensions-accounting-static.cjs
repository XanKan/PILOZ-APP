const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');

const index=read('index.html');
const checkout=read('supabase/functions/stripe-public-checkout/index.ts');
const webhook=read('supabase/functions/stripe-webhook/index.ts');
const billing=read('supabase/functions/stripe-billing/index.ts');
const integrations=read('supabase/functions/external-integrations/index.ts');
const exportPackage=read('supabase/functions/accounting-export-package/index.ts');
const pdf=read('supabase/functions/generate-document-pdf/index.ts');
const ui=read('assets/js/modules/erp/erp-accounting-extensions.js');
const m70=read('supabase/migrations/202607260070_secure_checkout_onboarding.sql');
const m71=read('supabase/migrations/202607260071_extensions_and_sales_terms.sql');
const m72=read('supabase/migrations/202607260072_accounting_engine_exports.sql');
const m73=read('supabase/migrations/202607260073_sales_terms_snapshots_and_sync_queue.sql');
const m74=read('supabase/migrations/202607260074_external_sync_observability.sql');
const m85=read('supabase/migrations/202607260085_accounting_export_backfill_diagnostics.sql');

const browserSources=[index,ui,read('assets/js/modules/subscription/site-offer.js')].join('\n');
const checks={
 stripe_webhook_is_truth:webhook.includes('stripe_onboarding_grants')&&webhook.includes('constructEventAsync(rawBody,signature,webhookSecret')&&billing.includes('stripe_onboarding_grants'),
 stripe_redirect_not_proof:checkout.includes('stripe_checkout_claims')&&checkout.includes('payment_method_collection:"always"')&&m70.includes('status text not null default \'ready\''),
 onboarding_grant_private:m70.includes('enable row level security')&&m70.includes('revoke all on public.stripe_onboarding_grants,public.stripe_checkout_audit_events from public,anon,authenticated'),
 official_sso_vectors:index.includes('fill="#4285F4"')&&index.includes('fill="#F25022"')&&index.includes("authOAuth('azure')"),
 oauth_state_pkce:integrations.includes('code_challenge_method:"S256"')&&integrations.includes('state_hash:await sha(state)')&&integrations.includes('consumed_at'),
 oauth_secrets_encrypted:integrations.includes('AES-GCM')&&integrations.includes('external_connection_secrets')&&m71.includes('revoke all on public.external_connection_secrets'),
 browser_has_no_server_secrets:!browserSources.includes('SUPABASE_SERVICE_ROLE_KEY')&&!browserSources.includes('GOOGLE_OAUTH_CLIENT_SECRET')&&!browserSources.includes('MICROSOFT_OAUTH_CLIENT_SECRET')&&!browserSources.includes('STRIPE_SECRET_KEY'),
 calendar_incremental:integrations.includes('nextSyncToken')&&integrations.includes('@odata.deltaLink')&&integrations.includes('response.status===410')&&integrations.includes('nextPageToken'),
 calendar_observable:m74.includes('external_webhook_subscriptions')&&m74.includes('external_sync_errors')&&integrations.includes('dead_letter')&&integrations.includes('INTEGRATION_SCHEDULER_SECRET'),
 mail_is_consent_limited:integrations.includes('gmail.send')&&integrations.includes('Mail.Send')&&!integrations.includes('gmail.readonly')&&!integrations.includes('Mail.Read'),
 imap_is_honest:ui.includes('Connecteur non activé')&&integrations.includes('imap_runtime_not_configured'),
 sales_terms_versioned:m71.includes('create_sales_terms_version')&&m73.includes('document_sales_terms_snapshots_immutable')&&ui.includes('50 000 caractères maximum'),
 sales_terms_pdf_frozen:pdf.includes('appendFrozenSalesTerms')&&pdf.includes('sales_terms_pdf_integrity_failed')&&pdf.includes('copyPages'),
 sales_terms_per_client:ui.includes('Toutes les entreprises clientes')&&m73.includes('assignment.client_id=doc.client_id'),
 accounting_balanced_engine:m72.includes('_generate_document_accounting_entry')&&m72.includes('documents_generate_accounting')&&m72.includes('payments_generate_accounting'),
 accounting_append_only:ui.includes('reverse_payment_receipt')&&ui.includes('Aucun règlement n’est supprimé'),
 export_is_frozen:m72.includes('snapshot_sha256')&&m72.includes('accounting_export_batch_entries')&&m72.includes("status='validated'"),
 export_package_integrity:exportPackage.includes('manifest.json')&&exportPackage.includes('async function sha256')&&exportPackage.includes('final_pdf_sha256'),
 proprietary_formats_disabled:m72.includes("'proprietary','to_configure'")&&!m72.includes("'proprietary','available'"),
 fec_not_falsely_certified:m72.includes('Revue comptable requise')&&ui.includes('Revue comptable requise'),
 accounting_legacy_backfill_visible:m85.includes('_piloz_accounting_document_is_final')&&m85.includes('diagnose_accounting_export')&&m85.includes("'failures',failure_details")&&ui.includes('previewExport:previewExportWithDiagnostics')&&ui.includes('Toutes les écritures de cette période ont déjà été incluses dans un export validé.'),
 company_isolation:m71.includes('public.is_company_member(company_id)')&&m71.includes("connection_scope in('personal','shared','company')")&&m72.includes("connection.connection_scope in('shared','company')")&&m72.includes('enable row level security')&&m74.includes('public.is_company_member(company_id)')
};

const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
