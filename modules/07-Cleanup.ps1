# modules/07-Cleanup.ps1 - Nettoyage profond (temp, cache, DISM, SFC, défrag/TRIM)
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\07-Cleanup.ps1 [-WhatIf]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [switch]$EmptyRecycleBin,
    [switch]$RemoveWindowsOld,
    [switch]$CleanBrowserCache,
    [switch]$SkipRepair   # nettoyage rapide : saute DISM (peut durer 30-60 min) et SFC (reparation, pas nettoyage)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 07-Cleanup : début ===" -Level 'INFO'

$totalFreedBytes = 0

function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        return (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    }
    catch { return 0 }
}

function Remove-FolderContents {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-KitLog -Message "SKIP (absent) : $Label ($Path)" -Level 'INFO'
        return 0
    }
    $before = Get-FolderSizeBytes $Path
    if ($WhatIf) {
        $sizeMB = [math]::Round($before / 1MB, 1)
        Write-KitLog -Message "WHATIF: Vider $Label ($Path) - ~$sizeMB MB libérables" -Level 'WHATIF'
        return 0
    }
    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $after  = Get-FolderSizeBytes $Path
    $freed  = $before - $after
    $sizeMB = [math]::Round($freed / 1MB, 1)
    Write-KitLog -Message "OK : $Label vidé - $sizeMB MB libérés" -Level 'OK'
    return $freed
}

