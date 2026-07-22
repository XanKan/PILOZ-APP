[CmdletBinding()]
param(
  [string]$ProjectRef = "hpxcbemezvynofxiffzs",
  [switch]$Apply,
  [switch]$BackupConfirmed
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$supabaseCli = "supabase@2.109.1"

function Invoke-Checked {
  param([Parameter(Mandatory=$true)][string]$Program,[Parameter(Mandatory=$true)][string[]]$Arguments)
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Échec de la commande $Program (code $LASTEXITCODE)." }
}

Push-Location $repoRoot
try {
  if ((Get-Content "CNAME" -Raw).Trim() -ne "app.piloz.fr") { throw "CNAME invalide." }
  $gitRoot = (Resolve-Path ((git rev-parse --show-toplevel).Trim())).Path
  if ($gitRoot -ne $repoRoot) { throw "Ce script doit être lancé depuis PILOZ-APP." }
  $origin = (git remote get-url origin).Trim()
  if ($origin -notmatch '(^|[:/])XanKan/PILOZ-APP(?:\.git)?$') { throw "Le remote origin n'est pas le dépôt PILOZ-APP attendu." }
  if ((git status --porcelain).Count -gt 0) { throw "Le dépôt contient des modifications non commitées." }
  if (-not $env:SUPABASE_ACCESS_TOKEN) { throw "Définissez SUPABASE_ACCESS_TOKEN dans cette session PowerShell." }
  if (-not $env:SUPABASE_DB_PASSWORD) { throw "Définissez SUPABASE_DB_PASSWORD dans cette session PowerShell." }
  if ($Apply -and -not $BackupConfirmed) { throw "Avec -Apply, ajoutez -BackupConfirmed après avoir vérifié une sauvegarde restaurable." }

  Invoke-Checked "node" @("scripts/verify-release.mjs")
  Invoke-Checked "git" @("pull","--rebase","origin","main")
  Invoke-Checked "npx.cmd" @("--yes",$supabaseCli,"--yes","link","--project-ref",$ProjectRef)
  Invoke-Checked "npx.cmd" @("--yes",$supabaseCli,"--yes","db","push","--linked","--include-all","--dry-run")

  if (-not $Apply) {
    Write-Output "Prévisualisation terminée. Aucune migration ni fonction n'a été déployée."
    Write-Output "Après vérification de la sauvegarde, relancez avec -Apply -BackupConfirmed."
    exit 0
  }

  Invoke-Checked "npx.cmd" @("--yes",$supabaseCli,"--yes","db","push","--linked","--include-all")
  Invoke-Checked "npx.cmd" @("--yes",$supabaseCli,"--yes","db","lint","--linked","--level","error","--fail-on","error")
  Invoke-Checked "npx.cmd" @("--yes",$supabaseCli,"--yes","functions","deploy","--project-ref",$ProjectRef)
  Invoke-Checked "npx.cmd" @("--yes",$supabaseCli,"--yes","migration","list","--linked")
  Write-Output "Déploiement Supabase terminé. Exécutez scripts/post-deploy-production-checks.sql dans le SQL Editor."
}
finally {
  Pop-Location
}
