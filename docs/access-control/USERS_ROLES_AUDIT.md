# Audit utilisateurs, rôles et autorisations

Date de l’audit : 26 juillet 2026
Dépôt : `PILOZ-APP`
Application : `https://app.piloz.fr`

## Résumé

L’application possède déjà une isolation multi-entreprise par `company_id`, une table `company_members`, des politiques RLS et plusieurs protections SQL sur les opérations sensibles. En revanche, la gestion des accès n’a pas encore une source de vérité unique : le rôle est un texte historique dans `company_members.role`, certaines exceptions sont enregistrées dans `company_members.permissions`, la fonction `has_company_permission` contient des listes codées en dur et plusieurs écrans ou Edge Functions testent directement `owner`/`admin`.

La migration retenue est additive. Elle conserve les données et les rôles historiques, ajoute un catalogue central, quatre rôles système par entreprise et un moteur commun de résolution. Le champ historique reste temporairement alimenté pour assurer la compatibilité avec le code existant pendant la transition.

## Architecture actuelle

### Authentification et profils

- Supabase Auth est la source des identités et des sessions.
- `auth.users.raw_user_meta_data` contient éventuellement le prénom et le nom.
- `user_preferences` contient également `first_name`, `last_name` et `display_name` sur les installations récentes.
- Un utilisateur peut appartenir à plusieurs entreprises grâce à la clé composée `(company_id, user_id)` de `company_members`.

### Entreprises et membres

- `companies.owner_user_id` désigne le propriétaire historique.
- `company_members.role` accepte actuellement `owner`, `admin`, `billing`, `sales`, `accounting`, `read_only`, `auditor` et `member`.
- `company_members.permissions` est un objet JSON contenant des exceptions directes.
- `company_members.platform_status` distingue un membre actif d’un membre suspendu.
- La protection actuelle interdit la suppression ou le changement direct du rôle `owner`, mais elle ne modélise pas encore le dernier administrateur du futur système de rôles.

### Invitations

- Il n’existe pas de registre d’invitations propre aux entreprises clientes.
- L’Edge Function `platform-admin-api` peut inviter un utilisateur depuis le back-office Piloz, mais ce parcours n’est pas celui de `Paramètres > Équipe et accès`.
- Les expirations, renvois, révocations, rôles prévus et erreurs d’envoi ne sont donc pas centralisés pour une équipe cliente.

### Permissions

- `has_company_permission(company_id, permission)` est la principale protection serveur existante.
- La fonction traduit les anciens rôles en listes de chaînes codées en dur et applique ensuite les exceptions JSON du membre.
- `set_company_member_access` permet à un ancien `owner/admin` de changer un rôle historique et le JSON de permissions.
- Les transitions sensibles des documents et les insertions de règlements utilisent déjà `has_company_permission`.
- Les fonctions comptables récentes utilisent aussi ce helper, ce qui constitue une base saine à conserver.

### Interface et navigation

- La page actuelle `settings/users` est un tableau minimal : identifiant utilisateur, rôle historique et trois cases (`view_purchase_prices`, `view_margins`, `adjust_stock`).
- `PilozApp.allowed()` autorise directement `owner/admin` ou lit une clé du JSON du membre.
- Certaines extensions, pages de conformité, actions de catalogue et vues de documents testent encore le nom du rôle.
- La navigation n’est donc pas entièrement calculée depuis des permissions centrales.

## Contrôles réellement appliqués côté serveur

- RLS multi-entreprise sur les principales tables métier.
- `guard_sensitive_document_transition` pour la finalisation des devis, factures et avoirs.
- `guard_payment_ledger_insert` pour la création des règlements.
- Permissions explicites sur les RPC de comptabilité, d’exports et de conformité.
- Journalisation fiscale des changements de rôle et de permissions historiques.
- Protection du propriétaire historique.

## Contrôles seulement visuels ou incomplets

- Affichage de plusieurs menus et boutons selon `owner/admin` côté JavaScript.
- Accès aux prix d’achat et aux marges encore partiellement filtré dans le navigateur.
- Accès aux connexions partagées testé directement dans des Edge Functions.
- Page utilisateurs sans invitations d’entreprise, rôles personnalisés, portées ni pagination serveur.
- Absence de moteur central pour `own`, `team` et `company`.

## Risques détectés

1. Une permission ajoutée dans un écran peut ne pas être appliquée dans une RPC ou une politique RLS.
2. Les listes codées en dur peuvent diverger entre CRM, ventes, comptabilité et extensions.
3. Un changement de permission JSON peut conserver une ancienne décision dans l’interface jusqu’au rechargement.
4. Les rôles historiques ne permettent pas de distinguer un rôle système verrouillé d’un rôle personnalisé.
5. Le statut d’une invitation et son expiration ne sont pas auditables dans l’application cliente.
6. Les portées d’accès ne sont pas uniformes sur les clients, opportunités, activités et documents.
7. Une Edge Function testant seulement `owner/admin` ignore les futurs rôles et permissions.
8. Une policy RLS permissive de simple appartenance peut exposer plus de lignes que la portée commerciale attendue.

