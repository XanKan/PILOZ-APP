# Activation de SUPER PDP en production

Piloz utilise le flux OAuth 2.0 `authorization_code` recommandé par SUPER PDP pour les ERP. Chaque entreprise cliente autorise séparément Piloz, termine sa vérification dans SUPER PDP et peut demander son inscription dans l’annuaire de réception. Les jetons sont chiffrés côté serveur et ne sont jamais renvoyés au navigateur.

## 1. Application SUPER PDP

Dans SUPER PDP, créer une application :

- type : **Confidentielle** ;
- environnement : **Production** ;
- format préféré : **Factur-X** ;
- URL de redirection : `https://hpxcbemezvynofxiffzs.supabase.co/functions/v1/superpdp-oauth/callback`.

Si un `client_secret` a été affiché dans une capture, un chat, un terminal enregistré ou un document partagé, le renouveler avant l’ouverture commerciale.

## 2. Secrets Supabase

Dans `Supabase > Edge Functions > Secrets`, enregistrer :

- `SUPERPDP_PRODUCTION_CLIENT_ID` : identifiant de l’application confidentielle ;
- `SUPERPDP_PRODUCTION_CLIENT_SECRET` : secret renouvelé de l’application ;
- `SUPERPDP_TOKEN_ENCRYPTION_KEY` : secret aléatoire d’au moins 32 caractères, distinct des autres clés ;
- `SUPERPDP_WORKER_SECRET` : autre secret aléatoire d’au moins 32 caractères ;
- `PILOZ_APP_URL` : `https://app.piloz.fr`.

Génération locale possible, sans enregistrer la valeur dans un fichier :

```powershell
[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
```

## 3. Déployer

Appliquer toutes les migrations jusqu’à `202607280101_superpdp_production_oauth.sql`, puis déployer :

```powershell
npx.cmd --yes supabase@2.109.1 functions deploy superpdp-oauth --project-ref hpxcbemezvynofxiffzs
npx.cmd --yes supabase@2.109.1 functions deploy platform-connector --project-ref hpxcbemezvynofxiffzs
```

Exécuter ensuite `scripts/post-deploy-production-checks.sql`. Le résultat attendu est `"ok": true` et `"schema_version": "202607280101"`.

## 4. Worker automatique

Dans le dépôt GitHub `PILOZ-APP`, créer le secret Actions `SUPERPDP_WORKER_SECRET` avec exactement la même valeur que dans Supabase. Le workflow `Synchronisation SUPER PDP` traite alors toutes les cinq minutes :

- les factures clients finalisées mises en file ;
- les nouvelles factures fournisseurs ;
- les reprises sur erreur avec délai exponentiel ;
- les journaux techniques, sans contenu confidentiel dans GitHub.

Le bouton de transmission manuelle reste utile pour un diagnostic, mais le fonctionnement normal est automatique.

## 5. Activation par entreprise cliente

Dans Piloz :

1. compléter le SIREN et les informations légales de l’entreprise ;
2. ouvrir `Paramètres > Extensions > Facturation électronique` ;
3. cliquer sur `Activer SUPER PDP` ;
4. se connecter à SUPER PDP et autoriser Piloz ;
5. terminer les contrôles d’identité ou d’autorité demandés par SUPER PDP ;
6. actualiser le statut dans Piloz ;
7. cliquer sur `Activer la réception` pour demander l’inscription dans l’annuaire PPF.

La production n’est activée que lorsque SUPER PDP renvoie l’entreprise comme `verified`. Si l’identité du représentant est requise, elle doit également être `verified`.

## 6. Recette obligatoire

Avant ouverture générale, tester avec deux entreprises autorisées :

- facture client simple, multi-TVA, acompte, situation, solde et avoir ;
- réception d’une facture fournisseur ;
- approbation, litige motivé et refus motivé ;
- doublon et reprise après indisponibilité ;
- révocation OAuth puis reconnexion ;
- isolement entre deux sociétés Piloz ;
- concordance PDF, CII/Factur-X, montants et événements.

Piloz ne doit jamais être présenté comme une Plateforme Agréée : SUPER PDP assure ce rôle. Piloz est le logiciel de gestion raccordé à la PA.
