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

const checks = [
  ['company default resolver', app.includes('function resolveDocumentTemplateId') && app.includes('default_quote_template_id')],
  ['temporary system themes excluded', app.includes("row.document_type===templateType&&!row.is_system")],
  ['template resolved before save', app.includes('ensureDraftDocumentTemplate(d);if(d.numberReservation')],
  ['template resolved before preview', app.includes('const d=state.draft;ensureDraftDocumentTemplate(d);')],
  ['editor uses shared resolver', editor.includes('resolveDocumentTemplateId?.(d.document_type,d.template_id)')],
  ['viewer uses resolved template', viewer.includes('resolveDocumentTemplateId?.(doc.document_type,doc.template_id)')],
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
];

const failed = checks.filter(([, ok]) => !ok).map(([name]) => name);
if (failed.length) {
  console.error(JSON.stringify({ ok: false, failed }));
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({ ok: true, assertions: checks.length }));
}
