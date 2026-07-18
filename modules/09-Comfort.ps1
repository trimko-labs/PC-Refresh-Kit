# modules/09-Comfort.ps1 - Réglages de confort (OneDrive, extensions, alimentation, suggestions)
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\09-Comfort.ps1 [-WhatIf]

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [switch]$RemoveOneDrive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 09-Comfort : début ===" -Level 'INFO'

# ---------------------------------------------------------------------------
# 1. OneDrive : géré UNIQUEMENT si explicitement demandé (case GUI -> -RemoveOneDrive)
#    Décoché = le kit ne touche A RIEN (process, démarrage, sync, notifications).
#    Coché   = arrêt + désinstallation + blocage durable (résiste aux MAJ) + coupure des rappels.
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 1. OneDrive ---" -Level 'INFO'

if (-not $RemoveOneDrive) {
    Write-KitLog -Message "OneDrive : option non cochée - le kit ne touche pas à OneDrive (process, démarrage, sync, notifications)." -Level 'INFO'
}
elseif ($WhatIf) {
    Write-KitLog -Message "WHATIF: arrêterait le process OneDrive + le retirerait du démarrage auto (HKCU Run)" -Level 'WHATIF'
    Write-KitLog -Message "WHATIF: désinstallerait OneDrive via OneDriveSetup.exe /uninstall si présent" -Level 'WHATIF'
    Write-KitLog -Message "WHATIF: poserait la stratégie DisableFileSyncNGSC=1 (bloque OneDrive durablement, résiste aux mises à jour)" -Level 'WHATIF'
    Write-KitLog -Message "WHATIF: ShowSyncProviderNotifications=0 (coupe les rappels/pubs OneDrive de l'Explorateur) + retrait du volet de navigation" -Level 'WHATIF'
}
else {
    $oneDriveSetup = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    # Arrêter le process OneDrive si en cours
    $odProcess = Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue
    if ($odProcess) {
        Stop-Process -Name 'OneDrive' -Force -ErrorAction SilentlyContinue
        Write-KitLog -Message "Process OneDrive arrêté." -Level 'OK'
    }
    else {
        Write-KitLog -Message "Process OneDrive : non actif." -Level 'INFO'
    }

    # Retirer du démarrage automatique (HKCU Run)
    $oneDriveRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runProps = Get-ItemProperty -Path $oneDriveRunKey -ErrorAction SilentlyContinue
    if ($runProps -and $runProps.PSObject.Properties['OneDrive']) {
        Remove-ItemProperty -Path $oneDriveRunKey -Name 'OneDrive' -ErrorAction SilentlyContinue
        Write-KitLog -Message "OneDrive retiré du démarrage automatique (HKCU Run)." -Level 'OK'
    }

    # Désinstallation complète
    if ($oneDriveSetup) {
        Write-KitLog -Message "Désinstallation de OneDrive ($oneDriveSetup)..." -Level 'INFO'
        Start-Process $oneDriveSetup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
        Write-KitLog -Message "OneDrive désinstallé." -Level 'OK'
    }
    else {
        Write-KitLog -Message "OneDriveSetup.exe introuvable - OneDrive absent ou déjà désinstallé." -Level 'INFO'
    }

    # Persistance : stratégie qui empêche OneDrive de revenir (résiste aux mises à jour Windows et aux réinstallations).
    $odPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
    try {
        if (-not (Test-Path $odPolicyKey)) { New-Item -Path $odPolicyKey -Force | Out-Null }
        Set-ItemProperty -Path $odPolicyKey -Name 'DisableFileSyncNGSC' -Value 1 -Type DWord -Force
        Write-KitLog -Message "Stratégie DisableFileSyncNGSC=1 posée : OneDrive bloqué durablement (résiste aux mises à jour)." -Level 'OK'
    }
    catch { Write-KitLog -Message "Échec pose stratégie OneDrive : $_" -Level 'WARN' }

    # Couper les rappels / notifications natifs (pubs OneDrive du fournisseur de synchronisation dans l'Explorateur)
    $explorerAdv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if (Test-Path $explorerAdv) {
        Set-ItemProperty -Path $explorerAdv -Name 'ShowSyncProviderNotifications' -Value 0 -Type DWord -Force
        Write-KitLog -Message "Notifications de fournisseur de synchronisation (rappels OneDrive de l'Explorateur) désactivées." -Level 'OK'
    }

    # Retirer OneDrive du volet de navigation de l'Explorateur
    foreach ($clsid in @(
        'HKCU:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
        'HKCU:\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    )) {
        try {
            if (-not (Test-Path $clsid)) { New-Item -Path $clsid -Force | Out-Null }
            Set-ItemProperty -Path $clsid -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord -Force
        }
        catch { Write-KitLog -Message "OneDrive volet Explorateur ($clsid) : $_" -Level 'WARN' }
    }
    Write-KitLog -Message "OneDrive retiré du volet de navigation de l'Explorateur." -Level 'OK'
    Write-KitLog -Message "Pour réactiver OneDrive plus tard : supprimer DisableFileSyncNGSC sous $odPolicyKey, puis réinstaller OneDrive." -Level 'INFO'
}

# ---------------------------------------------------------------------------
# 2. Explorateur : afficher les extensions de fichiers
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 2. Extensions de fichiers ---" -Level 'INFO'
$explorerAdvKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

if ($WhatIf) {
    Write-KitLog -Message "WHATIF: HideFileExt = 0 (HKCU Explorer\Advanced)" -Level 'WHATIF'
}
else {
    $currentHide = (Get-ItemProperty -Path $explorerAdvKey -Name 'HideFileExt' -ErrorAction SilentlyContinue).HideFileExt
    if ($currentHide -eq 0) {
        Write-KitLog -Message "Extensions de fichiers : déjà visibles (SKIP)." -Level 'OK'
    }
    else {
        Set-ItemProperty -Path $explorerAdvKey -Name 'HideFileExt' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-KitLog -Message "Extensions de fichiers : rendues visibles." -Level 'OK'

        if ($Unattended) {
            # En run automatisé, ne pas tuer le shell : le réglage s'applique au prochain logon.
            Write-KitLog -Message "Extensions visibles au prochain logon (explorateur non redémarré en mode automatique)." -Level 'INFO'
        }
        else {
            # Redémarrer l'explorateur pour que le changement soit visible immédiatement
            Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-Process 'explorer.exe' -ErrorAction SilentlyContinue
            Write-KitLog -Message "Explorateur redémarré pour appliquer le changement." -Level 'OK'
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Plan d'alimentation : Équilibre
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 3. Plan d'alimentation ---" -Level 'INFO'

if ($WhatIf) {
    Write-KitLog -Message "WHATIF: powercfg /setactive SCHEME_BALANCED" -Level 'WHATIF'
}
else {
    # SCHEME_BALANCED est l'alias générique du plan équilibré
    $powerOut = & powercfg /setactive SCHEME_BALANCED 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-KitLog -Message "Plan d'alimentation : Équilibre activé." -Level 'OK'
    }
    else {
        Write-KitLog -Message "powercfg SCHEME_BALANCED : code $LASTEXITCODE. Essai via GUID..." -Level 'WARN'
        # GUID universel du plan équilibré Windows
        $balancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
        $powerOut2 = & powercfg /setactive $balancedGuid 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-KitLog -Message "Plan d'alimentation Équilibre activé via GUID." -Level 'OK'
        }
        else {
            Write-KitLog -Message "powercfg : impossible d'activer le plan équilibré (code $LASTEXITCODE). Vérifier manuellement." -Level 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Suggestions, publicités et apps silencieuses (ContentDeliveryManager)
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- 4. Suggestions et publicités ---" -Level 'INFO'
$cdmKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

$cdmSettings = @{
    'SystemPaneSuggestionsEnabled'     = 0  # suggestions dans le volet système Start
    'SubscribedContent-338388Enabled'  = 0  # apps suggérées dans Start
    'SubscribedContent-338389Enabled'  = 0  # conseils Windows dans Start
    'SubscribedContent-353698Enabled'  = 0  # suggestions dans la timeline
    'SubscribedContent-338387Enabled'  = 0  # Spotlight écran de verrouillage
    'RotatingLockScreenOverlayEnabled' = 0  # faits divers sur écran de verrouillage
    'SoftLandingEnabled'               = 0  # bulles de conseil Windows
    'OemPreInstalledAppsEnabled'       = 0  # apps OEM silencieuses
    'PreInstalledAppsEnabled'          = 0  # apps MS silencieuses
    'PreInstalledAppsEverEnabled'      = 0
    'SilentInstalledAppsEnabled'       = 0  # réinstallation silencieuse d'apps suggérées
}

if ($WhatIf) {
    foreach ($k in $cdmSettings.Keys) {
        Write-KitLog -Message "WHATIF: ContentDeliveryManager\$k = 0" -Level 'WHATIF'
    }
    Write-KitLog -Message "WHATIF: ShowSyncProviderNotifications = 0 (Explorer\Advanced)" -Level 'WHATIF'
}
else {
    if (-not (Test-Path $cdmKey)) { New-Item -Path $cdmKey -Force | Out-Null }

    $applied = 0
    foreach ($k in $cdmSettings.Keys) {
        $current = (Get-ItemProperty -Path $cdmKey -Name $k -ErrorAction SilentlyContinue).$k
        if ($current -ne $cdmSettings[$k]) {
            Set-ItemProperty -Path $cdmKey -Name $k -Value $cdmSettings[$k] -Type DWord -Force -ErrorAction SilentlyContinue
            $applied++
        }
    }
    Write-KitLog -Message "ContentDeliveryManager : $applied réglage(s) modifié(s) (0 = déjà OK)." -Level 'OK'

    # Annonces de sync dans l'explorateur (pubs OneDrive dans la barre d'adresse)
    $syncNotif = (Get-ItemProperty -Path $explorerAdvKey -Name 'ShowSyncProviderNotifications' -ErrorAction SilentlyContinue).ShowSyncProviderNotifications
    if ($syncNotif -ne 0) {
        Set-ItemProperty -Path $explorerAdvKey -Name 'ShowSyncProviderNotifications' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-KitLog -Message "Annonces OneDrive dans explorateur : désactivées." -Level 'OK'
    }
    else {
        Write-KitLog -Message "Annonces OneDrive dans explorateur : déjà désactivées (SKIP)." -Level 'OK'
    }
}

Write-KitLog -Message "=== 09-Comfort : terminé ===" -Level 'OK'
exit 0
