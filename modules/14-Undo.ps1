# modules/14-Undo.ps1 - Annule (restaure) les changements réversibles du dernier run
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\14-Undo.ps1 [-WhatIf] [-ManifestPath <chemin>]
<#
.SYNOPSIS
    Lit le manifeste d'annulation écrit par les modules réversibles (12-Startup, 13-BrowserPUP)
    et défait chaque action dans l'ordre inverse :
    - RunKeyDisabled   : réactive l'autostart (StartupApproved octet 0x02)
    - ShortcutMoved    : remet le .lnk déplacé dans le dossier Démarrage d'origine
    - TaskDisabled     : Enable-ScheduledTask
    - RegBackupRestore : réimporte le .reg de sauvegarde (restaure la clé pré-suppression)
    Par défaut, prend le manifeste le plus récent de runtime\undo. -ManifestPath force un fichier précis.
    NE supprime rien : ce module ne fait que restaurer.
#>

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,   # accepté par convention (lanceurs/GUI) ; sans effet ici : ce module ne fait aucune pause interactive
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 14-Undo : début ===" -Level 'INFO'

# --- Localiser le manifeste : -ManifestPath, sinon le plus récent dans runtime\undo ---
$undoDir = Join-Path $PSScriptRoot '..\runtime\undo'
if (-not $ManifestPath) {
    if (Test-Path $undoDir) {
        $latest = Get-ChildItem -Path $undoDir -Filter 'undo-*.json' -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $ManifestPath = $latest.FullName }
    }
}
if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) {
    Write-KitLog -Message "Aucun manifeste d'annulation trouvé (rien à restaurer)." -Level 'WARN'
    Write-KitLog -Message "=== 14-Undo : terminé ===" -Level 'OK'
    exit 0
}
Write-KitLog -Message "Manifeste : $ManifestPath" -Level 'INFO'

$entries = @()
# PS 5.1 : ConvertFrom-Json renvoie un tableau JSON comme UN SEUL objet non enumere ; @(pipe) donne
# alors 1 element emballant tout le tableau (rollback qui ne voit qu'une entree). On assigne d'abord
# a une variable PUIS on enveloppe avec @() pour un aplatissement correct.
try {
    $parsedManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($parsedManifest)
}
catch {
    Write-KitLog -Message "Manifeste illisible : $_" -Level 'ERROR'
    exit 1
}

$plan = Get-UndoPlan -Entries $entries
Write-KitLog -Message "$($plan.Count) action(s) à annuler (ordre inverse des modifications)." -Level 'INFO'

