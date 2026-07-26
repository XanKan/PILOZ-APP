# Audit CRM et tableau de bord Piloz

Date de l'audit : 26 juillet 2026  
Dépôt : `PILOZ-APP` (`https://github.com/XanKan/PILOZ-APP`)  
Application : `https://app.piloz.fr`

## Résumé exécutif

Piloz possède déjà une base commerciale réelle : clients/prospects, contacts, opportunités, étapes, activités, rappels, documents, règlements, notifications et un cockpit analytique servi par une agrégation SQL. Les données ne sont donc pas simulées. En revanche, l'architecture actuelle juxtapose trois interprétations du suivi commercial : une vue historique, une vue centrée sur les opportunités et un pipeline documentaire centré sur les devis. Cette superposition rend la navigation incohérente et empêche les pipelines multiples, les prévisions commerciales fiables et une fiche prospect complète.

Le tableau de bord est techniquement plus avancé que son apparence précédente : un RPC agrège les sources, les préférences sont persistées côté serveur, les droits masquent les métriques interdites et le glisser-déposer est disponible. Il doit être raccordé au nouveau modèle CRM pour que le pipeline pondéré, les priorités et les prévisions utilisent les opportunités plutôt que le seul cycle des devis.

## Architecture actuelle

### Frontend

- Application statique sans bundler, servie par GitHub Pages.
- Point d'entrée : `index.html`.
- Orchestrateur ERP et chargement des données : `assets/js/modules/erp/erp-app.js`.
- Navigation et vues historiques : `erp-modern.js`.
- Calculs commerciaux historiques : `erp-commercial-v2.js`.
- Espace opportunités/activités/échéances : `erp-commercial-workspace.js`.
- Cockpit analytique : `erp-dashboard-cockpit.js`.
- Styles modernes et cockpit : `modern-erp.css`, `dashboard-cockpit.css`.
- API navigateur : jeton utilisateur Supabase uniquement ; aucune clé `service_role` n'est exposée au navigateur.

### Supabase

Les sources de vérité réutilisables sont :

- `clients` avec `relationship_type` pour distinguer prospect/client sans doublon ;
- `client_contacts` et `client_contact_roles` ;
- `opportunities` ;
- `pipeline_stages` ;
- `activities`, `activity_assignments` et `reminders` ;
- `documents`, `document_lines`, `document_links`, snapshots et PDF finaux ;
- `payments`, échéances et relances ;
- `notifications` et préférences ;
- `activity_logs` et `opportunity_stage_history` ;
- `dashboard_preferences`.

Les opérations déjà atomiques comprennent le déplacement d'une opportunité, la conversion devis/facture, les règlements et le cycle fiscal des documents. Le tableau de bord est chargé par un seul RPC coordonné (`get_dashboard_cockpit`) et non par une succession de requêtes navigateur.

## Fonctionnalités réellement persistées

- création/modification d'une opportunité ;
- étape, probabilité, responsable et prochaine action ;
- déplacement d'étape par RPC avec historique ;
- activités liées à un client, une opportunité ou un document ;
- assignations, notifications et journal d'activité ;
- automatisations documentaires configurables ;
- conversion prospect/client via la même table de tiers ;
- préférences du tableau de bord par utilisateur et entreprise ;
- documents et règlements liés aux opportunités ;
- agrégations du cockpit et filtres par période.

## Problèmes constatés

