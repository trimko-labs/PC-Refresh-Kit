#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Desactive ~96 parametres de telemetrie Windows. Version kit portable.
.DESCRIPTION
    Adaptation de Disable-WindowsTelemetry.ps1 pour PC-Refresh-Kit.
    Changements par rapport a l'original :
    - Chemins logs/backups dans C:\ProgramData\TelemetryGuard (portable, hors profil)
    - Parametre -DisableSmartScreen (defaut false = SmartScreen GARDE)
    - Parametre -BlockTelemetryIPs  (defaut false = pas de regles firewall par IP)
    - Rotation automatique des backups/logs (15 fichiers max)
    NE PAS modifier l'installation active C:\ProgramData\TelemetryGuard.
    Ce fichier est la copie kit portable.
#>

param(
    [switch]$DisableSmartScreen,
    [switch]$BlockTelemetryIPs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# --- CONFIG ---
$ScriptDir  = 'C:\ProgramData\TelemetryGuard'
$BackupDir  = "$ScriptDir\backups"
$LogDir     = "$ScriptDir\logs"
$LogFile    = "$LogDir\telemetry-$(Get-Date -f 'yyyyMMdd-HHmmss').log"
$BackupFile = "$BackupDir\telemetry-backup-$(Get-Date -f 'yyyyMMdd-HHmmss').reg"
$Global:Stats = @{ Applied = 0; Skipped = 0; Errors = 0 }

foreach ($dir in @($ScriptDir, $BackupDir, $LogDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# --- FONCTIONS ---

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord',
        [string]$Description = ''
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        $Global:Stats.Applied++
        Write-Log "  OK  $Description [$Name=$Value]" 'OK'
    }
    catch {
        $Global:Stats.Errors++
        Write-Log "  ERR $Description [$Name] : $_" 'ERROR'
    }
}

function Disable-ScheduledTaskSafe {
    param([string]$TaskPath, [string]$TaskName)
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName | Out-Null
            $Global:Stats.Applied++
            Write-Log "  OK  Tache desactivee : $TaskPath$TaskName" 'OK'
        }
        else {
            $Global:Stats.Skipped++
            Write-Log "  SKP Tache introuvable : $TaskPath$TaskName" 'WARN'
        }
    }
    catch {
        $Global:Stats.Errors++
        Write-Log "  ERR Tache $TaskPath$TaskName : $_" 'ERROR'
    }
}

function Stop-And-DisableService {
    param([string]$ServiceName, [string]$Description)
    try {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service  -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Set-Service   -Name $ServiceName -StartupType Disabled
            $Global:Stats.Applied++
            Write-Log "  OK  Service desactive : $Description ($ServiceName)" 'OK'
        }
        else {
            $Global:Stats.Skipped++
            Write-Log "  SKP Service introuvable : $ServiceName" 'WARN'
        }
    }
    catch {
        $Global:Stats.Errors++
        Write-Log "  ERR Service $ServiceName : $_" 'ERROR'
    }
}

# Rotation inline (standalone, pas de dependance a Common.ps1)
function Invoke-LocalRotation {
    param([string]$Path, [string]$Pattern, [int]$Keep)
    if (-not (Test-Path $Path)) { return }
    $files = Get-ChildItem -Path $Path -Filter $Pattern -File | Sort-Object LastWriteTime -Descending
    if ($files.Count -le $Keep) { return }
    $files | Select-Object -Skip $Keep | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Log "  Rotation : supprime $($_.Name)" 'INFO'
    }
}

# =============================================================
# BACKUP REGISTRY
# =============================================================
Write-Log "=== BACKUP REGISTRY ===" 'INFO'

$regKeys = @(
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection',
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo',
    'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack',
    'HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice'
)

