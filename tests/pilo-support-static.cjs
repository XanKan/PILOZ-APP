const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const app = read("assets/js/modules/erp/erp-help-support.js");
const helpCss = read("assets/css/piloz-help-support.css");
const documentEditor = read("assets/js/modules/erp/erp-document-editor-v2.js");
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
const guidedAnswers = read("supabase/migrations/202607290114_pilo_guided_answers.sql");
const academy = read("supabase/migrations/202607290115_help_academy_documentation.sql");

assert.ok(app.includes("trainingAdvanceTimer:0"), "La formation doit disposer d'un minuteur d'enchainement automatique");
assert.ok(app.includes("function scheduleTrainingAdvance(delay=900)"), "Une action reussie doit programmer automatiquement l'etape suivante");
assert.ok(app.includes("scheduleTrainingAdvance(isLast?850:320)"), "La confirmation de reussite doit avancer rapidement sans clic obligatoire");
assert.ok(app.includes("La prochaine consigne arrive automatiquement"), "L'utilisateur doit etre informe de l'enchainement automatique sans bouton suivant");
assert.ok(app.includes("function continueTraining(){clearTimeout(ui.trainingAdvanceTimer)"), "Un clic manuel ne doit pas doubler l'avancement automatique");
assert.ok(app.includes("function closeTraining(){clearTimeout(ui.trainingFramePoll);clearTimeout(ui.trainingFieldTimer);clearTimeout(ui.trainingAdvanceTimer)"), "Quitter la formation doit annuler l'enchainement automatique");

