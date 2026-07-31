# Rapport de tests du module Activités

Date de recette : 31 juillet 2026  
Version applicative : `0.9.0-compliance.71`  
Version de schéma attendue : `202607310120`

## Résultat

Le module Activités et ses migrations additives ont passé la recette automatisée disponible dans le dépôt.

| Périmètre | Résultat |
| --- | --- |
| Contrôles statiques Activités | 76/76 réussis |
| Parcours commercial navigateur | 108/108 réussis |
| Cycle documentaire PostgreSQL isolé | Réussi |
| CRM, activités, filtres et confidentialité PostgreSQL isolé | Réussi |
| Moteur comptable et TVA PostgreSQL isolé | Réussi |
| Tableau de bord, préférences et RLS PostgreSQL isolé | Réussi |
| Support Pilo et documentation officielle PostgreSQL isolé | Réussi |
| Administration de plateforme et isolation PostgreSQL isolé | Réussi |
| Archives fiscales et détection d'altération | Réussi |
| Volumétrie tableau de bord | 10 001 clients, 50 000 factures, 100 000 paiements et 50 000 activités traités |

## Couverture du module

- création, modification, duplication, report, annulation, clôture et archivage logique ;
- création d'une prochaine action lors de la clôture ;
- types configurables, actifs ou inactifs, sans perte d'historique ;
- vues liste, agenda jour/semaine/mois, chronologie, personnelles et équipe ;
- filtres rapides, filtres enregistrés, pagination serveur et actions groupées ;
- relations avec clients, prospects, contacts, opportunités, devis, factures, avoirs, paiements et fournisseurs ;
- rappels, checklist, participants, pièces jointes privées et journal d'événements non modifiable ;
- permissions par portée, confidentialité privée, RLS et isolation entre entreprises ;
- synchronisation Google Agenda ou Outlook uniquement lorsqu'une connexion réelle est active ;
- documentation officielle Pilo et documentation technique du dépôt.

## Commandes exécutées

```powershell
node --check assets/js/modules/erp/erp-activities-workspace.js
node tests/activities-workspace-static.cjs
node tests/crm-sales-rework-pglite.cjs
node tests/run-html-tests.cjs tests/commercial-workspace.html
node scripts/verify-release.mjs
```

La suite statique complète du dépôt et les scénarios PostgreSQL isolés de cycle documentaire, CRM, comptabilité, tableau de bord, support, administration et archives fiscales ont également été exécutés avec succès.

## Limite de recette externe

Les parcours Google Agenda et Outlook Calendar nécessitent un compte de test réellement connecté au fournisseur. Le code n'annonce jamais une synchronisation réussie en l'absence de réponse réelle du fournisseur ; ces deux parcours devront être rejoués en recette connectée après déploiement des migrations Supabase.
