const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'assets', 'js', 'modules', 'erp', 'erp-document-editor-v2.js'),
  'utf8',
);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function bodyOf(name) {
  const start = source.indexOf(`function ${name}`);
  if (start === -1) throw new Error(`${name} introuvable`);
  const next = source.indexOf('\nfunction ', start + 1);
  return source.slice(start, next === -1 ? source.length : next);
}

const select = bodyOf('selectItem');
assert(
  source.includes('async function selectItem'),
  'La sélection article doit rester asynchrone pour résoudre le tarif avant rendu.',
);
assert(
  select.includes('ui.suggestions=null;renderEditor(state);'),
  'Après sélection article, l’éditeur doit fermer la suggestion puis effectuer un rendu complet stable.',
);
assert(
  !select.includes('syncCatalogLineDom') && !select.includes('refreshDocumentCalculations'),
  'La sélection article ne doit pas utiliser les rafraîchissements partiels instables.',
);
assert(
  !select.includes('runWhenDocumentIdle') && !select.includes('forceHideDocumentSuggestions'),
  'La sélection article ne doit pas laisser de garde DOM différé pouvant bloquer la ligne suivante.',
);

const addLine = bodyOf('addLine');
assert(
  addLine.includes('lines.push(line)') && addLine.includes('renderEditor(s())'),
  'Ajouter une ligne doit conserver le rendu complet stable, y compris après sélection client.',
);

const itemSuggestions = bodyOf('itemSuggestions');
assert(
  itemSuggestions.includes('onmousedown="event.preventDefault()"'),
  'Les suggestions article doivent empêcher le blur pendant le clic.',
);
assert(
  itemSuggestions.includes('PilozDocumentEditorV2.selectItem'),
  'Les suggestions article doivent appeler la sélection article standard.',
);

const render = bodyOf('renderEditor');
assert(
  render.includes("document.getElementById('main').innerHTML"),
  'Le rendu principal doit rester centralisé dans renderEditor.',
);
assert(
  !source.includes('target.replaceWith(clone)') &&
    !source.includes('node.replaceWith(fresh)') &&
    !source.includes('section.replaceWith(next)'),
  'Aucun remplacement DOM partiel ne doit être réintroduit pendant les événements de saisie.',
);

const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
assert(
  indexHtml.includes('erp-document-editor-v2.js?v=20260802.6'),
  'Le cache navigateur doit être invalidé pour charger le correctif document.',
);

console.log('document-multiline-suggestions-static: ok');
