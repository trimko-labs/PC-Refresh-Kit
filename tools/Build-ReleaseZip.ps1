# Produit un zip propre du kit pour distribution (exclut le dev).
[CmdletBinding()]
param(
    [string]$Version = "2.4.1",
    [string]$OutDir  = ""
)
$ErrorActionPreference = "Stop"
# $PSScriptRoot indisponible dans le bloc param sous PS 5.1 - calcul ici.
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "..\dist" }
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$staging = Join-Path $env:TEMP "prk-stage-$Version"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# vendor/ est indispensable : le module 04-Privacy echoue si vendor\TelemetryGuard est absent.
# docs/ accompagne l'operateur sur le terrain (procedure + notes de version).
# secours.bat vit à la racine du zip : sur un PC qui ne démarre plus, l'opérateur
# le lance depuis WinRE en tapant la lettre de la clé suivie de \secours.bat.
$include = @(
    "modules","lib","config","tools","templates","vendor","docs",
    "Run.ps1","Run-GUI.ps1","secours.bat","README.md","LICENSE"
) + (Get-ChildItem $root -Filter "Lancer*.bat").Name

foreach ($item in $include) {
    $src = Join-Path $root $item
    if (Test-Path $src) { Copy-Item $src -Destination $staging -Recurse -Force }
    else { Write-Warning "absent, ignore : $item" }
}

# runtime/ : creer la structure vide uniquement (ne pas copier les donnees de run).
# Le dossier est exclu de git et contient des artefacts locaux (logs, FICHE-PC, rapports, undo).
foreach ($sub in @("runtime","runtime\logs","runtime\undo","runtime\smoke")) {
    New-Item -ItemType Directory -Path (Join-Path $staging $sub) -Force | Out-Null
}
# Purge defensive de tout residu dev dans le staging
Get-ChildItem $staging -Recurse -Include "*.Tests.ps1","test-results.xml" -Force |
    Remove-Item -Force -ErrorAction SilentlyContinue
# docs/plans et docs/superpowers = notes de conception internes, hors distribution.
# tools/regf = atelier expert de réparation de ruche, interne lui aussi : son
# README annonce déjà « absent du zip de release », cette purge le rend vrai.
foreach ($internal in @("docs\plans", "docs\superpowers", "tools\regf")) {
    $dir = Join-Path $staging $internal
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
}

# Contrôle du staging avant compression. Une promesse de distribution qui n'est
# jamais vérifiée finit par mentir : ici elle casse la construction du zip.
$attendus  = @("secours.bat", "Run.ps1", "Run-GUI.ps1", "vendor")
$interdits = @("docs\plans", "docs\superpowers", "tools\regf")
$manquants = @($attendus  | Where-Object { -not (Test-Path (Join-Path $staging $_)) })
$restants  = @($interdits | Where-Object {      Test-Path (Join-Path $staging $_)  })
if ($manquants.Count -gt 0) { throw "Zip incomplet, éléments absents du staging : $($manquants -join ', ')" }
if ($restants.Count  -gt 0) { throw "Contenu interne encore présent dans le staging : $($restants -join ', ')" }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zip = Join-Path $OutDir "PC-Refresh-Kit-v$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -Force
Write-Host "OK : $zip"
