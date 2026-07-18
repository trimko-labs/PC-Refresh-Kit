# Run.ps1 - Orchestrateur du PC-Refresh-Kit
# Usage : powershell -ExecutionPolicy Bypass -File .\Run.ps1 [-WhatIf] [-All] [-DisableSmartScreen]

param(
    [switch]$WhatIf,
    [switch]$All,
    [string]$Profile = 'Standard',
    [switch]$DisableSmartScreen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Initialisation du log avant de dot-sourcer Common.ps1
# ---------------------------------------------------------------------------
$runtimeDir = Join-Path $PSScriptRoot 'runtime\logs'
if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:KitLogFile = Join-Path $runtimeDir "run-$env:COMPUTERNAME-$timestamp.log"

# Dot-source la bibliothèque commune
. "$PSScriptRoot\lib\Common.ps1"

Assert-Admin

Write-KitLog -Message "=== PC-Refresh-Kit démarrage ===" -Level 'INFO'
Write-KitLog -Message "Ordinateur : $env:COMPUTERNAME | Profil : $Profile | WhatIf : $WhatIf" -Level 'INFO'

# ---------------------------------------------------------------------------
# Définition des modules dans l'ordre d'exécution
# ---------------------------------------------------------------------------
$modules = @(
    [PSCustomObject]@{ Id = '00'; Name = 'Diagnostic'   ; File = '00-Diagnostic.ps1'  ; Destructif = $false },
    [PSCustomObject]@{ Id = '01'; Name = 'Backup'       ; File = '01-Backup.ps1'       ; Destructif = $true  },
    [PSCustomObject]@{ Id = '02'; Name = 'Antivirus'    ; File = '02-Antivirus.ps1'    ; Destructif = $true  },
    [PSCustomObject]@{ Id = '03'; Name = 'Debloat'      ; File = '03-Debloat.ps1'      ; Destructif = $true  },
    [PSCustomObject]@{ Id = '04'; Name = 'Privacy'      ; File = '04-Privacy.ps1'      ; Destructif = $true  },
    [PSCustomObject]@{ Id = '05'; Name = 'Updates'      ; File = '05-Updates.ps1'      ; Destructif = $false },
    [PSCustomObject]@{ Id = '06'; Name = 'Software'     ; File = '06-Software.ps1'     ; Destructif = $false },
    [PSCustomObject]@{ Id = '07'; Name = 'Cleanup'      ; File = '07-Cleanup.ps1'      ; Destructif = $true  },
    [PSCustomObject]@{ Id = '08'; Name = 'Accounts'     ; File = '08-Accounts.ps1'     ; Destructif = $true  },
    [PSCustomObject]@{ Id = '09'; Name = 'Comfort'      ; File = '09-Comfort.ps1'      ; Destructif = $false },
    [PSCustomObject]@{ Id = '15'; Name = 'Network'      ; File = '15-Network.ps1'      ; Destructif = $true  },
    [PSCustomObject]@{ Id = '10'; Name = 'Report'       ; File = '10-Report.ps1'       ; Destructif = $false }
)

# ---------------------------------------------------------------------------
# Invocation d'un module avec gestion des erreurs
# Retourne $true si OK, $false si erreur critique
# ---------------------------------------------------------------------------
function Invoke-Module {
    param([PSCustomObject]$Mod)

    $path = Join-Path $PSScriptRoot "modules\$($Mod.File)"

    if (-not (Test-Path $path)) {
        Write-KitLog -Message "Module $($Mod.Id)-$($Mod.Name) : fichier absent ($path), SKIP." -Level 'WARN'
        return $true
    }

    Write-KitLog -Message "--- Début module $($Mod.Id) : $($Mod.Name) ---" -Level 'INFO'

    try {
        # Passer les paramètres globaux au module via la ligne de commande
        $psArgs = @(
            '-ExecutionPolicy', 'Bypass',
            '-File', $path,
            '-Profile', $Profile
        )
        if ($WhatIf) { $psArgs += '-WhatIf' }
        if ($DisableSmartScreen -and $Mod.Id -eq '04') { $psArgs += '-DisableSmartScreen' }
        if ($All) { $psArgs += '-Force' }

        & powershell.exe @psArgs
        Write-KitLog -Message "--- Fin module $($Mod.Id) : $($Mod.Name) - Code retour : $LASTEXITCODE ---" -Level 'INFO'
        return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
    }
    catch {
        Write-KitLog -Message "ERREUR module $($Mod.Id) $($Mod.Name) : $_" -Level 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Mode -All : enchaîner tous les modules dans l'ordre
# ---------------------------------------------------------------------------
function Invoke-AllModules {
    foreach ($mod in $modules | Where-Object { $_.Id -ne '10' -and $_.Id -ne '15' }) {
        # Module Backup : si échec, demander si on continue
        if ($mod.Id -eq '01') {
            $ok = Invoke-Module $mod
            if (-not $ok) {
                Write-KitLog -Message "Le point de restauration n'a pas pu être créé." -Level 'WARN'
                if (-not $WhatIf) {
                    Write-Host ""
                    Write-Host "[ATTENTION] Le point de restauration système a échoué." -ForegroundColor Yellow
                    $answer = Read-Host "Continuer sans point de restauration ? (O/N)"
                    if ($answer -notmatch '^[Oo]') {
                        Write-KitLog -Message "Interruption demandée par l'utilisateur (pas de point de restauration)." -Level 'WARN'
                        return
                    }
                }
            }
        }
        else {
            Invoke-Module $mod | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Menu interactif
# ---------------------------------------------------------------------------
function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host "  PC-REFRESH-KIT - Menu principal" -ForegroundColor Cyan
        if ($WhatIf) { Write-Host "  [MODE DRY-RUN ACTIF - aucune modification réelle]" -ForegroundColor Yellow }
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host ""
        foreach ($mod in $modules) {
            Write-Host "  $($mod.Id) - $($mod.Name)"
        }
        Write-Host ""
        Write-Host "  A  - Tout enchaîner dans l'ordre (00 -> 13, rapport 10 ; exclut 15-Network)"
        Write-Host "  Q  - Quitter"
        Write-Host ""
        $choice = (Read-Host "Votre choix").Trim().ToUpper()

        switch ($choice) {
            'A' {
                Write-KitLog -Message "Mode tout-enchaîné démarré." -Level 'INFO'
                Invoke-AllModules
                # Rapport final
                Invoke-Module ($modules | Where-Object { $_.Id -eq '10' }) | Out-Null
                $rebootFlag = Join-Path $PSScriptRoot 'runtime\reboot-required.flag'
                if (Test-Path $rebootFlag) {
                    Write-Host ""
                    Write-Host "#########################################################" -ForegroundColor Yellow
                    Write-Host "#  REDÉMARRAGE REQUIS avant de rendre le PC au client.  #" -ForegroundColor Yellow
                    Write-Host "#########################################################" -ForegroundColor Yellow
                }
                break
            }
            'Q' {
                Write-KitLog -Message "Sortie demandée." -Level 'INFO'
                return
            }
            default {
                $mod = $modules | Where-Object { $_.Id -eq $choice }
                if ($null -ne $mod) {
                    Invoke-Module $mod | Out-Null
                }
                else {
                    Write-Host "[ERREUR] Choix invalide : '$choice'" -ForegroundColor Red
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
if ($All) {
    Write-KitLog -Message "Démarrage mode -All." -Level 'INFO'
    Invoke-AllModules
    # Rapport final (évite le doublon si 10 déjà dans la chaîne)
    $reportMod = $modules | Where-Object { $_.Id -eq '10' }
    Invoke-Module $reportMod | Out-Null
    $rebootFlag = Join-Path $PSScriptRoot 'runtime\reboot-required.flag'
    if (Test-Path $rebootFlag) {
        Write-Host ""
        Write-Host "#########################################################" -ForegroundColor Yellow
        Write-Host "#  REDÉMARRAGE REQUIS avant de rendre le PC au client.  #" -ForegroundColor Yellow
        Write-Host "#########################################################" -ForegroundColor Yellow
    }
    Write-KitLog -Message "=== PC-Refresh-Kit terminé ===" -Level 'OK'
}
else {
    Show-Menu
}
