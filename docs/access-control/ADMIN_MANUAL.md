# Manuel administrateur — Équipe et accès

## Ouvrir l’espace

Dans Piloz, ouvrez **Paramètres**, puis **Équipe et accès**. La carte de paramètres affiche le nombre d’utilisateurs actifs, d’invitations en attente, de rôles personnalisés et les éventuelles anomalies.

L’écran comporte quatre onglets : **Utilisateurs**, **Rôles**, **Invitations** et **Journal des accès**.

## Inviter un utilisateur

1. Cliquez sur **Ajouter un utilisateur**.
2. Saisissez le prénom, le nom et l’adresse e-mail.
3. Passez à l’étape suivante et choisissez un rôle.
4. Choisissez éventuellement une équipe.
5. Confirmez l’invitation.

Piloz vérifie le nombre de licences, les doublons et l’existence éventuelle du compte Supabase Auth. Un compte existant peut rejoindre une seconde entreprise sans qu’un deuxième compte Auth soit créé.

L’invité doit accepter explicitement l’accès avec l’adresse e-mail invitée. Tant que cette acceptation n’a pas eu lieu, le membre reste inactif et ne reçoit aucun droit métier.

## Gérer les utilisateurs

La liste permet de rechercher par nom ou e-mail, de filtrer par rôle ou statut, de trier les colonnes et de paginer côté serveur.

Selon vos permissions, vous pouvez :

- changer le rôle ;
- suspendre ou réactiver l’accès ;
- révoquer toutes les sessions ;
- retirer l’utilisateur de l’entreprise.

Piloz bloque la suspension, le retrait ou la rétrogradation du dernier administrateur actif.

## Gérer les rôles

Les quatre rôles Piloz sont verrouillés. Le message suivant est affiché :

> Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.

Pour créer un rôle adapté :

1. cliquez sur **Créer un rôle** ;
2. choisissez **Rôle vide** ou un rôle existant à copier ;
3. nommez le rôle ;
4. activez les permissions utiles ;
5. sélectionnez la portée lorsque plusieurs choix sont disponibles ;
6. enregistrez.

Vous pouvez ensuite dupliquer, modifier ou archiver le rôle personnalisé. Un rôle utilisé par des membres doit d’abord être remplacé avant son archivage.

## Suivre les invitations

L’onglet Invitations indique le destinataire, le rôle prévu, le statut, le résultat de l’envoi et l’expiration. Le rôle peut être ajusté avant l’acceptation. Il est également possible de renvoyer ou d’annuler l’invitation.

## Consulter l’historique

Le Journal des accès conserve les changements de rôle, suspensions, réactivations, retraits, invitations, renvois et révocations. Il est en lecture seule et protégé contre la modification et la suppression.

## Bonnes pratiques

- conservez au moins deux administrateurs actifs ;
- attribuez le rôle le plus restrictif compatible avec le travail réel ;
- utilisez un rôle personnalisé plutôt que de chercher à modifier un rôle Piloz ;
- suspendez immédiatement un accès en cas de départ ou de doute ;
- consultez régulièrement le Journal des accès.
