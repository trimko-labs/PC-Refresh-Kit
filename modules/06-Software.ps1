# modules/06-Software.ps1 - Installation du pack de logiciels de base via winget
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\06-Software.ps1 [-WhatIf]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 06-Software : début ===" -Level 'INFO'

# ---------------------------------------------------------------------------
# Vérifier winget
# ---------------------------------------------------------------------------
if (-not (Test-WingetAvailable)) {
    Write-KitLog -Message "winget non disponible. Installation de logiciels impossible." -Level 'WARN'
    Write-KitLog -Message (Get-WingetAbsentAdvice -IsWin11 (Get-MachineInfo).IsWin11) -Level 'WARN'
    exit 0
}

if (-not (Test-InternetConnection)) {
    Write-KitLog -Message "Pas de connexion Internet. Installation des logiciels impossible (winget a besoin du réseau)." -Level 'WARN'
    Write-KitLog -Message "Relancer le module 06 une fois le PC connecté." -Level 'WARN'
    Write-KitLog -Message "=== 06-Software : terminé (hors-ligne) ===" -Level 'WARN'
    exit 0
}

# ---------------------------------------------------------------------------
# Charger la liste des apps
# ---------------------------------------------------------------------------
$appsJsonPath = Join-Path $PSScriptRoot '..\config\apps.json'
if (-not (Test-Path $appsJsonPath)) {
    Write-KitLog -Message "config/apps.json introuvable ($appsJsonPath)." -Level 'ERROR'
    exit 1
}

$apps = Get-Content $appsJsonPath -Encoding UTF8 | ConvertFrom-Json
$required = $apps | Where-Object { $_.optional -eq $false }
$optional  = $apps | Where-Object { $_.optional -eq $true }

Write-KitLog -Message "$($required.Count) app(s) obligatoires, $($optional.Count) optionnelle(s)." -Level 'INFO'

# ---------------------------------------------------------------------------
# Fonction : vérifier si une app est déjà installée via winget
# ---------------------------------------------------------------------------
function Test-AppInstalled {
    param([string]$WingetId)
    $check = & winget list --id $WingetId --exact --accept-source-agreements 2>&1
    return ($LASTEXITCODE -eq 0) -and ($check | Where-Object { $_ -match [regex]::Escape($WingetId) })
}

# ---------------------------------------------------------------------------
# Installation des apps
# ---------------------------------------------------------------------------
function Install-App {
    param([PSCustomObject]$App)

    Write-KitLog -Message "Vérification : $($App.name) ($($App.wingetId))..." -Level 'INFO'

    if (Test-AppInstalled -WingetId $App.wingetId) {
        Write-KitLog -Message "SKIP (déjà installé) : $($App.name)" -Level 'OK'
        return
    }

    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: winget install --id $($App.wingetId) -e --silent" -Level 'WHATIF'
        return
    }

    Write-KitLog -Message "Installation : $($App.name)..." -Level 'INFO'
    $result = & winget install --id $App.wingetId -e --silent `
        --accept-source-agreements --accept-package-agreements 2>&1
    $rc = $LASTEXITCODE

    if ($rc -eq 0) {
        Write-KitLog -Message "Installé : $($App.name)" -Level 'OK'
    }
    else {
        # winget renvoie parfois -1978335189 (0x8A150031) si déjà installé via un autre gestionnaire
        # ou -1978335221 (no applicable update) - traiter comme SKIP
        if ($rc -in -1978335189, -1978335221) {
            Write-KitLog -Message "SKIP (déjà présent via autre source) : $($App.name)" -Level 'OK'
        }
        else {
            Write-KitLog -Message "ERREUR installation $($App.name) (code winget : $rc)" -Level 'ERROR'
            $result | ForEach-Object { Write-KitLog -Message "  $_" -Level 'WARN' }
        }
    }
}

# Apps obligatoires
Write-KitLog -Message "--- Apps obligatoires ---" -Level 'INFO'
foreach ($app in $required) { Install-App $app }

# Apps optionnelles : proposer sauf en -All (trop lent pour les ignorer)
Write-KitLog -Message "--- Apps optionnelles ---" -Level 'INFO'
foreach ($app in $optional) {
    if ($Unattended) {
        Write-KitLog -Message "SKIP (optionnel, mode non-interactif) : $($app.name)" -Level 'INFO'
        continue
    }
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF (optionnel): $($app.name) ($($app.wingetId))" -Level 'WHATIF'
        continue
    }

    Write-Host ""
    Write-Host "[OPTIONNEL] $($app.name) ($($app.wingetId))" -ForegroundColor Cyan
    $answer = Read-Host "Installer ? (O/N)"
    if ($answer -match '^[Oo]') {
        Install-App $app
    }
    else {
        Write-KitLog -Message "SKIP (optionnel refusé) : $($app.name)" -Level 'INFO'
    }
}

Write-KitLog -Message "=== 06-Software : terminé ===" -Level 'OK'
exit 0
