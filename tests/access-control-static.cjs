const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const migration = read('supabase/migrations/202607260081_company_access_control.sql');
const roadmapMigration = read('supabase/migrations/202607260082_hide_stock_permissions_from_roles.sql');
const accessUi = read('assets/js/modules/erp/erp-access-control.js');
const app = read('assets/js/modules/erp/erp-app.js');
const edge = read('supabase/functions/company-access/index.ts');
const index = read('index.html');

const checks = [];
function expect(name, condition) {
  checks.push({ name, ok: Boolean(condition) });
  if (!condition) throw new Error(`Échec du contrôle : ${name}`);
}

const commercial = migration.slice(
  migration.indexOf('select commercial_id,value.permission_key,value.scope'),
  migration.indexOf('select accountant_id,value.permission_key')
);
const accountant = migration.slice(
  migration.indexOf('select accountant_id,value.permission_key'),
  migration.indexOf("perform set_config('piloz.system_role_seed','0'")
);

expect('quatre rôles système bornés par contrainte SQL', /system_key in\('administrator','user','commercial','accountant'\)/.test(migration));
expect('rôle Administrateur', /'Administrateur'.*'administrator',true/.test(migration));
expect('rôle Utilisateur', /'Utilisateur'.*'user',true/.test(migration));
expect('rôle Commercial', /'Commercial'.*'commercial',true/.test(migration));
expect('rôle Expert-comptable', /'Expert-comptable'.*'accountant',true/.test(migration));

for (const permission of [
  'crm.opportunities.write',
  'clients.write',
  'sales.quotes.finalize',
  'sales.quotes.send',
  'sales.quotes.convert',
  'sales.invoices.read',
  'sales.invoices.create_draft',
  'sales.invoices.update_draft',
  'sales.invoices.send'
]) expect(`Commercial autorisé : ${permission}`, commercial.includes(`'${permission}'`));

for (const permission of [
  'sales.invoices.finalize',
  'payments.create',
  'payments.cancel',
  'sales.credit_notes.create',
  'catalog.purchase_price.read',
  'catalog.margin.read',
  'accounting.settings.manage',
  'company.users.manage',
  'stock.write'
]) expect(`Commercial interdit : ${permission}`, !commercial.includes(`'${permission}'`));

for (const permission of [
  'clients.read',
  'sales.invoices.read',
  'payments.read',
  'accounting.entries.read',
  'accounting.exports.manage',
  'accounting.settings.manage',
  'accounting.vat.manage'
]) expect(`Expert-comptable autorisé : ${permission}`, accountant.includes(`'${permission}'`));

for (const permission of ['clients.write', 'sales.quotes.create', 'sales.invoices.finalize', 'payments.create']) {
  expect(`Expert-comptable sans écriture commerciale : ${permission}`, !accountant.includes(`'${permission}'`));
}

expect('résolveur central', /create or replace function public\.resolve_company_permissions/.test(migration));
expect('portée own team company', /create or replace function public\.company_permission_scope/.test(migration));
expect('contrôle serveur documents', /documents_enforce_central_permission/.test(migration));
expect('contrôle serveur règlements', /payments_enforce_central_permission/.test(migration));
expect('dernier administrateur protégé', migration.includes('L’entreprise doit toujours conserver au moins un administrateur actif.'));
expect('rôles système immuables côté SQL', migration.includes('Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.'));
expect('journal des accès immuable', /company_access_audit_immutable/.test(migration));
expect('acceptation explicite invitation', /create or replace function public\.accept_company_invitation/.test(migration));
expect('pagination utilisateurs côté serveur', /create or replace function public\.list_company_access_users/.test(migration));

expect('interface quatre onglets', ['Utilisateurs', 'Rôles', 'Invitations', 'Journal des accès'].every(label => accessUi.includes(label)));
expect('éditeur de permissions en deux colonnes', accessUi.includes('access-permission-grid'));
expect('Stock masqué du catalogue des rôles', /editor_visible=false/.test(roadmapMigration) && /module_key='stock'/.test(roadmapMigration));
expect('Stock filtré de l’éditeur et des compteurs', accessUi.includes('isRoadmapPermission') && accessUi.includes('visiblePermissions'));
expect('message rôle système exact côté interface', accessUi.includes('Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.'));
expect('garde interface finalisation facture', accessUi.includes("'sales.invoices.finalize'"));
expect('navigation filtrée par permissions', accessUi.includes('routePermissions'));
expect('résolveur chargé par application', app.includes("resolve_company_permissions"));

expect('Edge Function vérifie la permission', edge.includes("company.users.manage"));
expect('Edge Function contrôle la limite de licence', /max_users|maxUsers/.test(edge));
expect('Edge Function ne contient pas de clé service_role littérale', !/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/.test(edge));
expect('ancien formulaire de mot de passe temporaire retiré', !index.includes('adminCreerCompte'));
expect('aucune clé service_role dans le navigateur', !/SUPABASE_SERVICE_ROLE_KEY|service_role/.test(index + accessUi + app));
expect('CNAME intact', read('CNAME').trim() === 'app.piloz.fr');

process.stdout.write(`${JSON.stringify({ ok: true, checks }, null, 2)}\n`);
