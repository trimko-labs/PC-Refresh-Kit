# Produit un zip propre du kit pour distribution (exclut le dev).
[CmdletBinding()]
param(
    [string]$Version = "2.0.0",
    [string]$OutDir  = ""
)
$ErrorActionPreference = "Stop"
# $PSScriptRoot indisponible dans le bloc param sous PS 5.1 - calcul ici.
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "..\dist" }
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$staging = Join-Path $env:TEMP "prk-stage-$Version"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$include = @(
    "modules","lib","config","tools","templates",
    "Run.ps1","Run-GUI.ps1","README.md","LICENSE","TOOLTIPS.md"
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

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zip = Join-Path $OutDir "PC-Refresh-Kit-v$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -Force
Write-Host "OK : $zip"
