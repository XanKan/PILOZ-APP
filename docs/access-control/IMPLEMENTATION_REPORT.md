# Rapport d’implémentation — Utilisateurs, rôles et permissions

## Résultat

Piloz dispose désormais d’une source centrale pour les rôles et autorisations d’entreprise. L’ancien champ texte `company_members.role` reste synchronisé pour la compatibilité, mais la décision d’accès provient de `company_roles`, `company_role_permissions` et du résolveur commun.

## Base de données

La migration additive `202607260081_company_access_control.sql` ajoute :

- le catalogue `permission_definitions` ;
- les rôles `company_roles` ;
- les permissions par rôle `company_role_permissions` ;
- les équipes et leur rattachement ;
- le registre d’invitations ;
- le journal immuable des accès ;
- les fonctions de résolution, de recherche, de gestion et d’acceptation ;
- les protections du dernier administrateur et des rôles système ;
- les colonnes d’attribution nécessaires aux portées `own`, `team` et `company` ;
- les contrôles serveur et politiques RLS sur les opérations métier sensibles.

La migration ne supprime aucune donnée et provisionne automatiquement les quatre rôles système sur les entreprises existantes et futures.

## Interface

La page **Équipe et accès** comprend :

- recherche, filtres, tris et pagination serveur ;
- statuts utilisateur et invitation ;
- changement de rôle, suspension, réactivation, retrait et révocation des sessions ;
- parcours d’invitation en deux étapes ;
- suivi et modification des invitations ;
- cartes de rôles système et personnalisés ;
- éditeur groupé en deux colonnes avec interrupteurs et portées ;
- création depuis un rôle vide ou existant ;
- duplication et archivage ;
- journal chronologique des changements.

La navigation et les actions sensibles s’adaptent aux droits résolus. Les coûts et marges restent cachés quand le rôle ne les autorise pas.

## Traitement serveur des invitations

L’Edge Function `company-access` traite les invitations, renvois, annulations, mises à jour et révocations de sessions avec la clé serveur exclusivement côté Supabase. Elle vérifie l’identité de l’administrateur, sa permission, la limite d’utilisateurs de l’offre et les doublons.

## Exploitation

Après le push du code, la migration et l’Edge Function doivent être déployées sur le projet Supabase de production. Le script `scripts/post-deploy-production-checks.sql` valide la version, les quatre rôles, les RPC, les tables RLS et les déclencheurs serveur.

## Fichiers de référence

- [Audit initial](./USERS_ROLES_AUDIT.md)
- [Matrice des permissions](./PERMISSIONS_MATRIX.md)
- [Manuel administrateur](./ADMIN_MANUAL.md)
- [Migration du rôle Commercial](./COMMERCIAL_ROLE_MIGRATION_REPORT.md)
