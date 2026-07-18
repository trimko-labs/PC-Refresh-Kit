# modules/00-Diagnostic.ps1 - Lecture des informations du PC (zéro modification)
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\00-Diagnostic.ps1

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

$runtimeDir = Join-Path $PSScriptRoot '..\runtime'
if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }
$kitCfg = Get-KitConfig

Write-KitLog -Message "=== 00-Diagnostic : début ===" -Level 'INFO'

# ---------------------------------------------------------------------------
# Infos machine de base
# ---------------------------------------------------------------------------
Write-KitLog -Message "Collecte des informations système..." -Level 'INFO'
$machine = Get-MachineInfo
Write-KitLog -Message "Fabricant   : $($machine.Manufacturer)" -Level 'INFO'
Write-KitLog -Message "Modèle      : $($machine.Model)" -Level 'INFO'
Write-KitLog -Message "N/S BIOS    : $($machine.BiosSerial)" -Level 'INFO'
Write-KitLog -Message "OS          : $($machine.OSCaption)" -Level 'INFO'
Write-KitLog -Message "Build       : $($machine.OSBuild)" -Level 'INFO'
Write-KitLog -Message "Windows 11  : $($machine.IsWin11)" -Level 'INFO'

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-KitLog -Message "CPU         : $($cpu.Name) ($($cpu.NumberOfCores) coeurs, $($cpu.NumberOfLogicalProcessors) logiques)" -Level 'INFO'

# ---------------------------------------------------------------------------
# RAM
# ---------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$ramTotalGB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$ramLibreGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
Write-KitLog -Message "RAM         : $ramTotalGB Go totaux, $ramLibreGB Go libres" -Level 'INFO'

# ---------------------------------------------------------------------------
# Disques : type SSD/HDD, espace libre, santé SMART
# ---------------------------------------------------------------------------
Write-KitLog -Message "Analyse des disques..." -Level 'INFO'
$diskResults = @()
try {
    $physicalDisks = Get-PhysicalDisk | Where-Object { $_.BusType -ne 'USB' }
    foreach ($pd in $physicalDisks) {
        $diskResults += [PSCustomObject]@{
            FriendlyName = $pd.FriendlyName
            MediaType    = $pd.MediaType
            HealthStatus = $pd.HealthStatus
            SizeGB       = [math]::Round($pd.Size / 1GB, 0)
        }
        Write-KitLog -Message "Disque : $($pd.FriendlyName) | Type : $($pd.MediaType) | Santé : $($pd.HealthStatus) | Taille : $([math]::Round($pd.Size / 1GB, 0)) Go" -Level 'INFO'
    }
}
catch {
    Write-KitLog -Message "Impossible de lister les disques physiques : $_" -Level 'WARN'
}

# -----------------------------------------------------------------------
# SMART étendu : usure, température, erreurs non corrigées. Signal réel
# d'un disque mourant, au-delà du HealthStatus binaire. Défensif : absent
# sur certains pilotes -> champs $null, jamais de crash.
# -----------------------------------------------------------------------
$smartDetails = @()
try {
    $physicalForSmart = Get-PhysicalDisk -ErrorAction Stop
    foreach ($pd in $physicalForSmart) {
        $wear = $null; $temp = $null; $readUnc = $null; $writeUnc = $null
        try {
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($rc) {
                if ($null -ne $rc.Wear)                   { $wear     = [int]$rc.Wear }
                if ($null -ne $rc.Temperature)            { $temp     = [int]$rc.Temperature }
                if ($null -ne $rc.ReadErrorsUncorrected)  { $readUnc  = [int]$rc.ReadErrorsUncorrected }
                if ($null -ne $rc.WriteErrorsUncorrected) { $writeUnc = [int]$rc.WriteErrorsUncorrected }
            }
        }
        catch { }
        $totalUnc = $null
        if ($null -ne $readUnc -or $null -ne $writeUnc) {
            $totalUnc = ([int]$readUnc + [int]$writeUnc)
        }
        $alert = Test-SmartDriveAlert -WearPct $wear -UncorrectedErrors $totalUnc
        if ($alert.IsAlert) {
            Write-KitLog -Message "Disque '$($pd.FriendlyName)' : ALERTE SMART ($($alert.Reason))" -Level 'WARN'
        }
        $smartDetails += [PSCustomObject]@{
            FriendlyName           = [string]$pd.FriendlyName
            WearPct                = $wear
            TemperatureC           = $temp
            ReadErrorsUncorrected  = $readUnc
            WriteErrorsUncorrected = $writeUnc
            Alert                  = [bool]$alert.IsAlert
            AlertReason            = $alert.Reason
        }
    }
}
catch {
    Write-KitLog -Message "SMART étendu indisponible sur ce système (pilote de stockage)." -Level 'INFO'
}

