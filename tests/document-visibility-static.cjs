const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const app = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-app.js'), 'utf8');
const migration = fs.readFileSync(
  path.join(root, 'supabase/migrations/202607260080_restore_document_visibility.sql'),
  'utf8',
);

const checks = [
  ['authenticated users can read the selected sales terms column',
    /grant\s+select\s*\(selected_sales_terms_id\)[\s\S]*on\s+public\.documents[\s\S]*to\s+authenticated/i.test(migration)],
  ['document request failures are logged instead of silently becoming an empty list',
    app.includes("queryFailures[key]=error") && app.includes("[PILOZ Chargement] Requête indisponible")],
  ['documents retry without the optional sales terms column',
    app.includes("column!=='selected_sales_terms_id'") && app.includes('Les documents ont été restaurés avec les colonnes essentielles')],
  ['the fallback keeps client labels available',
    app.includes('const clientsById=new Map') && app.includes('clientsById.get(document.client_id)')],
];

const failed = checks.filter(([, ok]) => !ok).map(([name]) => name);
if (failed.length) {
  console.error(JSON.stringify({ ok: false, failed }));
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({ ok: true, assertions: checks.length }));
}