$backupContent = "Windows Registry Editor Version 5.00`r`n`r`n"
foreach ($key in $regKeys) {
    $tmpFile = "$env:TEMP\tmpkey_$([System.IO.Path]::GetRandomFileName()).reg"
    $null    = & reg export $key $tmpFile /y 2>&1
    if (Test-Path $tmpFile) {
        $backupContent += (Get-Content $tmpFile -Raw)
        Remove-Item $tmpFile -Force
    }
}
Set-Content -Path $BackupFile -Value $backupContent -Encoding Unicode
Write-Log "Backup cree : $BackupFile (restaurer avec : reg import `"$BackupFile`")" 'OK'

# =============================================================
# SECTION 1 - SERVICES
# =============================================================
Write-Log "`n=== SECTION 1 : SERVICES ===" 'INFO'
Stop-And-DisableService 'DiagTrack'                              'Connected User Experiences and Telemetry'
Stop-And-DisableService 'dmwappushservice'                       'WAP Push Message Routing'
Stop-And-DisableService 'diagnosticshub.standardcollector.service' 'Microsoft Diagnostics Hub Standard Collector'
Stop-And-DisableService 'WerSvc'                                 'Windows Error Reporting Service'
Stop-And-DisableService 'PcaSvc'                                 'Program Compatibility Assistant Service'

# =============================================================
# SECTION 2 - REGISTRY DATA COLLECTION
# =============================================================
Write-Log "`n=== SECTION 2 : REGISTRY DATA COLLECTION ===" 'INFO'

$dcPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'
$dcPath2 = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$dcPath3 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack'

$edition  = (Get-WindowsEdition -Online -ErrorAction SilentlyContinue).Edition
$telLevel = if ($edition -match 'Enterprise|Education') { 0 } else { 1 }
Set-RegValue $dcPath  'AllowTelemetry'             $telLevel 'DWord' "Niveau telemetrie minimum ($telLevel)"
Set-RegValue $dcPath  'MaxTelemetryAllowed'        $telLevel 'DWord' "Niveau telemetrie max"
Set-RegValue $dcPath  'DisableEnterpriseAuthProxy' 1        'DWord' "Desactiver proxy auth telemetrie"
Set-RegValue $dcPath  'CommercialDataOptIn'        0        'DWord' "Commercial data opt-in"
Set-RegValue $dcPath2 'AllowTelemetry'             $telLevel 'DWord' "Policy AllowTelemetry"
Set-RegValue $dcPath3 'DiagTrackAuthorization'     0        'DWord' "DiagTrack Authorization"

$appCompatPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags'
Set-RegValue $appCompatPath 'AITEnable' 0 'DWord' "Application Impact Telemetry"

$censusPath = 'HKLM:\SOFTWARE\Microsoft\DeviceMetadataService'
Set-RegValue $censusPath 'PreventDeviceMetadataFromNetwork' 1 'DWord' "Device Metadata from Network"

# SmartScreen : conditionnel selon -DisableSmartScreen
if ($DisableSmartScreen) {
    $smartscreenPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    Set-RegValue $smartscreenPath 'EnableSmartScreen' 0 'DWord' "SmartScreen Network Check (desactive)"
    # SmartScreen Store/Defender (Policies > MicrosoftDefender SmartScreen)
    $ssSPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen'
    Set-RegValue $ssSPath 'ConfigureAppInstallControl' 0 'DWord' "SmartScreen App Install Control (desactive)"
}
else {
    $Global:Stats.Skipped++
    Write-Log "  SKP SmartScreen : garde actif (defaut, -DisableSmartScreen non specifie)" 'WARN'
}

# =============================================================
# SECTION 3 - CEIP
# =============================================================
Write-Log "`n=== SECTION 3 : CEIP ===" 'INFO'
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows'         'CEIPEnable' 0 'DWord' "CEIP Enable"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0 'DWord' "CEIP Enable (policy)"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\SQMClient'                  'OptIn'      0 'DWord' "SQM OptIn"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\MRT'               'DontReportInfectionInformation' 1 'DWord' "MRT Infection Reporting"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\PCHealth\ErrorReporting'    'DoReport'   0 'DWord' "Watson DoReport"

# =============================================================
# SECTION 4 - TACHES PLANIFIEES
# =============================================================
Write-Log "`n=== SECTION 4 : TACHES PLANIFIEES ===" 'INFO'

