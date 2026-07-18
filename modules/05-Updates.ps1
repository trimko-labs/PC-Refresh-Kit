# modules/05-Updates.ps1 - Windows Update (COM natif) + winget upgrade
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\05-Updates.ps1 [-WhatIf]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 05-Updates : début ===" -Level 'INFO'

if (-not (Test-InternetConnection)) {
    Write-KitLog -Message "Pas de connexion Internet. Windows Update et winget ignorés." -Level 'WARN'
    Write-KitLog -Message "Relancer le module 05 une fois le PC connecté." -Level 'WARN'
    Write-KitLog -Message "=== 05-Updates : terminé (hors-ligne) ===" -Level 'WARN'
    exit 0
}

# ---------------------------------------------------------------------------
# Windows Update via COM natif (zéro dépendance externe), dans un JOB avec
# timeout : Search() peut geler 30-60 min sur un service WU en mauvais état.
# Timeout recherche : 10 min (cas pathologique classique) ; étendu à 60 min
# une fois la recherche terminée (téléchargements volumineux = normal).
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Windows Update ---" -Level 'INFO'

$kitCfg  = Get-KitConfig
$wuBlock = {
    param([bool]$IsWhatIf)
    function Send-Log { param([string]$Level, [string]$Message) Write-Output "KITLOG|$Level|$Message" }
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        Send-Log 'INFO' 'Recherche des mises à jour disponibles...'

        $result  = $searcher.Search('IsInstalled=0 and Type=''Software'' and IsHidden=0')
        Write-Output 'KITPHASE|SEARCH_DONE'
        $updates = $result.Updates
        $count   = $updates.Count

        Send-Log $(if ($count -gt 0) { 'WARN' } else { 'OK' }) "$count mise(s) à jour trouvée(s)."

        if ($count -eq 0) {
            Send-Log 'OK' 'Système à jour.'
        }
        elseif ($IsWhatIf) {
            Send-Log 'WHATIF' 'WHATIF: Liste des mises à jour disponibles :'
            for ($i = 0; $i -lt $count; $i++) {
                $upd = $updates.Item($i)
                Send-Log 'WHATIF' "  [$i] $($upd.Title) ($([math]::Round($upd.MaxDownloadSize / 1MB, 1)) MB)"
            }
        }
        else {
            for ($i = 0; $i -lt $count; $i++) {
                $upd = $updates.Item($i)
                Send-Log 'INFO' "  Disponible : $($upd.Title)"
            }
            for ($i = 0; $i -lt $count; $i++) {
                $upd = $updates.Item($i)
                if ($upd.EulaAccepted -eq $false) { $upd.AcceptEula() }
            }

            Send-Log 'INFO' "Téléchargement des $count mise(s) à jour..."
            $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
            for ($i = 0; $i -lt $count; $i++) {
                $toDownload.Add($updates.Item($i)) | Out-Null
            }
            $downloader         = $session.CreateUpdateDownloader()
            $downloader.Updates = $toDownload
            $downloadResult     = $downloader.Download()
            Send-Log 'INFO' "Téléchargement terminé (code : $($downloadResult.ResultCode))"

            Send-Log 'INFO' 'Installation des mises à jour...'
            $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            for ($i = 0; $i -lt $count; $i++) {
                $upd = $updates.Item($i)
                if ($upd.IsDownloaded) { $toInstall.Add($upd) | Out-Null }
            }

            if ($toInstall.Count -eq 0) {
                Send-Log 'WARN' 'Aucune update téléchargée avec succès. Vérifier la connexion réseau.'
            }
            else {
                $installer         = $session.CreateUpdateInstaller()
                $installer.Updates = $toInstall
                $installResult     = $installer.Install()

                $rc = $installResult.ResultCode
                Send-Log $(if ($rc -eq 2) { 'OK' } else { 'WARN' }) "Installation terminée (code : $rc)"

                $successCount = 0
                $failCount    = 0
                for ($i = 0; $i -lt $toInstall.Count; $i++) {
                    $upd   = $toInstall.Item($i)
                    $updRc = $installResult.GetUpdateResult($i).ResultCode
                    if ($updRc -eq 2) {
                        Send-Log 'OK' "  OK  : $($upd.Title)"
                        $successCount++
                    }
                    else {
                        Send-Log 'WARN' "  ERR : $($upd.Title) (code $updRc)"
                        $failCount++
                    }
                }
                Send-Log $(if ($failCount -eq 0) { 'OK' } else { 'WARN' }) "Bilan : $successCount installée(s), $failCount échec(s)."

                if ($installResult.RebootRequired) {
                    Send-Log 'WARN' 'REBOOT REQUIS pour finaliser les mises à jour. Ne pas redémarrer maintenant - le kit continue.'
                }
            }
        }
    }
    catch {
        Send-Log 'ERROR' "Erreur lors de Windows Update : $_"
        Send-Log 'WARN' 'Vérifier que le service wuauserv est actif.'
    }
}

