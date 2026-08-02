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
  select.includes('resetTransientUi();renderEditor(state);'),
  'Après sélection article, l’éditeur doit fermer les menus transitoires puis effectuer un rendu complet stable.',
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
  addLine.includes('lines.push(line)') && addLine.includes('resetTransientUi();renderEditor(s())'),
  'Ajouter une ligne doit fermer les menus transitoires et conserver le rendu complet stable, y compris après sélection client.',
);

const itemSuggestions = bodyOf('itemSuggestions');
assert(
  source.includes('function suggestionAction(action)') &&
    itemSuggestions.includes('suggestionAction(`PilozDocumentEditorV2.selectItem'),
  'Les suggestions article doivent déclencher la sélection dès pointerdown via le helper sécurisé.',
);
assert(
  itemSuggestions.includes('onpointerdown="event.stopPropagation()"') &&
    itemSuggestions.includes('onmousedown="event.preventDefault();event.stopPropagation()"'),
  'Le conteneur des suggestions article doit rester ouvert pendant le clic sans casser le focus.',
);
assert(
  itemSuggestions.includes('PilozDocumentEditorV2.selectItem'),
  'Les suggestions article doivent appeler la sélection article standard.',
);

const render = bodyOf('renderEditorNow');
assert(
  render.includes('setMainHtml('),
  'Le rendu principal doit rester centralisé et passer par le rendu sécurisé.',
);
assert(
  !source.includes('target.replaceWith(clone)') &&
    !source.includes('node.replaceWith(fresh)') &&
    !source.includes('section.replaceWith(next)'),
  'Aucun remplacement DOM partiel ne doit être réintroduit pendant les événements de saisie.',
);

const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
assert(
  indexHtml.includes('erp-document-editor-v2.js?v=20260802.9'),
  'Le cache navigateur doit être invalidé pour charger le correctif document.',
);

console.log('document-multiline-suggestions-static: ok');