1. La navigation expose encore `Vue d'ensemble`, `Opportunités` et `Relances commerciales`, contrairement au parcours cible centré sur Pipeline / Prospects / Activités / Automatisations / Rapports CRM.
2. Le pipeline principal visible dans l'espace commercial est alimenté par les devis, alors que le Kanban métier doit être alimenté par les opportunités.
3. `pipeline_stages` est rattachée uniquement à l'entreprise ; aucun objet pipeline ne permet plusieurs processus commerciaux.
4. Les prospects sont une simple liste de `clients.relationship_type='prospect'` sans scoring explicable, vues sauvegardées, conversion atomique ni détection de doublons.
5. Les activités sont persistées, mais les vues agenda/équipe, participants, liens multiples et résultats structurés sont incomplets.
6. Les raisons de perte, sources, tags, champs personnalisés, séquences, segments et automatisations n'ont pas de modèle relationnel complet.
7. Certaines vues chargent les collections dans l'état global du navigateur. Cela n'est pas adapté aux volumes demandés.
8. Les routes de fiches CRM ne sont pas toutes reconnues par le routeur historique.
9. Le cockpit calcule encore le bloc commercial à partir des devis et non du pipeline d'opportunités.
10. Le rôle commercial n'est pas systématiquement limité à ses propres opportunités dans les lectures analytiques historiques.

## Composants inutilisés ou dupliqués

- Le CRM historique intégré à `index.html` n'est plus la source d'affichage principale mais reste présent.
- `erp-modern.js`, `erp-commercial-v2.js` et `erp-commercial-workspace.js` possèdent chacun une implémentation partielle du pipeline/tableau de bord.
- `dashboard_widgets` a été remplacé fonctionnellement par `dashboard_preferences`, mais reste nécessaire pour la compatibilité des anciennes préférences.

Ces éléments ne sont pas supprimés pendant la migration. Une couche de compatibilité redirige les anciennes routes vers le nouveau workspace.

## Risques de migration

- perte de l'étape actuelle si une opportunité n'est pas rattachée à une étape du pipeline par défaut ;
- collision de slugs lors de la duplication d'un pipeline ;
- doublon prospect/client si une nouvelle table de prospects remplace brutalement `clients` ;
- contournement des permissions par une fonction `SECURITY DEFINER` mal bornée ;
- surcharge du navigateur si les activités/timelines sont chargées sans pagination ;
- déclenchement d'e-mails sans connecteur réel ;
- divergence entre les documents finalisés et les métriques CRM.

## Stratégie retenue

1. Conserver `clients` comme source unique des prospects et clients.
2. Ajouter `crm_pipelines`, puis rattacher de façon additive `pipeline_stages` et `opportunities` à un pipeline.
3. Conserver les slugs historiques et affecter toutes les étapes/opportunités existantes au pipeline par défaut.
4. Ajouter les objets CRM manquants (sources, raisons, tags, produits, notes, champs, automatisations, séquences, segments, scoring et timeline).
5. Exposer des RPC paginés et atomiques qui déduisent l'entreprise depuis `auth.uid()`.
6. Faire du Pipeline la page des opportunités et rediriger les anciennes routes.
7. Charger le Kanban, les prospects, les activités et les rapports côté serveur, avec des limites strictes.
8. Enrichir le cockpit existant au lieu de créer un second tableau de bord.
9. Conserver tous les anciens modules comme repli tant que la migration Supabase n'est pas appliquée.

## Modèle de données recommandé

Le modèle cible est documenté dans `CRM_MIGRATION_REPORT.md`. Il réutilise les tiers, contacts, documents, règlements et fichiers. Les nouvelles tables ne dupliquent pas ces objets ; elles stockent uniquement les informations spécifiques au CRM.

## RLS et sécurité

- toutes les tables CRM portent `company_id` et activent RLS ;
- les lectures vérifient l'appartenance à l'entreprise ;
- les écritures vérifient l'appartenance et l'auteur ;
- les suppressions de configuration sont limitées aux propriétaires/administrateurs ;
- les historiques ne sont pas modifiables depuis le navigateur ;
- les RPC atomiques fixent `search_path`, utilisent `auth.uid()` et déduisent l'entreprise depuis l'adhésion ;
- aucune fonction ne fait confiance à un `company_id` transmis par le navigateur.

## Direction UI

Le nouveau workspace conserve la palette claire Piloz mais adopte une composition plus éditoriale : barre de pilotage compacte, indicateurs dans une surface unique, colonnes légères, cartes d'opportunités fines, détails contextuels et états vides utiles. Les animations sont brèves et désactivées avec `prefers-reduced-motion`.

