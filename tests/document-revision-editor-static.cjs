#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const appPath = path.join(root, 'assets/js/modules/erp/erp-app.js');
const editorPath = path.join(root, 'assets/js/modules/erp/erp-document-editor-v2.js');
const viewerPath = path.join(root, 'assets/js/modules/erp/erp-document-viewer-v2.js');
const indexPath = path.join(root, 'index.html');

const source = fs.readFileSync(appPath, 'utf8');
const editor = fs.readFileSync(editorPath, 'utf8');
const viewer = fs.readFileSync(viewerPath, 'utf8');
const indexHtml = fs.readFileSync(indexPath, 'utf8');

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
assert(source.includes('function isSyntheticRevisionLine'), 'Les lignes synthétiques/démo doivent être détectées avant une révision.');
assert(revision.includes('.filter(line=>!isSyntheticRevisionLine(line))'), 'Une révision ne doit pas recopier les lignes synthétiques/démo.');

assert(!source.includes('ARTICLE, MAIN'), 'L’ancienne interface ligne devis ne doit plus être présente.');
assert(!source.includes('Ligne ponctuelle'), 'L’ancien bouton Ligne ponctuelle ne doit plus être présent.');
assert(!source.includes('Variante / option'), 'L’ancien bouton Variante / option ne doit plus être présent.');
assert(!source.includes('Créer dans le catalogue'), 'L’ancien bouton catalogue ne doit plus être présent.');

assert(!viewer.includes("'secondary')}}${locked?"), 'Le bouton Révision ne doit pas afficher de caractère parasite.');
assert(viewer.includes("actionButton('Révision de devis','PilozDocumentViewerV2.appAction(\\'newDocumentVersion\\')','secondary')}${locked?"), 'Le bouton Révision doit être correctement fermé.');

assert(!editor.includes(`class="document-v2-line \${progress?'progress':''}" draggable="\${!quoteLocked(d)}"`), 'La ligne article ne doit plus être draggable en entier.');
assert(!editor.includes('class="document-v2-structural ${line.line_type}" draggable="${!quoteLocked(d)}"'), 'La ligne structurelle ne doit plus être draggable en entier.');
assert(editor.includes('class="document-v2-handle" type="button" title="Déplacer" draggable="${!quoteLocked(d)}"'), 'La poignée article doit rester draggable.');
assert(editor.includes('class="document-v2-handle" type="button" aria-label="Déplacer" draggable="${!quoteLocked(d)}"'), 'La poignée structurelle doit rester draggable.');

assert(indexHtml.includes('erp-app.js?v=20260804.status-fix1'), 'Le cache erp-app doit être invalidé.');
assert(indexHtml.includes('erp-document-editor-v2.js?v=20260804.status-fix1'), 'Le cache de l’éditeur V2 doit être invalidé.');
assert(indexHtml.includes('erp-document-viewer-v2.js?v=20260803.revision-editor-v4'), 'Le cache de la consultation doit être invalidé.');

console.log(JSON.stringify({ ok: true, assertions: 23 }));
