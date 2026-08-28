# modules/10-Report.ps1 - Rapport d'intervention final
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\10-Report.ps1 [-WhatIf]
# Lecture seule : ne modifie pas le système, peut être exécuté sans droits admin.

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"

Write-KitLog -Message "=== 10-Report : début ===" -Level 'INFO'

$runtimeDir   = Join-Path $PSScriptRoot '..\runtime'
$templatesDir = Join-Path $PSScriptRoot '..\templates'
$dateStr      = Get-Date -Format 'yyyy-MM-dd_HHmm'
$reportFile   = Join-Path $runtimeDir "RAPPORT-$env:COMPUTERNAME-$dateStr.txt"

if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# ---------------------------------------------------------------------------
# 1. Collecter les logs du run
# ---------------------------------------------------------------------------
$logsDir  = Join-Path $runtimeDir 'logs'
$logFiles = @()
# On ne compte QUE le run courant : tous les modules d'un même run écrivent dans
# le log partagé $env:KIT_LOG_FILE. Lire tous les *.log agrégeait les runs
# précédents et gonflait le bilan (OK:125 au lieu de OK:73 au run réel).
$currentRunLog = $null
if ($env:KIT_LOG_FILE -and (Test-Path $env:KIT_LOG_FILE)) {
    $currentRunLog = Get-Item -LiteralPath $env:KIT_LOG_FILE -ErrorAction SilentlyContinue
}
elseif (Test-Path $logsDir) {
    # Module lancé seul (hors orchestrateur) : on prend le log le plus récent.
    $currentRunLog = Get-ChildItem -Path $logsDir -Filter '*.log' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime | Select-Object -Last 1
}
if ($currentRunLog) {
    $logFiles = @($currentRunLog)
    Write-KitLog -Message "Bilan scopé au run courant : $($currentRunLog.Name)" -Level 'INFO'
}
else {
    Write-KitLog -Message "Aucun log de run trouvé dans $logsDir." -Level 'WARN'
}

# ---------------------------------------------------------------------------
# 2. Charger le diagnostic JSON si disponible
# ---------------------------------------------------------------------------
$diagJson = $null
$diagFile = Get-ChildItem -Path $runtimeDir -Filter "diagnostic-$env:COMPUTERNAME.json" -ErrorAction SilentlyContinue |
            Select-Object -First 1
if ($diagFile) {
    try {
        $diagJson = Get-Content $diagFile.FullName -Encoding UTF8 | ConvertFrom-Json
        Write-KitLog -Message "Diagnostic JSON chargé." -Level 'OK'
    }
    catch {
        Write-KitLog -Message "Lecture diagnostic JSON impossible : $_" -Level 'WARN'
    }
}
else {
    Write-KitLog -Message "Diagnostic JSON absent (module 00 non exécuté ?)." -Level 'WARN'
}

# ---------------------------------------------------------------------------
# 3. Charger la fiche PC si disponible
# ---------------------------------------------------------------------------
$ficheFile    = Join-Path $runtimeDir "FICHE-PC-$env:COMPUTERNAME.txt"
$ficheContent = ''
if (Test-Path $ficheFile) {
    $ficheContent = Get-Content $ficheFile -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    Write-KitLog -Message "Fiche PC chargée." -Level 'OK'
}

# ---------------------------------------------------------------------------
# 3b. Charger les findings extensions navigateur (module 13) si disponibles
# ---------------------------------------------------------------------------
$extFindings  = $null
$findingsFile = Join-Path $runtimeDir "browser-findings-$env:COMPUTERNAME.json"
if (Test-Path $findingsFile) {
    try {
        $extFindings = Get-Content $findingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-KitLog -Message "Findings extensions navigateur chargés." -Level 'OK'
    }
    catch {
        Write-KitLog -Message "Lecture findings extensions impossible : $_" -Level 'WARN'
    }
}

