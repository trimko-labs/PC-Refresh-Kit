# modules/01-Backup.ps1 - Point de restauration système + backup data léger
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\01-Backup.ps1 [-WhatIf] [-Force] [-SkipDataBackup]
<#
.SYNOPSIS
    Crée un point de restauration système et optionnellement sauvegarde les données utilisateur.

.PARAMETER SkipDataBackup
    Si $true, saute la sauvegarde des données utilisateur (robocopy).
    Le point de restauration système est TOUJOURS créé.

.PARAMETER Unattended
    Mode non-interactif (utilisé par la GUI pour -All).

.EXAMPLE
    & ".\01-Backup.ps1" -WhatIf
    & ".\01-Backup.ps1" -SkipDataBackup
    & ".\01-Backup.ps1" -Unattended -SkipDataBackup
#>

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [switch]$SkipDataBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 01-Backup : début ===" -Level 'INFO'

# Code de retour : 0 = OK ou skip, 1 = échec point de restauration (Run.ps1 demandera confirmation)
$exitCode = 0

# ---------------------------------------------------------------------------
# Point de restauration système
# ---------------------------------------------------------------------------
Write-KitLog -Message "Création du point de restauration système..." -Level 'INFO'

# Relance dans la même session d'intervention ? Un point du kit de moins de
# 4 h suffit : on ne recrée pas (vu au run réel : 3 points identiques/jour).
$maxAgeH     = (Get-KitConfig).restorePointMaxAgeHours
$recentPoint = $false
try {
    $points = @()
    foreach ($rp in @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)) {
        $points += [PSCustomObject]@{
            Description  = [string]$rp.Description
            CreationTime = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$rp.CreationTime)
        }
    }
    $recentPoint = Test-HasRecentKitRestorePoint -Points $points -Now (Get-Date) -MaxAgeHours $maxAgeH
}
catch { $recentPoint = $false }

