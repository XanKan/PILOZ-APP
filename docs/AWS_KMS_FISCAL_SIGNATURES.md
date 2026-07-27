# Signature des archives fiscales avec AWS KMS

## À quoi cela sert

AWS KMS conserve la clé privée hors de Piloz. L'Edge Function envoie l'empreinte SHA-256 de l'archive, AWS la signe, Piloz vérifie la signature puis enregistre uniquement la signature, l'algorithme et l'identifiant de clé. Une modification ultérieure de l'archive rend la vérification invalide.

Ce mécanisme fournit une preuve technique d'intégrité et une piste d'audit. Il ne remplace pas une certification, une analyse juridique, une politique de conservation de 10 ans ni la facturation électronique via une plateforme agréée.

## Coût AWS indicatif

La page tarifaire AWS KMS fait foi. Au 27 juillet 2026, une clé gérée par le client coûte 1 USD par mois, au prorata horaire. Les opérations asymétriques de signature ne sont pas comprises dans le quota gratuit ; l'exemple AWS facture 0,15 USD pour 10 000 signatures. Une seule clé Piloz suffit pour démarrer, avec séparation possible par environnement plus tard.

## 1. Créer la clé

Dans AWS, choisir la région Paris `eu-west-3`, puis KMS > Clés gérées par le client > Créer une clé :

- type : asymétrique ;
- utilisation : `Sign and verify` / `SIGN_VERIFY` ;
- spécification : `RSA_3072` ;
- alias conseillé : `alias/piloz-fiscal-production` ;
- rotation : documenter la procédure avant de remplacer la clé, car les anciennes archives doivent rester vérifiables avec l'ancienne clé publique.

## 2. Créer une identité IAM dédiée

Ne pas utiliser un compte administrateur AWS. Accorder uniquement les actions suivantes sur l'ARN exact de la clé :

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["kms:DescribeKey", "kms:Sign", "kms:Verify", "kms:GetPublicKey"],
    "Resource": "ARN_EXACT_DE_LA_CLE"
  }]
}
```

Créer une clé d'accès pour cette identité, la conserver dans un gestionnaire de secrets et prévoir sa rotation. Ne jamais l'ajouter au dépôt, au frontend ou à un fichier `.env` commité.

## 3. Configurer les secrets Supabase

Depuis une session PowerShell locale, saisir les valeurs de manière masquée :

```powershell
$kmsKeyId = Read-Host "ARN de la clé KMS"
$kmsAccess = Read-Host "Access key IAM" -AsSecureString
$kmsSecret = Read-Host "Secret key IAM" -AsSecureString
$kmsAccessPlain = [System.Net.NetworkCredential]::new("", $kmsAccess).Password
$kmsSecretPlain = [System.Net.NetworkCredential]::new("", $kmsSecret).Password

npx.cmd --yes supabase@2.109.1 secrets set --project-ref hpxcbemezvynofxiffzs `
  FISCAL_KMS_PROVIDER=aws-kms `
  FISCAL_KMS_AWS_REGION=eu-west-3 `
  FISCAL_KMS_KEY_ID="$kmsKeyId" `
  FISCAL_KMS_SIGNING_ALGORITHM=RSASSA_PSS_SHA_256 `
  FISCAL_KMS_AWS_ACCESS_KEY_ID="$kmsAccessPlain" `
  FISCAL_KMS_AWS_SECRET_ACCESS_KEY="$kmsSecretPlain"

Remove-Variable kmsAccess,kmsSecret,kmsAccessPlain,kmsSecretPlain,kmsKeyId
```

Supabase rend les secrets disponibles aux Edge Functions sans nouveau déploiement. Vérifier seulement les noms, jamais les valeurs :

```powershell
npx.cmd --yes supabase@2.109.1 secrets list --project-ref hpxcbemezvynofxiffzs
```

## 4. Déployer la base et l'Edge Function

Appliquer d'abord la migration `202607270095_fiscal_archive_kms_signatures.sql`, puis déployer `export-fiscal-archive` :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\deploy-supabase-production.ps1 `
  -Apply `
  -BackupConfirmed

npx.cmd --yes supabase@2.109.1 functions deploy export-fiscal-archive `
  --project-ref hpxcbemezvynofxiffzs
```

## 5. Valider

Au premier export d'une archive non signée, l'Edge Function :

1. recalcule l'intégrité SQL de l'archive ;
2. demande la signature KMS ;
3. vérifie cette signature auprès d'AWS ;
4. l'inscrit de façon immuable ;
5. journalise l'événement et l'export avec le statut `valid`.

Contrôler ensuite qu'une ligne existe dans `fiscal_archive_signatures`, que `company_fiscal_configurations.signing_status` vaut `configured` et que l'export JSON contient `signature.status=valid`. En cas de KMS configuré mais inaccessible ou de signature invalide, l'export est bloqué.

## Limites restantes

- les anciennes archives ne sont signées qu'à leur prochain export ;
- les clôtures fiscales ne sont pas encore signées par ce connecteur ;
- `kms_configured` doit rester `false` dans le manifeste tant que la validation réelle n'a pas été réalisée ;
- conserver les anciennes clés publiques et les métadonnées de rotation est indispensable pour vérifier les archives historiques.
