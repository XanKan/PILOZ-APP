# Rapport de migration Activités

## Migrations

### `202607310118_activities_workspace_completion.sql`

Migration additive : permissions, types, résultats, colonnes de cycle de vie, rappels, checklist, pièces jointes, événements, synchronisation, filtres enregistrés, index, valeurs par défaut et reprise des activités existantes.

### `202607310119_activities_workspace_security_api.sql`

Ajoute les contrôles de visibilité/écriture, la RLS restrictive, les politiques des tables filles et du stockage, la validation des relations et toutes les RPC du workspace.

### `202607310120_activities_knowledge_base.sql`

Publie les articles officiels Pilo relatifs aux activités et à leur sécurité.

## Compatibilité et reprise

- aucune donnée existante supprimée ;
- les anciens types sont associés aux nouveaux types configurables ;
- les dates historiques sont reportées vers `starts_at`/`ends_at` ;
- les relations historiques restent présentes et sont compatibles avec le modèle multi-liens ;
- les anciennes routes et les appels rapides CRM sont redirigés vers le nouveau module.

## Déploiement

### `202607310121_activities_enterprise_scale.sql`

- préférences d’affichage persistantes par utilisateur ;
- pagination serveur jusqu’à 200 lignes par page, tri serveur et compteurs agrégés en une seule lecture ;
- recherche serveur des clients, prospects, contacts, opportunités, documents et fournisseurs ;
- transitions groupées côté serveur, limitées à 500 activités, avec bilan des éléments modifiés, ignorés ou en erreur ;
- index dédiés aux volumes importants sans suppression ni réécriture des données existantes.

Les migrations doivent être appliquées dans l’ordre numérique par le processus Supabase de production. Tant qu’elles ne sont pas appliquées, l’interface ne doit pas être considérée active en production. Après déploiement, exécuter les contrôles post-déploiement et vérifier la version `202607310121`.
