# modules/11-DeepClean.ps1 - Nettoyage léger résiduel : raccourcis morts + dossiers d'apps désinstallées
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\11-DeepClean.ps1 [-WhatIf] [-Unattended]
<#
.SYNOPSIS
    Supprime les raccourcis .lnk morts du menu Démarrer et les dossiers résiduels
    d'apps désinstallées (liste blanche uniquement). NE TOUCHE PAS au registre.
    NE fait PAS de DISM (déjà couvert par 07-Cleanup). Conçu pour être lançable seul.
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

Write-KitLog -Message "=== 11-DeepClean : début ===" -Level 'INFO'

# Racines autorisées : aucun chemin hors de cette liste ne sera jamais supprimé.
$allowedRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    $env:LOCALAPPDATA,
    $env:APPDATA
) | Where-Object { $_ -and (Test-Path $_) }

# ---------------------------------------------------------------------------
# 1. Raccourcis .lnk morts du menu Démarrer
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 1. Raccourcis morts (menu Démarrer) ---" -Level 'INFO'

$startMenus = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:APPDATA     'Microsoft\Windows\Start Menu\Programs')
) | Where-Object { Test-Path $_ }

$wsh = $null
$deadCount = 0
try {
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($menu in $startMenus) {
        $lnks = Get-ChildItem -Path $menu -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue
        foreach ($lnk in $lnks) {
            try {
                $sc      = $wsh.CreateShortcut($lnk.FullName)
                $target  = $sc.TargetPath
                $exists  = if ([string]::IsNullOrWhiteSpace($target)) { $false } else { Test-Path -LiteralPath $target -ErrorAction SilentlyContinue }
                $verdict = Get-ShortcutVerdict -TargetPath $target -TargetExists $exists
                if ($verdict -eq 'DEAD') {
                    if ($WhatIf) {
                        Write-KitLog -Message "WHATIF: supprimerait le raccourci mort '$($lnk.Name)' -> '$target'" -Level 'WHATIF'
                    }
                    else {
                        Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction Stop
                        Write-KitLog -Message "Raccourci mort supprimé : $($lnk.Name) (cible absente : $target)" -Level 'OK'
                    }
                    $deadCount++
                }
            }
            catch {
                Write-KitLog -Message "Raccourci ignoré ($($lnk.Name)) : $_" -Level 'WARN'
            }
        }
    }
    Write-KitLog -Message "Raccourcis morts traités : $deadCount" -Level $(if ($deadCount -gt 0) { 'OK' } else { 'INFO' })
}
catch {
    Write-KitLog -Message "WScript.Shell indisponible, section raccourcis ignorée : $_" -Level 'WARN'
}
finally {
    if ($wsh) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
}

# ---------------------------------------------------------------------------
# 2. Dossiers résiduels d'apps désinstallées (liste blanche uniquement)
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 2. Dossiers résiduels (liste blanche) ---" -Level 'INFO'

$whitelistPath = Join-Path $PSScriptRoot '..\config\deepclean-residuals.json'
if (-not (Test-Path $whitelistPath)) {
    Write-KitLog -Message "Liste blanche introuvable ($whitelistPath). Section résidus ignorée." -Level 'WARN'
}
else {
    $wl = $null
    try { $wl = Get-Content $whitelistPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-KitLog -Message "Liste blanche illisible : $_. Section ignorée." -Level 'WARN' }

    if ($wl) {
        # Retrouver le dernier log Debloat (run précédent) pour savoir ce qui a été désinstallé.
        $removedApps = @()
        $logDir = Join-Path $PSScriptRoot '..\runtime\logs'
        if (Test-Path $logDir) {
            $priorLog = Get-ChildItem $logDir -Filter 'run-*.log' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -ne $script:KitLogFile } |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($priorLog) {
                $removedApps = Get-RemovedAppsFromLog -Lines (Get-Content $priorLog.FullName -ErrorAction SilentlyContinue)
                Write-KitLog -Message "Log Debloat lu ($($priorLog.Name)) : $($removedApps.Count) app(s) désinstallée(s) détectée(s)." -Level 'INFO'
            }
            else {
                Write-KitLog -Message "Aucun log Debloat antérieur. Nettoyage par-app ignoré (liste alwaysCheck seule)." -Level 'INFO'
            }
        }

        # Construire la liste des chemins candidats (accès défensif : JSON possiblement partiel sous StrictMode).
        $candidates = New-Object System.Collections.Generic.List[object]
        $alwaysCheckList  = if ($wl.PSObject.Properties['alwaysCheck'])  { @($wl.alwaysCheck)  } else { @() }
        $byRemovedAppList = if ($wl.PSObject.Properties['byRemovedApp']) { @($wl.byRemovedApp) } else { @() }
        foreach ($entry in $alwaysCheckList) {
            $paths = if ($entry.PSObject.Properties['paths']) { @($entry.paths) } else { @() }
            $label = if ($entry.PSObject.Properties['label']) { $entry.label } else { '(sans label)' }
            foreach ($p in $paths) { $candidates.Add([PSCustomObject]@{ Label = $label; Path = $p }) }
        }
        foreach ($entry in $byRemovedAppList) {
            if (-not $entry.PSObject.Properties['match']) { continue }
            $hit = $removedApps | Where-Object { $_ -match [regex]::Escape($entry.match) }
            if ($hit) {
                $paths = if ($entry.PSObject.Properties['paths']) { @($entry.paths) } else { @() }
                $label = if ($entry.PSObject.Properties['label']) { $entry.label } else { '(sans label)' }
                foreach ($p in $paths) { $candidates.Add([PSCustomObject]@{ Label = $label; Path = $p }) }
            }
        }

        $removedDirs = 0
        foreach ($c in $candidates) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($c.Path)
            if (-not (Test-ResidualPathAllowed -Path $expanded -AllowedRoots $allowedRoots)) {
                Write-KitLog -Message "REFUS (hors racine autorisée) : $expanded" -Level 'WARN'
                continue
            }
            if (-not (Test-Path -LiteralPath $expanded)) { continue }
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: supprimerait le dossier résiduel [$($c.Label)] : $expanded" -Level 'WHATIF'
            }
            else {
                try {
                    Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction Stop
                    Write-KitLog -Message "Dossier résiduel supprimé [$($c.Label)] : $expanded" -Level 'OK'
                    $removedDirs++
                }
                catch {
                    Write-KitLog -Message "Échec suppression $expanded : $_" -Level 'WARN'
                }
            }
        }
        Write-KitLog -Message "Dossiers résiduels traités : $removedDirs" -Level $(if ($removedDirs -gt 0) { 'OK' } else { 'INFO' })
    }
}

Write-KitLog -Message "=== 11-DeepClean : terminé ===" -Level 'OK'
exit 0
