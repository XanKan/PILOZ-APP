#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const editorPath = path.join(root, 'assets/js/modules/erp/erp-document-editor-v2.js');
const indexPath = path.join(root, 'index.html');

const source = fs.readFileSync(editorPath, 'utf8');
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

const selectItem = bodyOf('selectItem');
const addLine = bodyOf('addLine');
const itemSuggestions = bodyOf('itemSuggestions');

assert(source.includes('async function selectItem'), 'La sélection article doit rester une action explicite.');
assert(selectItem.includes('ui.suggestions=null;renderEditor(state);'), 'Après sélection article, les suggestions doivent se fermer puis l’éditeur doit être rendu entièrement.');
assert(!selectItem.includes('syncCatalogLineDom'), 'La sélection article ne doit pas modifier le DOM ligne par ligne.');
assert(!source.includes('refreshDocumentCalculations'), 'Le recalcul visuel incrémental est désactivé pour éviter le gel après sélection.');
assert(!source.includes('runWhenDocumentIdle'), 'Le rendu différé idle ne doit pas être utilisé dans l’éditeur document.');
assert(!source.includes('forceHideDocumentSuggestions'), 'La fermeture forcée des suggestions hors rendu Reactif ne doit pas revenir.');
assert(!source.includes('resetTransientUi'), 'Le nettoyage transitoire global causait des courses blur/click.');
assert(!source.includes('safelyRemoveNode'), 'La suppression manuelle de noeuds transitoires ne doit pas revenir.');
assert(!source.includes('setElementHtml'), 'L’écriture HTML protégée globale ne doit pas revenir.');
assert(!source.includes('setMainHtml'), 'Le rendu principal doit rester direct et simple.');
assert(!source.includes('renderScheduled'), 'La file de rendu différé ne doit pas revenir.');
assert(!source.includes("document.addEventListener('pointerdown'"), 'Aucun listener pointerdown global ne doit capturer les clics de l’éditeur.');

assert(addLine.includes('lines.push(line)'), 'Ajouter une ligne doit modifier le modèle de données.');
assert(addLine.includes('renderEditor(s())'), 'Ajouter une ligne doit effectuer un rendu complet stable.');
assert(itemSuggestions.includes('PilozDocumentEditorV2.selectItem'), 'Les suggestions doivent appeler la sélection article.');
assert(itemSuggestions.includes('onmousedown="event.preventDefault()"'), 'Le clic suggestion doit conserver le focus et éviter le blur prématuré.');

assert(source.includes('function looksLikeRegistrationOnly'), 'Le nom client ne doit pas retomber sur un SIRET seul.');
assert(source.includes('Client sans nom'), 'Le libellé client de secours doit être explicite.');
assert(index.includes('erp-document-editor-v2.js?v=20260803.rollback1'), 'Le cache navigateur doit être invalidé après restauration.');

console.log(JSON.stringify({ ok: true, assertions: 19 }));
