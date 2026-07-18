# lib/Hardware.ps1 - Diagnostic matériel, santé et état système (dot-source par
# lib/Common.ps1). Ne pas dot-sourcer directement. UTF-8 avec BOM.

# ---------------------------------------------------------------------------
# Get-MachineInfo : infos matériel et OS
# Retourne : [PSCustomObject] {Manufacturer, Model, BiosSerial, OSCaption, OSBuild, IsWin11}
# ---------------------------------------------------------------------------
function Get-MachineInfo {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem

    $build   = [int]($os.BuildNumber)
    $isWin11 = $build -ge 22000

    return [PSCustomObject]@{
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
        BiosSerial   = $bios.SerialNumber
        OSCaption    = $os.Caption
        OSBuild      = $build
        IsWin11      = $isWin11
    }
}

# ---------------------------------------------------------------------------
# Get-DiskType : détecte SSD ou HDD pour un lecteur donné
# -DriveLetter : lettre du lecteur (ex : 'C')
# Supporte aussi un objet simulé {MediaType} pour les tests Pester
# Retourne 'SSD', 'HDD', ou 'UNKNOWN'
# ---------------------------------------------------------------------------
function Get-DiskType {
    param(
        [string]$DriveLetter,
        # Objet simulé pour les tests (contourne l'accès WMI)
        [PSCustomObject]$SimulatedDisk = $null
    )

    if ($null -ne $SimulatedDisk) {
        return ConvertFrom-MediaType $SimulatedDisk.MediaType
    }

    try {
        # Trouver le numéro du disque physique qui héberge ce lecteur
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk      = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $physical  = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.Number }
        if ($null -eq $physical) { return 'UNKNOWN' }
        # Certains pilotes NVMe retournent MediaType='Unspecified' - vérifier BusType en priorité
        if ($physical.BusType -eq 'NVMe') { return 'SSD' }
        return ConvertFrom-MediaType $physical.MediaType
    }
    catch {
        return 'UNKNOWN'
    }
}

function ConvertFrom-MediaType {
    [CmdletBinding()]
    param([AllowNull()][object]$MediaType)
    switch ([string]$MediaType) {
        'SSD'          { return 'SSD' }
        'HDD'          { return 'HDD' }
        # MSFT_PhysicalDisk.MediaType numérique (doc officielle) :
        # 0 = Unspecified, 3 = HDD, 4 = SSD, 5 = SCM (assimilé SSD).
        # Le NVMe est déjà résolu en amont par la garde BusType de Get-DiskType.
        '4'            { return 'SSD' }
        '5'            { return 'SSD' }
        '3'            { return 'HDD' }
        'Unspecified'  { return 'UNKNOWN' }
        '0'            { return 'UNKNOWN' }
        default        { return 'UNKNOWN' }
    }
}

# ---------------------------------------------------------------------------
# Get-FreeSpaceGB : espace libre d'un lecteur en Go. -1 si introuvable.
# ---------------------------------------------------------------------------
function Get-FreeSpaceGB {
    param([Parameter(Mandatory)][string]$DriveLetter)
    $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if (-not $vol) { return -1 }
    return [math]::Round($vol.SizeRemaining / 1GB, 1)
}

# ---------------------------------------------------------------------------
# Get-DiskSpaceLevel : niveau de log pour un pourcentage d'espace libre.
# Bornes : < ErrorPct -> ERROR ; < WarnPct -> WARN ; sinon INFO. PURE/testable.
# ---------------------------------------------------------------------------
function Get-DiskSpaceLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$FreePct,
        [int]$WarnPct  = 15,
        [int]$ErrorPct = 5
    )
    if ($FreePct -lt $ErrorPct) { return 'ERROR' }
    if ($FreePct -lt $WarnPct)  { return 'WARN' }
    return 'INFO'
}

# ---------------------------------------------------------------------------
# Test-RebootPending : état de redémarrage en attente (registre). Objet
# {Pending=[bool]; Reasons=[string[]]}.
# ---------------------------------------------------------------------------
function Test-RebootPending {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) { $reasons += 'PendingFileRename' }
    return [PSCustomObject]@{ Pending = ($reasons.Count -gt 0); Reasons = $reasons }
}