# Espace libre par lecteur
$volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }
$volumeResults = @()
foreach ($vol in $volumes) {
    $libreGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
    $totalGB = [math]::Round($vol.Size / 1GB, 1)
    $pctLibre = if ($vol.Size -gt 0) { [math]::Round(100 * $vol.SizeRemaining / $vol.Size, 0) } else { 0 }
    # Seuil d'alerte sur le volume système uniquement (C:) : Windows Update,
    # DISM et l'hibernation se dégradent sous ~15% libres.
    $volLevel = 'INFO'
    if ($vol.DriveLetter -eq 'C') {
        $volLevel = Get-DiskSpaceLevel -FreePct $pctLibre -WarnPct $kitCfg.diskWarnFreePct -ErrorPct $kitCfg.diskErrorFreePct
    }
    Write-KitLog -Message "Volume $($vol.DriveLetter): $libreGB Go libres / $totalGB Go ($pctLibre% libre)" -Level $volLevel
    if ($volLevel -eq 'WARN') {
        Write-KitLog -Message "Espace faible sur C: (moins de $($kitCfg.diskWarnFreePct)% libres) : le module 07 (nettoyage) est prioritaire." -Level 'WARN'
    }
    elseif ($volLevel -eq 'ERROR') {
        Write-KitLog -Message "Espace CRITIQUE sur C: (moins de $($kitCfg.diskErrorFreePct)% libres) : lancer le module 07 en priorité absolue, certaines opérations (DISM, mises à jour) échoueront." -Level 'ERROR'
    }
    $diskType = Get-DiskType -DriveLetter $vol.DriveLetter
    $volumeResults += [PSCustomObject]@{
        DriveLetter  = $vol.DriveLetter
        DiskType     = $diskType
        SizeGB       = $totalGB
        FreeGB       = $libreGB
        FreeBytes    = [int64]$vol.SizeRemaining
        FreePct      = $pctLibre
        FileSystem   = $vol.FileSystem
    }
}

# -----------------------------------------------------------------------
# BitLocker : état de chiffrement par volume. Get-BitLockerVolume d'abord
# (Pro/Enterprise), fallback WMI Win32_EncryptableVolume (Home). Lecture
# seule : aucune clé n'est générée ni loggée.
# -----------------------------------------------------------------------
$bitlockerResults = @()
try {
    $blVolumes = Get-BitLockerVolume -ErrorAction Stop
    foreach ($bv in $blVolumes) {
        $pct = $null; if ($null -ne $bv.EncryptionPercentage) { $pct = [int]$bv.EncryptionPercentage }
        $status = $null; if ($null -ne $bv.ProtectionStatus) { $status = [int]$bv.ProtectionStatus }
        $protectors = @()
        try { $protectors = @($bv.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType }) } catch { }
        $bitlockerResults += [PSCustomObject]@{
            DriveLetter          = [string]$bv.MountPoint
            ProtectionStatus     = $status
            EncryptionPercentage = $pct
            ProtectorTypes       = $protectors
            Label                = (Get-BitLockerStatusLabel -ProtectionStatus $status -EncryptionPercentage $pct)
        }
    }
}
catch {
    # Fallback WMI (Windows Home : module BitLocker absent)
    try {
        $encVols = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
            -ClassName 'Win32_EncryptableVolume' -ErrorAction Stop
        foreach ($ev in $encVols) {
            $status = $null; if ($null -ne $ev.ProtectionStatus) { $status = [int]$ev.ProtectionStatus }
            $bitlockerResults += [PSCustomObject]@{
                DriveLetter          = [string]$ev.DriveLetter
                ProtectionStatus     = $status
                EncryptionPercentage = $null
                ProtectorTypes       = @()
                Label                = (Get-BitLockerStatusLabel -ProtectionStatus $status -EncryptionPercentage $null)
            }
        }
    }
    catch {
        Write-KitLog -Message "État BitLocker non lisible (ni module BitLocker ni WMI)." -Level 'INFO'
    }
}
if (@($bitlockerResults).Count -gt 0) {
    foreach ($b in $bitlockerResults) {
        Write-KitLog -Message "BitLocker $($b.DriveLetter) : $($b.Label)" -Level 'INFO'
    }
}

