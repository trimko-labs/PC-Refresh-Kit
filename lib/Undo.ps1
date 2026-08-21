# lib/Undo.ps1 - Réversibilité (manifeste undo) et helpers de nettoyage résiduel
# (dot-source par lib/Common.ps1). Ne pas dot-sourcer directement. UTF-8 avec BOM.

function Get-ShortcutVerdict {
    # Décide si un raccourci est mort, SANS I/O (testable).
    # -TargetExists : résultat de Test-Path sur la cible, calculé par l'appelant.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$TargetPath,
        [bool]$TargetExists
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return 'SKIP' }   # raccourci shell/URL sans cible fichier
    if ($TargetPath -match '^\\\\')                { return 'SKIP' }   # UNC réseau : ne pas juger
    if ($TargetPath -notmatch '^[A-Za-z]:\\')      { return 'SKIP' }   # pas un chemin disque local
    if ($TargetExists) { return 'ALIVE' }
    return 'DEAD'
}

function Test-ResidualPathAllowed {
    # Garde-fou : un chemin candidat à la suppression doit être STRICTEMENT
    # sous l'une des racines autorisées (jamais la racine elle-même, jamais hors liste).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $Path.TrimEnd('\')
    foreach ($root in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $r = $root.TrimEnd('\')
        if ($full.Length -gt ($r.Length + 1) -and
            $full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-RemovedAppsFromLog {
    # Extrait les noms d'apps désinstallées depuis des lignes de log Debloat.
    # Matche les messages commençant par "Supprimé :" ou "Provisioning supprimé :".
    [CmdletBinding()]
    param([string[]]$Lines)
    $apps = New-Object System.Collections.Generic.List[string]
    # Virgule unaire obligatoire : un @() nu se déroule au retour et le caller reçoit
    # $null, donc $removedApps.Count lève sous StrictMode (11-DeepClean, log vide).
    if ($null -eq $Lines) { return ,@() }
    foreach ($l in $Lines) {
        if ($null -eq $l) { continue }
        if ($l -match '\]\s+(?:Provisioning supprimé|Supprimé)\s*:\s*(.+?)\s*$') {
            $name = $Matches[1].Trim()
            if ($name) { [void]$apps.Add($name) }
        }
    }
    return ,(@($apps | Select-Object -Unique))
}

function Get-UndoRequiredFields {
    # Champs obligatoires par type d'action d'annulation. Pur (table de référence interne).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Action)
    switch ($Action) {
        'RunKeyDisabled'   { return @('ApprovedKeyPath','ValueName') }
        'ShortcutMoved'    { return @('OriginalPath','DisabledPath') }
        'TaskDisabled'     { return @('TaskName','TaskPath') }
        'RegBackupRestore' { return @('RegBackupFile') }
        'reg-value'        { return @('RegPath','ValueName','ValueType','ValueWasAbsent') }
        default            { return $null }
    }
}

function New-UndoEntry {
    # Construit une entrée de manifeste normalisée et VALIDÉE (throw si champ requis manquant ;
    # l'appelant Add-UndoEntry catch et n'interrompt jamais le module). Pur.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][ValidateSet('RunKeyDisabled','ShortcutMoved','TaskDisabled','RegBackupRestore','reg-value')][string]$Action,
        [Parameter(Mandatory)][hashtable]$Data
    )
    foreach ($k in (Get-UndoRequiredFields -Action $Action)) {
        if (-not $Data.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$Data[$k])) {
            throw "Champ requis manquant pour $Action : $k"
        }
    }
    $entry = [ordered]@{ Module = $Module; Action = $Action }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    return [PSCustomObject]$entry
}

function Test-UndoEntryValid {
    # $true si l'entrée porte une action connue et tous ses champs requis (non vides). Pur.
    [CmdletBinding()]
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return $false }
    if (-not $Entry.PSObject.Properties['Action']) { return $false }
    $required = Get-UndoRequiredFields -Action ([string]$Entry.Action)
    if ($null -eq $required) { return $false }
    foreach ($k in $required) {
        if (-not $Entry.PSObject.Properties[$k] -or [string]::IsNullOrWhiteSpace([string]$Entry.$k)) { return $false }
    }
    return $true
}

function Get-UndoPlan {
    # Retourne les entrées VALIDES en ordre INVERSE (LIFO : on défait dans l'ordre inverse
    # des actions). Pur/testable.
    [CmdletBinding()]
    param([AllowNull()][object[]]$Entries)
    if ($null -eq $Entries) { return ,@() }
    $valid = @($Entries | Where-Object { Test-UndoEntryValid -Entry $_ })
    if ($valid.Count -eq 0) { return ,@() }
    [array]::Reverse($valid)
    return ,$valid
}

function Resolve-UndoManifestPath {
    # Chemin du manifeste d'annulation du run courant, ancré sur le log unifié :
    # runtime\logs\<run>.log -> runtime\undo\undo-<run>.json. 12 et 13 écrivent ainsi dans
    # le MÊME manifeste durant un run GUI (KIT_LOG_FILE partagé). I/O minimal (lecture d'état).
    [CmdletBinding()]
    param()
    $logFile = $script:KitLogFile
    if ([string]::IsNullOrWhiteSpace($logFile)) {
        return (Join-Path (Get-Location) ("runtime\undo\undo-fallback-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".json"))
    }
    $logsDir    = Split-Path $logFile -Parent
    $runtimeDir = Split-Path $logsDir -Parent
    $undoDir    = Join-Path $runtimeDir 'undo'
    $runId      = [System.IO.Path]::GetFileNameWithoutExtension($logFile)
    return (Join-Path $undoDir ("undo-$runId.json"))
}

function Add-UndoEntry {
    # Ajoute une entrée au manifeste d'annulation du run courant. DÉFENSIF : ne lève JAMAIS
    # (un échec de manifeste ne doit pas casser le module appelant) ; logue un WARN au pire.
    # Retourne $true si enregistré, $false sinon.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Data
    )
    try {
        $entry = New-UndoEntry -Module $Module -Action $Action -Data $Data
        $path  = Resolve-UndoManifestPath
        $dir   = Split-Path $path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $existing = @()
        if (Test-Path $path) {
            # PS 5.1 : ConvertFrom-Json renvoie un tableau JSON comme UN SEUL objet non enumere ;
            # @(pipe | ConvertFrom-Json) donnerait alors un tableau a 1 element emballant tout le
            # tableau. On assigne d'abord a une variable PUIS on enveloppe avec @() (aplatissement
            # correct sur PS 5.1 comme sur PS 7).
            try {
                $parsedManifest = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $existing = @($parsedManifest)
            } catch { $existing = @() }
        }
        $all  = @($existing) + @($entry)
        $json = ConvertTo-Json @($all) -Depth 6
        # Écriture atomique : tmp puis rename (atomique sur un même volume NTFS).
        # Un process tué en pleine écriture ne peut plus corrompre le manifeste.
        $tmpPath = "$path.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmpPath -Destination $path -Force
        return $true
    }
    catch {
        Write-KitLog -Message "Manifeste d'annulation : entrée non enregistrée ($Action) : $_" -Level 'WARN'
        return $false
    }
}
