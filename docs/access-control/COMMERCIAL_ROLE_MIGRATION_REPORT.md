# Rapport de migration — rôle Commercial

## Objectif

Remplacer les autorisations historiques dispersées du rôle Commercial par une définition centrale, vérifiable et identique dans l’interface, les RPC, les politiques RLS et les déclencheurs SQL.

## Décision de migration

La migration `202607260081_company_access_control.sql` crée le rôle système Commercial pour chaque entreprise et lui attribue uniquement les droits documentés dans [PERMISSIONS_MATRIX.md](./PERMISSIONS_MATRIX.md).

Les anciens membres `sales` sont rattachés au rôle système Commercial. Lorsqu’un ancien membre possède des exceptions non standard qui ne sont pas des droits sensibles, Piloz crée ou réutilise un rôle **Commercial historique** afin de préserver les usages existants sans élargir silencieusement le rôle système.

Les exceptions sensibles historiques concernant les prix d’achat, les marges ou les ajustements de stock ne sont pas reprises dans le rôle système Commercial.

## Sécurité appliquée

- Les boutons interdits sont masqués.
- Les méthodes JavaScript sensibles sont protégées même si elles sont appelées directement.
- Les écritures de documents, lignes et paiements passent par des déclencheurs SQL centraux.
- Les politiques RLS utilisent le même résolveur de permissions.
- Les requêtes du catalogue destinées aux commerciaux ne sélectionnent pas les colonnes de coût ou de marge.
- La finalisation d’une facture, la saisie d’un paiement et la création d’un avoir sont refusées côté serveur.

## Validation

Le contrôle automatisé `node tests/access-control-static.cjs` vérifie explicitement les droits accordés et interdits. Le test PostgreSQL `tests/document-lifecycle-pglite.cjs` vérifie que la migration n’endommage pas les devis, factures, conversions, numéros fiscaux ou factures de situation.