if ($recentPoint) {
    Write-KitLog -Message "Point de restauration du kit de moins de $maxAgeH h déjà présent : création ignorée." -Level 'OK'
}
elseif ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait activé la restauration sur C: et créé un point 'PC-Refresh-Kit avant intervention'" -Level 'WHATIF'
}
else {
    try {
        # Contourner la limite fréquence Windows (1/24h par défaut)
        $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $prevFreq = (Get-ItemProperty -Path $regKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-ItemProperty -Path $regKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -Force

        Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
        Checkpoint-Computer -Description 'PC-Refresh-Kit avant intervention' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-KitLog -Message "Point de restauration créé avec succès." -Level 'OK'

        # Restaurer la valeur précédente
        if ($null -ne $prevFreq) {
            Set-ItemProperty -Path $regKey -Name 'SystemRestorePointCreationFrequency' -Value $prevFreq -Type DWord -Force
        }
        else {
            Remove-ItemProperty -Path $regKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-KitLog -Message "ERREUR lors de la création du point de restauration : $_" -Level 'ERROR'
        $exitCode = 1
    }
}

# ---------------------------------------------------------------------------
# Backup data léger (D7) - seulement si disque externe détecté
# ---------------------------------------------------------------------------
Write-KitLog -Message "Recherche d'un disque externe pour le backup data..." -Level 'INFO'

$externalVolumes = @(Get-KitExternalBackupVolumes)
# Tri : un disque amovible (clé USB) passe avant une partition fixe (D: interne)
# pour ne pas écrire le backup sur le même disque physique que les données.
# Détection partagée avec le cockpit (indicateur de filet) : lib/Common.ps1.

if ($externalVolumes.Count -eq 0) {
    Write-KitLog -Message "Pas de disque externe détecté. Backup data ignoré (non bloquant)." -Level 'WARN'
    Write-KitLog -Message "Le kit est non-destructif, on continue sans backup." -Level 'INFO'
}
elseif ($SkipDataBackup) {
    Write-KitLog -Message "Backup data ignoré (mode -SkipDataBackup)" -Level 'INFO'
}
else {
    $targetVolume = $externalVolumes[0]
    $targetDrive  = "$($targetVolume.DriveLetter):"
    Write-KitLog -Message "Disque cible pour le backup : $targetDrive [$($targetVolume.DriveType)] ($([math]::Round($targetVolume.SizeRemaining / 1GB, 1)) Go libres)" -Level 'INFO'
    if ($targetVolume.DriveType -ne 'Removable') {
        Write-KitLog -Message "ATTENTION : $targetDrive n'est pas un disque amovible. Si c'est une partition interne, le backup n'est PAS sur un support externe. Vérifier visuellement avant de continuer." -Level 'WARN'
    }

    # Dossiers sources : résolus via la redirection des dossiers connus
    # (OneDrive KFM). Voir Get-BackupSourceFolders dans lib/Common.ps1.
    $sourceFolders = @(Get-BackupSourceFolders)
    Write-KitLog -Message "Dossiers sources résolus ($($sourceFolders.Count)) :" -Level 'INFO'
    foreach ($src in $sourceFolders) {
        Write-KitLog -Message "  > $src" -Level 'INFO'
    }
    # Garde-fou OneDrive : un dossier résolu vide alors qu'un dossier OneDrive
    # existe dans le profil peut signaler une redirection non suivie.
    $oneDrivePresent = @(Get-ChildItem -Path $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue).Count -gt 0
    if ($oneDrivePresent) {
        foreach ($src in $sourceFolders) {
            $hasFile = @(Get-ChildItem -Path $src -File -Recurse -ErrorAction SilentlyContinue |
                         Select-Object -First 1).Count -gt 0
            if (-not $hasFile) {
                Write-KitLog -Message "ATTENTION : '$src' ne contient aucun fichier alors qu'OneDrive est présent sur ce profil. Vérifier que les vraies données sont couvertes par la liste ci-dessus." -Level 'WARN'
            }
        }
    }

    # Estimation taille totale des sources
    Write-KitLog -Message "Estimation de la taille des dossiers sources..." -Level 'INFO'
    $totalBytes = 0
    foreach ($src in $sourceFolders) {
        try {
            $size = (Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -ne $size) { $totalBytes += $size }
        }
        catch { <# ignorer les erreurs d'accès #> }
    }
    $totalGB   = [math]::Round($totalBytes / 1GB, 2)
    $freeBytes = $targetVolume.SizeRemaining
    $marginBytes = $totalBytes * 0.1   # marge de 10%

    Write-KitLog -Message "Taille estimée à copier : $totalGB Go | Espace libre cible : $([math]::Round($freeBytes / 1GB, 1)) Go" -Level 'INFO'

    if ($freeBytes -lt ($totalBytes + $marginBytes)) {
        $deficitGB = [math]::Round(($totalBytes + $marginBytes - $freeBytes) / 1GB, 2)
        Write-KitLog -Message "ERREUR: Espace insuffisant sur $targetDrive (déficit estimé : $deficitGB Go)." -Level 'ERROR'
        Write-KitLog -Message "  Requis : $totalGB Go | Disponible : $([math]::Round($freeBytes / 1GB, 1)) Go" -Level 'ERROR'

        if ($WhatIf) {
            Write-KitLog -Message "WHATIF: Aurait arrêté l'exécution (espace insuffisant)" -Level 'WHATIF'
        }
        else {
            Write-KitLog -Message "Vide le disque externe et relance le kit." -Level 'ERROR'
            Write-KitLog -Message "=== 01-Backup : terminé ===" -Level 'OK'
            exit 1
        }
    }

    # Destination
    $dateStr  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destRoot = Join-Path $targetDrive "PCRefresh-Backup-$env:COMPUTERNAME-$dateStr"

    foreach ($src in $sourceFolders) {
        $folderName = Split-Path $src -Leaf
        $dest       = Join-Path $destRoot $folderName

        if ($WhatIf) {
            Write-KitLog -Message "WHATIF: robocopy '$src' '$dest' /E /XJ /R:1 /W:1 /MT:8 (copie additive)" -Level 'WHATIF'
        }
        else {
            Write-KitLog -Message "Copie de $folderName -> $dest" -Level 'INFO'
            $roboArgs = @($src, $dest, '/E', '/XJ', '/R:1', '/W:1', '/MT:8', '/NFL', '/NDL', '/NP')
            $roboResult = & robocopy @roboArgs
            $rc = $LASTEXITCODE
            # robocopy : codes < 8 = succès (0=aucune modif, 1=copie OK, 2=extra, 4=mismatch, 7=mix)
            if ($rc -lt 8) {
                Write-KitLog -Message "$folderName copié avec succès (code robocopy : $rc)" -Level 'OK'
            }
            else {
                Write-KitLog -Message "ERREUR robocopy pour $folderName (code : $rc)" -Level 'ERROR'
            }
        }
    }

    if (-not $WhatIf) {
        Write-KitLog -Message "Backup data terminé dans : $destRoot" -Level 'OK'
    }
}

Write-KitLog -Message "=== 01-Backup : terminé ===" -Level 'OK'
exit $exitCode