# ---------------------------------------------------------------------------
# Batterie
# ---------------------------------------------------------------------------
Write-KitLog -Message "Rapport batterie..." -Level 'INFO'
$batteryInfo = $null
$batteryReportPath = Join-Path $runtimeDir "battery-report-$env:COMPUTERNAME.html"
try {
    $powercfgResult = & powercfg /batteryreport /output $batteryReportPath 2>&1
    if (Test-Path $batteryReportPath) {
        # Parser le HTML pour extraire les capacités (ancrage mWh, toutes langues)
        $html = Get-Content $batteryReportPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
        $cap  = Get-BatteryCapacityFromHtml -Html $html
        if ($cap) {
            $design = $cap.DesignCapacityMWh
            $full   = $cap.FullCapacityMWh
            $usure = [math]::Round(100 - (100 * $full / $design), 0)
            $sante = [math]::Round(100 * $full / $design, 0)
            Write-KitLog -Message "Batterie    : capacité originale $design mWh, actuelle $full mWh - Santé : $sante% (usure : $usure%)" -Level $(if ($sante -lt 60) { 'WARN' } else { 'OK' })
            $batteryInfo = [PSCustomObject]@{
                DesignCapacityMWh = $design
                FullCapacityMWh   = $full
                HealthPct         = $sante
                WearPct           = $usure
            }
        }
        else {
            # INFO et pas WARN : l'absence de batterie (PC fixe) est normale,
            # un WARN permanent noie les vrais avertissements (vu au run réel).
            Write-KitLog -Message "Batterie    : non mesurable (pas de batterie ou format de rapport inattendu)" -Level 'INFO'
        }
        Write-KitLog -Message "Rapport batterie HTML : $batteryReportPath" -Level 'INFO'
    }
    else {
        Write-KitLog -Message "Batterie    : powercfg n'a pas généré de rapport (peut-être pas de batterie)" -Level 'WARN'
    }
}
catch {
    Write-KitLog -Message "Batterie    : erreur lors de la génération du rapport : $_" -Level 'WARN'
}

# ---------------------------------------------------------------------------
# Programmes au démarrage
# ---------------------------------------------------------------------------
Write-KitLog -Message "Programmes au démarrage..." -Level 'INFO'
$startupItems = @()
try {
    $startupItems = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User
    Write-KitLog -Message "Démarrage   : $($startupItems.Count) élément(s) trouvés" -Level 'INFO'
    foreach ($item in $startupItems) {
        $dispName = ConvertTo-PrintableText -Text ([string]$item.Name) -Placeholder ''
        $dispCmd  = ConvertTo-PrintableText -Text ([string]$item.Command) -Placeholder ''
        if ([string]::IsNullOrWhiteSpace($dispName)) {
            # Entrée Run sans nom lisible (valeur registre corrompue, ex bytes décodés
            # en caractères parasites au run réel) : on le signale au lieu d'afficher du bruit.
            Write-KitLog -Message "  > (entrée démarrage sans nom, probablement corrompue) | $dispCmd" -Level 'INFO'
        }
        else {
            Write-KitLog -Message "  > $dispName | $dispCmd" -Level 'INFO'
        }
    }
}
catch {
    Write-KitLog -Message "Impossible de lister les programmes au démarrage : $_" -Level 'WARN'
}

# ---------------------------------------------------------------------------
# Enrichissement optionnel : inventaire autoruns étendu via Sysinternals
# autorunsc64.exe (tools/, signé Microsoft). Fallback natif : le startup CIM
# ci-dessus reste la source. Aucun module ne DÉPEND de cet outil.
# ---------------------------------------------------------------------------
$autorunsInventory = $null
$autorunsExe = Get-OptionalTool -Name 'autorunsc64.exe'
if ($autorunsExe) {
    Write-KitLog -Message "Outil optionnel détecté : autorunsc64 (inventaire autoruns étendu)..." -Level 'INFO'
    try {
        # -a '*' = toutes catégories (quote pour ne pas être développé en glob PowerShell),
        # -c = CSV, -h = hash, -nobanner, -accepteula = pas de dialogue EULA.
        $raw  = & $autorunsExe -accepteula -nobanner -a '*' -c -h 2>$null | Out-String
        $rows = @($raw | ConvertFrom-Csv)
        $autorunsInventory = @($rows | ForEach-Object {
            # Accès défensif : les colonnes CSV varient selon la version d'autorunsc64.
            # Jamais d'accès direct sous StrictMode Latest -> PropertyNotFoundException.
            # Publisher : autorunsc64 expose 'Company' (éditeur MSI/EXE) ou 'Signer'
            # (certificat Authenticode) selon la version ; 'Publisher' n'existe pas.
            [PSCustomObject]@{
                Entry     = $(if ($_.PSObject.Properties['Entry'])      { [string]$_.'Entry' }      else { '' })
                Category  = $(if ($_.PSObject.Properties['Category'])   { [string]$_.'Category' }   else { '' })
                Enabled   = $(if ($_.PSObject.Properties['Enabled'])    { [string]$_.'Enabled' }    else { '' })
                ImagePath = $(if ($_.PSObject.Properties['Image Path']) { [string]$_.'Image Path' } else { '' })
                Publisher = $(if ($_.PSObject.Properties['Company'])    { [string]$_.'Company' }
                              elseif ($_.PSObject.Properties['Signer']) { [string]$_.'Signer' }
                              else { '' })
            }
        })
        Write-KitLog -Message "Autoruns étendu : $(@($autorunsInventory).Count) entrée(s)." -Level 'OK'
    }
    catch {
        Write-KitLog -Message "autorunsc64 présent mais exécution impossible : $_" -Level 'WARN'
        $autorunsInventory = $null
    }
}

