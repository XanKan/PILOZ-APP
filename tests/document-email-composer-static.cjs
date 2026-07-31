const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const app = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-app.js'), 'utf8');
const viewer = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-document-viewer-v2.js'), 'utf8');
const edge = fs.readFileSync(path.join(root, 'supabase/functions/send-document-email/index.ts'), 'utf8');

assert.match(app, /billing_email/, 'Le composeur doit proposer l’adresse de facturation du client.');
assert.match(app, /electronic_billing_email/, 'Le composeur doit proposer l’adresse électronique dédiée du client.');
assert.match(app, /secondary_email/, 'Le composeur doit proposer les adresses secondaires des contacts.');
assert.match(app, /Saisir ou choisir une adresse e-mail/, 'La saisie libre d’un destinataire doit rester disponible.');
assert.match(app, /copySelf/, 'La copie à soi-même doit être prise en charge.');
assert.match(app, /replyTo:composer\.senderEmail/, 'L’adresse de réponse de l’utilisateur doit être transmise.');
assert.match(app, /if\(state\.busy\)return/, 'Le double envoi doit être bloqué.');
assert.match(viewer, /Envoyer par e-mail/, 'Le panneau du document doit exposer l’action d’envoi explicite.');
assert.match(edge, /RESEND_API_KEY/, 'L’envoi serveur doit utiliser le fournisseur configuré.');
assert.match(edge, /reply_to:replyTo\[0\]/, 'Le fournisseur doit recevoir l’adresse de réponse.');
assert.match(edge, /document_email_deliveries/, 'Chaque tentative doit être historisée.');
assert.match(edge, /final_pdf_path/, 'Le PDF final archivé doit être utilisé comme pièce jointe.');
assert.match(edge, /historyRecorded:false/, 'Un historique indisponible ne doit pas encourager un double envoi déjà accepté.');

console.log('document-email-composer-static: ok');
