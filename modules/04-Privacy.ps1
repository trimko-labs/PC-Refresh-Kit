# modules/04-Privacy.ps1 - Télémétrie Windows (TelemetryGuard) + guard permanent
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\04-Privacy.ps1 [-WhatIf] [-DisableSmartScreen]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$DisableSmartScreen,
    [switch]$BlockTelemetryIPs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 04-Privacy : début ===" -Level 'INFO'
Write-KitLog -Message "SmartScreen : $(if ($DisableSmartScreen) {'sera désactivé'} else {'gardé actif (défaut)'})" -Level 'INFO'
Write-KitLog -Message "IPs télémétrie bloquées par firewall : $($BlockTelemetryIPs.IsPresent)" -Level 'INFO'

$activeAv = Get-ActiveThirdPartyAv
if ($activeAv.Count -gt 0) {
    Write-KitLog -Message "ATTENTION : antivirus tiers actif ($($activeAv -join ', '))." -Level 'WARN'
    Write-KitLog -Message "Il peut bloquer silencieusement les modifications registre/policies. Le désinstaller (module 02) ou le désactiver d'abord pour un résultat fiable." -Level 'WARN'
}

$vendorDir = Join-Path $PSScriptRoot '..\vendor\TelemetryGuard'
$disableScript = Join-Path $vendorDir 'Disable-WindowsTelemetry.ps1'
$installScript = Join-Path $vendorDir 'Install-TelemetryGuard.ps1'

