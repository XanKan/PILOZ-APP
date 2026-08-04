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
  selectClientSource.includes('d.client_id=id') && selectClientSource.includes('applyPreferences(id)'),
  'La sélection client doit mettre à jour le brouillon et ses préférences.',
);

assert(
  selectClientSource.includes('scheduleDocumentRender(state)') && !selectClientSource.includes('runWhenDocumentIdle'),
  'La sélection client doit différer le rendu complet après la fin du clic.',
);

assert(
  !source.includes('document-v2-client-results" onpointerdown') &&
    !source.includes('document-v2-client-results" onmousedown'),
  'Les résultats client doivent laisser le clic se terminer sans mutation pendant pointerdown.',
);

assert(
  source.includes('function suggestionAction(action)') &&
    source.includes('PilozDocumentEditorV2.selectClient') &&
    source.includes('PilozDocumentEditorV2.selectItem') &&
    source.includes('onclick="event.preventDefault();event.stopPropagation();${action};"'),
  'Les choix client/article doivent se valider au clic avant le rendu différé.',
);

assert(
  source.includes('function setElementHtml(node,html)') &&
    source.includes('setElementHtml(results,clientSearchResults(state))'),
  'Les mises à jour HTML internes doivent utiliser le rendu sécurisé.',
);

assert(
  source.includes('function safelyRemoveNode(node)') &&
    source.includes("node.dataset.destroying='1'") &&
    source.includes("node.classList.add('is-closing')") &&
    source.includes("removeTransientNodes('.document-v2-suggestions,.document-v2-client-results')") &&
    source.includes("removeTransientNodes('.document-v2-client-results')") &&
    source.includes("removeTransientNodes('.document-v2-suggestions')"),
  'Les listes transitoires client/article doivent être nettoyées de façon différée et sécurisée.',
);

assert(
  source.includes("document.addEventListener('pointerdown',event=>{const target=event.target;setTimeout(()=>global.PilozDocumentEditorV2?.dismissTransientUi?.(target),0);},true);"),
  'La fermeture globale des listes doit être différée pour ne pas supprimer un nœud pendant le blur/pointerdown.',
);

assert(
  source.includes('function closeTransientDetails(selector)') &&
    source.includes("closeTransientDetails('.document-v2-line-menu[open]')") &&
    source.includes("closeTransientDetails('.document-v2-actions[open]')"),
  'Les menus details transitoires doivent être fermés sans suppression DOM agressive.',
);

console.log('document-client-selection-static: ok');
