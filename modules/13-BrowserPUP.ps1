# modules/13-BrowserPUP.ps1 - Nettoyage conservateur des détournements navigateur (policy) + rapport
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\13-BrowserPUP.ps1 [-WhatIf] [-Unattended]
<#
.SYNOPSIS
    Nettoie les détournements navigateur posés par POLICY (search/homepage/newtab forcés,
    extensions force-installées) sur Chrome et Edge, avec backup .reg avant. Conservateur :
    ne touche pas aux profils si le navigateur tourne, et se contente de RAPPORTER le reste.
#>

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

Write-KitLog -Message "=== 13-BrowserPUP : début ===" -Level 'INFO'

$backupDir  = Join-Path $env:ProgramData ("PC-Refresh-Kit\BrowserPUP-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$runtimeDir = Join-Path $PSScriptRoot '..\runtime'

$policyRoots = @(
    'HKLM:\SOFTWARE\Policies\Google\Chrome',
    'HKCU:\SOFTWARE\Policies\Google\Chrome',
    'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
    'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
)
$hijackValues = @(
    'DefaultSearchProviderEnabled','DefaultSearchProviderSearchURL','DefaultSearchProviderName',
    'HomepageLocation','HomepageIsNewTabPage','NewTabPageLocation','RestoreOnStartupURLs'
)

function Backup-RegKey {
    param([string]$PsPath, [string]$OutFile)
    # Normaliser vers la forme reg.exe (HKLM\... / HKCU\...), y compris la forme longue du provider
    # (Get-ChildItem renvoie 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\...').
    $regPath = $PsPath `
        -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE\\', 'HKLM\' `
        -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_CURRENT_USER\\',  'HKCU\' `
        -replace '^HKLM:\\', 'HKLM\' `
        -replace '^HKCU:\\', 'HKCU\'
    & reg.exe export "$regPath" "$OutFile" /y 2>&1 | Out-Null
    # Si l'export échoue, on LÈVE : l'appelant (try/catch) annule alors la suppression -> jamais de suppression sans backup.
    if ($LASTEXITCODE -ne 0) { throw "Échec backup .reg (reg.exe exit $LASTEXITCODE) pour $regPath" }
}

Write-KitLog -Message "--- 1. Policies de détournement (search/homepage/newtab) ---" -Level 'INFO'
$cleaned = 0
foreach ($root in $policyRoots) {
    if (-not (Test-Path $root)) { continue }
    $props = (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)
    $present = @($hijackValues | Where-Object { $props -and $props.PSObject.Properties[$_] })
    if ($present.Count -eq 0) { continue }
    if ($WhatIf) {
        foreach ($val in $present) { Write-KitLog -Message "WHATIF: retirerait la policy $val dans $root" -Level 'WHATIF' }
        continue
    }
    # Backup de la clé COMPLÈTE une seule fois, AVANT toute suppression (sinon une valeur déjà retirée
    # manquerait du .reg). Si le backup échoue, on annule toutes les suppressions de cette clé.
    $regBak = Join-Path $backupDir (($root -replace '[:\\]', '_') + '.reg')
    try {
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        Backup-RegKey -PsPath $root -OutFile $regBak
    }
    catch {
        Write-KitLog -Message "Backup impossible pour $root, suppressions annulées : $_" -Level 'WARN'
        continue
    }
    # Backup OK : on enregistre l'annulation (réimport du .reg restaure la clé pré-suppression).
    [void](Add-UndoEntry -Module '13-BrowserPUP' -Action 'RegBackupRestore' -Data @{ RegBackupFile = $regBak; KeyPath = $root })
    foreach ($val in $present) {
        try {
            Remove-ItemProperty -Path $root -Name $val -Force -ErrorAction Stop
            Write-KitLog -Message "Policy détournement retirée : $val ($root)" -Level 'OK'
            $cleaned++
        }
        catch { Write-KitLog -Message "Échec retrait policy $val ($root) : $_" -Level 'WARN' }
    }
}
Write-KitLog -Message "Policies de détournement retirées : $cleaned" -Level $(if ($cleaned -gt 0) { 'OK' } else { 'INFO' })

# ---------------------------------------------------------------------------
# 2. Extensions force-installées (registre) + liste noire + rapport
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 2. Extensions force-installées / liste noire ---" -Level 'INFO'

$pupCfgPath = Join-Path $PSScriptRoot '..\config\browser-pup.json'
$extBlacklist = @()
if (Test-Path $pupCfgPath) {
    try { $extBlacklist = @((Get-Content $pupCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).extensionBlacklist) }
    catch { Write-KitLog -Message "Config PUP illisible : $_" -Level 'WARN' }
}

$forcelistKeys = @(
    'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
    'HKCU:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
    'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist',
    'HKCU:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
)
$extCleaned = 0
foreach ($fk in $forcelistKeys) {
    if (-not (Test-Path $fk)) { continue }
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: retirerait la clé ExtensionInstallForcelist : $fk" -Level 'WHATIF'
    }
    else {
        try {
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            $regBak = Join-Path $backupDir (($fk -replace '[:\\]', '_') + '.reg')
            Backup-RegKey -PsPath $fk -OutFile $regBak
            # Manifeste AVANT suppression : si le process meurt entre les deux, la clé perdue reste annulable.
            [void](Add-UndoEntry -Module '13-BrowserPUP' -Action 'RegBackupRestore' -Data @{ RegBackupFile = $regBak; KeyPath = $fk })
            Remove-Item -Path $fk -Recurse -Force -ErrorAction Stop
            Write-KitLog -Message "ExtensionInstallForcelist retirée : $fk" -Level 'OK'
            $extCleaned++
        }
        catch { Write-KitLog -Message "Échec retrait $fk : $_" -Level 'WARN' }
    }
}

