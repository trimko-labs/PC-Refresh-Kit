# modules/02-Antivirus.ps1 - Désinstallation Avast + activation Microsoft Defender
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\02-Antivirus.ps1 [-WhatIf] [-Force]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$SkipDefenderScan,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 02-Antivirus : début ===" -Level 'INFO'

# ---------------------------------------------------------------------------
# Detection Avast
# Via clés registre Uninstall (rapide) plutôt que Win32_Product (très lent)
# ---------------------------------------------------------------------------
function Find-AvastInstall {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $paths) {
        $keys = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                Where-Object { (Get-JsonProp $_ 'DisplayName') -match 'Avast' }   # acces defensif (cle sans DisplayName sous StrictMode 5.1)
        if ($keys) { return $keys }
    }
    return $null
}

$avastKeys       = Find-AvastInstall
$avastDirExists  = Test-Path 'C:\Program Files\Avast Software'
$avastFound      = ($null -ne $avastKeys) -or $avastDirExists

if ($avastFound) {
    Write-KitLog -Message "Avast détecté sur ce PC." -Level 'WARN'
}
else {
    Write-KitLog -Message "Avast non détecté, étape ignorée." -Level 'OK'
}

# ---------------------------------------------------------------------------
# Désinstallation Avast
# ---------------------------------------------------------------------------
if ($avastFound) {
    # Étape 1 : uninstaller natif Avast
    $instupPath = 'C:\Program Files\Avast Software\Avast\Setup\Instup.exe'
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: Aurait lancé '$instupPath /uninstall /silent'" -Level 'WHATIF'
    }
    elseif (Test-Path $instupPath) {
        Write-KitLog -Message "Lancement de l'uninstaller natif Avast..." -Level 'INFO'
        Start-Process -FilePath $instupPath -ArgumentList '/uninstall /silent' -Wait -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10

        # Vérifier si toujours présent après désinstall
        $stillPresent = (Find-AvastInstall) -ne $null -or (Test-Path 'C:\Program Files\Avast Software')
        if ($stillPresent) {
            Write-KitLog -Message "Avast toujours présent après uninstaller natif - tentative avec les entrées registre..." -Level 'WARN'
            # Tenter via UninstallString du registre
            if ($null -ne $avastKeys) {
                foreach ($key in $avastKeys) {
                    # Accès gardé : une clé Uninstall du registre peut ne pas avoir
                    # UninstallString, ce qui lève sous StrictMode Latest.
                    if ($key.PSObject.Properties['UninstallString'] -and $key.UninstallString) {
                        $cmd = $key.UninstallString -replace '"', ''
                        Write-KitLog -Message "Désinstall via registre : $cmd /silent" -Level 'INFO'
                        Start-Process -FilePath $cmd -ArgumentList '/silent /uninstall' -Wait -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5
                    }
                }
            }
        }
        else {
            Write-KitLog -Message "Avast désinstallé avec succès (uninstaller natif)." -Level 'OK'
        }
    }
    else {
        Write-KitLog -Message "Uninstaller natif Avast introuvable ($instupPath). Passage à l'étape suivante." -Level 'WARN'
    }

    # Étape 2 : résidus - Avast Clear (si réseau disponible)
    $stillPresent2 = (Find-AvastInstall) -ne $null -or (Test-Path 'C:\Program Files\Avast Software')
    if ($stillPresent2 -and -not $WhatIf) {
        Write-KitLog -Message "Résidus Avast détectés. Téléchargement d'Avast Clear..." -Level 'WARN'
        $avastClearPath = Join-Path $env:TEMP 'avastclear.exe'
        # URL officielle Avast Clear
        $avastClearUrl  = 'https://files.avast.com/iavs9x/avastclear.exe'
        try {
            # Invoke-WebRequest avec timeout : WebClient.DownloadFile n'a pas de
            # timeout configurable et peut geler indéfiniment (proxy, filtrage).
            Invoke-WebRequest -Uri $avastClearUrl -OutFile $avastClearPath -UseBasicParsing `
                -TimeoutSec ((Get-KitConfig).downloadTimeoutSeconds) -ErrorAction Stop
            if (Test-Path $avastClearPath) {
                Write-KitLog -Message "Avast Clear téléchargé. Lancement en mode safe (peut nécessiter un reboot)..." -Level 'INFO'
                # /silent = pas d'UI ; note : Avast Clear peut demander un reboot pour finir
                Start-Process -FilePath $avastClearPath -ArgumentList '/silent' -Wait -ErrorAction SilentlyContinue
                Write-KitLog -Message "Avast Clear exécuté. Vérifier après reboot si besoin." -Level 'WARN'
            }
        }
        catch {
            Write-KitLog -Message "Impossible de télécharger Avast Clear (pas de réseau ?) : $_" -Level 'WARN'
            Write-KitLog -Message "Télécharger manuellement depuis https://www.avast.com/fr-fr/uninstall-utility et relancer." -Level 'WARN'
        }
    }
    elseif ($WhatIf) {
        Write-KitLog -Message "WHATIF: Aurait téléchargé et exécuté Avast Clear si résidus présents" -Level 'WHATIF'
    }
}

# ---------------------------------------------------------------------------
# Activation / renforcement Microsoft Defender
# ---------------------------------------------------------------------------
Write-KitLog -Message "Configuration de Microsoft Defender..." -Level 'INFO'

if ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait activé la protection en temps réel, cloud, et anti-PUA" -Level 'WHATIF'
    if (-not $SkipDefenderScan) {
        Write-KitLog -Message "WHATIF: Aurait mis à jour les signatures Defender et lancé un scan rapide" -Level 'WHATIF'
    }
    else {
        Write-KitLog -Message "WHATIF: Scan Defender ignoré (-SkipDefenderScan actif)" -Level 'WHATIF'
    }
}
else {
    # Un AV tiers actif (Kaspersky, etc.) fait passer Defender en mode PASSIF :
    # Set-MpPreference echoue alors avec 0x800106ba. C'est attendu, pas une erreur
    # du kit -> on rétrograde ces échecs en WARN quand un AV tiers est aux commandes.
    # Source unique : le diag du module 00 fait foi (query WMI intermittente
    # en session élevée, vu au run réel). Fallback : query directe si le
    # module est lancé seul, sans diagnostic préalable.
    # NOTE contrat (a) : ces deux fonctions retournent ,@(...) -> appel par
    # ASSIGNATION puis @($var) en expression. @(Get-ActiveThirdPartyAv) en
    # direct collecterait un tableau imbriqué (Count toujours 1, même vide) :
    # c'est le bug latent de l'ancien code, $defenderPassive était toujours vrai.
    $diagPath = Join-Path $PSScriptRoot "..\runtime\diagnostic-$env:COMPUTERNAME.json"
    $fromDiag = Get-DiagThirdPartyAv -DiagPath $diagPath
    if ($null -ne $fromDiag) {
        $activeThirdPartyAv = @($fromDiag)
    }
    else {
        $directAv = Get-ActiveThirdPartyAv
        $activeThirdPartyAv = @($directAv)
    }
    $defenderPassive    = $activeThirdPartyAv.Count -gt 0
    $failLevel          = if ($defenderPassive) { 'WARN' } else { 'ERROR' }
    if ($defenderPassive) {
        Write-KitLog -Message "AV tiers actif ($($activeThirdPartyAv -join ', ')) : Defender est en mode passif, sa configuration est ignorée par Windows (comportement normal)." -Level 'WARN'
    }

    try {
        # Protection en temps réel
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-KitLog -Message "Protection en temps réel : activée." -Level 'OK'

        # Protection cloud (MAPS)
        Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
        Write-KitLog -Message "Protection cloud (MAPS) : Advanced." -Level 'OK'

        # Anti-PUA (Potentially Unwanted Applications)
        Set-MpPreference -PUAProtection Enabled -ErrorAction SilentlyContinue
        Write-KitLog -Message "Protection anti-PUA : activée." -Level 'OK'

        # Vérification de l'état
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $rtStatus = $mpStatus.RealTimeProtectionEnabled
        Write-KitLog -Message "Vérification Defender : RealTimeProtection = $rtStatus" -Level $(if ($rtStatus) { 'OK' } else { $failLevel })

        if (-not $rtStatus -and -not $defenderPassive) {
            Write-KitLog -Message "ATTENTION : la protection temps réel n'a pas pu être activée. Vérifier manuellement." -Level 'ERROR'
        }
    }
    catch {
        if ($defenderPassive) {
            Write-KitLog -Message "Configuration Defender ignorée (mode passif car AV tiers actif) : $_" -Level 'WARN'
        }
        else {
            Write-KitLog -Message "Erreur lors de la configuration de Defender : $_" -Level 'ERROR'
            Write-KitLog -Message "Vérifier que le service WinDefend est actif (services.msc)." -Level 'WARN'
        }
    }

    # Mise à jour des signatures Defender avant le scan
    if (-not $SkipDefenderScan) {
        try {
            Write-KitLog -Message "Mise à jour des signatures Defender..." -Level 'INFO'
            Update-MpSignature -ErrorAction Stop
            Write-KitLog -Message "Signatures Defender à jour." -Level 'OK'
        }
        catch { Write-KitLog -Message "Mise à jour des signatures Defender échouée (poursuite du scan) : $($_.Exception.Message)" -Level 'WARN' }
    }

    # Quick scan avec attente du job et collecte des menaces détectées
    if (-not $SkipDefenderScan) {
        Write-KitLog -Message "Lancement du scan rapide Defender..." -Level 'INFO'
        $scanJob       = $null
        $scanStartTime = Get-Date
        try {
            $scanJob = Start-MpScan -ScanType QuickScan -AsJob -ErrorAction Stop
            $done = Wait-Job -Job $scanJob -Timeout 600
            if (-not $done) {
                Write-KitLog -Message "Scan Defender toujours en cours après 10 min - il se poursuit en arrière-plan." -Level 'WARN'
            }
            else {
                Write-KitLog -Message "Scan rapide Defender terminé." -Level 'OK'
                # Filtre sur InitialDetectionTime : ne WARN que sur les menaces
                # trouvées par CE scan, pas sur tout l'historique Defender.
                $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue |
                    Where-Object { $_.InitialDetectionTime -ge $scanStartTime })
                if ($threats.Count -gt 0) {
                    Write-KitLog -Message "Defender : $($threats.Count) détection(s) lors de ce scan. Vérifier l'historique de protection." -Level 'WARN'
                    foreach ($t in ($threats | Select-Object -First 10)) {
                        Write-KitLog -Message "  Menace détectée : $($t.ThreatID) (action $($t.CleanActionSuccess))" -Level 'WARN'
                    }
                }
                else {
                    Write-KitLog -Message "Scan Defender : aucune menace détectée." -Level 'OK'
                }
            }
        }
        catch {
            Write-KitLog -Message "Scan Defender non lancé : $($_.Exception.Message)" -Level 'WARN'
        }
        finally {
            # Nettoyage du job dans tous les cas (catch ou timeout)
            if ($null -ne $scanJob) {
                Remove-Job -Job $scanJob -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Write-KitLog -Message "Scan Defender ignoré (option -SkipDefenderScan)." -Level 'INFO'
    }
}

Write-KitLog -Message "=== 02-Antivirus : terminé ===" -Level 'OK'
exit 0
