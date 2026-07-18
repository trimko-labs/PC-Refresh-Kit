# modules/12-Startup.ps1 - Désactive (réversible) les autostarts indésirables (liste noire)
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\12-Startup.ps1 [-WhatIf] [-Unattended]
<#
.SYNOPSIS
    Désactive de façon RÉVERSIBLE les programmes au démarrage matchant la liste noire :
    - clés Run : via StartupApproved (onglet Démarrage), jamais supprimées
    - dossier Démarrage : .lnk DÉPLACÉS vers un dossier de sauvegarde, jamais supprimés
    - tâches planifiées logon/boot : Disable-ScheduledTask, jamais Unregister
    Rien hors liste noire n'est touché. NE supprime jamais de façon irréversible.
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

Write-KitLog -Message "=== 12-Startup : début ===" -Level 'INFO'

$blPath = Join-Path $PSScriptRoot '..\config\startup-blacklist.json'
$blacklist = @()
if (Test-Path $blPath) {
    try { $blacklist = @((Get-Content $blPath -Raw -Encoding UTF8 | ConvertFrom-Json).entries) }
    catch { Write-KitLog -Message "Liste noire illisible : $_. Module ignoré." -Level 'WARN' }
}
if ($blacklist.Count -eq 0) {
    Write-KitLog -Message "Liste noire vide/introuvable. Rien à faire." -Level 'WARN'
    Write-KitLog -Message "=== 12-Startup : terminé ===" -Level 'OK'
    exit 0
}

$backupDir = Join-Path $env:ProgramData ("PC-Refresh-Kit\Startup-disabled-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-KitLog -Message "--- Détection des autostarts ---" -Level 'INFO'
$items = @()
try { $items = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop | Select-Object Name, Command, Location, User) }
catch { Write-KitLog -Message "Impossible de lister les autostarts : $_" -Level 'WARN' }

$disabledCount = 0
foreach ($it in $items) {
    $match = Get-StartupMatch -Name $it.Name -Command $it.Command -Blacklist $blacklist
    if (-not $match) { continue }

    $hive = Get-StartupHiveFromLocation -Location $it.Location
    switch ($hive) {
        { $_ -in @('HKCU-Run','HKLM-Run') } {
            $approvedBase = if ($hive -eq 'HKLM-Run') {
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            } else {
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            }
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: désactiverait (StartupApproved) [$($match.label)] : $($it.Name)" -Level 'WHATIF'
            }
            else {
                try {
                    if (-not (Test-Path $approvedBase)) { New-Item -Path $approvedBase -Force | Out-Null }
                    Set-ItemProperty -Path $approvedBase -Name $it.Name -Value (Get-StartupApprovedDisabledBytes) -Type Binary -Force
                    Write-KitLog -Message "Autostart désactivé (réversible) [$($match.label)] : $($it.Name)" -Level 'OK'
                    [void](Add-UndoEntry -Module '12-Startup' -Action 'RunKeyDisabled' -Data @{ ApprovedKeyPath = $approvedBase; ValueName = $it.Name; Label = $match.label })
                    $disabledCount++
                }
                catch { Write-KitLog -Message "Échec désactivation $($it.Name) : $_" -Level 'WARN' }
            }
        }
        'Folder' {
            $startupFolders = @(
                (Join-Path $env:APPDATA     'Microsoft\Windows\Start Menu\Programs\Startup'),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
            ) | Where-Object { Test-Path $_ }
            $lnk = $null
            foreach ($sf in $startupFolders) {
                $cand = Get-ChildItem -Path $sf -Filter '*.lnk' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.BaseName -eq $it.Name -or $_.BaseName -like "*$($it.Name)*" } | Select-Object -First 1
                if ($cand) { $lnk = $cand; break }
            }
            if (-not $lnk) { continue }
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: déplacerait le raccourci Démarrage [$($match.label)] : $($lnk.Name)" -Level 'WHATIF'
            }
            else {
                try {
                    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                    $dest = Join-Path $backupDir $lnk.Name
                    Move-Item -LiteralPath $lnk.FullName -Destination $dest -Force
                    Write-KitLog -Message "Raccourci Démarrage déplacé (sauvegarde) [$($match.label)] : $($lnk.Name)" -Level 'OK'
                    [void](Add-UndoEntry -Module '12-Startup' -Action 'ShortcutMoved' -Data @{ OriginalPath = $lnk.FullName; DisabledPath = $dest; Label = $match.label })
                    $disabledCount++
                }
                catch { Write-KitLog -Message "Échec déplacement $($lnk.Name) : $_" -Level 'WARN' }
            }
        }
        default {
            Write-KitLog -Message "Autostart ignoré (emplacement non géré : $($it.Location)) : $($it.Name)" -Level 'INFO'
        }
    }
}

# ---------------------------------------------------------------------------
# Tâches planifiées déclenchées au logon / au démarrage (réversible : Disable)
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Tâches planifiées au démarrage ---" -Level 'INFO'
try {
    $logonTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.State -ne 'Disabled' -and
        (@($_.Triggers) | Where-Object { Test-IsLogonOrBootTrigger -Trigger $_ })
    }
    foreach ($task in $logonTasks) {
        # Matcher sur le nom ET l'exécutable réel de la tâche (TaskPath n'est qu'un dossier).
        $taskExe = ''
        try { if ($task.Actions -and @($task.Actions).Count -gt 0) { $taskExe = [string]$task.Actions[0].Execute } } catch { }
        $match = Get-StartupMatch -Name $task.TaskName -Command $taskExe -Blacklist $blacklist
        if (-not $match) { continue }
        if ($WhatIf) {
            Write-KitLog -Message "WHATIF: désactiverait la tâche [$($match.label)] : $($task.TaskPath)$($task.TaskName)" -Level 'WHATIF'
        }
        else {
            try {
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
                Write-KitLog -Message "Tâche désactivée (réversible) [$($match.label)] : $($task.TaskName)" -Level 'OK'
                [void](Add-UndoEntry -Module '12-Startup' -Action 'TaskDisabled' -Data @{ TaskName = $task.TaskName; TaskPath = $task.TaskPath; Label = $match.label })
                $disabledCount++
            }
            catch { Write-KitLog -Message "Échec désactivation tâche $($task.TaskName) : $_" -Level 'WARN' }
        }
    }
}
catch { Write-KitLog -Message "Énumération des tâches planifiées impossible : $_" -Level 'WARN' }

Write-KitLog -Message "Autostarts désactivés : $disabledCount" -Level $(if ($disabledCount -gt 0) { 'OK' } else { 'INFO' })
if (-not $WhatIf -and $disabledCount -gt 0) {
    Write-KitLog -Message "Réactivation possible : Gestionnaire des tâches > Démarrage, ou restaurer les .lnk depuis $backupDir" -Level 'INFO'
}
Write-KitLog -Message "=== 12-Startup : terminé ===" -Level 'OK'
exit 0
