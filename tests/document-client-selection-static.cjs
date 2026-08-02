const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'assets/js/modules/erp/erp-document-editor-v2.js'),
  'utf8',
);

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

const forbiddenFragments = [
  '__pilozDocumentEditorLineInteractionGuard',
  '__pilozDocumentEditorSuggestionPointer',
  'function safeSetHtml',
  'function safeReplaceChildren',
  'function refreshDocumentCalculations',
  'function syncCatalogLineDom',
  'function patchClientSection',
  'function forceHideDocumentSuggestions',
  'function unlockDocumentEditorLayers',
];

for (const fragment of forbiddenFragments) {
  assert(
    !source.includes(fragment),
    `Le correctif document ne doit pas réintroduire le garde/fallback instable : ${fragment}`,
  );
}

const setDraftStart = source.indexOf('function setDraft');
const setDraftEnd = source.indexOf(' function togglePanel', setDraftStart);
const setDraftSource = source.slice(setDraftStart, setDraftEnd);

assert(
  setDraftSource.includes("if(field==='client_id')"),
  'La sélection client doit encore déclencher le chargement des préférences client.',
);

assert(
  setDraftSource.includes('renderEditor(s())'),
  'La sélection client doit repasser par le rendu complet stable de l’éditeur.',
);

assert(
  !setDraftSource.includes('patchClientSection()'),
  'La sélection client ne doit pas utiliser le patch partiel du bloc client.',
);

const selectClientStart = source.indexOf('function selectClient');
const selectClientEnd = source.indexOf(' function selectTrainingClient', selectClientStart);
const selectClientSource = source.slice(selectClientStart, selectClientEnd);

assert(
  selectClientSource.includes("setDraft('client_id',id)"),
  'La sélection client doit rester un simple changement de brouillon.',
);

assert(
  !selectClientSource.includes('requestAnimationFrame') && !selectClientSource.includes('runWhenDocumentIdle'),
  'La sélection client ne doit pas planifier de manipulation DOM différée.',
);

assert(
  source.includes('document-v2-client-results" onmousedown="event.preventDefault()"'),
  'Les résultats client doivent empêcher le blur pendant le clic.',
);

console.log('document-client-selection-static: ok');
