const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const app = read("assets/js/modules/erp/erp-help-support.js");
const access = read("assets/js/modules/erp/erp-access-control.js");
const html = read("index.html");
const pilo = read("supabase/functions/pilo/index.ts");
const providers = read("supabase/functions/_shared/pilo-providers.ts");
const adminApi = read("supabase/functions/platform-admin-api/index.ts");
const foundation = read("supabase/migrations/202607290106_documentation_pilo_support_foundation.sql");
const knowledge = read("supabase/migrations/202607290107_official_knowledge_base.sql");
const intake = read("supabase/migrations/202607290109_support_ticket_intake_details.sql");
const restrictions = read("supabase/migrations/202607290112_knowledge_access_indexing_and_review.sql");
const reliability = read("supabase/migrations/202607290113_help_support_reliability.sql");

for (const label of ["Documentation", "Pilo", "Mes tickets", "Contacter le support"]) {
  assert.ok(app.includes(label), `Entrée d'aide absente : ${label}`);
}
assert.ok(app.includes("Bonjour, je suis Pilo. Comment puis-je vous aider ?"));
assert.ok(app.includes("Je peux rechercher une réponse dans la documentation officielle Piloz ou vous aider sur la page actuellement ouverte."));
assert.ok(providers.includes("Je n’ai pas trouvé de réponse suffisamment précise dans la documentation Piloz."));
assert.ok(pilo.includes("La gestion des stocks fait actuellement partie de la roadmap Piloz et n’est pas encore disponible dans la version actuelle."));
assert.ok(knowledge.includes("La gestion des stocks est-elle disponible dans Piloz ?"));
assert.ok(knowledge.includes("Sa disponibilité sera annoncée officiellement lors de sa mise en production."));
assert.ok(app.includes("Envoyer au support"), "Le tunnel de ticket doit finir par un envoi explicite");
assert.ok(app.includes("target_details"), "Les informations de qualification doivent être persistées");
assert.ok(app.includes("assistantConversationId"), "La conversation Pilo doit pouvoir être liée au ticket");
assert.ok(app.includes("comment:comment||null"), "Le retour facultatif doit conserver son commentaire");
assert.ok(app.includes("10 Mo"), "La limite de pièce jointe doit être visible");
assert.ok(app.includes("renderPiloSurfaces()"), "Le chat flottant doit être rafraîchi immédiatement après l'envoi");
assert.ok(app.includes("piloz-ticket-overlay-root"), "Le formulaire de ticket doit être visible hors de la page Aide");
assert.ok(!app.includes("openTicket({category:'general'"), "Les tickets issus d'un article doivent utiliser une catégorie serveur valide");
assert.ok(!app.includes("name,description,icon,position"), "La documentation ne doit pas demander la colonne inexistante knowledge_categories.icon");
assert.ok(!app.includes("availability,source_label,source_url"), "La documentation ne doit pas demander les colonnes article inexistantes source_label/source_url");
assert.ok(app.includes("ui.docsLoaded=true;ui.docsLoading=false"), "Une erreur documentaire doit arrêter le rechargement automatique en boucle");

const categoryBlock = app.match(/const categoryLabels=\{([^;]+)\};/)?.[1] || "";
assert.ok(categoryBlock.includes("roadmap:"), "La catégorie spéciale Fonctionnalité à venir est requise");
assert.ok(!/(^|,)stock\s*:/.test(categoryBlock), "Stock ne doit pas être une catégorie de ticket");

for (const field of ["route", "module", "submodule", "object_type", "object_status", "available_actions", "role", "permissions", "language", "app_version", "technical_id"]) {
  assert.ok(foundation.includes(`'${field}'`) || app.includes(`${field}:`), `Contexte sûr incomplet : ${field}`);
}
assert.ok(intake.includes("sanitize_support_request_details"));
assert.ok(intake.includes("->>'blocking','none')<>'total'"), "L'urgence doit être contrôlée par le serveur");
assert.ok(restrictions.includes("can_read_knowledge_article"));
assert.ok(restrictions.includes("knowledge_article_modules"));
assert.ok(restrictions.includes("knowledge_article_roles"));
assert.ok(restrictions.includes("app_version_min"));
assert.ok(restrictions.includes("knowledge-article-attachments"));
assert.ok(reliability.includes("candidate.token_hits>0"), "La recherche doit accepter les formulations naturelles partielles");
assert.ok(!reliability.includes("requested_module is not null and exists"), "Le module courant ne doit pas masquer la documentation pertinente");
assert.ok(foundation.includes("support-ticket-attachments"));
assert.ok(foundation.includes("'support-ticket-attachments','support-ticket-attachments',false"), "Les pièces jointes ne doivent pas être publiques");

for (const action of ["documentation.restore", "documentation.duplicate", "documentation.attachment.upload", "documentation.attachment.download"]) {
  assert.ok(adminApi.includes(`action===\"${action}\"`), `Missing documentation admin action: ${action}`);
}
assert.ok(adminApi.includes("encoded.length>13981020"), "Oversized base64 payloads must be rejected before decoding");

assert.ok(access.includes("help/documentation"));
assert.ok(access.includes("help/tickets"));
assert.ok(html.includes("piloz-help-support.css"));
assert.ok(html.includes("erp-help-support.js"));
assert.ok(!app.includes("service_role"), "Aucune clé privilégiée ne doit être référencée dans le navigateur");

const carefulClaim = "Piloz intègre une architecture technique préparée pour plusieurs exigences de facturation électronique. Certaines fonctions peuvent nécessiter une configuration, un connecteur externe ou une validation complémentaire avant utilisation en production.";
assert.ok(knowledge.includes(carefulClaim));
for (const forbidden of ["Piloz est certifié NF525", "Piloz est une plateforme agréée", "transmission garantie"]) {
  assert.ok(!knowledge.includes(forbidden), `Allégation interdite détectée : ${forbidden}`);
}

console.log(JSON.stringify({ ok: true, navigation: 4, safeContext: 11, privateAttachments: true, feedbackComments: true }));
