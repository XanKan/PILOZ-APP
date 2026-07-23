# Catalogue Articles & services

## Objectif

Le catalogue centralise les articles, services, variantes, tarifs, fournisseurs et données de stock utilisés par les devis, factures, avoirs, commandes fournisseurs et réceptions. Les documents conservent une photographie des données commerciales afin qu'une modification ultérieure du catalogue ne réécrive jamais un document existant.

## Activation en production

1. Appliquer les migrations Supabase jusqu'à `202607230050_catalog_workspace.sql` avec le script de déploiement de production.
2. Exécuter `scripts/post-deploy-production-checks.sql` dans le projet Supabase de production.
3. Vérifier que `latest_migration` vaut `202607230050` avant d'utiliser les nouvelles fonctions.

La migration est additive : elle ne supprime ni table ni donnée existante. Tant qu'elle n'est pas appliquée, l'interface statique reste publiable mais les nouvelles écritures du catalogue ne peuvent pas être garanties.

## Garanties métier

- Références automatiques atomiques et uniques par entreprise.
- Historique daté des prix et résolution des tarifs par client, quantité, variante et période.
- Un fournisseur principal maximum par article, avec références et conditions propres à chaque fournisseur.
- Mouvements, transferts et réservations de stock atomiques, persistés côté base.
- Blocage de la suppression d'un article déjà utilisé ; l'action devient un archivage traçable.
- Photographie de la désignation, référence, catégorie, TVA, prix et origine tarifaire dans chaque ligne de document.
- Import CSV suivi par un rapport durable, avec détection des doublons et stratégie créer, mettre à jour ou ignorer.
- Isolation des données par `company_id`, politiques RLS et contrôle des permissions sensibles.

## Contrôles automatisés

- `tests/catalog-migration-pglite.cjs` applique toutes les migrations et teste les RPC, la RLS, l'isolation multi-entreprises, les prix, variantes, transferts, réservations et snapshots.
- `tests/catalog-workspace.html` couvre la navigation, les écrans liste/fiche, la recherche, les filtres, 10 000 références, les catégories, tags, variantes, fournisseurs, tarifs et imports.
- `tests/run-html-tests.cjs` permet d'exécuter les tests HTML avec Chromium via `playwright-core` installé hors du dépôt.

## Périmètre préparé

Les tables de packs/kits, profils comptables et grilles tarifaires sont prêtes à être étendues. Les écritures comptables restent volontairement hors de ce module tant que le futur paramétrage comptable global n'est pas finalisé.
