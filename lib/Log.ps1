# lib/Log.ps1 - Journalisation et formatage texte (dot-source par lib/Common.ps1).
# Ne JAMAIS dot-sourcer directement : passer par lib/Common.ps1 (dépendances,
# init du log). Encodage : UTF-8 avec BOM pour PowerShell 5.1.

# ---------------------------------------------------------------------------
# Write-KitLog : journalisation centralisée
# ---------------------------------------------------------------------------
function Write-KitLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','WHATIF')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    # Écriture dans le fichier log
    $logDir = Split-Path $script:KitLogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    Add-Content -Path $script:KitLogFile -Value $line -Encoding UTF8

    # Affichage console avec couleur
    $color = switch ($Level) {
        'OK'     { 'Green' }
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'WHATIF' { 'Cyan' }
        default  { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# ConvertFrom-JobLogLine : parse une ligne relayée par un job d'arrière-plan.
# Formats : 'KITLOG|LEVEL|message' (log), 'KITPHASE|nom' (jalon), toute autre
# ligne = LOG INFO brut. $null sur ligne vide. PURE/testable.
# ---------------------------------------------------------------------------
function ConvertFrom-JobLogLine {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    if ($Line -like 'KITPHASE|*') {
        return [PSCustomObject]@{ Kind = 'PHASE'; Level = $null; Message = $Line.Substring(9) }
    }
    if ($Line -like 'KITLOG|*') {
        $parts = $Line.Split('|', 3)
        if ($parts.Count -eq 3 -and $parts[1] -in @('INFO', 'OK', 'WARN', 'ERROR', 'WHATIF')) {
            return [PSCustomObject]@{ Kind = 'LOG'; Level = $parts[1]; Message = $parts[2] }
        }
    }
    return [PSCustomObject]@{ Kind = 'LOG'; Level = 'INFO'; Message = $Line }
}

# ===========================================================================
# Analyse et formatage des lignes de log (pures, testables, sans I/O)
# ===========================================================================

function Get-LogLineParts {
    # Décompose une ligne de log "[ts] [LEVEL] message". Retourne {Timestamp,Level,Message}
    # ou $null si la ligne n'est pas une ligne kit. Pur.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $m = [regex]::Match($Line, '^\[(?<ts>[^\]]+)\]\s+\[(?<lvl>INFO|OK|WARN|ERROR|WHATIF)\]\s?(?<msg>.*)$')
    if (-not $m.Success) { return $null }
    return [PSCustomObject]@{
        Timestamp = $m.Groups['ts'].Value
        Level     = $m.Groups['lvl'].Value
        Message   = $m.Groups['msg'].Value
    }
}

function ConvertTo-PrintableText {
    # Nettoie une chaîne pour affichage/log : retire les caractères de contrôle et
    # les codes non imprimables (entrées Run corrompues => noms binaires illisibles,
    # ex "섀Ĝǐ" au run réel). Si rien de lisible ne reste, renvoie un libellé de
    # remplacement. PURE/testable.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [string]$Placeholder = '(entrée illisible)'
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        $cat = [System.Char]::GetUnicodeCategory($ch)
        if ($cat -in @(
                [System.Globalization.UnicodeCategory]::Control,
                [System.Globalization.UnicodeCategory]::Format,
                [System.Globalization.UnicodeCategory]::Surrogate,
                [System.Globalization.UnicodeCategory]::PrivateUse,
                [System.Globalization.UnicodeCategory]::OtherNotAssigned
            )) { continue }
        [void]$sb.Append($ch)
    }
    $clean = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return $Placeholder }
    return $clean
}

# ===========================================================================
# Cockpit GUI (v1.6) - helpers purs pour le journal coloré et le temps écoulé
# ===========================================================================

function Get-LogLevelColor {
    # Nom de couleur (System.Drawing KnownColor) pour une ligne de log selon son niveau. Pur.
    # Retourne un NOM (string) et non un objet Color : reste testable sans charger System.Drawing.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Line)
    $parts = Get-LogLineParts -Line $Line
    $level = if ($parts) { $parts.Level } else { 'INFO' }
    switch ($level) {
        'OK'     { return 'Green' }
        'WARN'   { return 'DarkOrange' }
        'ERROR'  { return 'Red' }
        'WHATIF' { return 'Teal' }
        'INFO'   { return 'DimGray' }
        default  { return 'Black' }
    }
}

function Format-Elapsed {
    # Formate une durée en secondes : "mm:ss" (<1h) ou "h:mm:ss" (>=1h). Pur.
    [CmdletBinding()]
    param([int]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) {
        return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
    }
    return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}