# ---------------------------------------------------------------------------
# Antivirus présents
# ---------------------------------------------------------------------------
Write-KitLog -Message "Antivirus détectés..." -Level 'INFO'
$avProducts = @()
try {
    $avProducts = Get-CimInstance -Namespace root\SecurityCenter2 -Class AntiVirusProduct -ErrorAction Stop |
                  Select-Object displayName, productState
    foreach ($av in $avProducts) {
        Write-KitLog -Message "Antivirus   : $($av.displayName) (état : $($av.productState))" -Level 'INFO'
    }
}
catch {
    Write-KitLog -Message "Antivirus   : impossible de requêter SecurityCenter2 : $_" -Level 'WARN'
}

# ---------------------------------------------------------------------------
# winget
# ---------------------------------------------------------------------------
$wingetOk = Test-WingetAvailable
if ($wingetOk) {
    Write-KitLog -Message "winget      : present" -Level 'OK'
}
else {
    Write-KitLog -Message "winget      : absent. $(Get-WingetAbsentAdvice -IsWin11 $machine.IsWin11)" -Level 'WARN'
}

# ---------------------------------------------------------------------------
# Connectivité Internet
# ---------------------------------------------------------------------------
$online = Test-InternetConnection
Write-KitLog -Message "Internet    : $(if ($online) { 'connecte' } else { 'HORS LIGNE' })" -Level $(if ($online) { 'OK' } else { 'WARN' })

# ---------------------------------------------------------------------------
# Antivirus tiers actif (peut bloquer les modifications)
# ---------------------------------------------------------------------------
$thirdPartyAv = Get-ActiveThirdPartyAv
if ($thirdPartyAv.Count -gt 0) {
    Write-KitLog -Message "AV tiers actif : $($thirdPartyAv -join ', ') - peut bloquer les suppressions AppX/registre." -Level 'WARN'
}

# ---------------------------------------------------------------------------
# Redémarrage déjà en attente avant intervention
# ---------------------------------------------------------------------------
$rebootState = Test-RebootPending
if ($rebootState.Pending) {
    Write-KitLog -Message "Redémarrage déjà en attente (avant kit) : $($rebootState.Reasons -join ', ')" -Level 'WARN'
}

# -----------------------------------------------------------------------
# Pilotes en erreur (Device Manager) : intervention manuelle à signaler.
# -----------------------------------------------------------------------
$errorDevices = @()
try {
    $errorDevices = @(Get-PnpDevice -Status Error -ErrorAction Stop | ForEach-Object {
        [PSCustomObject]@{ FriendlyName = [string]$_.FriendlyName; Class = [string]$_.Class; InstanceId = [string]$_.InstanceId }
    })
    if ($errorDevices.Count -gt 0) {
        Write-KitLog -Message "Pilotes en erreur : $($errorDevices.Count) périphérique(s) à vérifier." -Level 'WARN'
    }
}
catch { Write-KitLog -Message "État des pilotes non lisible." -Level 'INFO' }

# -----------------------------------------------------------------------
# Activation Windows.
# -----------------------------------------------------------------------
$windowsActivation = [PSCustomObject]@{ IsActivated = $false; StatusLabel = 'Inconnu' }
try {
    $lic = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
           Where-Object { $_.PartialProductKey -and $_.ApplicationId -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } |
           Select-Object -First 1
    if ($lic) {
        $activated = ([int]$lic.LicenseStatus -eq 1)
        $windowsActivation = [PSCustomObject]@{
            IsActivated = $activated
            StatusLabel = $(if ($activated) { 'Activée' } else { "Non activée (statut $($lic.LicenseStatus))" })
        }
        Write-KitLog -Message "Activation Windows : $($windowsActivation.StatusLabel)" -Level $(if ($activated) { 'OK' } else { 'WARN' })
    }
}
catch { Write-KitLog -Message "Statut d'activation non lisible." -Level 'INFO' }