# ---------------------------------------------------------------------------
# Get-DefaultBrowserLabel : ProgId du navigateur par défaut -> nom lisible +
# drapeau IsFirefox. PURE/testable. La cible du kit préfère Firefox : IsFirefox
# permet à la note utilisateur de ne recommander le changement que si besoin.
# ---------------------------------------------------------------------------
function Get-DefaultBrowserLabel {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$ProgId)
    $isFf  = $false
    $label = $ProgId
    if ([string]::IsNullOrWhiteSpace($ProgId)) {
        return [PSCustomObject]@{ Label = 'Inconnu'; IsFirefox = $false }
    }
    switch -Regex ($ProgId) {
        '^Firefox'          { $label = 'Mozilla Firefox'; $isFf = $true; break }
        '^Chrome'           { $label = 'Google Chrome';   break }
        '^MSEdge'           { $label = 'Microsoft Edge';  break }
        '^IE\.'             { $label = 'Internet Explorer'; break }
        '^Opera'            { $label = 'Opera';           break }
        '^Brave'            { $label = 'Brave';           break }
        default             { $label = "$ProgId (non reconnu)" }
    }
    return [PSCustomObject]@{ Label = $label; IsFirefox = $isFf }
}

# ---------------------------------------------------------------------------
# Test-SmartDriveAlert : un disque mérite-t-il une alerte ? Usure > 80% ou au
# moins une erreur non corrigée. Les valeurs nulles (matériel qui n'expose pas
# le compteur) ne déclenchent pas d'alerte. PURE/testable.
# ---------------------------------------------------------------------------
function Test-SmartDriveAlert {
    [CmdletBinding()]
    param([AllowNull()][object]$WearPct, [AllowNull()][object]$UncorrectedErrors)
    $reasons = @()
    if ($null -ne $WearPct) {
        $w = 0; if ([int]::TryParse([string]$WearPct, [ref]$w) -and $w -gt 80) {
            $reasons += "usure $w%"
        }
    }
    if ($null -ne $UncorrectedErrors) {
        $e = 0; if ([int]::TryParse([string]$UncorrectedErrors, [ref]$e) -and $e -gt 0) {
            $reasons += "$e erreur(s) non corrigée(s)"
        }
    }
    return [PSCustomObject]@{ IsAlert = ($reasons.Count -gt 0); Reason = ($reasons -join ', ') }
}

# ---------------------------------------------------------------------------
# Get-BitLockerStatusLabel : état de chiffrement lisible à partir du couple
# (ProtectionStatus, EncryptionPercentage) de Get-BitLockerVolume ou du WMI.
# ProtectionStatus : 1 = protégé/chiffré, 0 = non protégé. PURE/testable.
# ---------------------------------------------------------------------------
function Get-BitLockerStatusLabel {
    [CmdletBinding()]
    param([AllowNull()][object]$ProtectionStatus, [AllowNull()][object]$EncryptionPercentage)
    if ($null -eq $ProtectionStatus) { return 'Inconnu' }
    $pct = 0; [void][int]::TryParse([string]$EncryptionPercentage, [ref]$pct)
    if ([string]$ProtectionStatus -eq '1') { return 'Chiffré (protégé)' }
    if ($pct -gt 0 -and $pct -lt 100)      { return "Chiffrement en cours ($pct%)" }
    return 'Non chiffré'
}

# ---------------------------------------------------------------------------
# Format-BootDuration : millisecondes -> "12,3 s" (virgule décimale FR), ou
# "non mesuré" si null/zero. PURE/testable.
# ---------------------------------------------------------------------------
function Format-BootDuration {
    [CmdletBinding()]
    param([AllowNull()][object]$Milliseconds)
    $ms = 0
    if ($null -eq $Milliseconds -or -not [int]::TryParse([string]$Milliseconds, [ref]$ms) -or $ms -le 0) {
        return 'non mesuré'
    }
    $s = [math]::Round($ms / 1000, 1)
    return ("{0} s" -f ($s.ToString([System.Globalization.CultureInfo]::GetCultureInfo('fr-FR'))))
}

