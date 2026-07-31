# Architecture du module Activités

## Flux principal

1. `erp-activities-workspace.js` demande `get_activity_workspace_v3`.
2. La RPC résout l’entreprise, les droits et la portée depuis la session.
3. PostgreSQL applique en complément la RLS et la confidentialité.
4. La réponse paginée alimente toutes les vues sans dupliquer les données.
5. Les mutations passent par `save_activity_workspace`, `complete_activity_workspace`, `transition_activity_workspace` ou les RPC spécialisées.
6. Les triggers écrivent les événements immuables.

## Interface

- route canonique : `#crm/activities` ; alias : `#activities` ;
- liste paginée et actions groupées ;
- agenda jour/semaine/mois avec replanification persistée ;
- chronologie ;
- vues personnelle et équipe selon la portée ;
- formulaires adaptatifs basés sur les types configurés ;
- détail avec compte rendu, prochaine étape, checklist, relations, pièces jointes, synchronisation et historique.

## Intégrations internes

Les liens vers clients, prospects, contacts, opportunités, devis, factures, avoirs, paiements, fournisseurs et factures fournisseurs sont stockés dans `crm_activity_links`. Les raccourcis CRM appellent `openActivityForEntity`, qui préremplit le nouvel éditeur sans créer une seconde activité.

## Rappels et notifications

Les rappels en application sont traités par `dispatch_due_activity_reminders`, exécutable uniquement par un worker de confiance. Les notifications d’assignation sont créées à l’enregistrement. Les canaux externes restent en échec explicite tant qu’aucun worker d’envoi réel n’est branché.

## Agenda externe

Le navigateur n’appelle l’intégration que pour une connexion réelle de l’utilisateur, active, bidirectionnelle et autorisant l’export des activités. Les identifiants et erreurs du fournisseur sont conservés dans `activity_sync_links`.

## Performance

La recherche, les filtres, les périodes et la pagination sont exécutés côté serveur. Des index couvrent entreprise, dates, responsable, équipe, statut, type, rappels et relations.

