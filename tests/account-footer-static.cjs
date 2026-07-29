const fs = require('node:fs');
const assert = require('node:assert/strict');

const html = fs.readFileSync('index.html', 'utf8');
const app = fs.readFileSync('assets/js/modules/erp/erp-app.js', 'utf8');
const css = fs.readFileSync('assets/css/piloz-ios.css', 'utf8');

const footerStart = html.indexOf('function nomEntrepriseConnectee()');
const footerEnd = html.indexOf('async function sb(', footerStart);
assert.ok(footerStart > -1 && footerEnd > footerStart, 'Le pied de compte doit être défini.');
const footer = html.slice(footerStart, footerEnd);

assert.match(footer, /settings\.trade_name[\s\S]*settings\.legal_name/, 'Le nom commercial puis la raison sociale Supabase doivent être prioritaires.');
assert.match(footer, /identity\.tradeName[\s\S]*identity\.legalName/, 'Le profil onboarding doit servir de repli.');
assert.match(footer, /return name \|\| 'Mon entreprise'/, 'Une valeur de repli lisible est obligatoire.');
assert.match(footer, /class="rail-company-name"/, 'Le nom de la société doit être visible dans le pied de navigation.');
assert.match(footer, /class="rail-logout-button"/, 'Un bouton de déconnexion dédié doit être rendu.');
assert.match(footer, /class="rail-help-button"/, 'Un bouton compact doit ouvrir le centre d’aide depuis le pied de navigation.');
assert.match(footer, /PilozHelp\?\.openArea\(\)/, 'Le bouton Aide doit ouvrir le centre d’aide existant.');
assert.match(footer, /onclick="deconnecter\(\)"/, 'Le bouton doit déclencher la déconnexion existante.');
assert.doesNotMatch(footer, />\s*Déconnexion\s*</i, 'La déconnexion doit rester un bouton icône compact.');
assert.doesNotMatch(footer, /LOGICIEL PILOZ|ERP\.PILOZ@OUTLOOK\.COM/i, 'Le pied ne doit plus afficher l’identité fixe de Piloz.');
assert.doesNotMatch(footer, /Synchronisé|rail-sync-status/, 'Le pied connecté doit rester limité au nom de la société et à la déconnexion.');
assert.match(app, /PilozRefreshAccountFooter\?\.\(\)/, 'Le pied doit être rafraîchi après le chargement des données de la société.');
assert.match(css, /\.rail-account-card/);
assert.match(css, /\.rail-logout-button:hover/);
assert.match(css, /\.rail-help-button/);

console.log('Account footer static checks: OK');
