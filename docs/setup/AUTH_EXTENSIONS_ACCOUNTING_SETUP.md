# Activation Auth, Extensions et Comptabilité

Ce document décrit uniquement les actions manuelles qui ne peuvent pas être
commitées. Ne copiez jamais une valeur de secret dans Git, dans le navigateur ou
dans une capture d'écran.

## 1. Appliquer la base Supabase

Depuis une session PowerShell contenant un jeton CLI Supabase et le mot de passe
Postgres du projet :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\deploy-supabase-production.ps1 `
  -Apply `
  -BackupConfirmed
```

Les migrations `202607260070` à `202607260075` sont additives. Elles installent
le parcours Stripe vérifié, les connexions externes, les CGV versionnées, le
moteur de pré-comptabilité, les exports figés et l'observabilité des tâches.

## 2. Supabase Auth : Google et Microsoft

Dans **Authentication > Providers**, activer :

- Google avec le Client ID et le Client Secret créés dans Google Cloud ;
- Azure avec l'Application ID et le secret créés dans Microsoft Entra ID.

Ajouter aux URL de redirection autorisées :

- `https://app.piloz.fr/`
- l'URL de staging utilisée par l'équipe ;
- `http://localhost:4173/`
- `http://localhost:5173/`

Dans Google et Entra, reprendre exactement l'URL de callback affichée par
Supabase Auth. Les boutons de connexion classiques restent disponibles.

## 3. Extensions Google et Microsoft

Définir les secrets de l'Edge Function, sans les écrire dans un fichier local :

- `APP_URL=https://app.piloz.fr`
- `INTEGRATION_TOKEN_KEY` : secret aléatoire d'au moins 32 caractères ;
- `GOOGLE_OAUTH_CLIENT_ID`
- `GOOGLE_OAUTH_CLIENT_SECRET`
- `MICROSOFT_OAUTH_CLIENT_ID`
- `MICROSOFT_OAUTH_CLIENT_SECRET`
- `INTEGRATION_OAUTH_CALLBACK_URL`
- `INTEGRATION_WEBHOOK_URL`
- `INTEGRATION_SCHEDULER_SECRET` : secret aléatoire réservé au planificateur.

L'URL de callback des deux applications OAuth est :

`https://<project-ref>.supabase.co/functions/v1/external-integrations`

Scopes demandés, de façon incrémentale :

- Google Agenda : profil et `calendar.readonly`, `calendar.events` ;
- Gmail : profil et `gmail.send` ;
- Outlook Calendar : profil, `offline_access`, `Calendars.ReadWrite` ;
- Outlook Mail : profil, `offline_access`, `Mail.Send`.

Déployer :

```powershell
npx.cmd --yes supabase@2.109.1 functions deploy external-integrations --project-ref <project-ref> --no-verify-jwt
```

La route OAuth et les webhooks sont publics, mais les actions applicatives
valident elles-mêmes le JWT de l'utilisateur. Les notifications Google et
Microsoft sont contrôlées avec un jeton haché ; les refresh tokens et curseurs
sont chiffrés en AES-GCM.

Appeler périodiquement l'action `process_jobs` avec l'en-tête
`x-piloz-scheduler-secret`. Un passage toutes les cinq minutes est recommandé.
La file est idempotente, applique un backoff et place les échecs persistants en
`dead_letter`.

IMAP/SMTP reste volontairement affiché **À configurer**. Le runtime Edge actuel
ne constitue pas un connecteur TCP/TLS suffisamment éprouvé pour recevoir et
tester des mots de passe de messagerie. Aucun faux succès n'est renvoyé.

## 4. Stripe

Conserver les secrets déjà utilisés par les fonctions Stripe :

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- les identifiants de prix Stripe existants.

Le webhook doit écouter au minimum :

- `checkout.session.completed`
- `customer.subscription.created|updated|deleted|paused|resumed`
- `customer.subscription.trial_will_end`
- `invoice.finalized|paid|payment_succeeded|payment_failed`
- `customer.updated`
- `charge.refunded`

Une redirection `success_url` n'active rien. Le droit d'onboarding n'est créé
qu'après un événement Stripe signé, journalisé et traité de façon idempotente.

## 5. CGV et stockage

La migration crée le bucket privé `company-sales-terms`, limité aux PDF de
10 Mo. Vérifier que le bucket `company-files` existe toujours pour les PDF
définitifs et les paquets comptables.

Une facture finalisée conserve un snapshot immuable des CGV. Les devis et
aperçus utilisent l'assignation courante ; une régénération d'un document final
utilise toujours le snapshot historique.

## 6. Comptabilité et exports

Déployer le générateur de paquets :

```powershell
npx.cmd --yes supabase@2.109.1 functions deploy accounting-export-package --project-ref <project-ref>
```

Le ZIP contient le fichier d'écritures figé, les PDF définitifs disponibles et
un manifeste avec leurs empreintes SHA-256. Une pièce absente est signalée dans
le manifeste, jamais remplacée par un faux document.

Les formats génériques CSV et le **FEC technique** sont activés. Les adaptateurs
propriétaires restent `À configurer` tant qu'une spécification éditeur et un jeu
d'essai validé ne sont pas disponibles. Le FEC reste libellé « Revue comptable
requise » : Piloz ne revendique pas de certification fiscale ou comptable.

Avant une utilisation réelle, faire valider par l'expert-comptable :

- le plan de comptes et les journaux ;
- les règles de TVA et la TVA sur encaissements ;
- les comptes d'acompte, d'attente, de vente et d'achat ;
- le fichier FEC sur un exercice de test ;
- les formats d'import propres au logiciel comptable du client.

## 7. Contrôles de production

Après le déploiement :

1. exécuter `scripts/post-deploy-production-checks.sql` dans l'éditeur SQL ;
2. vérifier que la dernière migration est `202607260075` ;
3. tester une entreprise A et une entreprise B ;
4. vérifier qu'aucun token OAuth n'apparaît dans les réponses réseau ;
5. vérifier un paiement, sa correction append-only et les soldes ;
6. finaliser une facture avec CGV, générer son PDF puis un ZIP comptable ;
7. tester Google et Microsoft avec un compte de recette ;
8. confirmer que `CNAME` contient uniquement `app.piloz.fr`.