function Invoke-DismToFile {
    # DISM écrit sa progression (0..100%) via l'API console, exactement comme SFC. Lancé par la GUI
    # dans un process CreateNoWindow (sans console) et capturé par un pipe non drainé (`& DISM ... 2>&1`),
    # il peut se BLOQUER indéfiniment - même classe de bug que le gel SFC de ~1h30. On redirige la sortie
    # vers un FICHIER au niveau cmd : DISM bascule en sortie plate non-interactive, sans dépendance
    # console ni deadlock de pipe. On ne lit pas le fichier (seul le code retour sert), on le supprime.
    param([Parameter(Mandatory)][string]$Arguments)
    $log = Join-Path $env:TEMP ("dism-" + [Guid]::NewGuid().ToString('N') + ".log")
    try {
        & cmd.exe /c "DISM $Arguments > `"$log`" 2>&1"
        return $LASTEXITCODE
    }
    finally {
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 1. Fichiers temporaires
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 1. Fichiers temporaires ---" -Level 'INFO'
$totalFreedBytes += Remove-FolderContents $env:TEMP        'TEMP utilisateur'
$totalFreedBytes += Remove-FolderContents 'C:\Windows\Temp' 'Windows\Temp'
# Prefetch volontairement non vidé : pur cache géré par Windows (cap 128 entrées).
# Le vider ne gagne presque rien et ralentit le démarrage des apps 24-48h
# (reconstruction SuperFetch) - contre-productif pour un PC qu'on vient de "refresh".

# ---------------------------------------------------------------------------
# 2. Corbeille (confirmation obligatoire)
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 2. Corbeille ---" -Level 'INFO'
$proceed = $false
if ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait proposé de vider la corbeille (confirmation requise)" -Level 'WHATIF'
}
elseif ($EmptyRecycleBin) {
    $proceed = $true
}
elseif ($Unattended) {
    Write-KitLog -Message "Corbeille : ignorée (non demandée, mode non-interactif)." -Level 'INFO'
}
else {
    Write-Host ""
    Write-Host "[CONFIRMATION] Vider la corbeille ? Elle peut contenir des fichiers à récupérer." -ForegroundColor Yellow
    $answer = Read-Host "Vider la corbeille ? (O/N)"
    $proceed = ($answer -match '^[Oo]')
}
if ($proceed) {
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-KitLog -Message "Corbeille vidée." -Level 'OK'
    }
    catch {
        Write-KitLog -Message "Erreur vidage corbeille : $_" -Level 'WARN'
    }
}

# ---------------------------------------------------------------------------
# 3. Cache Windows Update
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 3. Cache Windows Update ---" -Level 'INFO'
$wuCachePath = 'C:\Windows\SoftwareDistribution\Download'
if ($WhatIf) {
    $sizeMB = [math]::Round((Get-FolderSizeBytes $wuCachePath) / 1MB, 1)
    Write-KitLog -Message "WHATIF: Arrêter wuauserv+bits, vider SoftwareDistribution\Download (~$sizeMB MB), redémarrer services" -Level 'WHATIF'
}
else {
    if (Test-WindowsUpdateBusy) {
        Write-KitLog -Message "Windows Update est en cours (téléchargement/installation)." -Level 'WARN'
        Write-KitLog -Message "Cache WU NON purgé pour ne pas couper une mise à jour. Relancer le module 07 plus tard." -Level 'WARN'
    }
    else {
        Write-KitLog -Message "Arrêt de wuauserv et bits..." -Level 'INFO'
        Stop-Service 'wuauserv' -Force -ErrorAction SilentlyContinue
        Stop-Service 'bits'     -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        $freed = Remove-FolderContents $wuCachePath 'Cache Windows Update'
        $totalFreedBytes += $freed

        Start-Service 'wuauserv' -ErrorAction SilentlyContinue
        Start-Service 'bits'     -ErrorAction SilentlyContinue
        Write-KitLog -Message "Services wuauserv et bits redémarrés." -Level 'OK'
    }
}

# ---------------------------------------------------------------------------
# 4. Windows.old (avec confirmation)
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 4. Windows.old ---" -Level 'INFO'
$winOldPath = 'C:\Windows.old'
if (Test-Path $winOldPath) {
    $sizeMB = [math]::Round((Get-FolderSizeBytes $winOldPath) / 1MB, 0)
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: Windows.old présent (~$sizeMB MB), suppression avec confirmation" -Level 'WHATIF'
    }
    else {
        $doWinOld = $false
        if ($RemoveWindowsOld) {
            $doWinOld = $true
        }
        elseif ($Unattended) {
            Write-KitLog -Message "Windows.old : conservé (non demandé, mode non-interactif)." -Level 'INFO'
        }
        else {
            Write-Host ""
            Write-Host "[CONFIRMATION] Windows.old détecté (~$sizeMB MB)." -ForegroundColor Yellow
            Write-Host "  Ce dossier permet un retour à la version Windows précédente." -ForegroundColor Yellow
            $answer = Read-Host "Supprimer Windows.old ? (O/N)"
            $doWinOld = ($answer -match '^[Oo]')
        }
        if ($doWinOld) {
            $freed = Remove-FolderContents $winOldPath 'Windows.old'
            $totalFreedBytes += $freed
        }
        else {
            Write-KitLog -Message "Windows.old : conservé." -Level 'INFO'
        }
    }
}
else {
    Write-KitLog -Message "Windows.old : absent, SKIP." -Level 'INFO'
}

# ---------------------------------------------------------------------------
# 5. DISM : StartComponentCleanup + RestoreHealth
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 5. DISM ---" -Level 'INFO'
if ($SkipRepair) {
    Write-KitLog -Message "DISM ignoré (-SkipRepair : nettoyage rapide, pas de compactage du store de composants)." -Level 'INFO'
}
elseif ($WhatIf) {
    Write-KitLog -Message "WHATIF: DISM /Online /Cleanup-Image /StartComponentCleanup puis /RestoreHealth" -Level 'WHATIF'
}
else {
    $freeC = Get-FreeSpaceGB -DriveLetter 'C'
    $minGB = 8
    if ($freeC -ge 0 -and $freeC -lt $minGB) {
        Write-KitLog -Message "DISM ignoré : espace libre C: insuffisant ($freeC Go < $minGB Go requis pour /RestoreHealth)." -Level 'WARN'
        Write-KitLog -Message "Libérer de l'espace (corbeille, gros fichiers) puis relancer le module 07." -Level 'WARN'
    }
    else {
        Write-KitLog -Message "DISM /StartComponentCleanup (peut prendre plusieurs minutes)..." -Level 'INFO'
        $dismRc1 = Invoke-DismToFile -Arguments '/Online /Cleanup-Image /StartComponentCleanup'
        Write-KitLog -Message "DISM StartComponentCleanup : code $dismRc1" -Level $(if ($dismRc1 -eq 0) { 'OK' } else { 'WARN' })

        # /RestoreHealth peut devoir télécharger depuis Windows Update : sans réseau,
        # il attend de longs timeouts avant d'échouer. SFC (section 6) répare déjà
        # depuis le store local, on saute donc /RestoreHealth hors-ligne.
        if (Test-InternetConnection) {
            Write-KitLog -Message "DISM /RestoreHealth (peut prendre plusieurs minutes)..." -Level 'INFO'
            $dismRc2 = Invoke-DismToFile -Arguments '/Online /Cleanup-Image /RestoreHealth'
            Write-KitLog -Message "DISM RestoreHealth : code $dismRc2" -Level $(if ($dismRc2 -eq 0) { 'OK' } else { 'WARN' })
        }
        else {
            Write-KitLog -Message "DISM /RestoreHealth ignoré : pas de connexion internet (SFC couvre la réparation locale). Relancer le module 07 connecté si besoin." -Level 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# 6. SFC /scannow
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 6. SFC /scannow ---" -Level 'INFO'
if ($SkipRepair) {
    Write-KitLog -Message "SFC ignoré (-SkipRepair : nettoyage rapide, pas de vérification d'intégrité)." -Level 'INFO'
}
elseif ($WhatIf) {
    Write-KitLog -Message "WHATIF: sfc /scannow" -Level 'WHATIF'
}
else {
    Write-KitLog -Message "SFC /scannow (peut prendre plusieurs minutes)..." -Level 'INFO'
    # IMPORTANT : SFC ecrit sa progression via l'API console. Lance par la GUI dans un process
    # CreateNoWindow (sans console) et capture par un pipe non draine, il se BLOQUE indefiniment
    # (gel observe ~1h30). On redirige la sortie vers un FICHIER au niveau cmd : SFC bascule alors
    # en mode non-interactif (sortie plate), sans dependance console ni deadlock de pipe.
    $sfcLog = Join-Path $env:TEMP ("sfc-" + [Guid]::NewGuid().ToString('N') + ".log")
    try {
        & cmd.exe /c "sfc /scannow > `"$sfcLog`" 2>&1"
        $sfcRc = $LASTEXITCODE
        # SFC ecrit en Unicode (UTF-16) : on lit en brut et on retire les octets nuls pour parser le verdict.
        $sfcRaw = if (Test-Path $sfcLog) { (Get-Content $sfcLog -Raw -ErrorAction SilentlyContinue) -replace "`0", "" } else { "" }
        $sfcVerdict = ($sfcRaw -split "`r?`n" | Where-Object { $_ -match 'found|aucun|trouv|Resource Protection|Protection des ressources' } | Select-Object -Last 1)
    }
    finally {
        Remove-Item $sfcLog -Force -ErrorAction SilentlyContinue
    }
    Write-KitLog -Message "SFC : code $sfcRc - $sfcVerdict" -Level $(if ($sfcRc -eq 0) { 'OK' } else { 'WARN' })
}

