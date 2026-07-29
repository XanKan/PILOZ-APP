# Activer Cloudflare Workers AI pour Pilo

Pilo utilise Cloudflare Workers AI uniquement depuis la fonction serveur Supabase `pilo`. Le jeton Cloudflare ne doit jamais être ajouté au navigateur, à `index.html`, au dépôt Git ou à une variable `VITE_*`.

## Variables serveur attendues

- `CLOUDFLARE_ACCOUNT_ID` : identifiant du compte Cloudflare.
- `CLOUDFLARE_API_TOKEN` : jeton API limité à Workers AI Read/Edit.
- `CLOUDFLARE_AI_MODEL` : facultatif. Valeur par défaut : `@cf/zai-org/glm-4.7-flash`.

## Activation

Depuis PowerShell, à la racine de `PILOZ-APP` :

```powershell
$accountId = Read-Host "Identifiant du compte Cloudflare"
$token = Read-Host "Jeton Cloudflare Workers AI" -AsSecureString
$plainToken = [System.Net.NetworkCredential]::new("", $token).Password

npx.cmd --yes supabase@2.109.1 secrets set `
  CLOUDFLARE_ACCOUNT_ID="$accountId" `
  CLOUDFLARE_API_TOKEN="$plainToken" `
  CLOUDFLARE_AI_MODEL="@cf/zai-org/glm-4.7-flash" `
  --project-ref hpxcbemezvynofxiffzs

npx.cmd --yes supabase@2.109.1 functions deploy pilo `
  --project-ref hpxcbemezvynofxiffzs
```

Fermez ensuite la variable locale contenant le jeton :

```powershell
$plainToken = $null
$token = $null
```

## Comportement de repli

Si les deux secrets Cloudflare sont absents ou si Cloudflare est momentanément indisponible, Pilo répond à partir des guides officiels Piloz. Une indisponibilité du fournisseur ne crée jamais de faux ticket et ne simule jamais une action réussie.

## Contrôle

Posez à Pilo une question métier précise, par exemple : « Comment créer et finaliser une facture ? ». La réponse doit être naturelle, indiquer le chemin dans Piloz et citer les guides officiels pertinents.
