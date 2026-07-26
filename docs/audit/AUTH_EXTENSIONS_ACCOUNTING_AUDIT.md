# Audit auth, extensions et comptabilité

Date de l'audit : 26 juillet 2026

Dépôt : `XanKan/PILOZ-APP`
Branche : `main`

## Périmètre et méthode

L'audit a été réalisé avant modification avec `git status`, `git remote -v`, `git pull --rebase origin main`, l'inventaire des migrations Supabase, des Edge Functions, des politiques RLS, des RPC, des écrans d'authentification, des modules de paramètres, des règlements et du cycle de vie documentaire.

Le dépôt est une application statique sans `package.json`. Les contrôles locaux reposent sur les scripts Node autonomes du dossier `tests/` et sur `scripts/verify-release.mjs`. Les migrations sont additives et la production ne doit être modifiée qu'avec le script de déploiement prévu.

## État existant confirmé

### Stripe et inscription

- `stripe-public-checkout` crée une session Stripe avec essai et moyen de paiement obligatoire.
- `stripe-webhook` vérifie la signature Stripe, traite les événements de manière idempotente et met à jour les abonnements.
- `stripe_checkout_claims` rattache un checkout à une adresse e-mail et à un abonnement.
- `stripe-billing` contrôle le rattachement après authentification.
- Point à corriger : le parcours historique transportait encore un jeton de revendication dans l'URL de retour. Ce jeton doit être remplacé par un droit d'onboarding serveur, à durée de vie courte, dérivé d'un webhook validé et jamais exposé dans le navigateur.
- Google et Microsoft SSO ne sont pas encore proposés dans l'écran de connexion.

### Paramètres et extensions

- Les paramètres sont partagés entre l'ancien rendu et `erp-modern.js`.
- Plusieurs fonctions existent déjà (entreprise, utilisateurs, abonnement, ventes, achats, catalogue, documents, modèles, sécurité, données), mais la navigation n'est pas structurée autour d'une rubrique Extensions.
- Aucun coffre de jetons OAuth n'est accessible au navigateur. Il faut conserver cette séparation et stocker les secrets externes uniquement côté serveur, chiffrés avec une clé gérée par l'environnement d'exécution.

### CGV et documents

- Une zone `terms_conditions` existe déjà dans les versions de modèles de documents, avec une limite de 30 000 caractères.
- Le snapshot documentaire protège les documents finalisés contre les modifications ultérieures du modèle.
- Il manque une bibliothèque versionnée de CGV, l'import PDF privé, l'assignation par client/type de document et le snapshot explicite de la version de CGV choisie.

### Règlements

- Les tables `payment_receipts` et `payment_allocations`, le RPC de règlement multi-factures et l'annulation append-only existent déjà.
- Les références bancaires sensibles sont filtrées par permission.
- Il manque une rubrique principale dédiée, une fiche complète de règlement et une vue d'audit/export cohérente.

### Pré-comptabilité et fiscalité

- Le dépôt contient déjà les événements fiscaux, les clôtures, les archives, la conservation, les contrôles d'intégrité et la préparation à la facturation électronique.
- Les profils comptables d'articles existent partiellement.
- Les clients ont déjà un mécanisme de compte auxiliaire.
- Il manque un moteur central d'écritures équilibrées, le paramétrage complet, les journaux, les exercices, les adaptateurs d'export et la TVA sur encaissements.
- Un export nommé FEC ne doit jamais être présenté comme juridiquement conforme sans validation sur données réelles et contrôle par un professionnel. L'export ajouté au produit sera étiqueté « technique — à valider ».

## Décisions d'architecture

1. Une seule source de vérité par domaine : documents, règlements et abonnements existants sont réutilisés.
2. Toutes les nouvelles tables métier portent `company_id` et sont protégées par RLS.
3. Les écritures validées, exports et annulations sont append-only.
4. Les RPC `SECURITY DEFINER` valident systématiquement l'appartenance, la permission et fixent le `search_path`.
5. Les jetons OAuth ne sont jamais retournés au frontend. Le frontend ne reçoit qu'un état de connexion et des métadonnées non sensibles.
6. Les synchronisations externes conservent curseur, identifiant externe, version, dernière erreur et état de reprise pour éviter les doublons.
7. Les adaptateurs propriétaires sont désactivés tant que leur format n'a pas été validé à partir d'une spécification officielle ou d'un fichier de référence réel.
8. Les PDF de CGV sont stockés dans un bucket privé ; les documents finalisés pointent vers une version figée.

## Configuration externe nécessaire

Les fonctions peuvent être livrées sans secret, mais les connexions ne pourront être activées qu'après configuration :

- Supabase Auth : fournisseurs Google et Azure/Microsoft, URL de redirection et domaines autorisés ;
- Google Cloud : client OAuth, Calendar API et Gmail API ;
- Microsoft Entra : application OAuth et permissions Microsoft Graph ;
- Supabase Edge Functions : secrets OAuth, clé de chiffrement des jetons et URL publique de l'application ;
- Stripe : webhook actif, secret de signature et clés serveur déjà prévues par le module de facturation.

## Références officielles utilisées

- [Supabase Auth avec Google](https://supabase.com/docs/guides/auth/social-login/auth-google)
- [Supabase Auth avec Microsoft/Azure](https://supabase.com/docs/guides/auth/social-login/auth-azure)
- [Supabase — liaison d'identités](https://supabase.com/docs/guides/auth/auth-identity-linking)
- [Google Calendar — synchronisation incrémentale](https://developers.google.com/workspace/calendar/api/guides/sync)
- [Google Calendar — scopes OAuth](https://developers.google.com/workspace/calendar/api/auth)
- [Microsoft Graph — delta sur les événements](https://learn.microsoft.com/en-us/graph/delta-query-events)
- [Microsoft Graph — notifications Outlook](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview)
- [Stripe — webhooks d'abonnements](https://docs.stripe.com/billing/subscriptions/webhooks)
- [DGFiP — fichiers des écritures comptables](https://www.impots.gouv.fr/fichiers-standards-des-ecritures-comptables)
- [BOFiP — fichier des écritures comptables](https://bofip.impots.gouv.fr/bofip/9028-PGP.html/identifiant%3DBOI-CF-IOR-60-40-20-20170607)
- [Service Public — conservation des documents](https://entreprendre.service-public.fr/vosdroits/F10029)
- [CNIL — sécurité de l'authentification](https://www.cnil.fr/fr/authentification-par-mot-de-passe-les-mesures-de-securite-elementaires)

## Risques suivis

- Activation prématurée d'un adaptateur propriétaire non vérifié.
- Réexport d'une écriture déjà incluse dans un export validé.
- Déséquilibre débit/crédit à cause d'un paramétrage incomplet.
- Double création lors d'un webhook ou d'une synchronisation rejouée.
- Fuite de jeton OAuth via une réponse, un log ou une URL.
- Confusion entre un export FEC technique et une conformité réglementaire certifiée.

Ces risques sont traités par des contraintes SQL, des clés d'idempotence, des statuts explicites, des permissions dédiées et des écrans de validation avant activation.