for (const label of ["Documentation", "Formation", "Pilo", "Mes tickets", "Contacter le support"]) {
  assert.ok(app.includes(label), `Entrée d'aide absente : ${label}`);
}
assert.ok(app.includes("TRAINING_COURSES"), "Le catalogue de formation doit être disponible");
assert.ok(app.includes("TRAINING_EXERCISES"), "Chaque capsule doit proposer de vraies actions interactives");
assert.ok(app.includes("saveTrainingProgress"), "La progression des formations doit être conservée");
assert.ok(app.includes("help/training"), "La route Formation doit être rendue par le centre d’aide");
assert.ok(app.includes("trainingSimulator"), "La formation doit utiliser un simulateur Piloz guidé");
assert.ok(app.includes("aucune modification enregistrée"), "La formation doit signaler qu'elle n'enregistre aucune modification réelle");
assert.ok(app.includes("TRAINING_LIVE_SCREENS"), "Chaque capsule doit être reliée à un véritable écran Piloz");
assert.ok(app.includes("launchTraining"), "La formation doit ouvrir directement le véritable module Piloz");
assert.ok(app.includes("trainingActive"), "Le guidage doit rester actif sur le véritable écran Piloz");
assert.ok(!app.includes("ensureTrainingFallback(lesson,ui.trainingStep)"), "La formation ne doit jamais remplacer le vrai écran Piloz par une fausse fenêtre");
assert.ok(app.includes("attempt<80") && app.includes("L’écran Piloz est encore en cours de chargement"), "Le guidage doit attendre le vrai écran sans ouvrir de simulation de secours");
assert.ok(app.includes("text:'Ventes',selector:'.modern-primary-item[aria-label=\"Ventes\"]',allow:true"), "Le clic Ventes doit réellement ouvrir son sous-menu pendant la formation");
assert.ok(app.includes("selector:'.company-subnav-item[onclick*=\"/tax\"]',allow:true"), "La formation Fiscalité doit cibler et autoriser la vraie navigation");
assert.ok(app.includes("selector:'.company-subnav-item[onclick*=\"/bank\"]',allow:true"), "La formation Banque doit cibler et autoriser la vraie navigation");
assert.ok(app.includes("selector:'[data-training-client-search]',allow:true,event:'piloz-training-client-selected'"), "La formation doit valider le client uniquement après sa sélection dans la liste normale");
assert.ok(!documentEditor.includes('data-training-expected="Atelier Horizon"'), "La formation ne doit pas exiger le nom complet avant d’autoriser la sélection du client");
assert.ok(app.includes("trainingClientChoice&&targetEvent==='piloz-training-client-selected'"), "Le guide doit autoriser le clic sur le client proposé sans clignotement ni verrouillage");
assert.ok(app.includes("doc.addEventListener('piloz-training-client-selected',completeField,true)"), "La sélection du client doit faire avancer automatiquement la formation");
assert.ok(app.includes("element===document.activeElement"), "L’anonymisation ne doit jamais remplacer la saisie active de l’utilisateur");
assert.ok(!app.includes("animation:pilozTrainingPulse"), "Le repère de formation ne doit plus clignoter pendant la saisie");
assert.ok(app.includes("function resetTrainingViewport()") && app.includes("resetTrainingViewport();trainingAnonymizeScreen()"), "La formation doit repartir en haut de la vue avant d’afficher la première cible");
assert.ok(helpCss.includes(".piloz-training-privacy-active #main{padding-top:112px!important"), "L’en-tête Académie ne doit pas masquer les actions situées en haut de page");
assert.ok(helpCss.includes("scroll-margin-top:128px!important") && helpCss.includes("scroll-margin-bottom:260px!important"), "Les cibles doivent rester visibles entre l’en-tête et le coach");
assert.ok(documentEditor.includes("function refreshClientSearchResults()"), "La recherche client doit rafraîchir uniquement sa liste de résultats");
assert.ok(documentEditor.includes("data-training-demo-client") && documentEditor.includes("data-training-client-search") && documentEditor.includes("Atelier Horizon"), "La formation doit proposer Atelier Horizon dans la recherche client normale même sur un compte vide");
assert.ok(documentEditor.includes("function selectTrainingClient()") && documentEditor.includes("trainingClientSelected=true"), "Le client fictif doit pouvoir être réellement sélectionné dans la simulation");
assert.ok(documentEditor.includes("new CustomEvent('piloz-training-client-selected',{bubbles:true})"), "Le vrai sélecteur doit confirmer la sélection au guide de formation");
assert.ok(documentEditor.includes("blocked=!d.client_id&&!trainingClient"), "La sélection fictive doit rendre la dernière action de formation cliquable");
assert.ok(app.includes("[data-piloz-training-safe]"), "Les données fictives du parcours doivent rester stables pendant la saisie");
const clientSearchFunction = documentEditor.match(/function searchClient\(value\)\{([^}]+)\}/)?.[1] || "";
assert.ok(clientSearchFunction.includes("refreshClientSearchResults()") && !clientSearchFunction.includes("renderEditor"), "La saisie client ne doit pas reconstruire tout l’éditeur");
assert.ok(app.includes("selector:'[data-document-line] .document-v2-designation',allow:true,event:'change'"), "La recherche et la sélection de l’article doivent rester une seule action fluide");
assert.ok(app.includes("button[onclick*=\"newDocument(\\'invoice\\')\"]") && app.includes("title:'Créer et finaliser une facture',duration:420"), "La formation Facture doit couvrir le cycle complet dans le véritable éditeur");
assert.ok((app.match(/selector:'\[data-finalize-document\]'/g)||[]).length>=2, "Les formations Devis et Facture doivent aller jusqu'à la validation protégée");
assert.ok(app.includes("saisir une ligne manuellement") && app.includes("sélectionner un article déjà créé") && app.includes("créer un nouvel article"), "Le coach doit expliquer les trois modes de saisie d’un article");
assert.ok(!app.includes("selector:'[data-training-demo-item]'"), "Le guide ne doit pas bloquer le clic sur un résultat avec une étape intermédiaire");
assert.ok(documentEditor.includes("TRAINING_DEMO_ITEMS") && documentEditor.includes("data-training-demo-item"), "La formation doit proposer un catalogue fictif indépendant des données réelles");
assert.ok(documentEditor.includes("function selectTrainingItem") && documentEditor.includes("training_demo:true"), "Un article fictif doit pouvoir remplir la ligne sans persistance réelle");
assert.ok(documentEditor.includes("new Event('change',{bubbles:true})"), "La sélection d’un article doit faire avancer automatiquement la formation");
assert.ok(!app.includes("id:'electronique'"), "Le parcours Facturation électronique doit être retiré de la formation");
assert.ok(app.includes("TRAINING_DEMO_COMPANIES"), "La formation doit utiliser des entreprises fictives");
assert.ok(app.includes("trainingAnonymizeScreen"), "Les données réelles doivent être anonymisées sur chaque écran de formation");
assert.ok(app.includes("trainingNormalizeAmountNodes"), "Les montants fictifs doivent rester alignés et être remplacés comme une valeur unique");
assert.ok(!app.includes('class="training-step-dialog" role="dialog" aria-modal="true"'), "Aucune grande fenêtre intermédiaire ne doit masquer l’écran de formation");
assert.ok(!app.includes("function beginTrainingStep()") && !app.includes("Commencer cette étape"), "La consigne doit être active immédiatement, sans validation manuelle");
assert.ok(app.includes("ui.trainingStep=0") && app.includes("screen=trainingLiveConfig(lesson,0)"), "Une formation relancée doit toujours repartir par la création du devis");
assert.ok(app.includes('class="training-live-coach" id="training-live-coach"') && !app.includes('id="training-live-coach" hidden'), "La consigne doit rester visible en bas dès l’ouverture");
assert.ok(!app.includes('id="training-live-success"') && app.includes("scheduleTrainingAdvance(isLast?850:320)"), "Une action réussie doit avancer automatiquement sans bouton Étape suivante");
assert.ok(helpCss.includes(".piloz-training-privacy-active .rail-company-name{display:none"), "Le nom de l’entreprise doit être masqué pendant une formation");
assert.ok(app.includes("aucune donnée client réelle affichée"), "Le mode formation doit annoncer clairement les données fictives");
assert.ok(!app.includes("piloz_training_frame"), "La formation ne doit plus redémarrer Piloz dans une iframe");
assert.ok(!app.includes('id="piloz-training-live-frame"'), "Aucune iframe de formation ne doit pouvoir rester bloquée au chargement");
assert.ok(app.includes("piloz-live-training-target"), "La zone réelle à cliquer doit être mise en évidence");
assert.ok(app.includes("event.stopImmediatePropagation()"), "Les actions métier dangereuses doivent être bloquées pendant la formation");
assert.ok(app.includes("closeTraining"), "L'utilisateur doit pouvoir quitter la formation à tout moment");
assert.ok(!app.includes('class="training-sim-app"'), "L'ancien faux écran Piloz ne doit plus être rendu");
assert.ok(!app.includes("Vous commencerez par créer un devis, puis vous choisirez"), "L'introduction d'une capsule ne doit jamais reprendre le texte d'une autre formation");
for (const route of ["sales/quotes", "sales/invoices", "crm/pipeline", "library/prospects", "sales/due-dates"]) {
  assert.ok(app.includes(`route:'${route}'`), `Parcours de formation absent pour ${route}`);
}
assert.ok(app.includes("loadedKey=`${trainingStorageKey()}:${lesson.id}`"), "La progression doit être isolée par utilisateur, entreprise et capsule");
assert.ok(app.includes("saved.step??(saved.completed?lesson.steps.length:0)"), "Une ancienne position vidéo ne doit pas valider une capsule interactive");
for (const interaction of ["completeTrainingAction", "validateTrainingInput", "trainingSelect", "trainingChoice", "trainingToggle", "trainingDrop"]) {
  assert.ok(app.includes(interaction), `Interaction de formation absente : ${interaction}`);
}
assert.ok(!app.includes("toggleTraining,seekTraining"), "L'ancien lecteur passif ne doit plus piloter les formations");
assert.ok(app.includes("guidePresentation"), "Les articles doivent être présentés comme des guides pratiques");
assert.ok(app.includes("Comment faire"), "Le gabarit administratif doit être remplacé par un guidage orienté action");
assert.ok(app.includes("openTraining(courseId,lessonId)"), "Un article doit pouvoir ouvrir directement sa formation associée");
assert.ok(!app.includes("${safeMarkdown(article.content)}</div>${article.source_url"), "La vue article ne doit plus afficher le gabarit documentaire brut");
assert.ok(academy.includes("prise-en-main-piloz-15-minutes"), "Le parcours de prise en main doit être publié");
assert.ok(academy.includes("checklist-avant-finalisation-facture"), "La checklist de finalisation doit être publiée");
assert.ok(app.includes("Bonjour, je suis Pilo. Comment puis-je vous aider ?"));
assert.ok(app.includes("Je peux discuter avec vous et vous guider dans Piloz en m’appuyant sur la documentation officielle."));
assert.ok(providers.includes("OpenAIResponsesAssistantProvider"), "Pilo doit disposer d’un fournisseur IA réel");
assert.ok(providers.includes("CloudflareWorkersAIAssistantProvider"), "Pilo doit pouvoir utiliser Cloudflare Workers AI");
assert.ok(providers.includes("api.cloudflare.com/client/v4/accounts"), "Cloudflare doit être appelé côté serveur par son API officielle");
assert.ok(providers.includes("detectPilozIntent"), "Pilo doit distinguer une procédure métier d'un format technique");
assert.ok(providers.includes("Ventes > Factures"), "La création d'une facture doit produire un guidage concret");
assert.ok(providers.includes("Ne recopie jamais les titres Markdown"), "Le fournisseur IA ne doit pas restituer le gabarit documentaire brut");
assert.ok(providers.includes("https://api.openai.com/v1/responses"), "Pilo doit utiliser l’API Responses officielle");
assert.ok(providers.includes("store:false"), "Les réponses Pilo ne doivent pas être conservées chez le fournisseur IA");
assert.ok(providers.includes('private model="gpt-5.6-sol"'), "Le modèle résolu officiellement doit être configuré par défaut");
assert.ok(pilo.includes('Deno.env.get("OPENAI_API_KEY")'), "La clé OpenAI doit rester exclusivement côté serveur");
assert.ok(pilo.includes('Deno.env.get("CLOUDFLARE_API_TOKEN")'), "Le jeton Cloudflare doit rester exclusivement côté serveur");
assert.ok(pilo.includes('Deno.env.get("CLOUDFLARE_ACCOUNT_ID")'), "L’identifiant Cloudflare doit rester exclusivement côté serveur");
assert.ok(pilo.includes("privacySafeIdentifier"), "Un identifiant de sûreté pseudonymisé est requis");
assert.ok(pilo.includes('clean(body.conversationId,40)'), "Pilo doit réutiliser une conversation validée");
assert.ok(app.includes("conversationId:ui.piloConversationId"), "Le navigateur doit transmettre uniquement l’identifiant de conversation");
assert.ok(!app.includes("OPENAI_API_KEY"), "La clé OpenAI ne doit jamais apparaître dans le navigateur");
assert.ok(!app.includes("CLOUDFLARE_API_TOKEN"), "Le jeton Cloudflare ne doit jamais apparaître dans le navigateur");
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
assert.ok(guidedAnswers.includes("left(article.content,2400)"), "La recherche doit transmettre les étapes utiles et pas seulement l'introduction");
assert.ok(guidedAnswers.includes("candidate.slug='creer-finaliser-facture'"), "Le guide de facture doit être prioritaire pour une question opérationnelle");
assert.ok(app.includes("localPiloAnswer(question,sources)"), "Le mode dégradé doit lui aussi répondre avec une procédure lisible");
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

assert.ok(app.includes('class="training-live-modal" role="dialog"'), "La formation doit utiliser une grande fenetre modale");
assert.ok(helpCss.includes(".training-live-modal{position:fixed"), "La modale de formation doit couvrir le grand espace utile");
assert.ok(app.includes("ui.helpSecondaryOpen=false"), "Le sous-menu Aide doit se fermer au clic exterieur");

console.log(JSON.stringify({ ok: true, navigation: 5, trainingCourses: 5, safeContext: 11, privateAttachments: true, feedbackComments: true }));
