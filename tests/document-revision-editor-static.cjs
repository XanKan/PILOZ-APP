#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const appPath = path.join(root, 'assets/js/modules/erp/erp-app.js');
const indexPath = path.join(root, 'index.html');

const source = fs.readFileSync(appPath, 'utf8');
const index = fs.readFileSync(indexPath, 'utf8');

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function bodyOf(functionName) {
  const marker = `function ${functionName}`;
  const start = source.indexOf(marker);
  assert(start >= 0, `Fonction ${functionName} introuvable.`);
  const open = source.indexOf('{', start);
  assert(open >= 0, `Corps de ${functionName} introuvable.`);
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    const char = source[index];
    if (char === '{') depth += 1;
    if (char === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(open, index + 1);
    }
  }
  throw new Error(`Fin de ${functionName} introuvable.`);
}

const revision = bodyOf('newDocumentVersion');
const legacy = bodyOf('renderLegacyDocumentEditor_DEPRECATED_DO_NOT_USE');

assert(legacy === '{return renderDocumentEditor();}', 'L’ancien éditeur doit uniquement déléguer vers le rendu document actuel.');
assert(revision.includes("go('document-editor')"), 'Une révision doit toujours ouvrir l’éditeur document V2.');
assert(revision.includes('finalized_at:null'), 'Une révision doit redevenir un brouillon finalisable.');
assert(revision.includes('locked_at:null'), 'Une révision ne doit pas conserver le verrou du devis source.');
assert(revision.includes('archived_at:null'), 'Une révision ne doit pas conserver l’archivage du devis source.');
assert(revision.includes('document_id:null'), 'Les lignes de révision ne doivent pas rester liées au devis source.');
assert(revision.includes('nextQuoteRevisionNumber(source)'), 'Les numéros R1/R2/R3 doivent être calculés depuis tout l’historique.');
assert(revision.includes('revision_number:revision'), 'Le numéro de révision doit être enregistré dans les métadonnées.');
assert(!source.includes('ARTICLE, MAIN'), 'L’ancienne interface ligne devis ne doit plus être présente.');
assert(!source.includes('Ligne ponctuelle'), 'L’ancien bouton Ligne ponctuelle ne doit plus être présent.');
assert(!source.includes('Variante / option'), 'L’ancien bouton Variante / option ne doit plus être présent.');
assert(!source.includes('Créer dans le catalogue'), 'L’ancien bouton catalogue ne doit plus être présent.');
assert(index.includes('erp-app.js?v=20260803.revision-editor-v3'), 'Le cache erp-app doit être invalidé.');
assert(index.includes('erp-document-editor-v2.js?v=20260803.revision-editor-v3'), 'Le cache de l’éditeur V2 doit être invalidé.');

console.log(JSON.stringify({ ok: true, assertions: 14 }));