# Hors Policies\ intentionnel : enregistrements d'extension posés par des installeurs tiers.
# On ne RETIRE que ceux de la liste noire (avec backup) ; les autres sont seulement rapportés
# et leurs IDs collectés pour la classification du rapport (module 10).
$forceInstalledIds = [System.Collections.Generic.List[string]]::new()
$extRegRoots = @(
    'HKLM:\SOFTWARE\Wow6432Node\Google\Chrome\Extensions',
    'HKLM:\SOFTWARE\Google\Chrome\Extensions',
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Edge\Extensions',
    'HKLM:\SOFTWARE\Microsoft\Edge\Extensions'
)
foreach ($er in $extRegRoots) {
    if (-not (Test-Path $er)) { continue }
    foreach ($sub in (Get-ChildItem -Path $er -ErrorAction SilentlyContinue)) {
        $id = $sub.PSChildName
        $isBad = Get-PupExtensionMatch -ExtensionId $id -Blacklist $extBlacklist
        if ($isBad) {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: retirerait l'extension liste-noire $id ($er)" -Level 'WHATIF'
            }
            else {
                try {
                    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                    $regBak = Join-Path $backupDir ("ext_$id.reg")
                    Backup-RegKey -PsPath $sub.PSPath -OutFile $regBak
                    [void](Add-UndoEntry -Module '13-BrowserPUP' -Action 'RegBackupRestore' -Data @{ RegBackupFile = $regBak; KeyPath = [string]$sub.PSPath })
                    Remove-Item -Path $sub.PSPath -Recurse -Force -ErrorAction Stop
                    Write-KitLog -Message "Extension liste-noire retirée : $id" -Level 'OK'
                    $extCleaned++
                }
                catch { Write-KitLog -Message "Échec retrait extension $id : $_" -Level 'WARN' }
            }
        }
        else {
            Write-KitLog -Message "Extension force-installée détectée (NON retirée, à vérifier) : $id ($er)" -Level 'INFO'
            [void]$forceInstalledIds.Add($id)
        }
    }
}
Write-KitLog -Message "Extensions/forcelists retirées : $extCleaned" -Level $(if ($extCleaned -gt 0) { 'OK' } else { 'INFO' })

# ---------------------------------------------------------------------------
# 3. Écriture des findings extensions pour le module 10-Report
# IDs dédupliqués et triés, écriture atomique (tmp + rename) pour cohérence.
# ---------------------------------------------------------------------------
if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
$findingsPath = Join-Path $runtimeDir "browser-findings-$env:COMPUTERNAME.json"
$dedupedIds   = @($forceInstalledIds | Sort-Object -Unique)
$findings     = [PSCustomObject]@{ ForceInstalledExtensionIds = $dedupedIds }
$tmp          = "$findingsPath.tmp"
$findings | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -Encoding UTF8
Move-Item -Path $tmp -Destination $findingsPath -Force
Write-KitLog -Message "Findings extensions écrits : $findingsPath ($($dedupedIds.Count) ID(s))" -Level 'INFO'

Write-KitLog -Message "=== 13-BrowserPUP : terminé ===" -Level 'OK'
exit 0