if (-not (Test-Path $disableScript)) {
    Write-KitLog -Message "ERREUR : $disableScript introuvable. Vérifier vendor/TelemetryGuard/." -Level 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
# Étape 1 : Disable-WindowsTelemetry
# ---------------------------------------------------------------------------
if ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait lancé Disable-WindowsTelemetry.ps1 (SmartScreen=$($DisableSmartScreen.IsPresent), IPs=$($BlockTelemetryIPs.IsPresent))" -Level 'WHATIF'
}
else {
    Write-KitLog -Message "Lancement de Disable-WindowsTelemetry.ps1..." -Level 'INFO'

    $args = @('-ExecutionPolicy', 'Bypass', '-File', $disableScript)
    if ($DisableSmartScreen) { $args += '-DisableSmartScreen' }
    if ($BlockTelemetryIPs)  { $args += '-BlockTelemetryIPs'  }

    & powershell.exe @args
    $rc = $LASTEXITCODE

    if ($rc -eq 0 -or $null -eq $rc) {
        Write-KitLog -Message "Disable-WindowsTelemetry.ps1 terminé avec succès." -Level 'OK'
    }
    else {
        Write-KitLog -Message "Disable-WindowsTelemetry.ps1 terminé avec code $rc (vérifier logs dans C:\ProgramData\TelemetryGuard\logs\)" -Level 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Étape 2 : Install-TelemetryGuard (guard permanent)
# ---------------------------------------------------------------------------
if (-not (Test-Path $installScript)) {
    Write-KitLog -Message "ERREUR : $installScript introuvable." -Level 'ERROR'
    exit 1
}

if ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait lancé Install-TelemetryGuard.ps1 (guard permanent, 2 tâches planifiées)" -Level 'WHATIF'
}
else {
    Write-KitLog -Message "Installation du guard permanent (TelemetryGuard)..." -Level 'INFO'

    $installArgs = @('-ExecutionPolicy', 'Bypass', '-File', $installScript)
    if ($DisableSmartScreen) { $installArgs += '-DisableSmartScreen' }
    if ($BlockTelemetryIPs)  { $installArgs += '-BlockTelemetryIPs'  }

    & powershell.exe @installArgs
    $rc = $LASTEXITCODE

    if ($rc -eq 0 -or $null -eq $rc) {
        Write-KitLog -Message "TelemetryGuard installé." -Level 'OK'

        # Vérification : les 2 tâches planifiées doivent exister
        $taskWU   = Get-ScheduledTask -TaskName 'TelemetryGuard-OnWindowsUpdate' -ErrorAction SilentlyContinue
        $taskBoot = Get-ScheduledTask -TaskName 'TelemetryGuard-OnStartup'       -ErrorAction SilentlyContinue

        if ($taskWU)   { Write-KitLog -Message "Tâche TelemetryGuard-OnWindowsUpdate : $($taskWU.State)"  -Level 'OK' }
        else           { Write-KitLog -Message "Tâche TelemetryGuard-OnWindowsUpdate manquante !"         -Level 'ERROR' }

        if ($taskBoot) { Write-KitLog -Message "Tâche TelemetryGuard-OnStartup : $($taskBoot.State)"      -Level 'OK' }
        else           { Write-KitLog -Message "Tâche TelemetryGuard-OnStartup manquante !"                -Level 'ERROR' }
    }
    else {
        Write-KitLog -Message "Install-TelemetryGuard.ps1 terminé avec code $rc" -Level 'WARN'
    }

    # Vérification SmartScreen : si -DisableSmartScreen absent, la clé ne doit pas être à 0
    if (-not $DisableSmartScreen) {
        $ssKey = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue).EnableSmartScreen
        if ($ssKey -eq 0) {
            Write-KitLog -Message "ATTENTION : SmartScreen semble désactivé malgré le profil par défaut. Vérifier." -Level 'WARN'
        }
        else {
            Write-KitLog -Message "SmartScreen : actif (inchangé)." -Level 'OK'
        }
    }

    # Vérification service DiagTrack
    $diagTrack = Get-Service 'DiagTrack' -ErrorAction SilentlyContinue
    if ($diagTrack) {
        Write-KitLog -Message "DiagTrack : StartType=$($diagTrack.StartType), Status=$($diagTrack.Status)" `
            -Level $(if ($diagTrack.StartType -eq 'Disabled') { 'OK' } else { 'WARN' })
    }
}

# ---------------------------------------------------------------------------
# Étape 3 : Cibles confidentialité Windows 11 (réglages HKCU, réversibles)
# Chaque valeur modifiée est enregistrée dans le manifeste d'annulation.
# ---------------------------------------------------------------------------

function Set-PrivacyRegValue {
    # Lit l'ancienne valeur, écrit la nouvelle, enregistre l'entrée d'annulation.
    # Respecte -WhatIf : log seulement, aucune écriture registre ni entrée undo.
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value,
        [string]$Type = 'DWord'
    )
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: Aurait mis $Path\$Name = $Value" -Level 'WHATIF'
        return
    }
    try {
        $wasAbsent = $true
        $old = $null
        if (Test-Path $Path) {
            $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $existing -and $existing.PSObject.Properties[$Name]) {
                $wasAbsent = $false
                $old = $existing.$Name
            }
        }
        else {
            New-Item -Path $Path -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
        Add-UndoEntry -Module '04' -Action 'reg-value' -Data @{
            RegPath        = $Path
            ValueName      = $Name
            ValueType      = $Type
            OldValueData   = $old
            ValueWasAbsent = $wasAbsent
        }
        Write-KitLog -Message "Confidentialité : $Name désactivé ($Path)" -Level 'OK'
    }
    catch {
        Write-KitLog -Message "Échec réglage $Path\$Name : $($_.Exception.Message)" -Level 'WARN'
    }
}

$machine = Get-MachineInfo

if ($machine.IsWin11) {
    Write-KitLog -Message "--- Confidentialité Windows 11 (Copilot, Widgets, Search Highlights) ---" -Level 'INFO'

    # Bouton Copilot dans la barre des tâches
    Set-PrivacyRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
                        -Name 'ShowCopilotButton' -Value 0

    # Widgets (TaskbarDa) dans la barre des tâches
    Set-PrivacyRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
                        -Name 'TaskbarDa' -Value 0

    # Mise en avant dynamique dans la recherche (Search Highlights)
    Set-PrivacyRegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' `
                        -Name 'IsDynamicSearchBoxEnabled' -Value 0

    if ([int]$machine.OSBuild -ge 26100) {
        # Recall / Click to Do : disponible à partir de la build 24H2 (26100)
        # DisableAIDataAnalysis est la clé de stratégie documentée pour désactiver Recall.
        Write-KitLog -Message "--- Recall / Click to Do (24H2+, build $($machine.OSBuild)) ---" -Level 'INFO'
        Set-PrivacyRegValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' `
                            -Name 'DisableAIDataAnalysis' -Value 1
    }
}
else {
    Write-KitLog -Message "Cibles confidentialité Windows 11 ignorées (Windows 10 détecté)." -Level 'INFO'
}

Write-KitLog -Message "=== 04-Privacy : terminé ===" -Level 'OK'
exit 0
