# Connexion SUPER PDP en bac à sable

PILOZ et ses données métier restent en production. Seuls les appels à l’API SUPER PDP sont verrouillés sur le **bac à sable**, avec une application confidentielle et le flux OAuth `client_credentials`.

## Périmètre

- environnement SUPER PDP : bac à sable uniquement ;
- entreprise de test : entreprise synthétique choisie lors de la création de l'application ;
- formats produits : Factur-X (PDF hybride) et CII XML ;
- envoi des factures clients finalisées vers l’entreprise synthétique SUPER PDP ;
- réception des factures fournisseurs du bac à sable dans PILOZ ;
- consultation PDF/XML et synchronisation du statut dans PILOZ ;
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

Les migrations `202607270097_superpdp_sandbox_connector.sql` et `202607270098_superpdp_sandbox_invoice_exchange.sql` sont additives. Elles ne contiennent aucun secret. La seconde ajoute le registre des échanges et événements, les politiques RLS par entreprise et le stockage privé des artefacts PDF/XML.

```powershell
npx.cmd --yes supabase@2.109.1 functions deploy platform-connector `
  --project-ref hpxcbemezvynofxiffzs
```

Appliquer ensuite les migrations avec la procédure de production habituelle, après sauvegarde confirmée.

## 4. Tester la connexion dans PILOZ

1. Ouvrir **Paramètres > Facturation électronique**.
2. Cliquer sur **Tester la connexion**.
3. Contrôler le nom et l'identifiant de l'entreprise synthétique retournée par SUPER PDP.
4. Cliquer sur **Envoyer une facture de test**.
5. Lire l'avertissement puis confirmer.
6. Vérifier dans SUPER PDP que la facture synthétique Factur-X apparaît dans le bac à sable.

Le journal Piloz conserve la référence externe et le résultat du test, sans stocker le document synthétique ni les identifiants OAuth.

## 5. Tester une facture client réelle dans le bac à sable

1. Créer puis finaliser une facture avec un client et un PDF définitif disponible.
2. Ouvrir sa consultation.
3. Dans **Facturation électronique**, cliquer sur **Préparer et envoyer au bac à sable**.
4. Vérifier que l’onglet **XML** affiche le CII produit et que le PDF Factur-X reste consultable.
5. Cliquer sur **Actualiser le statut** puis contrôler la facture dans SUPER PDP.

L’action est idempotente : une même facture PILOZ n’est pas renvoyée une seconde fois. L’interface indique toujours **PILOZ en production / SUPER PDP bac à sable**.

## 6. Tester les factures fournisseurs

1. Déposer ou générer une facture entrante dans l’entreprise synthétique SUPER PDP.
2. Ouvrir **Achats > Factures fournisseurs** dans PILOZ.
3. Cliquer sur **Synchroniser les factures reçues**.
4. Contrôler le fournisseur, les lignes, les montants, le PDF et l’onglet XML.

Une facture déjà importée n’est pas recréée. Les documents entrants restent des brouillons d’achat afin de permettre leur contrôle avant traitement comptable.

## 7. Limite volontaire

Cette version ne constitue pas un raccordement de production à une plateforme agréée. `SUPERPDP_ENVIRONMENT` doit rester égal à `sandbox` et la base refuse toute valeur d’environnement différente pour ces échanges. Le passage en production nécessitera un mandat/consentement par entreprise, une activation séparée et une recette réglementaire dédiée.
