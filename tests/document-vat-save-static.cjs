#!/usr/bin/env node

const fs = require('node:fs');

const app = fs.readFileSync('assets/js/modules/erp/erp-app.js', 'utf8');
const editor = fs.readFileSync('assets/js/modules/erp/erp-document-editor-v2.js', 'utf8');
const catalog = fs.readFileSync('assets/js/modules/erp/erp-catalog-v2.js', 'utf8');
const index = fs.readFileSync('index.html', 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function functionSource(source, name) {
  const start = source.indexOf(`function ${name}`);
  assert(start >= 0, `Fonction ${name} introuvable.`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let cursor = open; cursor < source.length; cursor += 1) {
    if (source[cursor] === '{') depth += 1;
    if (source[cursor] === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, cursor + 1);
    }
  }
  throw new Error(`Fin de ${name} introuvable.`);
}

const appVatRows = new Function(
  'state',
  'companySubjectToVat',
  `${functionSource(app, 'accountingVatRows')}; return accountingVatRows;`,
)({
  data: {
    settings: [{ default_vat_rate: 10 }],
    vatRates: [
      { rate: '20', active: true },
      { rate: 20, active: true },
      { rate: 5.5, active: false },
    ],
  },
}, () => true);
assert(appVatRows().length === 1 && appVatRows()[0].rate === 20, 'La TVA du cœur ERP doit être dédupliquée et ignorer les taux inactifs.');

const fallbackVatRows = new Function(
  'state',
  'companySubjectToVat',
  `${functionSource(app, 'accountingVatRows')}; return accountingVatRows;`,
)({ data: { settings: [{ default_vat_rate: 10 }], vatRates: [] } }, () => true);
assert(fallbackVatRows()[0].rate === 10, 'Le taux par défaut doit rester disponible lorsque la table TVA est vide.');

let generated = 0;
const draftLineId = new Function(
  'uuid',
  `${functionSource(app, 'draftLineId')}; return draftLineId;`,
)(() => `generated-${++generated}`);
const seen = new Set();
const draft = { id: 'document-b' };
const foreignLine = { id: 'line-a', document_id: 'document-a' };
const duplicateLine = { id: 'line-b', document_id: 'document-b' };
assert(draftLineId(draft, foreignLine, seen) === 'generated-1', 'Une ligne issue d’un autre document doit recevoir un nouvel identifiant.');
seen.add('line-b');
assert(draftLineId(draft, duplicateLine, seen) === 'generated-2', 'Deux lignes du même brouillon ne doivent jamais partager un identifiant.');

const catalogVatRows = new Function(
  'state',
  'companySubjectToVat',
  `${functionSource(catalog, 'catalogVatRows')}; return catalogVatRows;`,
)(() => ({
  data: {
    settings: [{ default_vat_rate: 10 }],
    vatRates: [{ rate: 20, active: true }, { rate: '20', active: true }, { rate: 5.5, active: false }],
  },
}), () => true);
assert(catalogVatRows().length === 1 && catalogVatRows()[0].rate === 20, 'Le catalogue doit présenter chaque taux actif une seule fois.');

assert(app.includes('lineId=draftLineId(d,line,lineIds)'), 'La sauvegarde doit assainir les identifiants de lignes avant l’appel serveur.');
assert(app.includes("unit:normalizeCatalogUnit(line.unit)||'unité'"), 'La sauvegarde doit envoyer une unité UTF-8 canonique.');
assert(app.includes('tax_rate:normalizeDocumentVatRate(line.tax_rate)'), 'La sauvegarde doit envoyer un taux TVA canonique.');
assert(editor.includes('const seen=new Set(),rows=vatSourceRows(state)'), 'L’éditeur doit dédupliquer les taux avant de construire le sélecteur TVA.');
assert(editor.includes("${rate.toLocaleString('fr-FR',{maximumFractionDigits:3})} %"), 'Le sélecteur TVA doit générer un libellé unique à partir du taux.');

for (const [name, source] of [['erp-app', app], ['éditeur', editor], ['catalogue', catalog]]) {
  for (const token of ['unitÃ', 'â€™', 'â€“', 'â€”', 'Å“', 'finalisÃ', 'enregistrÃ']) {
    assert(!source.includes(token), `${name} contient encore une corruption UTF-8 : ${token}`);
  }
}

assert(index.includes('erp-app.js?v=20260806.load-race-fix1'), 'Le cache de erp-app.js doit être invalidé.');
assert(index.includes('erp-document-editor-v2.js?v=20260804.delete-print2'), 'Le cache de erp-document-editor-v2.js doit être invalidé.');
assert(index.includes('erp-catalog-v2.js?v=20260803.document-vat-save1'), 'Le cache de erp-catalog-v2.js doit être invalidé.');

console.log(JSON.stringify({ ok: true, assertions: 18 }));