$extWhitelist = @()
$pupCfgPath   = Join-Path $PSScriptRoot '..\config\browser-pup.json'
if (Test-Path $pupCfgPath) {
    try {
        $pupCfg       = Get-Content $pupCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $extWhitelist = @(Get-JsonProp $pupCfg 'extensionWhitelist')
    }
    catch { Write-KitLog -Message "Config PUP illisible pour liste blanche : $_" -Level 'WARN' }
}

# ---------------------------------------------------------------------------
# 4. Compter les événements dans les logs
# ---------------------------------------------------------------------------
$countOK    = 0
$countWarn  = 0
$countError = 0
$allLines   = [System.Collections.Generic.List[string]]::new()

foreach ($lf in $logFiles) {
    $lines = Get-Content $lf.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($lines) {
        foreach ($l in $lines) { $allLines.Add($l) }
        # @() obligatoire : avec exactement 1 correspondance, Where-Object renvoie un
        # scalaire dont .Count leve sous StrictMode Latest (bilan ERROR:1 compté 0 au run réel).
        $countOK    += @($lines | Where-Object { $_ -match '\[OK\]' }).Count
        $countWarn  += @($lines | Where-Object { $_ -match '\[WARN\]' }).Count
        $countError += @($lines | Where-Object { $_ -match '\[ERROR\]' }).Count
    }
}

# Contrat (a) de Get-RebootMarkersFromLogs (retour ,@(...)) : ASSIGNER puis
# envelopper. En enveloppe directe, .Count valait 1 même sans marqueur et le
# rapport réclamait un redémarrage à chaque intervention.
$markers       = Get-RebootMarkersFromLogs -Lines $allLines
$rebootMarkers = @($markers)
$rebootState   = Test-RebootPending
$rebootNeeded  = ($rebootMarkers.Count -gt 0) -or $rebootState.Pending

# ---------------------------------------------------------------------------
# Recapture de l'état "après" (mêmes champs que le Snapshot du module 00) et
# calcul du delta avant/après. $before vient du diag ; $after est l'état courant.
# ---------------------------------------------------------------------------
$before = $null
if ($diagJson -and $diagJson.PSObject.Properties['Snapshot']) { $before = $diagJson.Snapshot }

$afterVolumes = @()
try {
    $afterVolumes = @(Get-Volume -ErrorAction Stop |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { [PSCustomObject]@{ DriveLetter = [string]$_.DriveLetter; FreeBytes = [int64]$_.SizeRemaining } })
}
catch { }
$afterStartup = 0
try { $afterStartup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop).Count } catch { }
$after = [PSCustomObject]@{
    Volumes        = $afterVolumes
    StartupCount   = $afterStartup
    Win32Apps      = @(Get-Win32AppNames)
    BootDurationMs = (Get-LastBootDurationMs)
}
$delta = Get-ReportDelta -Before $before -After $after
# Source unique des métadonnées machine (machine/cpu/ram/volumes/antivirus) partagée
# par le bloc TXT et le bloc HTML. Remplace la double extraction dupliquée.
$diagMeta = Get-MetaFromDiag -Diag $diagJson

# Santé machine pour le rapport HTML v1.8 : lecture défensive du diag.
# $health = $null si le diag est absent (section non rendue dans le HTML).
$health = $null
if ($diagJson) {
    $health = [PSCustomObject]@{
        Smart        = $(if ($diagJson.PSObject.Properties['SmartDetails'])      { $diagJson.SmartDetails }      else { @() })
        BitLocker    = $(if ($diagJson.PSObject.Properties['BitLocker'])         { $diagJson.BitLocker }         else { @() })
        ErrorDevices = $(if ($diagJson.PSObject.Properties['ErrorDevices'])      { $diagJson.ErrorDevices }      else { @() })
        Activation   = $(if ($diagJson.PSObject.Properties['WindowsActivation']) { $diagJson.WindowsActivation } else { $null })
    }
}
# Delta passé au HTML uniquement si un snapshot "avant" était disponible.
$deltaParam = if ($null -ne $before) { $delta } else { $null }
# Sentinelle résilience (module 00, v2.4) : $null sur un diagnostic antérieur,
# la carte « Filets de sécurité » est alors simplement omise du rapport HTML.
$resilience = Get-JsonProp $diagJson 'Resilience'

