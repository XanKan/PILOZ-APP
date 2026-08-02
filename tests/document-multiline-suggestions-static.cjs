const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'assets', 'js', 'modules', 'erp', 'erp-document-editor-v2.js'),
  'utf8'
);

function bodyOf(name) {
  const start = source.indexOf(`function ${name}`);
  if (start === -1) throw new Error(`${name} introuvable`);
  const next = source.indexOf('\nfunction ', start + 1);
  return source.slice(start, next === -1 ? source.length : next);
}

function effectiveBodyOf(name) {
  const start = source.lastIndexOf(`function ${name}`);
  if (start === -1) throw new Error(`${name} introuvable`);
  const next = source.indexOf('\nfunction ', start + 1);
  return source.slice(start, next === -1 ? source.length : next);
}

if (!source.includes('function forceHideDocumentSuggestions')) {
  throw new Error('Le nettoyage force des suggestions document doit exister.');
}
if (!source.includes('function unlockDocumentEditorLayers')) {
  throw new Error('Les calques flottants doivent etre deverrouilles apres les interactions.');
}
if (!source.includes('function scheduleDocumentTotalsRefresh')) {
  throw new Error('Le recalcul des totaux doit etre planifie hors interaction active.');
}
if (source.includes('outerHTML=renderTotals') || source.includes('totals.replaceWith(fresh)')) {
  throw new Error('Les totaux ne doivent plus remplacer le conteneur actif pendant la saisie.');
}
if (source.includes('clone.innerHTML=html') || source.includes('target.replaceWith(clone)')) {
  throw new Error('Le fallback DOM ne doit plus remplacer un noeud potentiellement deplace par un blur.');
}
if (source.includes('node.replaceWith(fresh)')) {
  throw new Error('Les suggestions article doivent etre rafraichies sans remplacer le noeud actif.');
}
if (source.includes('section.replaceWith(next)')) {
  throw new Error('La selection client doit rafraichir le bloc client sans remplacer le noeud actif.');
}

const refresh = bodyOf('refreshItemSuggestions');
if (!refresh.includes('forceHideTransientLayer(existing)')) {
  throw new Error('Les suggestions des autres lignes doivent etre masquees, pas supprimees pendant le focus.');
}
if (refresh.includes('existing.remove()') || refresh.includes('node.remove()')) {
  throw new Error('refreshItemSuggestions ne doit plus supprimer de noeud actif pendant les evenements de souris.');
}
if (!refresh.includes('host.isConnected')) {
  throw new Error('refreshItemSuggestions doit ignorer les conteneurs detaches du DOM.');
}
if (!refresh.includes('data-line-suggestion-index') && !refresh.includes('dataset.lineSuggestionIndex')) {
  throw new Error('Les suggestions doivent etre indexees par ligne.');
}

const drop = bodyOf('dropLineSuggestions');
if (!drop.includes('forceHideTransientLayer') || drop.includes('.remove()')) {
  throw new Error('dropLineSuggestions doit fermer sans suppression destructrice.');
}

const itemSuggestions = bodyOf('itemSuggestions');
if (!itemSuggestions.includes('onpointerdown="event.preventDefault()"')) {
  throw new Error('Les suggestions doivent neutraliser pointerdown pour eviter les blur destructeurs.');
}
if (!itemSuggestions.includes('onmousedown="event.preventDefault()"')) {
  throw new Error('Les suggestions doivent aussi neutraliser mousedown pour eviter les blur destructeurs.');
}

const render = bodyOf('renderEditor');
if (!render.includes('safeSetHtml(document.getElementById')) {
  throw new Error('renderEditor doit utiliser le rendu securise.');
}
if (render.includes("document.getElementById('main').innerHTML")) {
  throw new Error('renderEditor ne doit plus affecter directement innerHTML sur #main.');
}

const select = effectiveBodyOf('selectItem');
if (!select.includes('forceHideDocumentSuggestions();') || !select.includes('dropLineSuggestions(index);') || select.includes('setTimeout(()=>dropLineSuggestions(index),0)')) {
  throw new Error('La selection article doit fermer la suggestion immediatement.');
}
if (!select.includes('runWhenDocumentIdle(unlockDocumentEditorLayers);')) {
  throw new Error('La selection article doit liberer les calques apres le recalcul.');
}

const trainingSelect = effectiveBodyOf('selectTrainingItem');
if (!trainingSelect.includes('forceHideDocumentSuggestions();') || trainingSelect.includes('setTimeout(()=>dropLineSuggestions(index),0)')) {
  throw new Error('La selection article en formation doit fermer la suggestion immediatement.');
}

const clientSelect = bodyOf('selectClient');
if (!clientSelect.includes('forceHideDocumentSuggestions();') || !clientSelect.includes('runWhenDocumentIdle(unlockDocumentEditorLayers);')) {
  throw new Error('La selection client doit liberer les calques de suggestion avant de continuer la saisie.');
}

const css = fs.readFileSync(path.join(__dirname, '..', 'assets', 'css', 'modern-erp.css'), 'utf8');
if (!css.includes('.document-v2-suggestions:empty') || !css.includes('[aria-hidden="true"]')) {
  throw new Error('Les suggestions fermees ou vides doivent etre invisibles et non cliquables en CSS.');
}

const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
if (!indexHtml.includes('erp-document-editor-v2.js?v=20260802.5')) {
  throw new Error('Le cache navigateur doit etre invalide pour charger le correctif document.');
}

['addLine', 'addTitleSubtotal', 'duplicateLine', 'removeLine', 'lineAction'].forEach(name => {
  const body = bodyOf(name);
  if (!body.includes('resetTransientState();')) {
    throw new Error(`${name} doit purger les suggestions avant de re-rendre les lignes.`);
  }
});

console.log('document-multiline-suggestions-static: ok');