try {
    $wuJob      = Start-Job -ScriptBlock $wuBlock -ArgumentList ([bool]$WhatIf)
    $deadline   = (Get-Date).AddMinutes($kitCfg.wuSearchTimeoutMinutes)
    $searchDone = $false

    while ($wuJob.State -eq 'Running' -and (Get-Date) -lt $deadline) {
        foreach ($line in @(Receive-Job -Job $wuJob)) {
            $parsed = ConvertFrom-JobLogLine -Line ([string]$line)
            if ($null -eq $parsed) { continue }
            if ($parsed.Kind -eq 'PHASE' -and $parsed.Message -eq 'SEARCH_DONE' -and -not $searchDone) {
                $searchDone = $true
                $deadline   = (Get-Date).AddMinutes($kitCfg.wuInstallTimeoutMinutes)
            }
            elseif ($parsed.Kind -eq 'LOG') {
                Write-KitLog -Message $parsed.Message -Level $parsed.Level
            }
        }
        Start-Sleep -Seconds 3
    }

    # Drainer les derniers messages du job
    foreach ($line in @(Receive-Job -Job $wuJob)) {
        $parsed = ConvertFrom-JobLogLine -Line ([string]$line)
        if ($parsed -and $parsed.Kind -eq 'LOG') {
            Write-KitLog -Message $parsed.Message -Level $parsed.Level
        }
    }

    if ($wuJob.State -eq 'Running') {
        Stop-Job -Job $wuJob -ErrorAction SilentlyContinue
        if ($searchDone) {
            Write-KitLog -Message "Windows Update interrompu après $($kitCfg.wuInstallTimeoutMinutes) min (téléchargement/installation trop longs). WU est transactionnel : laisser Windows Update se stabiliser au prochain redémarrage." -Level 'WARN'
        }
        else {
            Write-KitLog -Message "Recherche Windows Update bloquée plus de $($kitCfg.wuSearchTimeoutMinutes) min : service wuauserv probablement en mauvais état. On passe à winget." -Level 'WARN'
        }
    }
}
catch {
    Write-KitLog -Message "Erreur lors de Windows Update : $_" -Level 'ERROR'
    Write-KitLog -Message "Vérifier que le service wuauserv est actif." -Level 'WARN'
}
finally {
    # Garde Get-Variable : si Start-Job a levé, $wuJob n'existe pas et
    # StrictMode lèverait dans le finally.
    if (Get-Variable -Name 'wuJob' -ErrorAction SilentlyContinue) {
        Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# winget upgrade --all
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- winget upgrade ---" -Level 'INFO'

if (-not (Test-WingetAvailable)) {
    Write-KitLog -Message "winget non disponible. SKIP winget upgrade." -Level 'WARN'
    Write-KitLog -Message (Get-WingetAbsentAdvice -IsWin11 (Get-MachineInfo).IsWin11) -Level 'WARN'
}
elseif ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait lancé : winget upgrade --all --silent --accept-source-agreements --accept-package-agreements" -Level 'WHATIF'
    # En WhatIf, on liste quand même ce qui serait mis à jour
    Write-KitLog -Message "Listing des mises à jour winget disponibles..." -Level 'INFO'
    & winget upgrade 2>&1 | ForEach-Object { Write-KitLog -Message "  $_" -Level 'WHATIF' }
}
else {
    Write-KitLog -Message "Lancement de winget upgrade --all..." -Level 'INFO'

    $wingetRc = -1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-KitLog -Message "Tentative $attempt/3 de winget upgrade..." -Level 'INFO'

        $wingetResult = & winget upgrade --all --silent --accept-source-agreements --accept-package-agreements 2>&1
        $wingetRc     = $LASTEXITCODE

        if ($wingetRc -eq 0) {
            Write-KitLog -Message "winget upgrade --all réussi (tentative $attempt)." -Level 'OK'
            $wingetResult | ForEach-Object { Write-KitLog -Message "  $_" -Level 'INFO' }
            break
        }
        elseif (Test-WingetRetryableExitCode -ExitCode $wingetRc) {
            Write-KitLog -Message "winget : confirmation interactive requise en mode silencieux, nouvelle tentative..." -Level 'WARN'
            Start-Sleep -Seconds 2
        }
        else {
            Write-KitLog -Message "winget upgrade --all erreur code $wingetRc." -Level 'WARN'
            $wingetResult | ForEach-Object { Write-KitLog -Message "  $_" -Level 'WARN' }
            break
        }
    }

    if ($wingetRc -ne 0) {
        Write-KitLog -Message "winget upgrade --all terminé avec code $wingetRc après 3 tentatives." -Level 'WARN'
        Write-KitLog -Message "Vous pouvez relancer manuellement : winget upgrade --all --silent" -Level 'INFO'
    }
}

Write-KitLog -Message "=== 05-Updates : terminé ===" -Level 'OK'
exit 0