$restored = 0
foreach ($e in $plan) {
    switch ([string]$e.Action) {

        'RunKeyDisabled' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: réactiverait l'autostart $($e.ValueName) ($($e.ApprovedKeyPath))" -Level 'WHATIF'
            }
            else {
                try {
                    if (Test-Path $e.ApprovedKeyPath) {
                        Set-ItemProperty -Path $e.ApprovedKeyPath -Name $e.ValueName -Value (Get-StartupApprovedEnabledBytes) -Type Binary -Force -ErrorAction Stop
                        Write-KitLog -Message "Autostart réactivé : $($e.ValueName)" -Level 'OK'
                        $restored++
                    }
                    else {
                        Write-KitLog -Message "Clé StartupApproved absente, ignoré : $($e.ApprovedKeyPath)" -Level 'WARN'
                    }
                }
                catch { Write-KitLog -Message "Échec réactivation $($e.ValueName) : $_" -Level 'WARN' }
            }
        }

        'ShortcutMoved' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: restaurerait le raccourci $($e.OriginalPath)" -Level 'WHATIF'
            }
            else {
                try {
                    if (Test-Path $e.DisabledPath) {
                        $destDir = Split-Path $e.OriginalPath -Parent
                        if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                        Move-Item -LiteralPath $e.DisabledPath -Destination $e.OriginalPath -Force -ErrorAction Stop
                        Write-KitLog -Message "Raccourci Démarrage restauré : $(Split-Path $e.OriginalPath -Leaf)" -Level 'OK'
                        $restored++
                    }
                    else {
                        Write-KitLog -Message "Sauvegarde du raccourci absente, ignoré : $($e.DisabledPath)" -Level 'WARN'
                    }
                }
                catch { Write-KitLog -Message "Échec restauration raccourci : $_" -Level 'WARN' }
            }
        }

        'TaskDisabled' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: réactiverait la tâche $($e.TaskName)" -Level 'WHATIF'
            }
            else {
                try {
                    Enable-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath -ErrorAction Stop | Out-Null
                    Write-KitLog -Message "Tâche réactivée : $($e.TaskName)" -Level 'OK'
                    $restored++
                }
                catch { Write-KitLog -Message "Échec réactivation tâche $($e.TaskName) : $_" -Level 'WARN' }
            }
        }

        'RegBackupRestore' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: réimporterait la sauvegarde registre $($e.RegBackupFile)" -Level 'WHATIF'
            }
            else {
                try {
                    if (Test-Path $e.RegBackupFile) {
                        & reg.exe import "$($e.RegBackupFile)" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-KitLog -Message "Sauvegarde registre réimportée : $(Split-Path $e.RegBackupFile -Leaf)" -Level 'OK'
                            $restored++
                        }
                        else {
                            Write-KitLog -Message "Échec réimport (reg.exe code $LASTEXITCODE) : $($e.RegBackupFile)" -Level 'WARN'
                        }
                    }
                    else {
                        Write-KitLog -Message "Fichier .reg de sauvegarde absent, ignoré : $($e.RegBackupFile)" -Level 'WARN'
                    }
                }
                catch { Write-KitLog -Message "Échec réimport registre : $_" -Level 'WARN' }
            }
        }

        'reg-value' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: $(if ($e.ValueWasAbsent) { 'retirerait' } else { 'restaurerait' }) la valeur $($e.ValueName) dans $($e.RegPath)" -Level 'WHATIF'
            }
            else {
                try {
                    if ($e.ValueWasAbsent) {
                        # La valeur n'existait pas avant - on la retire via reg.exe pour restaurer l'état initial
                        if (Test-Path $e.RegPath) {
                            $regExePath = $e.RegPath -replace '^([^:]+):\\', '$1\'
                            & reg.exe delete $regExePath /v $e.ValueName /f 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) {
                                Write-KitLog -Message "Undo : valeur $($e.ValueName) retirée de $($e.RegPath)" -Level 'OK'
                                $restored++
                            }
                            else {
                                Write-KitLog -Message "Undo reg-value : reg.exe delete a échoué (code $LASTEXITCODE) pour $($e.RegPath)\$($e.ValueName)" -Level 'WARN'
                            }
                        }
                    }
                    else {
                        # La valeur existait - on recrée la clé si nécessaire puis on restaure l'ancienne donnée
                        if (-not (Test-Path $e.RegPath)) { New-Item -Path $e.RegPath -Force | Out-Null }
                        Set-ItemProperty -Path $e.RegPath -Name $e.ValueName -Value $e.OldValueData -Type $e.ValueType
                        Write-KitLog -Message "Undo : valeur $($e.ValueName) restaurée dans $($e.RegPath)" -Level 'OK'
                        $restored++
                    }
                }
                catch {
                    Write-KitLog -Message "Undo reg-value échoue pour $($e.RegPath)\$($e.ValueName) : $($_.Exception.Message)" -Level 'WARN'
                }
            }
        }

        default {
            Write-KitLog -Message "Action d'annulation inconnue ignorée : $($e.Action)" -Level 'WARN'
        }
    }
}

Write-KitLog -Message "Actions restaurées : $restored / $($plan.Count)" -Level $(if ($restored -gt 0) { 'OK' } else { 'INFO' })
if (-not $WhatIf -and $restored -gt 0) {
    Write-KitLog -Message "Restauration terminée. Un redémarrage peut être nécessaire pour que tout reprenne effet." -Level 'INFO'
}
Write-KitLog -Message "=== 14-Undo : terminé ===" -Level 'OK'
exit 0
