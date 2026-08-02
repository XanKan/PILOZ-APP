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

assert(
  source.includes('function closeClientTransientLayers()'),
  'Le nettoyage ciblé des suggestions client est manquant.',
);

assert(
  source.includes("document.querySelectorAll('.document-v2-client-results').forEach(node=>node.remove());"),
  'Les suggestions client doivent être retirées du DOM pour ne plus bloquer les clics.',
);

const setDraftStart = source.indexOf('function setDraft');
const refreshStart = source.indexOf(' function refreshDocumentCalculations', setDraftStart);
const setDraftSource = source.slice(setDraftStart, refreshStart);

assert(
  setDraftSource.includes('const clientToken=value'),
  'La sélection client doit mémoriser le client demandé pour ignorer les réponses obsolètes.',
);

assert(
  setDraftSource.includes('if(s().draft!==d||d.client_id!==clientToken)return;'),
  'Le chargement asynchrone des préférences client doit ignorer les réponses obsolètes.',
);

assert(
  setDraftSource.includes('patchClientSection();refreshDocumentCalculations();closeClientTransientLayers();'),
  'Après chargement client, seul le bloc client doit être rafraîchi.',
);

assert(
  !setDraftSource.includes('patchClientSection();refreshDocumentCalculations();clearTransientLayers();'),
  'Après chargement client, il ne faut plus nettoyer les suggestions articles globalement.',
);

const selectClientStart = source.indexOf('function selectClient');
const selectTrainingClientStart = source.indexOf(' function selectTrainingClient', selectClientStart);
const selectClientSource = source.slice(selectClientStart, selectTrainingClientStart);

assert(
  selectClientSource.includes('requestAnimationFrame(()=>{patchClientSection();closeClientTransientLayers();});'),
  'La sélection client doit fermer uniquement la recherche client, sans toucher aux lignes article.',
);

assert(
  !selectClientSource.includes('requestAnimationFrame(()=>{patchClientSection();clearTransientLayers();});'),
  'La sélection client ne doit plus nettoyer les couches temporaires globales.',
);

const openSuggestionsStart = source.indexOf('function openSuggestions');
const itemSuggestionsStart = source.indexOf(' function itemSuggestions', openSuggestionsStart);
const lineSuggestionSource = source.slice(openSuggestionsStart, itemSuggestionsStart);

assert(
  lineSuggestionSource.includes('function openSuggestions(index){const line=s().draft?.lines?.[index];if(!line||quoteLocked(s().draft))return;closeClientTransientLayers();'),
  'Ouvrir une recherche article doit fermer les résultats client restants.',
);

assert(
  lineSuggestionSource.includes('function searchItem(index,value){closeClientTransientLayers();'),
  'Saisir une ligne article doit fermer les résultats client restants.',
);

console.log('document-client-selection-static: ok');
