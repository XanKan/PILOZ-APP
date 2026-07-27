# Connexion SUPER PDP en bac à sable

Cette première intégration valide le raccordement technique de Piloz avec une application SUPER PDP **confidentielle** utilisant le flux OAuth `client_credentials`.

## Périmètre

- environnement SUPER PDP : bac à sable uniquement ;
- entreprise de test : entreprise synthétique choisie lors de la création de l'application ;
- format testé : Factur-X ;
- aucune facture d'un client Piloz n'est transmise par ce test ;
- aucune émission de production n'est activée ;
- le `client_secret` reste exclusivement dans les secrets Supabase Edge Functions.

Le raccordement multi-entreprises de production utilisera ultérieurement le flux OAuth `authorization_code`, avec le consentement individuel de chaque entreprise cliente.

## 1. Renouveler tout secret exposé

Un secret affiché dans une capture, un ticket ou une conversation doit être renouvelé dans SUPER PDP avant toute configuration. Ne jamais l'ajouter dans Git, un fichier `.env` versionné ou du JavaScript navigateur.

## 2. Configurer les secrets Supabase

Dans PowerShell, saisir les valeurs dans les invites. Ne pas écrire les secrets directement dans la commande :

```powershell
cd C:\Users\Quentin\Documents\PILOZ\PILOZ-APP

$superPdpClientId = Read-Host "Identifiant SUPER PDP"
$superPdpSecretSecure = Read-Host "Nouveau secret SUPER PDP" -AsSecureString
$superPdpSecret = [System.Net.NetworkCredential]::new("", $superPdpSecretSecure).Password

npx.cmd --yes supabase@2.109.1 secrets set `
  "SUPERPDP_CLIENT_ID=$superPdpClientId" `
  "SUPERPDP_CLIENT_SECRET=$superPdpSecret" `
  "SUPERPDP_ENVIRONMENT=sandbox" `
  --project-ref hpxcbemezvynofxiffzs

Remove-Variable superPdpClientId,superPdpSecret,superPdpSecretSecure -ErrorAction SilentlyContinue
```

## 3. Appliquer la migration et déployer la fonction

La migration `202607270097_superpdp_sandbox_connector.sql` est additive. Elle ne contient aucun secret.

```powershell
npx.cmd --yes supabase@2.109.1 functions deploy platform-connector `
  --project-ref hpxcbemezvynofxiffzs
```

Appliquer ensuite les migrations avec la procédure de production habituelle, après sauvegarde confirmée.

## 4. Tester dans Piloz

1. Ouvrir **Paramètres > Facturation électronique**.
2. Cliquer sur **Tester la connexion**.
3. Contrôler le nom et l'identifiant de l'entreprise synthétique retournée par SUPER PDP.
4. Cliquer sur **Envoyer une facture de test**.
5. Lire l'avertissement puis confirmer.
6. Vérifier dans SUPER PDP que la facture synthétique Factur-X apparaît dans le bac à sable.

Le journal Piloz conserve la référence externe et le résultat du test, sans stocker le document synthétique ni les identifiants OAuth.
