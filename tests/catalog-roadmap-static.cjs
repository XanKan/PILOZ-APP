const assert = require('node:assert/strict');
const fs = require('node:fs');

const catalog = fs.readFileSync('assets/js/modules/erp/erp-catalog-v2.js', 'utf8');
const commercial = fs.readFileSync('assets/js/modules/erp/erp-commercial-v2.js', 'utf8');
const dashboard = fs.readFileSync('assets/js/modules/erp/erp-dashboard-cockpit.js', 'utf8');
const settings = fs.readFileSync('assets/js/modules/erp/erp-modern.js', 'utf8');
const onboarding = fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js', 'utf8');

const itemFormSource = catalog.slice(
  catalog.indexOf('function itemForm('),
  catalog.indexOf('function renderCreate('),
);

assert(!itemFormSource.includes('Stock et logistique'), 'Le formulaire catalogue ne doit plus afficher le stock.');
assert(!itemFormSource.includes('name="stock_managed"'), 'La gestion du stock ne doit plus être sélectionnable.');
assert(!itemFormSource.includes('<h2>Main d’œuvre</h2>'), 'Le type Main d’œuvre ne doit pas créer une seconde section redondante.');
assert(!commercial.includes("stock:{label:'Stock'"), 'Le stock ne doit plus être exposé dans la navigation active.');
assert(!dashboard.includes("key:'stockAlerts'"), 'Le stock ne doit plus être proposé comme widget actif.');
assert(settings.includes('class="sales-numbering-grid"'), 'Les numérotations devis et factures doivent être regroupées côte à côte.');
assert(settings.includes("field('Marge par défaut (%)','default_margin_rate'"), 'La marge par défaut doit être configurable dans Ventes & Documents.');
assert(settings.includes('default_margin_rate:margin'), 'La marge par défaut doit être persistée par entreprise.');
assert(onboarding.includes("input('Marge par défaut (%)','documents.defaultMarginRate'"), 'La marge par défaut doit être demandée pendant l’onboarding.');
assert(catalog.includes('function defaultMarginRate()'), 'Le catalogue doit lire la marge par défaut enregistrée.');

console.log('PASS catalogue sans stock et marge par défaut');