# -----------------------------------------------------------------------
# Navigateur par défaut (UserChoice du protocole https).
# -----------------------------------------------------------------------
$defaultBrowser = [PSCustomObject]@{ ProgId = $null; Label = 'Inconnu'; IsFirefox = $false }
try {
    $uc = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop
    $progId = [string]$uc.ProgId
    $lbl    = Get-DefaultBrowserLabel -ProgId $progId
    $defaultBrowser = [PSCustomObject]@{ ProgId = $progId; Label = $lbl.Label; IsFirefox = $lbl.IsFirefox }
    Write-KitLog -Message "Navigateur par défaut : $($lbl.Label)" -Level 'INFO'
}
catch { Write-KitLog -Message "Navigateur par défaut non lisible." -Level 'INFO' }

# Inventaire des applications Win32 via Get-Win32AppNames (lib/Common.ps1),
# partagé avec le module 10 (recapture "après") pour éviter toute dérive du
# filtre. Noms pour le snapshot "avant" (delta apps du rapport).
$win32Apps = @(Get-Win32AppNames)
Write-KitLog -Message "Applications Win32 installées : $(@($win32Apps).Count)" -Level 'INFO'

# Temps de boot moyen via Get-LastBootDurationMs (lib/Common.ps1), partagé
# avec le module 10 (recapture après reboot).
$lastBootDurationMs = Get-LastBootDurationMs
if ($null -ne $lastBootDurationMs) {
    Write-KitLog -Message "Temps de boot moyen (5 derniers) : $(Format-BootDuration -Milliseconds $lastBootDurationMs)" -Level 'INFO'
}
else {
    Write-KitLog -Message "Temps de boot non mesurable (journal Diagnostics-Performance indisponible)." -Level 'INFO'
}

# -----------------------------------------------------------------------
# Snapshot "avant" : état figé au diagnostic, relu et comparé par le
# module 10 pour afficher le delta avant/après. FreeBytes en octets bruts
# (valeur précise depuis Get-Volume.SizeRemaining, pas le FreeGB arrondi
# au dixième - le delta module 10 compare octet par octet).
# -----------------------------------------------------------------------
$snapshotVolumes = @($volumeResults | ForEach-Object {
    [PSCustomObject]@{ DriveLetter = [string]$_.DriveLetter; FreeBytes = [int64]$_.FreeBytes }
})
$snapshot = [PSCustomObject]@{
    Volumes        = $snapshotVolumes
    StartupCount   = @($startupItems).Count
    Win32Apps      = @($win32Apps)
    BootDurationMs = $lastBootDurationMs
}

# ---------------------------------------------------------------------------
# Écriture du JSON de synthèse pour les autres modules
# ---------------------------------------------------------------------------
$diagJson = [PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Machine        = $machine
    CPU            = [PSCustomObject]@{ Name = $cpu.Name; Cores = $cpu.NumberOfCores; Logical = $cpu.NumberOfLogicalProcessors }
    RAM            = [PSCustomObject]@{ TotalGB = $ramTotalGB; FreeGB = $ramLibreGB }
    PhysicalDisks  = $diskResults
    SmartDetails   = $smartDetails
    Volumes        = $volumeResults
    BitLocker      = $bitlockerResults
    Battery        = $batteryInfo
    StartupItems   = ($startupItems | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Command = $_.Command } })
    AntiVirus      = ($avProducts   | ForEach-Object { [PSCustomObject]@{ Name = $_.displayName; State = $_.productState } })
    WingetAvail        = $wingetOk
    Online             = $online
    ThirdPartyAvActive = $thirdPartyAv
    RebootPending      = $rebootState.Pending
    RebootReasons      = $rebootState.Reasons
    ErrorDevices       = $errorDevices
    WindowsActivation  = $windowsActivation
    DefaultBrowser     = $defaultBrowser
    Win32AppCount      = @($win32Apps).Count
    LastBootDurationMs = $lastBootDurationMs
    StartupItemCount   = @($startupItems).Count
    Snapshot           = $snapshot
    AutorunsInventory  = $autorunsInventory
}

$jsonPath = Join-Path $runtimeDir "diagnostic-$env:COMPUTERNAME.json"
$diagJson | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
Write-KitLog -Message "Synthèse JSON : $jsonPath" -Level 'OK'

Write-KitLog -Message "=== 00-Diagnostic : terminé ===" -Level 'OK'
exit 0
