# Audit préalable — refonte du CRM Piloz

Date de l’audit : 27 juillet 2026  
Dépôt : `PILOZ-APP`  
Périmètre : navigation CRM, prospects, opportunités, pipeline, activités, documents commerciaux, rapports et droits d’accès.

## Conclusion

Le dépôt possède déjà un socle CRM avancé et multi-entreprise. La refonte doit l’étendre, pas créer un second CRM. Les prospects sont stockés dans `clients` avec `relationship_type = 'prospect'`, les opportunités utilisent `opportunities`, les activités utilisent `activities` et les devis/factures sont reliés par `documents.opportunity_id`. Les tables de pipelines, sources, motifs de perte, contacts, notes, produits, liens, timeline, vues, automatisations et connecteurs existent également.

Les écarts constatés sont principalement des incohérences entre trois couches d’interface successives et quelques règles métier encore calculées côté navigateur.

## État du dépôt avant modification

- Branche suivie : `main`.
- Dépôt distant : `https://github.com/XanKan/PILOZ-APP.git`.
- Synchronisation : `git pull --rebase origin main` sans conflit.
- Dernier commit au début de l’audit : `1d64d8f`.
- Arbre de travail : propre.
- Dernière migration connue : `202607270091`.

## Architecture CRM existante

### Interface

- `assets/js/modules/erp/erp-modern.js` contient encore une première implémentation locale des opportunités, prospects et activités.
- `assets/js/modules/erp/erp-crm-command-center.js` ajoute le pipeline RPC, les vues Kanban/liste/prévision/calendrier, les fiches, les activités et les rapports.
- `assets/js/modules/erp/erp-crm-enterprise.js` enrichit ce module avec la gestion des pipelines, les contacts, la recherche globale, les vues enregistrées et les connecteurs e-mail/calendrier.
- `assets/css/crm-command-center.css` porte le style du centre CRM.

Cette superposition explique plusieurs divergences de comportement : certaines routes appellent encore `PilozModern`, tandis que d’autres sont interceptées par `PilozCRM`.

### Données

- `clients` : clients et prospects, contacts, statut et score CRM.
- `opportunities` : opportunités, pipeline, étape, responsable, priorité, prévision et prochaines actions.
- `activities` : appels, e-mails, rendez-vous, tâches et notes liés aux tiers, opportunités ou documents.
- `documents` : devis et factures avec `opportunity_id` déjà présent.
- `crm_pipelines` et `pipeline_stages` : pipelines configurables et étapes persistées.
- Tables associées existantes : `crm_sources`, `crm_loss_reasons`, `crm_opportunity_products`, `crm_activity_participants`, `crm_activity_links`, `crm_notes`, `crm_tags`, `crm_timeline_events`, vues et automatisations.

### Sécurité

- Les fonctions CRM passent par `_crm_context()` et respectent `company_id`.
- Les droits sont déjà centralisés dans le catalogue de permissions (`crm.prospects.*`, `crm.opportunities.*`, `crm.activities.*`, `crm.reports.*`).
- La portée propriétaire, équipe ou entreprise est appliquée dans les RPC de lecture.
- Aucun accès `service_role` n’est utilisé dans le navigateur.

## Écarts identifiés

1. La navigation affiche encore Prospects et Automatisations dans Suivi commercial, contrairement à l’arborescence cible.
2. Prospects n’est pas encore exposé dans Bibliothèque et l’ancienne route n’est pas redirigée proprement.
3. La création d’une opportunité utilise un tiroir latéral et des sélecteurs HTML simples au lieu de la modale centrée et du sélecteur de tiers recherchable demandés.
4. Les priorités techniques apparaissent en anglais dans plusieurs vues.
5. Les étapes par défaut historiques incluent `Contact établi`, `Proposition à préparer` et `Négociation`, alors que le nouveau parcours demande notamment `Qualifié`, `Besoin identifié` et `Devis à préparer`.
6. Le montant du pipeline repose encore directement sur `opportunities.amount`. La priorité documentaire devis actif / montant estimé n’est pas canonique côté serveur.
7. Les cartes du pipeline n’ont ni menu contextuel au clic droit ni bouton d’actions visible.
8. Les documents liés sont visibles dans le détail, mais la notion de devis principal, variante, complément ou remplacé n’est pas structurée.
9. Les activités disposent d’une liste, d’un calendrier et des connecteurs, mais pas encore de toutes les vues et du rapport de réalisation complet demandés.
10. Les rapports existent, mais leurs filtres et ventilations ne couvrent pas encore tous les axes commerciaux demandés.
11. Les deux anciennes implémentations CRM peuvent brièvement rendre des écrans différents avant que le module Command Center ne reprenne la route.

## Stratégie de refonte retenue

1. Conserver les tables et relations existantes.
2. Ajouter uniquement les colonnes et fonctions nécessaires au montant documentaire, au rôle des documents et aux recherches rapides.
3. Migrer les étapes et priorités sans supprimer l’historique : renommage lorsque possible, archivage contrôlé sinon, puis rattachement des opportunités.
4. Introduire une couche `erp-crm-rework.js` chargée après les modules CRM existants pour unifier les routes et les parcours sans réécrire les modules stables.
5. Déplacer Prospects dans Bibliothèque avec redirection rétrocompatible.
6. Centraliser le calcul des montants et les agrégats de rapports dans des RPC Supabase.
7. Réutiliser strictement le catalogue de permissions et les politiques RLS.
8. Ajouter des tests statiques et PGlite couvrant migration, isolation entreprise, permissions, montants et routes.

## Risques et garde-fous

- Aucune suppression de prospect, opportunité, activité, document ou étape utilisée.
- Les anciens slugs restent reconnus lors de la migration.
- Les montants manuels restent conservés dans `estimated_amount` même lorsqu’un devis devient la source affichée.
- Les documents brouillons sont exclus du montant documentaire par défaut.
- Les fonctions de recalcul sont limitées à l’entreprise de l’utilisateur et ne font confiance à aucun `company_id` envoyé par le navigateur.
- Les actions externes ne sont jamais déclarées comme envoyées sans confirmation du connecteur.

## Résultat de la refonte

- La navigation cible est appliquée : Pipeline, Activités et Rapports commerciaux ; Prospects est désormais dans Bibliothèque avec redirection rétrocompatible.
- Le pipeline conserve les données historiques tout en exposant les neuf étapes commerciales actives demandées.
- Les opportunités utilisent une modale centrée, un sélecteur clients/prospects, la création rapide, des contacts, des responsables, des sources, des priorités françaises et des actions contextuelles.
- Le montant affiché est recalculé côté serveur à partir des devis actifs principaux et complémentaires ; les brouillons, variantes, remplacements et documents annulés ne gonflent pas le pipeline.
- Les activités disposent des vues Aujourd’hui, Liste, Agenda, Semaine, Équipe et Chronologie, avec compte rendu de clôture, prochaine action, report, annulation, glisser-déposer et rattachements métier.
- Les rapports sont agrégés côté serveur et couvrent le pipeline, la période précédente, les prévisions, les collaborateurs, les sources, les pertes, les activités, les devis et la qualité du suivi.
- Les portées own/team/company et les droits de lecture des montants, performances et exports sont contrôlés par le catalogue central et les RPC Supabase.