## Source de vérité cible

La nouvelle source unique sera composée de :

- `permission_definitions` : catalogue global et stable des permissions ;
- `company_roles` : quatre rôles système et les rôles personnalisés de chaque entreprise ;
- `company_role_permissions` : permission et portée d’un rôle ;
- `company_members.role_id` : rôle unique du membre dans une entreprise ;
- `company_teams` et `company_team_members` : résolution de la portée équipe ;
- `company_invitations` : invitations, expiration et état ;
- `company_access_audit` : journal append-only ;
- `resolve_company_permissions` : résolution centrale ;
- `has_company_permission` et `has_company_permission_scope` : contrôles communs côté SQL.

Il n’y aura pas de moteur concurrent propre au CRM, aux ventes ou au pipeline.

## Rôles système cibles

Le complément obligatoire porte le nombre final à quatre rôles système :

1. Administrateur
2. Utilisateur
3. Commercial
4. Expert-comptable

Ils sont créés automatiquement, consultables et assignables, mais non renommables, non modifiables et non supprimables. Une adaptation se fait exclusivement par duplication vers un rôle personnalisé.

## Correspondance des anciens rôles

| Ancien rôle | Nouveau rôle par défaut | Remarque |
| --- | --- | --- |
| `owner` | Administrateur | `companies.owner_user_id` est conservé |
| `admin` | Administrateur | Protection du dernier administrateur actif |
| `member` | Utilisateur | Accès opérationnel courant |
| `read_only` | Utilisateur | Exceptions historiques conservées pendant la migration |
| `sales` | Commercial | Si les droits diffèrent, création de `Commercial historique` |
| `billing` | Expert-comptable | Exceptions directes conservées |
| `accounting` | Expert-comptable | Correspondance fonctionnelle principale |
| `auditor` | Expert-comptable | Accès de contrôle conservé par permissions |

## Stratégie de migration

1. Créer les nouvelles tables, index, RLS et fonctions sans supprimer les colonnes historiques.
2. Insérer une seule définition de chaque permission.
3. Créer les quatre rôles système pour toutes les entreprises existantes et futures.
4. Affecter chaque membre existant à un rôle cible.
5. Créer `Commercial historique` lorsqu’un membre `sales` possède des exceptions directes différentes du rôle Commercial.
6. Résoudre les droits depuis `role_id`, avec compatibilité temporaire pour les exceptions JSON historiques.
7. Faire appeler le même moteur par le menu, l’interface, les RPC, les triggers et les Edge Functions.
8. Déprécier `set_company_member_access` au profit des nouvelles RPC sans le supprimer immédiatement.
9. Ajouter des politiques restrictives et des triggers de contrôle sur les ressources à portée.
10. Tester l’isolation entreprise A/B, le dernier administrateur, les quatre rôles système et les appels directs réseau.

## Incohérences et données à surveiller

- Membres sans `role_id` après migration : doivent être ramenés à Utilisateur et signalés.
- Membres possédant des permissions JSON directes : conservés et recensés dans le rapport de migration.
- Rôles `sales` avec exceptions : migrés vers un rôle personnalisé distinct.
- Identités Auth sans prénom/nom : affichage de l’e-mail sans inventer d’identité, puis complétion lors de l’invitation.
- Abonnement dépassant la limite d’utilisateurs : aucune suppression ; nouvelle invitation bloquée avec message explicite.

## Actions manuelles éventuelles

- Déployer la nouvelle Edge Function d’invitation.
- Vérifier la configuration SMTP de Supabase Auth. Si elle est absente, l’interface doit signaler honnêtement que l’envoi n’a pas eu lieu.
- Contrôler les URL de redirection Auth de `https://app.piloz.fr`.
- Examiner les éventuels rôles `Commercial historique` après migration, sans modifier silencieusement leurs droits.

## Critères de sortie de migration

- Les quatre rôles système existent dans chaque entreprise.
- Aucun rôle système ne peut être modifié ou supprimé.
- Le dernier administrateur actif est protégé.
- Le commercial ne peut pas finaliser une facture ni saisir/annuler un règlement.
- L’expert-comptable voit les factures en lecture seule et les fonctions comptables prévues.
- Les invitations, rôles, suspensions et changements sont journalisés.
- Les données d’une autre entreprise sont absentes des réponses réseau.
- Le menu et les opérations serveur reposent sur les mêmes clés de permission.
