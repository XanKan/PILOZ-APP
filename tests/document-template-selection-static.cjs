const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const app = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-app.js'), 'utf8');
const editor = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-document-editor-v2.js'), 'utf8');
const viewer = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-document-viewer-v2.js'), 'utf8');
const modern = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-modern.js'), 'utf8');
const clients = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-clients.js'), 'utf8');
const pdf = fs.readFileSync(path.join(root, 'supabase/functions/generate-document-pdf/index.ts'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase/migrations/202607250060_restore_configured_document_templates.sql'), 'utf8');
const progressMigration = fs.readFileSync(path.join(root, 'supabase/migrations/202607250062_editable_progress_drafts.sql'), 'utf8');
const progressModeMigration = fs.readFileSync(path.join(root, 'supabase/migrations/202607250063_invoice_progress_mode.sql'), 'utf8');
const nextProgressMigration = fs.readFileSync(path.join(root, 'supabase/migrations/202607250065_next_progress_invoice_draft.sql'), 'utf8');
const marketMigration = fs.readFileSync(path.join(root, 'supabase/migrations/202607260067_deposit_followup_market_summary.sql'), 'utf8');
const depositDeductionMigration = fs.readFileSync(path.join(root, 'supabase/migrations/202607260068_deposit_deduction_and_template_terms.sql'), 'utf8');
const templateFunction = fs.readFileSync(path.join(root, 'supabase/functions/save-document-template/index.ts'), 'utf8');

const checks = [
  ['company default resolver', app.includes('function resolveDocumentTemplateId') && app.includes('default_quote_template_id')],
  ['temporary system themes excluded', app.includes("row.document_type===templateType&&!row.is_system")],
  ['template resolved before save', app.includes('ensureDraftDocumentTemplate(d);if(d.numberReservation')],
  ['template resolved before preview', app.includes('const d=state.draft;ensureDraftDocumentTemplate(d);')],
  ['editor uses shared resolver', editor.includes('resolveDocumentTemplateId?.(d.document_type,d.template_id)')],
  ['viewer uses resolved template', viewer.includes('resolveDocumentTemplateId?.(doc.document_type,doc.template_id)')],
  ['saved documents explicitly invalidate cached previews', app.includes('saveDocumentWithFreshPreview') && app.includes('invalidateDocumentPreview?.(savedId||previousId)')],
  ['viewer can prepare a draft before direct finalization', app.includes('newDocument,prepareDocument,editDocument') && viewer.includes("app().prepareDocument?.(doc.id)")],
  ['in-flight draft PDFs cannot restore stale templates', viewer.includes('draftPdfEpoch:new Map()') && viewer.includes("!==epoch") && viewer.includes('function invalidateDocumentPreview')],
  ['draft references repaired only before finalization', migration.includes('document.finalized_at is null')],
  ['finalized theme remains immutable', migration.includes('finalized_document_theme_is_immutable')],
  ['public document notes removed from editor', !editor.includes('Notes visibles sur le document')],
  ['public document notes removed from customer preferences', !clients.includes('Notes visibles dans les nouveaux documents')],
  ['public notes omitted from generated PDF', !pdf.includes('[doc.public_notes, settings.visible_mention')],
  ['one-off line is automatic', !editor.includes('comme ligne ponctuelle</button>') && editor.includes("line.line_type='free_item'")],
  ['deposit uses compact percent or euro selector', editor.includes('document-v2-deposit-control') && editor.includes('Type d’acompte')],
  ['same-route scroll position preserved', app.includes('function captureScrollState') && app.includes('function restoreScrollState')],
  ['editor suggestions close outside', editor.includes('function dismissTransientUi')],
  ['document filters close outside', modern.includes('function dismissDocumentFilters') && viewer.includes('function dismissTransientUi')],
  ['later progress drafts keep every source line', progressMigration.includes('_piloz_complete_progress_draft_lines') && progressMigration.includes("progress_delta_percent',0")],
  ['zero progress lines remain visible in PDF', !pdf.includes('unchangedProgressLine') && pdf.includes('for (const line of payload.lines || [])')],
  ['draft invoices have a provisional reference', app.includes('draft_reference') && editor.includes('PilozDocumentDisplayNumber')],
  ['draft documents have the correct watermark', pdf.includes('DEVIS BROUILLON') && pdf.includes('FACTURE BROUILLON') && pdf.includes('draftDocument') && viewer.includes('document-snapshot-provisional-watermark')],
  ['quote invoice conversion keeps classic and progress drafts distinct', viewer.includes("if(type==='invoice'){await runConversion('convert_quote_to_invoice'") && viewer.includes("if(type==='progress_invoice'){await runProgressConversion")],
  ['progress mode is activated from the editor side panel', editor.includes('Facture de situation') && editor.includes('toggleProgressMode') && editor.includes("api().rpc('set_invoice_progress_mode'")],
  ['progress invoice totals are simplified', editor.includes('Avancement total :') && viewer.includes('Avancement total :') && pdf.includes('Avancement total :') && !editor.includes('Avancement cumulé') && !editor.includes('Sans titre')],
  ['progress invoices display contract quantity without changing billed quantity', editor.includes('function contractQuantity') && editor.includes('displayedQuantity=progress?contractQuantity(line)') && viewer.includes('showProgress?contractQuantity(line)') && pdf.includes('isProgressInvoice ? contractQuantity(line)')],
  ['progress mode transition is atomic and company scoped', progressModeMigration.includes('create or replace function public.set_invoice_progress_mode') && progressModeMigration.includes('public.is_company_member(target.company_id)') && progressModeMigration.includes("link_type='progress'")],
  ['next situation opens its draft directly without obsolete popup', viewer.includes("runConversion('create_next_progress_invoice_draft'") && !viewer.includes("ui.modal={type:'progress'") && !viewer.includes("ui.modal.type==='progress'") && !viewer.includes("ui.modal?.type==='progress'")],
  ['progress editor has a compact weighted progress beside more actions', editor.includes('document-v2-progress-banner') && editor.includes('État d’avancement du devis') && editor.includes('progressTotal(d)') && editor.includes("${renderProgressBanner(d)}${d.id?moreActions(d):''}")],
  ['next situation creation is atomic and company scoped', nextProgressMigration.includes('create or replace function public.create_next_progress_invoice_draft') && nextProgressMigration.includes('public.is_company_member(current_situation.company_id)') && nextProgressMigration.includes("public.convert_quote_to_invoice(source_quote.id,'invoice')") && nextProgressMigration.includes('public.set_invoice_progress_mode(target_id,true)')],
  ['finalization keeps an existing configured preview without blocking the legal lock', app.includes('{keepDraft:true}') && viewer.includes('bridgePdf') && !app.includes('await global.PilozDocumentViewerV2?.primeDocumentPreview?.(documentId)')],
  ['save and quote validation prepare the configured preview in background', editor.includes('Promise.resolve(global.PilozDocumentViewerV2.primeDocumentPreview(savedId))') && !editor.includes('await global.PilozDocumentViewerV2.primeDocumentPreview(savedId)') && !viewer.includes("context.frozen?'Le contenu figé reste consultable.")],
  ['deposit must be finalized before classic or progress follow-up', viewer.includes('depositRequired||depositPending') && viewer.includes("convertFromInvoice('progress_invoice')")],
  ['market summary is rendered in final PDFs', pdf.includes('Récapitulatif du marché') && pdf.includes('marketSummary.previous_total_incl_tax')],
  ['market summary is frozen in legal snapshots', marketMigration.includes('document_snapshots_market_summary') && marketMigration.includes("'{market_summary}'") && marketMigration.includes('payload_hash:=encode')],
  ['linked invoices cannot exceed the quote amount', marketMigration.includes('documents_quote_billing_cap') && marketMigration.includes('total des factures depasse le montant du devis')],
  ['deposit deduction is visible and editable on progress invoices', editor.includes('openDepositDeductionModal') && editor.includes('value="complete"') && editor.includes('value="prorata"') && editor.includes('value="fixed"')],
  ['deposit deduction is enforced by the database totals trigger', depositDeductionMigration.includes('_piloz_document_deposit_deduction') && depositDeductionMigration.includes('deposit_deduction_ttc') && depositDeductionMigration.includes('financial-v2-deposit-deduction')],
  ['deposit deduction is rendered in final PDFs', pdf.includes('depositDeductionTtc') && pdf.includes('deposit_deduction_ttc')],
  ['template terms are limited and persisted', app.includes('maxlength="30000"') && app.includes('setTemplateTerms') && templateFunction.includes('target_terms_conditions') && depositDeductionMigration.includes('char_length(terms_conditions)<=30000')],
  ['template terms are appended to generated PDFs', pdf.includes('termsConditions') && pdf.includes('addTermsPage')],
];

const failed = checks.filter(([, ok]) => !ok).map(([name]) => name);
if (failed.length) {
  console.error(JSON.stringify({ ok: false, failed }));
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({ ok: true, assertions: checks.length }));
}
