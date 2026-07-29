# Audit — Documentation, Pilo et support Piloz

Date de l'audit : 29 juillet 2026

Dépôts audités : `PILOZ-APP`, `PILOZ-ADMIN`
Projet Supabase lié : `hpxcbemezvynofxiffzs`

## Synthèse

Piloz dispose déjà d'une application client, d'un back-office interne, d'un modèle central de rôles et permissions, d'un historique d'audit ADMIN et d'une isolation métier par `company_id`. Il ne dispose pas encore d'un centre d'aide publié, d'un assistant documentaire, ni d'un ticket partagé complet entre l'application client et l'équipe Piloz.

Le module existant `support_cases` est un registre interne minimal. Il ne gère ni numéro public, ni fil de messages client, ni pièces jointes privées, ni SLA, ni suggestions produit, ni index documentaire. Il est conservé pour éviter toute régression et sera progressivement remplacé par le nouveau domaine `support_tickets`.

## Architecture actuelle

### PILOZ-APP

- Application web statique modulaire servie sur `app.piloz.fr`.
- Écran principal dans `index.html`, modules métier sous `assets/js/modules/erp` et styles sous `assets/css`.
- Données réelles lues dans Supabase ; aucun service role dans le navigateur.
- Navigation actuelle : tableau de bord, suivi commercial, ventes, achats, bibliothèque, comptabilité et paramètres.
- Contrôle d'accès central via `permission_definitions`, `company_roles`, `company_role_permissions`, `company_members` et `has_company_permission`.
- Nombreux tests Node, navigateur et PGlite ; pas de `package.json` à la racine.

### PILOZ-ADMIN

- Application React/Vite/TypeScript servie sur `admin.piloz.fr`.
- Accès réservé aux administrateurs plateforme et protégé par MFA selon la politique du compte.
- API serveur unique `platform-admin-api`, avec service role uniquement dans l'Edge Function.
- Permissions internes déjà séparées : lecture/écriture du support, session support, entreprises, utilisateurs, conformité et audit.
- Le support actuel permet seulement de créer ou modifier une demande interne.

### Supabase

- Schéma multi-entreprises majoritairement isolé par `company_id` et RLS.
- Fonctions SECURITY DEFINER existantes avec contrôles de membre et de permission.
- Stockage Supabase déjà utilisé pour plusieurs fichiers métier.
- Dernière migration locale au début de ce chantier : `202607290105`.

## Fonctionnalités réellement disponibles et documentables

| Domaine | État audité | Remarque documentaire |
| --- | --- | --- |
| Tableau de bord et widgets | Disponible | Données Supabase et préférences utilisateur. |
| Entreprise et paramètres | Disponible | Identité, coordonnées, adresses, fiscalité, banque, ventes et documents. |
| Utilisateurs, équipes, rôles | Disponible | Permissions centrales réutilisées par l'aide et le support. |
| CRM, pipeline, opportunités, activités | Disponible | Pipeline persistant et liens avec documents. |
| Clients, prospects, contacts | Disponible | Recherche entreprise, adresses et contact principal selon les données disponibles. |
| Articles et services | Disponible | Articles, services, main-d'œuvre, abonnements et frais. |
| Stock | Roadmap | Aucune procédure opérationnelle ne doit être publiée. |
| Devis et modèles | Disponible | Brouillon, validation, PDF, conversion et modèles. |
| Factures, avoirs, situations, acomptes | Disponible avec cas particuliers | Les règles fiscales et les contrôles de finalisation doivent être explicités. |
| Règlements, échéances, relances | Disponible | Persistés et liés aux factures. |
| Facturation électronique | Configuration ou connecteur requis | Architecture et connecteur externe présents ; ne pas promettre une disponibilité universelle. |
| Achats et fournisseurs | Partiel | Commandes, réceptions et factures fournisseur présentes ; dépend des droits et de la configuration. |
| Comptabilité et exports | Disponible | Paramétrage, journaux, exports, TVA sur encaissements et archives fiscales. |
| Google/Outlook/Gmail | Configuration requise | Les fournisseurs doivent être activés/configurés ; ne jamais annoncer une connexion si elle ne l'est pas. |
| Abonnement | Disponible | Dépend du contrat et du service de paiement réel. |
| Certification NF525/NF203/AFNOR | Indisponible | Piloz ne doit pas être présenté comme certifié. |

## Pages et composants réutilisables

- Coque, navigation, panneaux, modales, badges, cartes et états vides de PILOZ-APP.
- `PilozModern.renderRoute` et `PilozModern.renderNavigation` pour intégrer l'aide sans seconde application.
- Client Supabase et résolution de l'entreprise active déjà disponibles dans l'état ERP.
- Composants `PageHeader`, `Card`, `Table`, `Modal`, `Field`, `Badge`, `Loading` et `ErrorState` dans PILOZ-ADMIN.
- `platform-admin-api` pour toutes les actions internes sensibles.
- Système d'audit ADMIN existant pour tracer publication, affectation et changements de statut.

## Lacunes avant chantier