# ---------------------------------------------------------------------------
# Get-Win32AppNames : noms des applications Win32 depuis le registre Uninstall
# (jamais Win32_Product, qui déclenche des réparations MSI). Deux ruches (natif
# + Wow6432Node). Dédup, tableau forcé. Partagé par le module 00 (snapshot
# "avant") et le module 10 (recapture "après") : une seule source de vérité.
# Contrat (b) : appelant fait @(Get-Win32AppNames).
# ---------------------------------------------------------------------------
function Get-Win32AppNames {
    [CmdletBinding()]
    param()
    $names = @()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        try {
            # Acces defensif (StrictMode 5.1) : certaines cles Uninstall n'ont ni
            # DisplayName ni SystemComponent ; $_.Prop direct leverait PropertyNotFoundStrict.
            $names += Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { (Get-JsonProp $_ 'DisplayName') -and -not (Get-JsonProp $_ 'SystemComponent') } |
                ForEach-Object { [string](Get-JsonProp $_ 'DisplayName') }
        }
        catch { }
    }
    return @($names | Sort-Object -Unique)
}

# ---------------------------------------------------------------------------
# Get-LastBootDurationMs : durée de boot moyenne (ms) des 5 derniers
# démarrages, EventID 100 du journal Diagnostics-Performance. $null si le
# journal est indisponible (souvent le cas sur SSD rapides / journaux purgés).
# Partagé module 00 (avant) et module 10 (après reboot). Défensif.
# ---------------------------------------------------------------------------
function Get-LastBootDurationMs {
    [CmdletBinding()]
    param()
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5 -ErrorAction Stop
        $durations = @()
        foreach ($ev in $events) {
            try {
                $xml = [xml]$ev.ToXml()
                $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -First 1
                if ($node -and [int]$node.'#text' -gt 0) { $durations += [int]$node.'#text' }
            }
            catch { }
        }
        if ($durations.Count -gt 0) { return [int](($durations | Measure-Object -Average).Average) }
    }
    catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Get-BatteryCapacityFromHtml : extrait (design, full charge) en mWh du rapport
# powercfg /batteryreport. Indépendant de la langue : ancré sur l'unité mWh
# (identique dans toutes les locales), pas sur les libellés EN/FR. Le tableau
# 'Installed batteries' liste toujours la capacité théorique avant la capacité
# de charge complète : 1re occurrence = design, 2e = full. PURE/testable.
# ---------------------------------------------------------------------------
function Get-BatteryCapacityFromHtml {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }
    # Séparateurs de milliers selon locale : virgule, point, espaces. En regex
    # .NET, \s couvre la catégorie Unicode Z, donc aussi les espaces insécables
    # (U+00A0, U+202F) des locales FR.
    $mwh = [regex]::Matches($Html, '([\d][\d\s,\.]*)\s*mWh')
    if ($mwh.Count -lt 2) { return $null }
    $design = [int64]([regex]::Replace($mwh[0].Groups[1].Value, '[^\d]', ''))
    $full   = [int64]([regex]::Replace($mwh[1].Groups[1].Value, '[^\d]', ''))
    if ($design -le 0 -or $full -le 0) { return $null }
    return [PSCustomObject]@{
        DesignCapacityMWh = [int]$design
        FullCapacityMWh   = [int]$full
    }
}

# ---------------------------------------------------------------------------
# Test-WindowsUpdateBusy : $true si une MAJ Windows est en cours
# (installation via IUpdateInstaller.IsBusy, ou téléchargement BITS actif).
# ---------------------------------------------------------------------------
function Test-WindowsUpdateBusy {
    try {
        $installer = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller()
        if ($installer.IsBusy) { return $true }
    }
    catch { }
    try {
        $bits = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.JobState -in 'Transferring','Connecting','Queued' }
        if ($bits) { return $true }
    }
    catch { }
    return $false
}
