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
    # Doctrine de journalisation : un volume saturé est un fait constaté sur la
    # machine, pas une panne du diagnostic - le journal est donc plafonné à WARN
    # (même règle que Write-SentinelLog plus bas). La sévérité réelle reste dans
    # le bloc Resilience du JSON et dans la pastille du rapport HTML.
    $volLogLevel = if ($volLevel -eq 'ERROR') { 'WARN' } else { $volLevel }
    Write-KitLog -Message "Volume $($vol.DriveLetter): $libreGB Go libres / $totalGB Go ($pctLibre% libre)" -Level $volLogLevel
    if ($volLevel -eq 'WARN') {
        Write-KitLog -Message "Espace faible sur C: (moins de $($kitCfg.diskWarnFreePct)% libres) : le module 07 (nettoyage) est prioritaire." -Level 'WARN'
    }
    elseif ($volLevel -eq 'ERROR') {
        Write-KitLog -Message "Espace critique sur C: (moins de $($kitCfg.diskErrorFreePct)% libres) : lancer le module 07 en priorité absolue, certaines opérations (DISM, mises à jour) échoueront." -Level 'WARN'
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

# -----------------------------------------------------------------------
# Sentinelle résilience (v2.4) : les filets Windows sont-ils vivants ?
# Origine : intervention du 21/08/2026, tous les filets morts silencieusement
# (restauration désactivée, RegBack vide, WinRE désarmé, disque saturé).
# Lecture seule ; les réarmements sont dans le module 16.
# -----------------------------------------------------------------------

# Doctrine du journal, appliquée par tout le module : le journal décrit
# l'EXÉCUTION du module, jamais la santé de la machine - un disque sous le
# plancher, un BitLocker sans clé de récupération ou des ruches figées sont des
# faits constatés, pas des pannes du diagnostic. Les verdicts de santé y sont
# donc journalisés au maximum en WARN (ici par plafonnement, en clair dans la
# boucle des volumes plus haut) ; le canal de santé est ailleurs, dans le bloc
# Resilience du JSON et dans la pastille de la carte « Filets de sécurité » du
# rapport HTML, où la sévérité réelle est conservée.
function Write-SentinelLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO'
    )
    $capped = if ($Level -eq 'ERROR') { 'WARN' } else { $Level }
    Write-KitLog -Message $Message -Level $capped
}

Write-SentinelLog -Message "Sentinelle résilience : vérification des filets de sécurité..." -Level 'INFO'

