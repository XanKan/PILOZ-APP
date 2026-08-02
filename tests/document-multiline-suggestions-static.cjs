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

const refresh = bodyOf('refreshItemSuggestions');
if (!refresh.includes('hideTransientLayer(existing)')) {
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
if (!drop.includes('hideTransientLayer') || drop.includes('.remove()')) {
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

const select = bodyOf('selectItem');
if (!select.includes('dropLineSuggestions(index);') || select.includes('setTimeout(()=>dropLineSuggestions(index),0)')) {
  throw new Error('La selection article doit fermer la suggestion immediatement.');
}

const trainingSelect = bodyOf('selectTrainingItem');
if (trainingSelect.includes('setTimeout(()=>dropLineSuggestions(index),0)')) {
  throw new Error('La selection article en formation doit fermer la suggestion immediatement.');
}

['addLine', 'addTitleSubtotal', 'duplicateLine', 'removeLine', 'lineAction'].forEach(name => {
  const body = bodyOf(name);
  if (!body.includes('resetTransientState();')) {
    throw new Error(`${name} doit purger les suggestions avant de re-rendre les lignes.`);
  }
});

console.log('document-multiline-suggestions-static: ok');