1. Absence de catégories, articles, versions, index et historique de publication.
2. Absence de distinction structurée entre brouillon, validation, publication et archivage.
3. Absence de Pilo et de recherche documentaire contextualisée.
4. Absence de source affichée, de niveau de réponse et de retour utile/non utile.
5. Absence de ticket client partagé, de numéro atomique et de conversation.
6. Absence de pièces jointes support dans un bucket privé.
7. Absence de notes internes séparées des messages visibles au client.
8. Absence de file d'attente, équipes, affectations, SLA et réponses enregistrées.
9. Absence de collecte des questions sans réponse et de suggestions produit.
10. Absence de documentation de disponibilité par version, rôle et état fonctionnel.

## Risques et garde-fous

### Sécurité

- Ne jamais accepter un `company_id` navigateur sans vérifier `auth.uid()` et l'appartenance.
- Ne jamais exposer `internal` ou `draft` aux utilisateurs clients.
- Ne jamais envoyer à Pilo une facture complète, des coordonnées bancaires, un token, un cookie ou des messages privés.
- Utiliser des URLs signées courtes pour les pièces jointes et un chemin incluant `company_id/ticket_id/attachment_id`.
- Valider extension, MIME, taille, nom, entreprise et autorisation à chaque ajout ou téléchargement.

### Produit et conformité

- Ne jamais inventer une fonctionnalité, un statut d'envoi, un ticket ou une synchronisation.
- Ne jamais présenter Piloz comme plateforme agréée ou logiciel certifié sans preuve officielle.
- La facturation électronique doit être formulée ainsi :

  > Piloz intègre une architecture technique préparée pour plusieurs exigences de facturation électronique. Certaines fonctions peuvent nécessiter une configuration, un connecteur externe ou une validation complémentaire avant utilisation en production.

- Le stock reste une fonctionnalité de roadmap. Réponse Pilo obligatoire :

  > La gestion des stocks fait actuellement partie de la roadmap Piloz et n’est pas encore disponible dans la version actuelle.

### Performance

- Recherche paginée et indexée pour plusieurs milliers d'articles.
- Tickets paginés et filtrés pour au moins 100 000 tickets et plusieurs millions de messages.
- Pas de chargement global des conversations ou pièces jointes.
- Index documentaire mis à jour à la publication, jamais à chaque frappe de l'éditeur.

## Architecture cible retenue

### Documentation

- `knowledge_categories`
- `knowledge_articles`
- `knowledge_article_versions`
- `knowledge_article_chunks`
- `knowledge_tags`, `knowledge_article_tags`, `knowledge_article_links`
- `knowledge_article_feedback`, `knowledge_search_events`, `knowledge_index_events`
- `knowledge_unanswered_questions`

Seuls les articles `published`, dans leur version courante et compatibles avec la visibilité de l'utilisateur, sont recherchables par Pilo.

### Assistant

- `assistant_conversations`
- `assistant_messages`
- `assistant_feedback`
- recherche serveur via l'Edge Function `pilo`
- contexte réduit par liste blanche : route, module, sous-module, type et statut d'objet, actions disponibles, rôle, permissions, langue et version de l'application.

Le fournisseur initial est documentaire et extractif. Il ne prétend pas être un modèle génératif. L'interface `AssistantProvider` permet d'ajouter ultérieurement un fournisseur serveur sans exposer sa clé.

### Support

- `support_tickets`, `support_ticket_messages`, `support_ticket_events`
- `support_ticket_attachments`, `support_ticket_assignments`, `support_ticket_watchers`
- `support_teams`, `support_team_members`, `support_saved_replies`
- `support_sla_policies`, `support_ticket_sla_events`
- `product_suggestions`, `product_suggestion_events`

Un message possède une visibilité `client`, `internal` ou `draft`. Les deux dernières ne sont jamais lisibles dans PILOZ-APP. Le journal d'événements est append-only.

## Stratégie de déploiement

1. Ajouter les tables, index, permissions, RLS, bucket privé et fonctions atomiques.
2. Publier les catégories et les premiers articles audités.
3. Ajouter Documentation, Pilo, Mes tickets et Contacter le support dans PILOZ-APP.
4. Ajouter Documentation et le nouveau Support dans PILOZ-ADMIN.
5. Déployer l'Edge Function `pilo` puis `platform-admin-api`.
6. Appliquer les migrations additives, exécuter les contrôles RLS A/B et vérifier les parcours bout en bout.
7. Enrichir progressivement la base depuis les questions sans réponse, avec validation humaine avant publication.

## Critères de sortie

- Une question documentée produit une réponse sourcée.
- Une question non couverte produit un état honnête et propose un ticket réel.
- Une question sur le stock renvoie la réponse roadmap sans procédure opérationnelle.
- Un ticket client est visible côté client et côté ADMIN, avec le même numéro.
- Une réponse ADMIN envoyée apparaît côté client ; une note interne n'apparaît jamais.
- Une publication met à jour la recherche ; un brouillon reste absent de Pilo.
- Deux entreprises ne peuvent lire aucun ticket, message, fichier, conversation ou événement l'une de l'autre.