# Espace libre C: avec planchers absolus (le pourcentage seul a laissé passer
# la saturation du 21/08 : fsutil négatif au moment du crash).
$volC = $volumeResults | Where-Object { $_.DriveLetter -eq 'C' } | Select-Object -First 1
# 'Unknown' et non 'OK' par défaut : sans volume C: dans la collecte, rien n'a
# été mesuré et la carte doit le dire plutôt que d'afficher un filet sain.
$freeSpaceLevel = 'Unknown'
if ($volC) {
    $freeSpaceLevel = Get-FreeSpaceVerdict -FreeBytes ([int64]$volC.FreeBytes) `
        -TotalBytes ([int64]($volC.SizeGB * 1GB)) `
        -WarnPct $kitCfg.diskWarnFreePct -ErrorPct $kitCfg.diskErrorFreePct `
        -WarnFloorGB $kitCfg.diskWarnFloorGB -ErrorFloorGB $kitCfg.diskErrorFloorGB
    if ($freeSpaceLevel -ne 'OK') {
        # Le verdict combine pourcentage ET plancher en Go : le message dit lequel
        # a parlé, sinon un petit disque (eMMC 32 Go) passe pour saturé alors qu'il
        # est simplement sous le plancher absolu par construction.
        Write-SentinelLog -Message "Espace libre C: sous les seuils de sécurité du registre : $($volC.FreeGB) Go libres sur $($volC.SizeGB) Go ($($volC.FreePct)% libre)." -Level $freeSpaceLevel
        Write-SentinelLog -Message "Seuils appliqués : avertissement sous $($kitCfg.diskWarnFreePct)% ou $($kitCfg.diskWarnFloorGB) Go libres, critique sous $($kitCfg.diskErrorFreePct)% ou $($kitCfg.diskErrorFloorGB) Go. Sur un volume de moins de $($kitCfg.diskWarnFloorGB) Go au total, le verdict est structurel et non une saturation. Sans marge, le registre peut ne plus écrire ses transactions." -Level 'INFO'
    }
}
else {
    Write-SentinelLog -Message "Espace libre C: non mesurable : aucun volume C: dans la collecte." -Level 'INFO'
}

# Fraîcheur des ruches : SYSTEM qui ne s'écrit plus = pré-crash détectable.
$hiveLag = $null
try {
    $sysHive  = Get-Item "$env:SystemRoot\System32\config\SYSTEM" -ErrorAction Stop
    $softHive = Get-Item "$env:SystemRoot\System32\config\SOFTWARE" -ErrorAction Stop
    $hiveLag = Test-HiveFreshnessAlert -SystemLastWrite $sysHive.LastWriteTime -SoftwareLastWrite $softHive.LastWriteTime
    if ($hiveLag.Level -ne 'OK') {
        Write-SentinelLog -Message "Ruches registre : $($hiveLag.Reason) (retard : $($hiveLag.LagHours) h)" -Level $hiveLag.Level
    }
    else {
        Write-SentinelLog -Message "Ruches registre : écritures récentes, rien à signaler." -Level 'OK'
    }
}
catch { Write-SentinelLog -Message "Fraîcheur des ruches non mesurable : $_" -Level 'INFO' }

# Restauration système : deux sondes distinctes, l'état du service (registre) et
# le nombre de points (VSS, exige l'élévation). Séparées pour qu'une sonde muette
# n'efface pas la mesure de l'autre.
# $null = sonde muette (clé absente, valeur RPSessionInterval absente, lecture
# refusée), distinct d'un $false mesuré : sans lecture réelle du registre, rien
# n'autorise à écrire « restauration désactivée » - le rapport rend alors une
# ligne neutre « état non lisible ».
$restoreEnabled = $null
try {
    $srKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction SilentlyContinue
    if ($srKey -and $srKey.PSObject.Properties['RPSessionInterval']) {
        $restoreEnabled = ([int]$srKey.RPSessionInterval -ge 1)
    }
    else {
        Write-SentinelLog -Message "État du service de restauration système non lisible (valeur RPSessionInterval absente) : aucune conclusion sur son activation." -Level 'INFO'
    }
}
catch {
    $restoreEnabled = $null
    Write-SentinelLog -Message "État du service de restauration système non lisible : aucune conclusion sur son activation." -Level 'INFO'
}

# $null = sonde muette, distinct d'un zéro mesuré : « service actif, 0 point »
# n'est pas un filet et doit alerter, alors qu'une sonde muette ne doit rien
# affirmer du tout.
$restoreCount = $null
try {
    # -ErrorAction Stop volontaire : en SilentlyContinue une requête refusée
    # (session non élevée, VSS injoignable) renverrait un tableau vide,
    # indiscernable d'un vrai « aucun point de restauration ».
    $restoreCount = @(Get-ComputerRestorePoint -ErrorAction Stop).Count
}
catch {
    $restoreCount = $null
    Write-SentinelLog -Message "Nombre de points de restauration non lisible (sonde VSS muette)." -Level 'INFO'
}
# Les deux sondes doivent avoir mesuré : `-not $null` vaut $true, un état de
# service non lu se journaliserait sinon en « DÉSACTIVÉE » sans aucune mesure.
if ($null -ne $restoreCount -and $null -ne $restoreEnabled) {
    if (-not $restoreEnabled -and $restoreCount -eq 0) {
        Write-SentinelLog -Message "Restauration système : DÉSACTIVÉE et aucun point présent (aucun filet VSS - l'étape Sauvegarde la réactive et crée un point avant l'intervention)." -Level 'WARN'
    }
    elseif (-not $restoreEnabled) {
        Write-SentinelLog -Message "Restauration système : DÉSACTIVÉE, $restoreCount point(s) encore présent(s) mais plus aucun nouveau (l'étape Sauvegarde la réactive avant l'intervention)." -Level 'WARN'
    }
    elseif ($restoreCount -eq 0) {
        Write-SentinelLog -Message "Restauration système : active mais aucun point présent - rien à restaurer aujourd'hui (l'étape Sauvegarde en crée un avant l'intervention)." -Level 'WARN'
    }
}

# Stockage de clichés (Win32_ShadowStorage : octets bruts, non localisés).
$shadowMax = $null
# $null = non mesuré, distinct de $false = mesuré et insuffisant : une sonde
# muette ne doit pas faire écrire « réserve insuffisante » au rapport.
$shadowAdequate = $null
try {
    $volCim = Get-CimInstance Win32_Volume -Filter "DriveLetter = 'C:'" -ErrorAction Stop | Select-Object -First 1
    # Requête sans erreur mais sans volume renvoyé : rien n'a été mesuré, on sort
    # par le catch plutôt que de conclure « réserve insuffisante » sur du vide.
    if ($null -eq $volCim) { throw "volume C: absent de Win32_Volume" }
    # -ErrorAction Stop volontaire : sans élévation la classe Win32_ShadowStorage
    # refuse la requête (« Échec d'initialisation ») ; en SilentlyContinue ce refus
    # devenait un tableau vide, donc « réserve insuffisante » sans rien avoir mesuré.
    # Une requête qui aboutit et ne renvoie rien reste, elle, une vraie mesure.
    $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop) | Where-Object {
        $_.Volume.DeviceID -eq $volCim.DeviceID
    } | Select-Object -First 1
    if ($ss) { $shadowMax = [uint64]$ss.MaxSpace }
    # Capacity peut être $null sans que StrictMode ne bronche ([int64]$null = 0) :
    # conclure « réserve insuffisante » sur un volume non mesuré violerait la
    # doctrine du bloc. Même garde que le module 16 avant sa décision de resize.
    if ($null -eq $volCim.Capacity -or [int64]$volCim.Capacity -le 0) { throw "capacité du volume C: non mesurable" }
    $shadowAdequate = Test-ShadowStorageAdequate -MaxSpaceBytes $shadowMax -VolumeSizeBytes ([int64]$volCim.Capacity) -MinPct 5
    if (-not $shadowAdequate) {
        Write-SentinelLog -Message "Stockage de clichés VSS : absent ou inférieur à 5% du volume (les points de restauration s'évaporent). Le module 16 l'agrandit." -Level 'WARN'
    }
}
catch {
    $shadowAdequate = $null
    Write-SentinelLog -Message "Stockage de clichés non lisible : aucune conclusion sur la réserve VSS." -Level 'INFO'
}

# WinRE armé ? (reagentc /info : valeurs Enabled/Disabled non localisées)
$winReVerdict = [PSCustomObject]@{ Status = 'Unknown'; Level = 'WARN' }
try {
    $reOut = @(& reagentc /info 2>&1 | ForEach-Object { [string]$_ })
    $winReVerdict = Get-WinReVerdict -ReagentcOutput $reOut
    Write-SentinelLog -Message "Environnement de récupération (WinRE) : $($winReVerdict.Status)" -Level $winReVerdict.Level
}
catch { Write-SentinelLog -Message "reagentc non exécutable." -Level 'INFO' }

# Auto-réparation au boot (BCD recoveryenabled).
$recVerdict = [PSCustomObject]@{ Status = 'Unknown'; Level = 'WARN' }
try {
    $bcdOut  = @(& bcdedit /enum '{default}' 2>&1 | ForEach-Object { [string]$_ })
    $bcdExit = $LASTEXITCODE
    if ($bcdExit -ne 0 -or @($bcdOut).Count -eq 0) {
        # bcdedit a échoué (session non élevée, BCD illisible) : sa sortie est du
        # bruit, la fonction pure y lirait « Absent » sans que rien n'ait été mesuré.
        $recVerdict = [PSCustomObject]@{ Status = 'Unknown'; Level = 'WARN' }
        Write-SentinelLog -Message "Auto-réparation au démarrage : bcdedit n'a rien renvoyé d'exploitable (code $bcdExit), état non mesuré." -Level 'INFO'
    }
    else {
        $recVerdict = Get-RecoveryEnabledVerdict -BcdOutput $bcdOut
        if ($recVerdict.Level -ne 'OK') {
            Write-SentinelLog -Message "Auto-réparation au démarrage (recoveryenabled) : $($recVerdict.Status) - le module 16 la réarme." -Level 'WARN'
        }
    }
}
catch { Write-SentinelLog -Message "bcdedit non exécutable." -Level 'INFO' }

# Verdict BitLocker C: (réutilise la collecte BitLocker ci-dessus).
# Pas de $blC = la collecte n'a rien renvoyé pour C: (ni module BitLocker ni WMI,
# ou lecture refusée) : rien n'a été mesuré. Appeler la fonction pure avec $null
# rendrait « volume non protégé par BitLocker » au niveau OK, soit une pastille
# verte affirmant qu'un disque jamais interrogé est en clair. Sonde muette = INFO.
$blVerdict = [PSCustomObject]@{ Level = 'INFO'; Reason = 'état BitLocker non lisible' }
try {
    $blC = $bitlockerResults | Where-Object { ([string]$_.DriveLetter).TrimEnd(':') -eq 'C' } | Select-Object -First 1
    if ($blC) {
        $blVerdict = Get-BitLockerResilienceVerdict `
            -ProtectionStatus $blC.ProtectionStatus `
            -ProtectorTypes   $blC.ProtectorTypes
    }
    if ($blVerdict.Level -eq 'ERROR') {
        # ERROR au call site (le verdict JSON et la pastille le restent) ; le journal
        # est plafonné à WARN par Write-SentinelLog, cf. commentaire en tête de bloc.
        Write-SentinelLog -Message "BitLocker C: : $($blVerdict.Reason)" -Level 'ERROR'
    }
    elseif ($blVerdict.Level -eq 'INFO') {
        Write-SentinelLog -Message "BitLocker C: : $($blVerdict.Reason)" -Level 'INFO'
    }
}
catch {
    # Une collecte BitLocker biscornue ne doit jamais faire sortir le module avant
    # l'écriture du JSON : verdict neutre, la sentinelle continue.
    $blVerdict = [PSCustomObject]@{ Level = 'INFO'; Reason = 'état BitLocker non lisible' }
    Write-SentinelLog -Message "Verdict BitLocker non calculable : aucune conclusion sur le chiffrement de C:." -Level 'INFO'
}

# Contrat JSON : toutes les clés sont toujours présentes. RestoreEnabled,
# RestorePointCount et ShadowAdequate valent $null quand la sonde n'a rien pu
# mesurer (ConvertTo-Json les sérialise en null) et BitLockerC tombe au niveau
# INFO - le rapport rend alors une ligne neutre au lieu d'affirmer un état.
$resilience = [PSCustomObject]@{
    FreeSpaceLevel        = $freeSpaceLevel
    HiveLagHours          = $(if ($hiveLag) { $hiveLag.LagHours } else { $null })
    HiveLevel             = $(if ($hiveLag) { $hiveLag.Level }    else { 'Unknown' })
    HiveReason            = $(if ($hiveLag) { $hiveLag.Reason }   else { '' })
    RestoreEnabled        = $restoreEnabled
    RestorePointCount     = $restoreCount
    ShadowMaxBytes        = $shadowMax
    ShadowAdequate        = $shadowAdequate
    WinReStatus           = $winReVerdict.Status
    WinReLevel            = $winReVerdict.Level
    RecoveryEnabledStatus = $recVerdict.Status
    RecoveryEnabledLevel  = $recVerdict.Level
    BitLockerC            = [PSCustomObject]@{ Level = $blVerdict.Level; Reason = $blVerdict.Reason }
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
    Resilience         = $resilience
}

$jsonPath = Join-Path $runtimeDir "diagnostic-$env:COMPUTERNAME.json"
$diagJson | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
Write-KitLog -Message "Synthèse JSON : $jsonPath" -Level 'OK'

Write-KitLog -Message "=== 00-Diagnostic : terminé ===" -Level 'OK'
exit 0