$tasks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'StartupAppTask' },
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'MareBackup' },
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'PcaPatchDbTask' },
    @{ Path = '\Microsoft\Windows\Autochk\';                Name = 'Proxy' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
    @{ Path = '\Microsoft\Windows\DiskDiagnostic\';         Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\';          Name = 'DmClient' },
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\';          Name = 'DmClientOnScenarioDownload' },
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting' },
    @{ Path = '\Microsoft\Windows\Maps\';                   Name = 'MapsToastTask' },
    @{ Path = '\Microsoft\Windows\Maps\';                   Name = 'MapsUpdateTask' },
    @{ Path = '\Microsoft\Windows\NetTrace\';               Name = 'GatherNetworkInfo' },
    @{ Path = '\Microsoft\Windows\PI\';                     Name = 'Sqm-Tasks' },
    @{ Path = '\Microsoft\Windows\Power Efficiency Diagnostics\'; Name = 'AnalyzeSystem' },
    @{ Path = '\Microsoft\Windows\Speech\';                 Name = 'SpeechModelDownloadTask' },
    @{ Path = '\Microsoft\Windows\License Manager\';        Name = 'TempSignedLicenseExchange' }
)
foreach ($t in $tasks) { Disable-ScheduledTaskSafe -TaskPath $t.Path -TaskName $t.Name }

# =============================================================
# SECTION 5 - ADVERTISING & PRIVACY
# =============================================================
Write-Log "`n=== SECTION 5 : ADVERTISING & PRIVACY ===" 'INFO'
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled'               0 'DWord' "Advertising ID"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'DisabledByGroupPolicy' 1 'DWord' "Advertising ID - Group Policy"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'       'DisabledByGroupPolicy' 1 'DWord' "Advertising ID Policy"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                'EnableActivityFeed'    0 'DWord' "Activity Feed"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                'PublishUserActivities' 0 'DWord' "Publish User Activities"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                'UploadUserActivities'  0 'DWord' "Upload User Activities"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'                             'NumberOfSIUFInPeriod'  0 'DWord' "Feedback frequency"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'                             'PeriodInNanoSeconds'   0 'DWord' "Feedback period"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'         'TailoredExperiencesWithDiagnosticDataEnabled' 0 'DWord' "Tailored Experiences"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\InputPersonalization'                   'RestrictImplicitInkCollection'  1 'DWord' "Restrict Ink Collection"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\InputPersonalization'                   'RestrictImplicitTextCollection' 1 'DWord' "Restrict Text Collection"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore'  'HarvestContacts' 0 'DWord' "Harvest Contacts"

# =============================================================
# SECTION 6 - CORTANA & SEARCH
# =============================================================
Write-Log "`n=== SECTION 6 : CORTANA & SEARCH ===" 'INFO'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana'          0 'DWord' "Allow Cortana"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch'      1 'DWord' "Disable Web Search"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0 'DWord' "Connected Search Use Web"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortanaAboveLock' 0 'DWord' "Cortana Above Lock"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'   'BingSearchEnabled'     0 'DWord' "Bing Search Enabled"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'   'CortanaConsent'        0 'DWord' "Cortana Consent"

# =============================================================
# SECTION 7 - WINDOWS ERROR REPORTING
# =============================================================
Write-Log "`n=== SECTION 7 : WINDOWS ERROR REPORTING ===" 'INFO'
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'          'Disabled'                  1 'DWord' "WER Disabled"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'          'DontSendAdditionalData'    1 'DWord' "WER DontSendAdditionalData"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'          'LoggingDisabled'           1 'DWord' "WER LoggingDisabled"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled'                  1 'DWord' "WER Policy Disabled"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'DontSendAdditionalData'    1 'DWord' "WER Policy DontSendAdditional"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Consent'  'DefaultConsent'            1 'DWord' "WER Default Consent"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Consent'  'DefaultOverrideBehavior'   1 'DWord' "WER Override Behavior"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\PCHealth\ErrorReporting\DW'               'DWNoExternalURL'           1 'DWord' "Dr Watson No External URL"

# =============================================================
# SECTION 8 - WINDOWS UPDATE TELEMETRY & DELIVERY OPT
# =============================================================
Write-Log "`n=== SECTION 8 : WINDOWS UPDATE TELEMETRY ===" 'INFO'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'                    'DODownloadMode' 0 'DWord' "Delivery Optimization (HTTP only)"
Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'       'DODownloadMode' 0 'DWord' "Delivery Optimization Config"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'                    'DOSetHoursToLimitBackgroundDownloadBandwidth' 0 'DWord' "DO Bandwidth reporting"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'                           'DisableWindowsUpdateAccess' 0 'DWord' "WU Access (preserve)"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'                        'NoAutoRebootWithLoggedOnUsers' 1 'DWord' "WU No Auto Reboot"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin'                           'BlockAADWorkplaceJoin' 1 'DWord' "Block AAD Workplace Join telemetry"

# =============================================================
# SECTION 9 - AUTOLOGGER / ETW SESSIONS
# =============================================================
Write-Log "`n=== SECTION 9 : AUTOLOGGER / ETW ===" 'INFO'
$autoLogBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
foreach ($logger in @('AutoLogger-Diagtrack-Listener','SQMLogger','DIAGTRACK','Diagtrack-Listener')) {
    $path = "$autoLogBase\$logger"
    if (Test-Path $path) { Set-RegValue $path 'Start' 0 'DWord' "AutoLogger desactive : $logger" }
    else { $Global:Stats.Skipped++; Write-Log "  SKP AutoLogger introuvable : $logger" 'WARN' }
}
Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\DiagTrack\Settings' 'DiagTrackBootComplete'  0 'DWord' "DiagTrack Boot Trace"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'        'AITEnable'              0 'DWord' "Application Impact Telemetry Policy"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'        'DisableInventory'       1 'DWord' "Application Inventory Disabled"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'        'DisableUAR'             1 'DWord' "Steps Recorder"

# =============================================================
# SECTION 10 - ONEDRIVE TELEMETRY
# =============================================================
Write-Log "`n=== SECTION 10 : ONEDRIVE ===" 'INFO'
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'DisablePersonalSync'                    0 'DWord' "OneDrive Sync (preserve)"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'PreventNetworkTrafficPreUserSignIn'      1 'DWord' "OneDrive pre-auth network traffic"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\OneDrive'          'EnableADAL'                             0 'DWord' "OneDrive ADAL telemetry"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\OneDrive\global'   'EnableSyncDiagReporting'                0 'DWord' "OneDrive Diagnostic Reporting"

# =============================================================
# SECTION 11 - EDGE / IE
# =============================================================
Write-Log "`n=== SECTION 11 : EDGE/IE ===" 'INFO'

# SmartScreen Edge : conditionnel selon -DisableSmartScreen
if ($DisableSmartScreen) {
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 0 'DWord' "Edge SmartScreen (desactive)"
}
else {
    $Global:Stats.Skipped++
    Write-Log "  SKP Edge SmartScreen : garde actif" 'WARN'
}

Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'MetricsReportingEnabled'       0 'DWord' "Edge Metrics Reporting"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SendSiteInfoToImproveServices' 0 'DWord' "Edge Send Site Info"
Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\SQM' 'DisableCustomerImprovementProgram' 1 'DWord' "IE CEIP"
Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Internet Explorer\Main' 'DoNotTrack' 1 'DWord' "IE Do Not Track"

# =============================================================
# SECTION 12 - REGLES FIREWALL (optionnel)
# =============================================================
Write-Log "`n=== SECTION 12 : FIREWALL ===" 'INFO'

if ($BlockTelemetryIPs) {
    $firewallRules = @(
        @{ Name = 'Block-Telemetry-DiagTrack'; RemoteAddress = '134.170.30.202' },
        @{ Name = 'Block-Telemetry-MSFT-1';    RemoteAddress = '137.116.81.24'  },
        @{ Name = 'Block-Telemetry-MSFT-2';    RemoteAddress = '157.56.106.189' },
        @{ Name = 'Block-Telemetry-MSFT-3';    RemoteAddress = '184.86.53.99'   }
    )
    foreach ($rule in $firewallRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue) {
                Write-Log "  SKP Regle deja existante : $($rule.Name)" 'WARN'
                $Global:Stats.Skipped++
            }
            else {
                New-NetFirewallRule -DisplayName $rule.Name -Direction Outbound -Action Block `
                    -RemoteAddress $rule.RemoteAddress -Protocol Any -Enabled True | Out-Null
                $Global:Stats.Applied++
                Write-Log "  OK  Regle firewall : $($rule.Name) -> $($rule.RemoteAddress)" 'OK'
            }
        }
        catch {
            $Global:Stats.Errors++
            Write-Log "  ERR Regle $($rule.Name) : $_" 'ERROR'
        }
    }
}
else {
    $Global:Stats.Skipped += 4
    Write-Log "  SKP Regles firewall IP : ignorees (-BlockTelemetryIPs non specifie)" 'WARN'
}

# =============================================================
# SECTION 13 - HOSTS FILE
# =============================================================
Write-Log "`n=== SECTION 13 : HOSTS FILE ===" 'INFO'

$hostsPath   = 'C:\Windows\System32\drivers\etc\hosts'
$hostsBackup = "$BackupDir\hosts-backup-$(Get-Date -f 'yyyyMMdd-HHmmss').txt"
Copy-Item $hostsPath $hostsBackup -ErrorAction SilentlyContinue

$telemetryHosts = @(
    '0.0.0.0 vortex.data.microsoft.com',
    '0.0.0.0 vortex-win.data.microsoft.com',
    '0.0.0.0 telecommand.telemetry.microsoft.com',
    '0.0.0.0 settings-win.data.microsoft.com'
)

$hostsContent = Get-Content $hostsPath -Raw
$marker       = '# === TELEMETRY BLOCK (added by PC-Refresh-Kit) ==='

if ($hostsContent -notlike "*$marker*") {
    try {
        $additions  = "`n$marker`n" + ($telemetryHosts -join "`n") + "`n# === END TELEMETRY BLOCK ===`n"
        [System.IO.File]::WriteAllText($hostsPath, $hostsContent + $additions, [System.Text.Encoding]::UTF8)
        $Global:Stats.Applied += $telemetryHosts.Count
        Write-Log "  OK  $($telemetryHosts.Count) entrees hosts ajoutees" 'OK'
    }
    catch {
        $Global:Stats.Errors++
        Write-Log "  ERR Hosts file : $_" 'ERROR'
    }
}
else {
    $Global:Stats.Skipped += $telemetryHosts.Count
    Write-Log "  SKP Entrees hosts deja presentes (idempotent)" 'WARN'
}

# =============================================================
# ROTATION (15 fichiers max)
# =============================================================
Invoke-LocalRotation -Path $BackupDir -Pattern '*.reg' -Keep 15
Invoke-LocalRotation -Path $BackupDir -Pattern '*.txt' -Keep 15
Invoke-LocalRotation -Path $LogDir    -Pattern '*.log' -Keep 15

# =============================================================
# RAPPORT FINAL
# =============================================================
Write-Log "`n=== RAPPORT FINAL ===" 'INFO'
Write-Log "Appliques : $($Global:Stats.Applied) | Ignores : $($Global:Stats.Skipped) | Erreurs : $($Global:Stats.Errors)" 'OK'
Write-Log "Log       : $LogFile" 'INFO'
Write-Log "Backup    : $BackupFile" 'INFO'
Write-Log "SmartScreen desactive : $($DisableSmartScreen.IsPresent)" 'INFO'
Write-Log "IPs bloquees par firewall : $($BlockTelemetryIPs.IsPresent)" 'INFO'

# Verification rapide
foreach ($svc in @('DiagTrack','dmwappushservice','WerSvc')) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
        $status = if ($s.StartType -eq 'Disabled') { 'OK - Disabled' } else { "ATTENTION - $($s.StartType)" }
        Write-Log "  Service $svc : $status"
    }
}
$tl = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name AllowTelemetry -ErrorAction SilentlyContinue).AllowTelemetry
Write-Log "  AllowTelemetry = $tl (0=Off, 1=Basic attendu sur Pro)"
Write-Log "`nRedemarrage recommande pour activer tous les changements." 'WARN'