# ---------------------------------------------------------------------------
# 7. Disk Cleanup via cleanmgr /sagerun:1
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 7. Disk Cleanup ---" -Level 'INFO'
if ($WhatIf) {
    Write-KitLog -Message "WHATIF: cleanmgr /sageset:1 (pré-sélection) puis cleanmgr /sagerun:1" -Level 'WHATIF'
}
else {
    # Pré-configurer les handlers via le registre (sageset:1) silencieusement
    $cleanmgrKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $handlersToClean = @(
        'Active Setup Temp Folders',
        'BranchCache',
        'Downloaded Program Files',
        'Internet Cache Files',
        'Memory Dump Files',
        'Old ChkDsk Files',
        'Previous Installations',
        'Recycle Bin',
        'Service Pack Cleanup',
        'Setup Log Files',
        'System error memory dump files',
        'System error minidump files',
        'Temporary Files',
        'Temporary Setup Files',
        'Thumbnail Cache',
        'Update Cleanup',
        'Upgrade Discarded Files',
        'User file versions',
        'Windows Defender',
        'Windows Error Reporting Files'
    )
    foreach ($h in $handlersToClean) {
        $keyPath = "$cleanmgrKey\$h"
        if (Test-Path $keyPath) {
            Set-ItemProperty -Path $keyPath -Name 'StateFlags0001' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    $cleanmgrTimeoutMin = (Get-KitConfig).cleanmgrTimeoutMinutes
    Write-KitLog -Message "Lancement de Disk Cleanup (cleanmgr /sagerun:1, timeout $cleanmgrTimeoutMin min)..." -Level 'INFO'
    $cleanProc = Start-Process 'cleanmgr.exe' -ArgumentList '/sagerun:1' -PassThru -ErrorAction SilentlyContinue
    if ($cleanProc) {
        if ($cleanProc.WaitForExit($cleanmgrTimeoutMin * 60000)) {
            Write-KitLog -Message "Disk Cleanup terminé." -Level 'OK'
        }
        else {
            # cleanmgr peut geler indéfiniment sur un store de composants corrompu
            # (cas documenté). On l'arrête proprement : les StateFlags sont remis
            # à zéro juste après, le nettoyage restant est couvert par DISM.
            try { $cleanProc.Kill() } catch { }
            Write-KitLog -Message "Disk Cleanup bloqué après $cleanmgrTimeoutMin min : processus arrêté. Le reste du nettoyage continue (DISM couvre le nettoyage de composants)." -Level 'WARN'
        }
    }
    else {
        Write-KitLog -Message "Disk Cleanup n'a pas pu être lancé." -Level 'WARN'
    }

    # Remettre StateFlags0001 à 0 : ne pas laisser une config persistante qui ferait
    # qu'un futur 'cleanmgr /sagerun:1' (tâche planifiée, autre outil) vide la corbeille
    # ou les installations précédentes sans confirmation.
    foreach ($h in $handlersToClean) {
        $keyPath = "$cleanmgrKey\$h"
        if (Test-Path $keyPath) {
            Set-ItemProperty -Path $keyPath -Name 'StateFlags0001' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 8. Défrag / TRIM selon type de disque
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 8. Défrag / TRIM ---" -Level 'INFO'
$volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' }

foreach ($vol in $volumes) {
    $letter   = $vol.DriveLetter
    $diskType = Get-DiskType -DriveLetter $letter

    switch ($diskType) {
        'SSD' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: Optimize-Volume -DriveLetter $letter -ReTrim (SSD)" -Level 'WHATIF'
            }
            else {
                Write-KitLog -Message "TRIM sur ${letter}: (SSD)..." -Level 'INFO'
                try {
                    Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop
                    Write-KitLog -Message "TRIM ${letter}: OK" -Level 'OK'
                }
                catch { Write-KitLog -Message "TRIM ${letter}: $_ (non bloquant)" -Level 'WARN' }
            }
        }
        'HDD' {
            if ($WhatIf) {
                Write-KitLog -Message "WHATIF: Optimize-Volume -DriveLetter $letter -Defrag (HDD)" -Level 'WHATIF'
            }
            else {
                Write-KitLog -Message "Défragmentation de ${letter}: (HDD)..." -Level 'INFO'
                try {
                    Optimize-Volume -DriveLetter $letter -Defrag -ErrorAction Stop
                    Write-KitLog -Message "Défrag ${letter}: OK" -Level 'OK'
                }
                catch { Write-KitLog -Message "Défrag ${letter}: $_ (non bloquant)" -Level 'WARN' }
            }
        }
        default {
            Write-KitLog -Message "Type de disque ${letter}: inconnu ($diskType) - Défrag/TRIM ignoré (sécurité)." -Level 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# 9. Caches navigateurs (optionnel, confirmation requise)
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 9. Caches navigateurs (optionnel) ---" -Level 'INFO'
$browserCaches = @()
$chromiumRoots = @(
    @{ Name = 'Chrome'; Root = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' },
    @{ Name = 'Edge';   Root = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' }
)
foreach ($cr in $chromiumRoots) {
    if (-not (Test-Path $cr.Root)) { continue }
    Get-ChildItem -Path $cr.Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            $cache = Join-Path $_.FullName 'Cache'
            if (Test-Path $cache) {
                $browserCaches += @{ Name = "$($cr.Name) ($($_.Name))"; Path = $cache }
            }
        }
}
# Firefox : un dossier cache2 par profil (ne pas cibler Profiles\ entier qui contient les données)
$ffProfilesRoot = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path $ffProfilesRoot) {
    Get-ChildItem -Path $ffProfilesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $cache2 = Join-Path $_.FullName 'cache2'
        if (Test-Path $cache2) {
            $browserCaches += @{ Name = "Firefox ($($_.Name))"; Path = $cache2 }
        }
    }
}

if ($WhatIf) {
    foreach ($b in $browserCaches) {
        if (Test-Path $b.Path) {
            $sizeMB = [math]::Round((Get-FolderSizeBytes $b.Path) / 1MB, 1)
            Write-KitLog -Message "WHATIF (optionnel): Cache $($b.Name) - $sizeMB MB" -Level 'WHATIF'
        }
    }
}
else {
    $anyCacheFound = $browserCaches | Where-Object { Test-Path $_.Path }
    if ($anyCacheFound) {
        $doCache = $false
        if ($CleanBrowserCache) {
            $doCache = $true
        }
        elseif ($Unattended) {
            Write-KitLog -Message "Caches navigateurs : ignorés (non demandés, mode non-interactif)." -Level 'INFO'
        }
        else {
            Write-Host ""
            Write-Host "[OPTIONNEL] Vider les caches navigateurs ?" -ForegroundColor Cyan
            Write-Host "  Attention : efface les sessions sauvegardées et l'historique de navigation local." -ForegroundColor Yellow
            $answer = Read-Host "Vider les caches ? (O/N, défaut N)"
            $doCache = ($answer -match '^[Oo]')
        }
        if ($doCache) {
            foreach ($b in $browserCaches) {
                if (Test-Path $b.Path) {
                    $freed = Remove-FolderContents $b.Path "Cache $($b.Name)"
                    $totalFreedBytes += $freed
                }
            }
        }
        else {
            Write-KitLog -Message "Caches navigateurs : ignorés." -Level 'INFO'
        }
    }
}

# ---------------------------------------------------------------------------
# Bilan
# ---------------------------------------------------------------------------
$totalMB = [math]::Round($totalFreedBytes / 1MB, 1)
Write-KitLog -Message "Espace total libéré par ce module : ~$totalMB MB" -Level 'OK'
Write-KitLog -Message "=== 07-Cleanup : terminé ===" -Level 'OK'
exit 0
