# lib/Report.ps1 - Rapport TXT/HTML, delta avant/après, helpers cockpit et
# extensions navigateur (dot-source par lib/Common.ps1). Ne pas dot-sourcer
# directement. UTF-8 avec BOM.

# ---------------------------------------------------------------------------
# Get-RebootMarkersFromLogs : extrait les lignes de log signalant un reboot.
# PURE/testable.
# ---------------------------------------------------------------------------
function Get-RebootMarkersFromLogs {
    param([string[]]$Lines)
    # Retour tableau FORCE (virgule unaire) : sans ça, @() vide retourné par une
    # fonction est déroulé en $null par le pipeline, et $null.Count lève sous
    # StrictMode Latest (bug observé au run réel dans 10-Report).
    if (-not $Lines) { return ,@() }
    $pattern = 'REBOOT REQUIS|reboot requis|RebootRequired|code 3010|redemarrage requis|necessiter un reboot'
    $markers = @($Lines | Where-Object { $_ -match $pattern })
    return ,$markers
}

# ---------------------------------------------------------------------------
# Test-BackupPauseNeeded : faut-il afficher la pause de vérification backup
# après le module 01 ? Oui seulement si un backup a RÉELLEMENT eu lieu (ligne
# "Backup data terminé dans" dans le log) et hors WhatIf. PURE/testable.
# ---------------------------------------------------------------------------
function Test-BackupPauseNeeded {
    [CmdletBinding()]
    param([AllowNull()][string[]]$LogLines, [AllowNull()][object]$IsWhatIf)
    if ($IsWhatIf -eq $true) { return $false }
    if (-not $LogLines) { return $false }
    foreach ($l in $LogLines) {
        if ([string]$l -match 'Backup data terminé dans') { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Get-HeartbeatMessage : rappel injecté dans le journal quand un module tourne
# sans nouvelle ligne de log. Minutes = plancher(elapsed/60), borné à >= 1.
# PURE/testable.
# ---------------------------------------------------------------------------
function Get-HeartbeatMessage {
    [CmdletBinding()]
    param([string]$ModuleLabel, [AllowNull()][object]$ElapsedSeconds)
    $sec = 0; [void][int]::TryParse([string]$ElapsedSeconds, [ref]$sec)
    $min = [int][math]::Floor($sec / 60); if ($min -lt 1) { $min = 1 }
    return "Module $ModuleLabel en cours depuis $min min (ne pas interrompre)"
}

# ---------------------------------------------------------------------------
# Get-EndChecklistItems : étapes post-run que l'opérateur doit cocher avant de
# rendre le PC (source : docs/PROCEDURE-OPERATEUR.md, phases 3 et 4). L'item
# redémarrage est formulé selon l'état du flag reboot. PURE/testable.
# ---------------------------------------------------------------------------
function Get-EndChecklistItems {
    [CmdletBinding()]
    param([AllowNull()][object]$RebootRequired)
    $items = @(
        "Récupérer la passphrase admin : onglet Clôture du cockpit (bouton Afficher) ou fichier runtime\FICHE-PC-<PC>.txt",
        "Se connecter une fois au compte Admin-Local pour vérifier le mot de passe",
        "Vérifier que la session du propriétaire s'ouvre (elle est en standard)",
        "Lire le rapport et vérifier le nombre d'ERROR",
        "Coffre de ruches à jour (module Filets de secours en OK)"
    )
    if ($RebootRequired -eq $true) {
        $items += "REDÉMARRER le PC avant de le rendre (REBOOT REQUIS détecté)"
    }
    else {
        $items += "Redémarrer le PC si la bannière l'a demandé"
    }
    $items += @(
        "Remettre la note utilisateur (NOTE-UTILISATEUR-<PC>.md)",
        "Communiquer le mot de passe admin au propriétaire (gestionnaire ou papier)",
        "Expliquer : Avast payant remplacé par Windows Defender (résilier l'abonnement)",
        "Nettoyer la clé : supprimer runtime\FICHE-PC-*.txt (ne pas repartir avec le mot de passe en clair)"
    )
    return $items
}

# ---------------------------------------------------------------------------
# Get-ReportDelta : compare l'état "avant" (Snapshot du diag, Task 5) et
# "après" (recapture par le module 10). Espace récupéré = somme par volume
# de la variation de FreeBytes (positif = libéré). Apps : différence
# d'ensembles insensible à la casse. Tolérant aux null (rapport rejoué sans
# snapshot). PURE/testable. Contrat : retourne un objet unique, jamais $null.
# ---------------------------------------------------------------------------
function Get-ReportDelta {
    [CmdletBinding()]
    param([AllowNull()][object]$Before, [AllowNull()][object]$After)

    $reclaimed = [int64]0
    $beforeVols = @(); $afterVols = @()
    if ($Before -and $Before.PSObject.Properties['Volumes']) { $beforeVols = @($Before.Volumes) }
    if ($After  -and $After.PSObject.Properties['Volumes'])  { $afterVols  = @($After.Volumes) }
    foreach ($av in $afterVols) {
        $bv = $beforeVols | Where-Object { [string]$_.DriveLetter -eq [string]$av.DriveLetter } | Select-Object -First 1
        if ($bv) { $reclaimed += ([int64]$av.FreeBytes - [int64]$bv.FreeBytes) }
    }

    $startupBefore = $null; $startupAfter = $null
    if ($Before -and $Before.PSObject.Properties['StartupCount']) { $startupBefore = [int]$Before.StartupCount }
    if ($After  -and $After.PSObject.Properties['StartupCount'])  { $startupAfter  = [int]$After.StartupCount }
    $startupDelta = $null
    if ($null -ne $startupBefore -and $null -ne $startupAfter) { $startupDelta = $startupAfter - $startupBefore }

    $beforeApps = @(); $afterApps = @()
    if ($Before -and $Before.PSObject.Properties['Win32Apps']) { $beforeApps = @($Before.Win32Apps | ForEach-Object { [string]$_ }) }
    if ($After  -and $After.PSObject.Properties['Win32Apps'])  { $afterApps  = @($After.Win32Apps  | ForEach-Object { [string]$_ }) }
    $afterSet  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $afterApps)  { [void]$afterSet.Add($a) }
    $beforeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($b in $beforeApps) { [void]$beforeSet.Add($b) }
    $removed = @($beforeApps | Where-Object { -not $afterSet.Contains($_) }  | Sort-Object -Unique)
    $added   = @($afterApps  | Where-Object { -not $beforeSet.Contains($_) } | Sort-Object -Unique)

    $bootBefore = $null; $bootAfter = $null
    if ($Before -and $Before.PSObject.Properties['BootDurationMs']) { $bootBefore = $Before.BootDurationMs }
    if ($After  -and $After.PSObject.Properties['BootDurationMs'])  { $bootAfter  = $After.BootDurationMs }

    $lines = @()
    $gb = [math]::Round($reclaimed / 1GB, 1)
    if ($reclaimed -ge 0) { $lines += "Espace disque récupéré : +$gb Go" }
    else                  { $lines += "Espace disque : $gb Go (installations nettes)" }
    if ($null -ne $startupDelta) { $lines += "Démarrages automatiques : $startupBefore -> $startupAfter" }
    $lines += "Applications retirées : $(@($removed).Count) ; installées : $(@($added).Count)"

    return [PSCustomObject]@{
        SpaceReclaimedBytes = $reclaimed
        StartupBefore       = $startupBefore
        StartupAfter        = $startupAfter
        StartupDelta        = $startupDelta
        AppsRemoved         = $removed
        AppsAdded           = $added
        BootBeforeMs        = $bootBefore
        BootAfterMs         = $bootAfter
        Lines               = $lines
    }
}

function Test-SearchEngineHijacked {
    # $true si l'URL de recherche ne pointe AUCUN domaine connu-bon. Pur.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Url,
        [string[]]$KnownGood
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    foreach ($g in $KnownGood) {
        if ($g -and $Url -match [regex]::Escape($g)) { return $false }
    }
    return $true
}

function Get-PupExtensionMatch {
    # $true si l'ID d'extension est dans la liste noire. Pur.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ExtensionId,
        [string[]]$Blacklist
    )
    if ([string]::IsNullOrWhiteSpace($ExtensionId) -or $null -eq $Blacklist) { return $false }
    return [bool]($Blacklist -contains $ExtensionId)
}

# ---------------------------------------------------------------------------
# Get-ExtensionClassification : une extension force-installée est-elle connue
# (liste blanche) ou à vérifier (lien direct vers sa fiche) ? PURE/testable.
# Retourne { IsKnown([bool]); Url([string]) }.
# ---------------------------------------------------------------------------
function Get-ExtensionClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [AllowNull()][string[]]$Whitelist)
    $known = $false
    if ($Whitelist) { $known = (@($Whitelist) -contains $Id) }
    return [PSCustomObject]@{
        IsKnown = $known
        Url     = "https://chromewebstore.google.com/detail/$Id"
    }
}

