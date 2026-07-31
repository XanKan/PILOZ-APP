# Audit du module Activités

Date : 31 juillet 2026  
Périmètre : PILOZ-APP, Supabase, CRM, extensions agenda et Pilo.

## État avant refonte

Le CRM utilisait déjà `activities`, `crm_activity_links` et `crm_activity_participants`. Une vue simple proposait liste, aujourd’hui, semaine, agenda, équipe et chronologie. La création était liée aux clients, opportunités et documents, mais les types étaient figés, les rappels limités à une date, les pièces jointes absentes et la confidentialité insuffisamment structurée.

L’historique des opportunités et des tiers lisait déjà les mêmes tables : la refonte conserve donc les données et les relations existantes. Aucune table parallèle d’activités n’a été créée.

## Sécurité observée

Le dépôt possède un modèle de permissions centralisé (`permission_definitions`, rôles, portées propre/équipe/entreprise), des fonctions de contexte serveur et des politiques RLS. Le nouveau module réutilise ces sources. Le navigateur ne choisit jamais un `company_id` lors d’un enregistrement : les RPC le déduisent de la session et de l’entreprise active autorisée.

## Intégrations observées

Les connexions `google_calendar` et `microsoft_calendar` existent dans `external_connections`. Une synchronisation n’est proposée que si la connexion est `connected`, bidirectionnelle et configurée pour exporter les activités. Aucun succès externe n’est simulé.

## Décisions de refonte

- conserver la table `activities` et migrer les données existantes ;
- ajouter des types et résultats configurables par entreprise ;
- conserver les colonnes historiques de relation tout en généralisant `crm_activity_links` ;
- imposer archivage/annulation plutôt que suppression ;
- exposer les opérations sensibles uniquement via RPC sécurisées ;
- ajouter une interface unique Liste, Agenda, Chronologie, Mes activités et Équipe ;
- utiliser les mêmes données dans les fiches client, prospect et opportunité ;
- publier la documentation dans la base officielle de Pilo.

## Risques traités

- fuite inter-entreprises : RLS et fonctions de contexte ;
- activité privée visible à tort : politique restrictive et fonction `activity_is_visible` ;
- relation vers un objet d’une autre entreprise : validation serveur par type ;
- suppression de la piste d’audit : protection de suppression et journal append-only ;
- synchronisation factice : connexion réelle obligatoire et erreurs conservées ;
- listes volumineuses : pagination serveur et index métier.

