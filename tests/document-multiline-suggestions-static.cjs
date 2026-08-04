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
assert(selectItem.includes('ui.suggestions=null;'), 'Après sélection article, les suggestions doivent se fermer.');
assert(selectItem.includes('ui.suggestionReady=null;'), 'Après sélection article, l’état de recherche doit être réinitialisé.');
assert(selectItem.includes('scheduleDocumentRender(state);'), 'Après sélection article, l’éditeur doit être rendu entièrement puis déverrouillé.');
assert(!selectItem.includes('syncCatalogLineDom'), 'La sélection article ne doit pas modifier le DOM ligne par ligne.');
assert(!source.includes('refreshDocumentCalculations'), 'Le recalcul visuel incrémental est désactivé pour éviter le gel après sélection.');
assert(!source.includes('runWhenDocumentIdle'), 'Le rendu différé idle ne doit pas être utilisé dans l’éditeur document.');
assert(!source.includes('forceHideDocumentSuggestions'), 'La fermeture forcée des suggestions hors rendu réactif ne doit pas revenir.');
assert(!source.includes('resetTransientUi'), 'Le nettoyage transitoire global causait des courses blur/click.');
assert(source.includes('function safelyRemoveNode'), 'Les noeuds transitoires doivent être retirés de manière asynchrone et sécurisée.');
assert(source.includes('function removeTransientNodes'), 'Le nettoyage des suggestions doit passer par un helper centralisé.');
assert(source.includes('function setElementHtml'), 'Le rendu principal doit protéger innerHTML contre les mutations externes.');
assert(!source.includes('setMainHtml'), 'Le rendu principal doit rester direct et simple.');
assert(!source.includes('renderScheduled'), 'La file de rendu différé ne doit pas revenir.');
assert(source.includes("document.addEventListener('pointerdown',event=>{const target=event.target;setTimeout(()=>global.PilozDocumentEditorV2?.dismissTransientUi?.(target),0);},true);"), 'Le listener global doit nettoyer après le pointerdown pour laisser la sélection se terminer.');

assert(addLine.includes('lines.push(line)'), 'Ajouter une ligne doit modifier le modèle de données.');
assert(addLine.includes('renderEditor(s())'), 'Ajouter une ligne doit effectuer un rendu complet stable.');
assert(itemSuggestions.includes('PilozDocumentEditorV2.selectItem'), 'Les suggestions doivent appeler la sélection article.');
assert(source.includes('function scheduleDocumentRender'), 'Le rendu après sélection doit être planifié pour éviter les courses blur/click.');
assert(source.includes('function suggestionAction(action)'), 'Les suggestions doivent passer par un helper d’action centralisé.');
assert(source.includes('onclick="event.preventDefault();event.stopPropagation();${action};"'), 'La sélection article/client doit bloquer l’événement natif avant de modifier le document.');
assert(source.includes("removeTransientNodes('.document-v2-suggestions')"), 'Les suggestions article doivent être purgées via le helper sécurisé.');
assert(source.includes("removeTransientNodes('.document-v2-client-results')"), 'Les suggestions client doivent être purgées via le helper sécurisé.');

assert(source.includes('function looksLikeRegistrationOnly'), 'Le nom client ne doit pas retomber sur un SIRET seul.');
assert(source.includes('Client sans nom'), 'Le libellé client de secours doit être explicite.');
assert(index.includes('erp-document-editor-v2.js?v=20260803.document-vat-save1'), 'Le cache navigateur doit être invalidé après correction des documents et de la TVA.');

console.log(JSON.stringify({ ok: true, assertions: 25 }));