function ConvertTo-HtmlEncoded {
    # Échappe les caractères HTML dangereux (anti-injection dans le rapport). Pur.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    return $t
}

# ---------------------------------------------------------------------------
# Get-KitVersion : version courante du kit, source unique. Utilisée dans le
# rapport (module 10). Centralise ce qui était codé en dur.
# ---------------------------------------------------------------------------
function Get-KitVersion { return 'v2.5.0' }

# ---------------------------------------------------------------------------
# Remove-PasswordLines : retire d'un bloc de texte toute ligne portant un mot
# de passe, en conservant le reste tel quel.
# Le rapport TXT recopiait la fiche PC integralement (module 10) : le mot de
# passe administrateur survivait donc a la suppression de la fiche et repartait
# sur la cle USB de l'operateur, alors que le bouton "Supprimer la fiche PC"
# et la checklist de fin laissaient croire le contraire. Le rapport renvoie
# desormais a la fiche au lieu de recopier le secret.
# ---------------------------------------------------------------------------
function Remove-PasswordLines {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $pattern     = '(?i)^\s*(mot de passe|passphrase|password|mdp)\s*[:=]'
    $replacement = '  Mot de passe  : [non repris dans le rapport - voir la fiche PC]'
    $lines       = $Text -split "`r?`n"
    $out         = foreach ($line in $lines) {
        if ($line -match $pattern) { $replacement } else { $line }
    }
    return (($out) -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Get-MetaFromDiag : extrait du diagnostic JSON les métadonnées machine
# partagées par le rapport TXT et le rapport HTML (auparavant dupliquées dans
# le module 10, source d'un bug silencieux). Tolérant au null et aux diag
# incomplets (StrictMode : accès via Get-JsonProp). PURE/testable.
# Retour : objet avec Volumes[] (chaque volume porte un champ Text prêt à
# afficher) et Antivirus[] (noms). Champs scalaires à $null si absents.
# ---------------------------------------------------------------------------
function Get-MetaFromDiag {
    [CmdletBinding()]
    param([AllowNull()][object]$Diag)
    $meta = [ordered]@{
        Manufacturer = $null; Model = $null; Serial = $null; OS = $null
        CPU = $null; RAM = $null; Volumes = @(); Antivirus = @()
    }
    if ($null -eq $Diag) { return [PSCustomObject]$meta }

    $mc = Get-JsonProp $Diag 'machine'
    if ($mc) {
        $meta.Manufacturer = Get-JsonProp $mc 'Manufacturer'
        $meta.Model        = Get-JsonProp $mc 'Model'
        $meta.Serial       = Get-JsonProp $mc 'BiosSerial'
        $osTxt = [string](Get-JsonProp $mc 'OSCaption')
        $build = Get-JsonProp $mc 'OSBuild'
        if ($null -ne $build) { $osTxt = "$osTxt (build $build)" }
        if (-not [string]::IsNullOrWhiteSpace($osTxt)) { $meta.OS = $osTxt }
    }
    $cpu = Get-JsonProp $Diag 'cpu'
    if ($cpu) { $meta.CPU = Get-JsonProp $cpu 'Name' }
    $ram = Get-JsonProp $Diag 'ram'
    if ($ram) { $tot = Get-JsonProp $ram 'TotalGB'; if ($null -ne $tot) { $meta.RAM = "$tot GB" } }

    $volList = @()
    $vols = Get-JsonProp $Diag 'volumes'
    if ($vols) {
        foreach ($v in @($vols)) {
            $dl = [string](Get-JsonProp $v 'DriveLetter'); if ([string]::IsNullOrEmpty($dl)) { $dl = '?' }
            $fs = [string](Get-JsonProp $v 'FileSystem')
            $sz = [string](Get-JsonProp $v 'SizeGB');     if ([string]::IsNullOrEmpty($sz)) { $sz = '?' }
            $fr = [string](Get-JsonProp $v 'FreeGB');     if ([string]::IsNullOrEmpty($fr)) { $fr = '?' }
            $dt = [string](Get-JsonProp $v 'DiskType')
            $volList += [PSCustomObject]@{
                DriveLetter = $dl; FileSystem = $fs; SizeGB = $sz; FreeGB = $fr; DiskType = $dt
                Text        = "${dl}: $fs - $sz GB total, $fr GB libre ($dt)"
            }
        }
    }
    $meta.Volumes = $volList

    $avList = @()
    $avs = Get-JsonProp $Diag 'antivirus'
    if ($avs) {
        foreach ($av in @($avs)) {
            $n = Get-JsonProp $av 'Name'
            if ($n) { $avList += [string]$n }
        }
    }
    $meta.Antivirus = $avList

    return [PSCustomObject]$meta
}

function Get-ReportSummary {
    # Agrège des lignes de log en synthèse : compteurs globaux + regroupement par module
    # (sections "=== NN-Nom : début ==="). Pur/testable.
    [CmdletBinding()]
    param([AllowNull()][string[]]$Lines)

    $countOK = 0; $countWarn = 0; $countError = 0; $countInfo = 0; $countWhatIf = 0
    $modules = New-Object System.Collections.Generic.List[object]
    $current = $null
    if ($null -eq $Lines) { $Lines = @() }

    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        $parts = Get-LogLineParts -Line $line
        $msg   = if ($parts) { $parts.Message } else { [string]$line }

        # Nouvelle section module : "=== 07-Cleanup : debut ===" (accent optionnel sur debut)
        $mm = [regex]::Match($msg, '^===\s*(?<mod>.+?)\s*:\s*(?:d[eé]but)\s*===')
        if ($mm.Success -or $null -eq $current) {
            $name = if ($mm.Success) { $mm.Groups['mod'].Value } else { '(préambule)' }
            $current = [PSCustomObject]@{
                Name  = $name; OK = 0; Warn = 0; Error = 0
                Lines = (New-Object System.Collections.Generic.List[string])
            }
            [void]$modules.Add($current)
        }

        [void]$current.Lines.Add([string]$line)

        if ($parts) {
            switch ($parts.Level) {
                'OK'     { $countOK++;    $current.OK++ }
                'WARN'   { $countWarn++;  $current.Warn++ }
                'ERROR'  { $countError++; $current.Error++ }
                'INFO'   { $countInfo++ }
                'WHATIF' { $countWhatIf++ }
            }
        }
    }

    return [PSCustomObject]@{
        CountOK     = $countOK
        CountWarn   = $countWarn
        CountError  = $countError
        CountInfo   = $countInfo
        CountWhatIf = $countWhatIf
        TotalLines  = @($Lines).Count
        Modules     = $modules.ToArray()
    }
}

function ConvertTo-ReportHtml {
    # Construit un rapport HTML autonome (zéro ressource externe) à partir d'une synthèse
    # Get-ReportSummary, d'un dictionnaire de métadonnées et de l'état reboot. Pur/testable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Summary,
        [hashtable]$Meta = @{},
        [bool]$RebootNeeded = $false,
        [string[]]$RebootReasons = @(),
        [string[]]$Lines = @(),
        [string[]]$Volumes = @(),
        [string[]]$Antivirus = @(),
        [AllowNull()][object]$Delta  = $null,
        [AllowNull()][object]$Health = $null,
        [AllowNull()][object]$Resilience = $null
    )

    # Normalise les métadonnées : toutes les clés attendues présentes et déjà échappées HTML.
    $keys = @('ComputerName','Operator','Generated','Manufacturer','Model','Serial','OS','CPU','RAM','KitVersion')
    $M = @{}
    foreach ($k in $keys) {
        $M[$k] = if ($Meta -and $Meta.ContainsKey($k)) { ConvertTo-HtmlEncoded ([string]$Meta[$k]) } else { '' }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport PC-Refresh-Kit - $($M['ComputerName'])</title>
<style>
  :root { --teal:#0d9488; --ink:#1e293b; --muted:#64748b; --line:#e2e8f0; }
  * { box-sizing:border-box; }
  body { font-family:'Segoe UI',Roboto,Arial,sans-serif; color:var(--ink); background:#fff; margin:0; padding:0 0 48px; }
  header { background:var(--teal); color:#fff; padding:24px 32px; }
  header h1 { margin:0 0 4px; font-size:22px; }
  header .sub { opacity:.92; font-size:14px; }
  main { max-width:1000px; margin:0 auto; padding:8px 32px; }
  h2 { color:var(--teal); border-bottom:2px solid var(--line); padding-bottom:6px; margin-top:32px; font-size:18px; }
  .badges { display:flex; gap:12px; margin:16px 0; flex-wrap:wrap; }
  .badge { border-radius:8px; padding:10px 16px; font-weight:600; color:#fff; }
  .b-ok { background:#16a34a; } .b-warn { background:#d97706; } .b-err { background:#dc2626; }
  .pill { display:inline-block; border-radius:999px; padding:2px 10px; margin-right:8px; font-size:12px; font-weight:600; color:#fff; }
  .p-ok { background:#16a34a; } .p-warn { background:#d97706; } .p-err { background:#dc2626; } .p-info { background:#64748b; }
  table { border-collapse:collapse; width:100%; margin:8px 0; font-size:14px; }
  th,td { border:1px solid var(--line); padding:8px 10px; text-align:left; }
  th { background:#f8fafc; }
  .reboot { background:#fffbeb; border:2px solid #d97706; border-radius:8px; padding:16px; margin:16px 0; }
  .reboot.none { background:#f0fdf4; border-color:#16a34a; }
  pre.log { background:#0f172a; color:#e2e8f0; padding:16px; border-radius:8px; overflow:auto; font-size:12.5px; line-height:1.5; }
  .lvl-OK { color:#4ade80; } .lvl-WARN { color:#fbbf24; } .lvl-ERROR { color:#f87171; } .lvl-WHATIF { color:#22d3ee; } .lvl-INFO { color:#cbd5e1; }
  footer { max-width:1000px; margin:24px auto 0; padding:0 32px; color:var(--muted); font-size:12px; }
</style>
</head>
<body>
<header>
  <h1>Rapport d'intervention - PC-Refresh-Kit</h1>
  <div class="sub">$($M['ComputerName']) - généré le $($M['Generated'])</div>
  <div style="color:#fff;opacity:.85;font-size:12px;margin-top:4px">Trimko Labs</div>
</header>
<main>
"@)

    [void]$sb.Append('<h2>Bilan</h2><div class="badges">')
    [void]$sb.Append("<div class=`"badge b-ok`">OK : $($Summary.CountOK)</div>")
    [void]$sb.Append("<div class=`"badge b-warn`">Avertissements : $($Summary.CountWarn)</div>")
    [void]$sb.Append("<div class=`"badge b-err`">Erreurs : $($Summary.CountError)</div>")
    [void]$sb.Append('</div>')

    if ($RebootNeeded) {
        $why = ConvertTo-HtmlEncoded ((@($RebootReasons) | Where-Object { $_ }) -join ' ; ')
        [void]$sb.Append("<div class=`"reboot`"><strong>REDÉMARRAGE REQUIS</strong> avant de livrer le PC.<br>Raison(s) : $why</div>")
    }
    else {
        [void]$sb.Append('<div class="reboot none">Aucun redémarrage requis détecté.</div>')
    }

    [void]$sb.Append('<h2>Machine</h2><table>')
    $rows = @(
        @('Ordinateur', $M['ComputerName']),
        @('Opérateur', $M['Operator']),
        @('Fabricant', $M['Manufacturer']),
        @('Modèle', $M['Model']),
        @('Numéro de série', $M['Serial']),
        @('Système', $M['OS']),
        @('Processeur', $M['CPU']),
        @('Mémoire', $M['RAM'])
    )
    foreach ($r in $rows) {
        if ($r[1]) { [void]$sb.Append("<tr><th>$($r[0])</th><td>$($r[1])</td></tr>") }
    }
    [void]$sb.Append('</table>')

    if (@($Volumes).Count -gt 0) {
        [void]$sb.Append('<h2>Volumes</h2><ul>')
        foreach ($v in @($Volumes)) { if ($v) { [void]$sb.Append("<li>$(ConvertTo-HtmlEncoded ([string]$v))</li>") } }
        [void]$sb.Append('</ul>')
    }
    if (@($Antivirus).Count -gt 0) {
        [void]$sb.Append('<h2>Antivirus</h2><ul>')
        foreach ($a in @($Antivirus)) { if ($a) { [void]$sb.Append("<li>$(ConvertTo-HtmlEncoded ([string]$a))</li>") } }
        [void]$sb.Append('</ul>')
    }

    # --- Ce que l'intervention a changé (delta avant/après, si snapshot disponible) ---
    if ($null -ne $Delta -and $Delta.PSObject.Properties['Lines']) {
        $dlLines = @($Delta.Lines)
        [void]$sb.Append("<h2>Ce que l'intervention a changé</h2><ul>")
        foreach ($dl in $dlLines) {
            if ($dl) { [void]$sb.Append("<li>$(ConvertTo-HtmlEncoded ([string]$dl))</li>") }
        }
        # Temps de démarrage (si mesuré avant l'intervention)
        if ($Delta.PSObject.Properties['BootBeforeMs'] -and $null -ne $Delta.BootBeforeMs) {
            $bootBTxt = ConvertTo-HtmlEncoded (Format-BootDuration -Milliseconds $Delta.BootBeforeMs)
            $bootATxt = if ($Delta.PSObject.Properties['BootAfterMs'] -and $null -ne $Delta.BootAfterMs) {
                ConvertTo-HtmlEncoded (Format-BootDuration -Milliseconds $Delta.BootAfterMs)
            } else { 'mesuré au prochain démarrage' }
            [void]$sb.Append("<li>Temps de démarrage : $bootBTxt -&gt; $bootATxt</li>")
        }
        # Applications retirées (max 20)
        if ($Delta.PSObject.Properties['AppsRemoved']) {
            $removed = @($Delta.AppsRemoved)
            if ($removed.Count -gt 0) {
                $remList = (@($removed | Select-Object -First 20) | ForEach-Object { ConvertTo-HtmlEncoded ([string]$_) }) -join ', '
                [void]$sb.Append("<li>Retirées : $remList</li>")
            }
        }
        [void]$sb.Append('</ul>')
    }

    # --- Santé machine (SMART, BitLocker, pilotes en erreur, activation) ---
    if ($null -ne $Health) {
        [void]$sb.Append('<h2>Santé machine</h2>')

        # Disques SMART
        $smartList = @()
        if ($Health.PSObject.Properties['Smart']) { $smartList = @($Health.Smart) }
        if (@($smartList).Count -gt 0) {
            [void]$sb.Append('<p style="font-weight:600;margin:12px 0 4px">Disques (SMART)</p>')
            [void]$sb.Append('<table><tr><th>Disque</th><th>Usure (%)</th><th>Temp. (°C)</th><th>Erreurs non corrigées</th></tr>')
            foreach ($d in @($smartList)) {
                $dName = if ($d.PSObject.Properties['FriendlyName']) { ConvertTo-HtmlEncoded ([string]$d.FriendlyName) } else { '(inconnu)' }
                $dWear = if ($d.PSObject.Properties['WearPct'] -and $null -ne $d.WearPct) { ConvertTo-HtmlEncoded ([string]$d.WearPct) } else { '-' }
                $dTemp = if ($d.PSObject.Properties['TemperatureC'] -and $null -ne $d.TemperatureC) { ConvertTo-HtmlEncoded ([string]$d.TemperatureC) } else { '-' }
                $rVal = 0; $wVal = 0; $hasErrData = $false
                if ($d.PSObject.Properties['ReadErrorsUncorrected']  -and $null -ne $d.ReadErrorsUncorrected)  { $rVal = [int]$d.ReadErrorsUncorrected;  $hasErrData = $true }
                if ($d.PSObject.Properties['WriteErrorsUncorrected'] -and $null -ne $d.WriteErrorsUncorrected) { $wVal = [int]$d.WriteErrorsUncorrected; $hasErrData = $true }
                $dErr     = if ($hasErrData) { ConvertTo-HtmlEncoded ([string]($rVal + $wVal)) } else { '-' }
                $alert    = $d.PSObject.Properties['Alert'] -and [bool]$d.Alert
                $rowStyle = if ($alert) { ' style="background:#fff7ed"' } else { '' }
                [void]$sb.Append("<tr$rowStyle><td>$dName</td><td>$dWear</td><td>$dTemp</td><td>$dErr</td></tr>")
            }
            [void]$sb.Append('</table>')
        }

        # Volumes BitLocker
        $blList = @()
        if ($Health.PSObject.Properties['BitLocker']) { $blList = @($Health.BitLocker) }
        if (@($blList).Count -gt 0) {
            [void]$sb.Append('<p style="font-weight:600;margin:12px 0 4px">BitLocker</p><ul>')
            foreach ($vol in @($blList)) {
                $dl    = if ($vol.PSObject.Properties['DriveLetter']) { ConvertTo-HtmlEncoded ([string]$vol.DriveLetter) } else { '?' }
                $label = if ($vol.PSObject.Properties['Label'])       { ConvertTo-HtmlEncoded ([string]$vol.Label) }       else { 'inconnu' }
                [void]$sb.Append("<li>$dl : $label</li>")
            }
            [void]$sb.Append('</ul>')
        }

        # Pilotes en erreur
        $errDev = @()
        if ($Health.PSObject.Properties['ErrorDevices']) { $errDev = @($Health.ErrorDevices) }
        if (@($errDev).Count -gt 0) {
            $errCnt = @($errDev).Count
            [void]$sb.Append("<p style=`"font-weight:600;margin:12px 0 4px`">Pilotes en erreur ($errCnt)</p><ul>")
            foreach ($dev in @($errDev)) {
                $devName = if ($dev.PSObject.Properties['FriendlyName']) { ConvertTo-HtmlEncoded ([string]$dev.FriendlyName) } else { '(inconnu)' }
                $devCls  = if ($dev.PSObject.Properties['Class']) { ConvertTo-HtmlEncoded ([string]$dev.Class) } else { '' }
                $clsTxt  = if ($devCls) { " ($devCls)" } else { '' }
                [void]$sb.Append("<li>$devName$clsTxt</li>")
            }
            [void]$sb.Append('</ul>')
        }

        # Activation Windows
        if ($Health.PSObject.Properties['Activation'] -and $null -ne $Health.Activation) {
            $act      = $Health.Activation
            $actLabel = if ($act.PSObject.Properties['StatusLabel']) { ConvertTo-HtmlEncoded ([string]$act.StatusLabel) } else { 'Inconnu' }
            $actOk    = $act.PSObject.Properties['IsActivated'] -and [bool]$act.IsActivated
            $actStyle = if (-not $actOk) { ' style="color:#dc2626"' } else { '' }
            [void]$sb.Append("<p style=`"font-weight:600;margin:12px 0 4px`">Activation Windows</p><p$actStyle>$actLabel</p>")
        }
    }

    # --- Filets de sécurité (sentinelle résilience du module 00, v2.4) ---
    # Section absente d'un diagnostic antérieur à v2.4 : la carte est omise, jamais
    # d'erreur. Chaque champ est lu via Get-JsonProp (section partielle tolérée).
    if ($null -ne $Resilience) {
        $netRows = @()

        $freeLvl = [string](Get-JsonProp $Resilience 'FreeSpaceLevel')
        if ($freeLvl) {
            # Le verdict combine pourcentage et plancher en Go : le texte le rappelle,
            # sinon un petit disque sous le plancher se lit comme une saturation.
            $freeTxt = switch ($freeLvl) {
                'OK'      { 'suffisant' }
                'WARN'    { 'faible : sous le pourcentage ou le plancher en Go du kit' }
                'ERROR'   { 'critique : sous le pourcentage ou le plancher en Go du kit' }
                'Unknown' { 'non mesurable' }
                default   { $freeLvl }
            }
            $netRows += [PSCustomObject]@{ Label = 'Espace libre C:'; Text = $freeTxt; Level = $freeLvl }
        }

        $hiveLvl = [string](Get-JsonProp $Resilience 'HiveLevel')
        if ($hiveLvl) {
            $hiveReason = [string](Get-JsonProp $Resilience 'HiveReason')
            $hiveTxt = if ($hiveLvl -eq 'OK') { 'récentes' }
                       elseif (-not [string]::IsNullOrWhiteSpace($hiveReason)) { $hiveReason }
                       else { 'non mesurable' }
            $netRows += [PSCustomObject]@{ Label = 'Écritures du registre'; Text = $hiveTxt; Level = $hiveLvl }
        }

        # Restauration système : le compte peut valoir $null (sonde muette côté
        # module 00). La carte n'affirme jamais « active » ni « désactivée » sans
        # mesure : elle rend alors une ligne neutre. Un zéro MESURÉ reste une
        # alerte même service actif - un service sans aucun point n'est pas un filet.
        $restEnabProp  = $Resilience.PSObject.Properties['RestoreEnabled']
        $restCountProp = $Resilience.PSObject.Properties['RestorePointCount']
        if ($restEnabProp -or $restCountProp) {
            $restEnabled = if ($restEnabProp)  { $restEnabProp.Value }  else { $null }
            $restCount   = if ($restCountProp) { $restCountProp.Value } else { $null }
            if ($null -eq $restEnabled -or $null -eq $restCount) {
                $netRows += [PSCustomObject]@{
                    Label = 'Restauration système'; Text = 'état non lisible'; Level = 'INFO'
                }
            }
            else {
                $rpN   = [int]$restCount
                $rpOn  = ($restEnabled -eq $true)
                $rpTxt = if ($rpOn -and $rpN -gt 0) { "active, $rpN point(s)" }
                         elseif ($rpOn) { 'active mais aucun point présent' }
                         elseif ($rpN -gt 0) { "désactivée, $rpN point(s) restant(s)" }
                         else { 'désactivée, aucun point présent' }
                $netRows += [PSCustomObject]@{
                    Label = 'Restauration système'; Text = $rpTxt
                    Level = $(if ($rpOn -and $rpN -gt 0) { 'OK' } else { 'WARN' })
                }
            }
        }

        # Même règle : $null = réserve non mesurée (CIM muet), $false = mesurée
        # et insuffisante. Seul le $false autorise à écrire « insuffisante ».
        $shadowProp = $Resilience.PSObject.Properties['ShadowAdequate']
        if ($shadowProp) {
            $shadowOk = $shadowProp.Value
            if ($null -eq $shadowOk) {
                $netRows += [PSCustomObject]@{
                    Label = 'Réserve de clichés'; Text = 'état non lisible'; Level = 'INFO'
                }
            }
            else {
                $netRows += [PSCustomObject]@{
                    Label = 'Réserve de clichés'
                    Text  = $(if ($shadowOk -eq $true) { 'adéquate' } else { 'insuffisante ou absente' })
                    Level = $(if ($shadowOk -eq $true) { 'OK' } else { 'WARN' })
                }
            }
        }

        # WinRE et recoveryenabled remontent les valeurs brutes des outils Windows
        # (Enabled/Disabled, Yes/No/Absent) : traduites pour l'opérateur, le jeton
        # technique reste affiché entre parenthèses pour le diagnostic.
        $winReStatus = [string](Get-JsonProp $Resilience 'WinReStatus')
        if ($winReStatus) {
            $winReTxt = switch ($winReStatus) {
                'Enabled'  { 'armé (Enabled)' }
                'Disabled' { 'désarmé (Disabled)' }
                'Unknown'  { 'état non lisible' }
                default    { $winReStatus }
            }
            $netRows += [PSCustomObject]@{
                Label = 'Environnement de récupération'; Text = $winReTxt
                Level = [string](Get-JsonProp $Resilience 'WinReLevel')
            }
        }

        $recStatus = [string](Get-JsonProp $Resilience 'RecoveryEnabledStatus')
        if ($recStatus) {
            $recTxt = switch ($recStatus) {
                'Yes'     { 'active (Yes)' }
                'Absent'  { 'absente du BCD' }
                'Unknown' { 'état non lisible' }
                default   { "inactive ($recStatus)" }
            }
            $netRows += [PSCustomObject]@{
                Label = 'Auto-réparation au démarrage'; Text = $recTxt
                Level = [string](Get-JsonProp $Resilience 'RecoveryEnabledLevel')
            }
        }

        $blCard = Get-JsonProp $Resilience 'BitLockerC'
        if ($blCard) {
            $blReason = [string](Get-JsonProp $blCard 'Reason')
            $netRows += [PSCustomObject]@{
                Label = 'BitLocker C:'
                Text  = $(if ($blReason) { $blReason } else { 'état non déterminé' })
                Level = [string](Get-JsonProp $blCard 'Level')
            }
        }

        if (@($netRows).Count -gt 0) {
            [void]$sb.Append('<h2>Filets de sécurité</h2><table><tr><th>Filet</th><th>État</th></tr>')
            foreach ($row in $netRows) {
                # INFO (BitLocker chiffré avec clé de récupération) : pastille neutre,
                # ce n'est pas une alerte mais une consigne de vérification.
                $pillCls = switch ($row.Level) { 'OK' { 'p-ok' } 'WARN' { 'p-warn' } 'ERROR' { 'p-err' } default { 'p-info' } }
                $pillTxt = switch ($row.Level) { 'OK' { 'OK' }   'WARN' { 'Attention' } 'ERROR' { 'Critique' } default { 'Info' } }
                $rowLbl  = ConvertTo-HtmlEncoded ([string]$row.Label)
                $rowTxt  = ConvertTo-HtmlEncoded ([string]$row.Text)
                [void]$sb.Append("<tr><td>$rowLbl</td><td><span class=`"pill $pillCls`">$pillTxt</span>$rowTxt</td></tr>")
            }
            [void]$sb.Append('</table>')
        }
    }

    [void]$sb.Append('<h2>Modules</h2><table><tr><th>Module</th><th>OK</th><th>Avert.</th><th>Erreurs</th></tr>')
    foreach ($mod in @($Summary.Modules)) {
        $nm  = ConvertTo-HtmlEncoded ([string]$mod.Name)
        $cls = if ($mod.Error -gt 0) { ' style="background:#fef2f2"' } elseif ($mod.Warn -gt 0) { ' style="background:#fffbeb"' } else { '' }
        [void]$sb.Append("<tr$cls><td>$nm</td><td>$($mod.OK)</td><td>$($mod.Warn)</td><td>$($mod.Error)</td></tr>")
    }
    [void]$sb.Append('</table>')

    [void]$sb.Append("<h2>Journal complet ($($Summary.TotalLines) lignes)</h2><pre class=`"log`">")
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $p    = Get-LogLineParts -Line $line
        $lvl  = if ($p) { $p.Level } else { 'INFO' }
        $safe = ConvertTo-HtmlEncoded ([string]$line)
        [void]$sb.Append("<span class=`"lvl-$lvl`">$safe</span>`n")
    }
    [void]$sb.Append('</pre>')

    [void]$sb.Append("</main><footer>PC-Refresh-Kit $($M['KitVersion']) - document technique d'intervention. Contient des informations machine : ne pas diffuser à des tiers.")
    [void]$sb.Append('<div><a href="https://kit.trimko.com" style="color:#0f766e">kit.trimko.com</a></div>')
    [void]$sb.Append('</footer></body></html>')
    return $sb.ToString()
}
