const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('assets/js/modules/erp/erp-document-editor-v2.js', 'utf8');

const suggestionAction = /function suggestionAction\(action\)\{([^]*?)\n?\}/.exec(source)?.[1] || '';
assert(
  suggestionAction.includes('onclick='),
  'Les suggestions doivent être validées au clic, pas pendant pointerdown/blur.'
);
assert(
  !suggestionAction.includes('onpointerdown') && !suggestionAction.includes('onmousedown'),
  'Les handlers pointerdown/mousedown sur suggestions réintroduisent le freeze DOM.'
);

assert(
  !source.includes('node.innerHTML=html'),
  'setElementHtml ne doit pas utiliser innerHTML brut sur un nœud live.'
);
assert(
  source.includes('function scheduleDocumentRender'),
  'Les sélections client/article doivent pouvoir différer le rendu après l’événement courant.'
);
assert(
  /async function selectItem[\s\S]*scheduleDocumentRender\(state\)/.test(source),
  'La sélection article doit différer le rendu pour éviter le blocage après plusieurs lignes.'
);
assert(
  /function selectClient[\s\S]*scheduleDocumentRender\(state\)/.test(source),
  'La sélection client doit différer le rendu pour éviter le blocage global de l’éditeur.'
);
assert(
  !source.includes('document-v2-suggestions" onmousedown') &&
    !source.includes('document-v2-suggestions" onpointerdown'),
  'Les listes article ne doivent plus muter le DOM pendant pointerdown.'
);
assert(
  !source.includes('document-v2-client-results" onpointerdown'),
  'La liste client ne doit plus muter le DOM pendant pointerdown.'
);

console.log('OK document editor freeze guard');