# ---------------------------------------------------------------------------
# 5. Assembler et écrire le rapport
# ---------------------------------------------------------------------------
if ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait généré $reportFile" -Level 'WHATIF'
    Write-KitLog -Message "WHATIF: Aurait aussi généré le rapport HTML ($([System.IO.Path]::ChangeExtension($reportFile, '.html')))" -Level 'WHATIF'
    Write-KitLog -Message "WHATIF: $($allLines.Count) ligne(s) de log - OK:$countOK WARN:$countWarn ERROR:$countError" -Level 'WHATIF'
}
else {
    $sb = [System.Text.StringBuilder]::new()

    $sb.AppendLine("=== RAPPORT D'INTERVENTION PC-Refresh-Kit ===") | Out-Null
    $sb.AppendLine("Machine      : $env:COMPUTERNAME") | Out-Null
    $sb.AppendLine("Opérateur    : $env:USERNAME") | Out-Null
    $sb.AppendLine("Date rapport : $(Get-Date -Format 'yyyy-MM-dd HH:mm')") | Out-Null
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("--- BILAN ---") | Out-Null
    $sb.AppendLine("OK     : $countOK") | Out-Null
    $sb.AppendLine("WARN   : $countWarn") | Out-Null
    $sb.AppendLine("ERROR  : $countError") | Out-Null
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("--- CE QUE L'INTERVENTION A CHANGÉ ---") | Out-Null
    if ($null -ne $before) {
        foreach ($line in @($delta.Lines)) { $sb.AppendLine($line) | Out-Null }
        if ($null -ne $delta.BootBeforeMs) {
            $bootAfterTxt = $(if ($null -ne $delta.BootAfterMs) { Format-BootDuration -Milliseconds $delta.BootAfterMs } else { "mesuré au prochain démarrage (relancer Lancer-Rapport.bat)" })
            $sb.AppendLine("Temps de démarrage : $(Format-BootDuration -Milliseconds $delta.BootBeforeMs) -> $bootAfterTxt") | Out-Null
        }
        if (@($delta.AppsRemoved).Count -gt 0) {
            $sb.AppendLine("  Retirées : $((@($delta.AppsRemoved) | Select-Object -First 20) -join ', ')") | Out-Null
        }
    }
    else {
        $sb.AppendLine("Delta avant/après indisponible (diagnostic antérieur à cette version)") | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("--- REDÉMARRAGE ---") | Out-Null
    if ($rebootNeeded) {
        $why = @()
        if ($rebootState.Pending) { $why += $rebootState.Reasons }
        if ($rebootMarkers.Count -gt 0) { $why += "$($rebootMarkers.Count) action(s) du kit signalent un reboot" }
        $sb.AppendLine("REDÉMARRAGE REQUIS avant de livrer le PC.") | Out-Null
        $sb.AppendLine("Raison(s) : $($why -join ' ; ')") | Out-Null
    }
    else {
        $sb.AppendLine("Aucun redémarrage requis détecté.") | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    if ($diagJson) {
        # Accès gardé via Get-JsonProp : sous StrictMode Latest, `$diagJson.cpu`
        # sur un diag incomplet LÈVE au lieu de valoir $null (piège aligné sur
        # la section HTML plus bas).
        if ($diagMeta.Manufacturer -or $diagMeta.Model -or $diagMeta.OS -or $diagMeta.Serial) {
            $sb.AppendLine("--- INFORMATIONS MACHINE ---") | Out-Null
            $sb.AppendLine("Fabricant  : $($diagMeta.Manufacturer)") | Out-Null
            $sb.AppendLine("Modèle     : $($diagMeta.Model)") | Out-Null
            $sb.AppendLine("Série      : $($diagMeta.Serial)") | Out-Null
            $sb.AppendLine("OS         : $($diagMeta.OS)") | Out-Null
        }
        if ($diagMeta.CPU) { $sb.AppendLine("CPU        : $($diagMeta.CPU)") | Out-Null }
        if ($diagMeta.RAM) { $sb.AppendLine("RAM        : $($diagMeta.RAM)") | Out-Null }
        if (@($diagMeta.Volumes).Count -gt 0) {
            $sb.AppendLine("") | Out-Null
            $sb.AppendLine("Volumes :") | Out-Null
            foreach ($v in @($diagMeta.Volumes)) {
                $sb.AppendLine("  $($v.Text)") | Out-Null
            }
        }
        if (@($diagMeta.Antivirus).Count -gt 0) {
            $sb.AppendLine("") | Out-Null
            $sb.AppendLine("Antivirus :") | Out-Null
            foreach ($name in @($diagMeta.Antivirus)) {
                $sb.AppendLine("  - $name") | Out-Null
            }
        }
        $sb.AppendLine("") | Out-Null

        # --- Santé machine (SMART, BitLocker, pilotes en erreur, activation Windows) ---
        $sb.AppendLine("--- SANTÉ MACHINE ---") | Out-Null
        $smart = @(Get-JsonProp $diagJson 'SmartDetails')
        foreach ($d in $smart) {
            $alertVal = Get-JsonProp $d 'Alert'
            $flag = if ($alertVal) { " [ALERTE : $(Get-JsonProp $d 'AlertReason')]" } else { '' }
            $wearPct = Get-JsonProp $d 'WearPct'
            $wear = if ($null -ne $wearPct) { "usure $wearPct%" } else { 'usure n/d' }
            $sb.AppendLine("Disque $(Get-JsonProp $d 'FriendlyName') : $wear$flag") | Out-Null
        }
        $bl = @(Get-JsonProp $diagJson 'BitLocker')
        foreach ($b in $bl) { $sb.AppendLine("BitLocker $(Get-JsonProp $b 'DriveLetter') : $(Get-JsonProp $b 'Label')") | Out-Null }
        $ed = @(Get-JsonProp $diagJson 'ErrorDevices')
        if ($ed.Count -gt 0) { $sb.AppendLine("Pilotes en erreur : $($ed.Count)") | Out-Null }
        $act = Get-JsonProp $diagJson 'WindowsActivation'
        if ($act) { $sb.AppendLine("Activation Windows : $(Get-JsonProp $act 'StatusLabel')") | Out-Null }
        $sb.AppendLine("") | Out-Null
    }

    # --- Extensions navigateur force-installées (findings module 13) ---
    $forceExtIds = @()
    if ($extFindings -and $extFindings.PSObject.Properties['ForceInstalledExtensionIds']) {
        $forceExtIds = @($extFindings.ForceInstalledExtensionIds)
    }
    if ($forceExtIds.Count -gt 0) {
        $sb.AppendLine("--- EXTENSIONS NAVIGATEUR (force-installées) ---") | Out-Null
        foreach ($eid in $forceExtIds) {
            $cls = Get-ExtensionClassification -Id $eid -Whitelist $extWhitelist
            if ($cls.IsKnown) {
                $sb.AppendLine("  $eid : connue - OK") | Out-Null
            }
            else {
                $sb.AppendLine("  $eid : à vérifier - $($cls.Url)") | Out-Null
            }
        }
        $sb.AppendLine("") | Out-Null
    }

    if ($ficheContent) {
        # Le mot de passe n'est JAMAIS recopie ici : il ne doit exister que dans
        # la fiche PC, seul fichier que l'operateur supprime avant de rendre la cle.
        $sb.AppendLine("--- FICHE PC ---") | Out-Null
        $sb.AppendLine((Remove-PasswordLines -Text $ficheContent)) | Out-Null
        $sb.AppendLine("") | Out-Null
    }

    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("--- JOURNAL COMPLET ---") | Out-Null
    if ($currentRunLog) {
        $sb.AppendLine("Journal détaillé : $($currentRunLog.FullName)") | Out-Null
        $sb.AppendLine("($($allLines.Count) lignes - consultable dans runtime\logs\)") | Out-Null
    }
    else {
        $sb.AppendLine("Journal non localisé.") | Out-Null
    }

    Set-Content -Path $reportFile -Value $sb.ToString() -Encoding UTF8
    Write-KitLog -Message "Rapport généré : $reportFile" -Level 'OK'
    Write-KitLog -Message "Bilan final - OK:$countOK WARN:$countWarn ERROR:$countError" -Level $(if ($countError -eq 0) { 'OK' } else { 'WARN' })

    # --- Rapport HTML (v1.8) : livrable présentable, en plus du TXT (rétrocompatible) ---
    $htmlFile = [System.IO.Path]::ChangeExtension($reportFile, '.html')
    $summary  = Get-ReportSummary -Lines @($allLines)
    $meta = @{
        ComputerName = $env:COMPUTERNAME
        Operator     = $env:USERNAME
        Generated    = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        KitVersion   = (Get-KitVersion)
    }
    if ($diagMeta.Manufacturer) { $meta['Manufacturer'] = [string]$diagMeta.Manufacturer }
    if ($diagMeta.Model)        { $meta['Model']        = [string]$diagMeta.Model }
    if ($diagMeta.Serial)       { $meta['Serial']       = [string]$diagMeta.Serial }
    if ($diagMeta.OS)           { $meta['OS']           = [string]$diagMeta.OS }
    if ($diagMeta.CPU)          { $meta['CPU']          = [string]$diagMeta.CPU }
    if ($diagMeta.RAM)          { $meta['RAM']          = [string]$diagMeta.RAM }

    # Volumes et antivirus : mêmes valeurs que le rapport TXT (source unique Get-MetaFromDiag).
    $volHtml = @($diagMeta.Volumes | ForEach-Object { $_.Text })
    $avHtml  = @($diagMeta.Antivirus)

    $rebootReasonsHtml = @()
    if ($rebootState.Pending)       { $rebootReasonsHtml += $rebootState.Reasons }
    if ($rebootMarkers.Count -gt 0) { $rebootReasonsHtml += "$($rebootMarkers.Count) action(s) du kit signalent un reboot" }

    try {
        $html = ConvertTo-ReportHtml -Summary $summary -Meta $meta -RebootNeeded $rebootNeeded `
                    -RebootReasons $rebootReasonsHtml -Lines @($allLines) -Volumes $volHtml -Antivirus $avHtml `
                    -Delta $deltaParam -Health $health -Resilience $resilience

        # --- Section Extensions navigateur (injection dans le HTML avant </main>) ---
        if ($forceExtIds.Count -gt 0) {
            $extHtmlSb = [System.Text.StringBuilder]::new()
            [void]$extHtmlSb.Append('<h2>Extensions navigateur (force-installées)</h2><ul>')
            foreach ($eid in $forceExtIds) {
                $cls    = Get-ExtensionClassification -Id $eid -Whitelist $extWhitelist
                $safeId = ConvertTo-HtmlEncoded $eid
                if ($cls.IsKnown) {
                    [void]$extHtmlSb.Append("<li>$safeId : <span style='color:#16a34a'>connue - OK</span></li>")
                }
                else {
                    $safeUrl = ConvertTo-HtmlEncoded $cls.Url
                    [void]$extHtmlSb.Append("<li>$safeId : <span style='color:#d97706'>à vérifier</span> - <a href='$safeUrl' target='_blank'>fiche Chrome Web Store</a></li>")
                }
            }
            [void]$extHtmlSb.Append('</ul>')
            $html = $html.Replace('</main>', ($extHtmlSb.ToString() + '</main>'))
        }

        [System.IO.File]::WriteAllText($htmlFile, $html, (New-Object System.Text.UTF8Encoding($false)))
        Write-KitLog -Message "Rapport HTML généré : $htmlFile" -Level 'OK'
    }
    catch {
        Write-KitLog -Message "Génération du rapport HTML impossible : $_ (le rapport TXT reste disponible)." -Level 'WARN'
    }

    # Ouvrir dans Notepad++ si disponible
    $npp = 'C:\Program Files\Notepad++\notepad++.exe'
    if (Test-Path $npp) {
        Start-Process $npp -ArgumentList "`"$reportFile`""
        Write-KitLog -Message "Rapport ouvert dans Notepad++." -Level 'OK'
    }
    else {
        Write-KitLog -Message "Pour lire le rapport : $reportFile" -Level 'INFO'
    }
}

# ---------------------------------------------------------------------------
# Copier la note utilisateur dans runtime/
# ---------------------------------------------------------------------------
$noteTemplate = Join-Path $templatesDir 'NOTE-UTILISATEUR.md'
$noteDest     = Join-Path $runtimeDir "NOTE-UTILISATEUR-$env:COMPUTERNAME.md"

if (Test-Path $noteTemplate) {
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: Copier NOTE-UTILISATEUR.md vers $noteDest" -Level 'WHATIF'
    }
    else {
        # Personnalisation de la note : remplacement des placeholders navigateur, sauvegarde, BitLocker
        $noteContent = Get-Content $noteTemplate -Raw -Encoding UTF8
        $db    = Get-JsonProp $diagJson 'DefaultBrowser'
        $dbTxt = $(if ($db) { Get-JsonProp $db 'Label' } else { 'inconnu' })
        if ($db -and -not (Get-JsonProp $db 'IsFirefox')) { $dbTxt += " (envisager Firefox pour la vie privée)" }
        # Détection backup via le log du run courant (01-Backup.ps1 ne crée pas de manifeste fichier)
        $backupDone = @($allLines | Where-Object { $_ -match 'Backup data terminé dans' }).Count -gt 0
        $backupTxt  = $(if ($backupDone) { 'réalisée (voir le disque externe)' } else { 'non réalisée lors de cette intervention' })
        $blNote = ''
        $blList = @(Get-JsonProp $diagJson 'BitLocker')
        if (@($blList | Where-Object { (Get-JsonProp $_ 'ProtectionStatus') -eq 1 }).Count -gt 0) {
            $blNote = 'Ce PC est chiffré (BitLocker) : vérifiez que la clé de récupération est sauvegardée sur votre compte Microsoft avant toute réinstallation.'
        }
        $noteContent = $noteContent.Replace('{{DEFAULT_BROWSER}}', $dbTxt).Replace('{{BACKUP_STATUS}}', $backupTxt).Replace('{{BITLOCKER_NOTE}}', $blNote)
        Set-Content -Path $noteDest -Value $noteContent -Encoding UTF8
        Write-KitLog -Message "Note utilisateur personnalisée générée : $noteDest" -Level 'OK'
    }
}
else {
    Write-KitLog -Message "Template NOTE-UTILISATEUR.md absent ($noteTemplate)." -Level 'WARN'
}

if (-not $WhatIf) {
    if ($rebootNeeded) {
        Write-KitLog -Message "=========================================================" -Level 'WARN'
        Write-KitLog -Message " REDÉMARRAGE REQUIS avant de livrer le PC (voir rapport)." -Level 'WARN'
        Write-KitLog -Message "=========================================================" -Level 'WARN'
        Set-Content -Path (Join-Path $runtimeDir 'reboot-required.flag') -Value ($rebootState.Reasons -join ',') -Encoding UTF8
    }
    else {
        $flag = Join-Path $runtimeDir 'reboot-required.flag'
        if (Test-Path $flag) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
    }
}

Write-KitLog -Message "=== 10-Report : terminé ===" -Level 'OK'
exit 0
