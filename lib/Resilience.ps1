# lib/Resilience.ps1 - Sentinelle résilience et coffre de ruches (v2.4).
# Fonctions PURES uniquement (entrées valeurs, sortie verdict) : la collecte
# (reagentc, bcdedit, CIM, tailles de fichiers) reste dans les modules.
# Origine : intervention réelle du 21/08/2026 (ruche SYSTEM corrompue par
# saturation disque, tous les filets Windows morts silencieusement).

# ---------------------------------------------------------------------------
# Test-HiveFreshnessAlert : une ruche SYSTEM qui n'est plus écrite alors que
# SOFTWARE vit encore est la signature d'un registre qui ne flush plus
# (pré-crash 0xc000014c). Comparaison RELATIVE : un PC éteint longtemps ne
# déclenche pas de faux positif. PURE/testable.
# ---------------------------------------------------------------------------
function Test-HiveFreshnessAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$SystemLastWrite,
        [Parameter(Mandatory)][datetime]$SoftwareLastWrite
    )
    $lagH = ($SoftwareLastWrite - $SystemLastWrite).TotalHours
    if ($lagH -ge 168) {
        return [PSCustomObject]@{ Level = 'ERROR'; LagHours = [math]::Round($lagH, 1); Reason = 'ruche SYSTEM figée depuis plus de 7 jours alors que SOFTWARE s''écrit encore : registre en danger' }
    }
    if ($lagH -ge 48) {
        return [PSCustomObject]@{ Level = 'WARN'; LagHours = [math]::Round($lagH, 1); Reason = 'ruche SYSTEM en retard de plus de 48 h sur SOFTWARE' }
    }
    return [PSCustomObject]@{ Level = 'OK'; LagHours = [math]::Round([math]::Max($lagH, 0), 1); Reason = '' }
}

# ---------------------------------------------------------------------------
# Get-FreeSpaceVerdict : combine le pourcentage (seuils kit.json existants) et
# des planchers ABSOLUS en Go. Un disque saturé a corrompu un registre le
# 21/08/2026 : le pourcentage seul ne suffit pas sur les petits volumes, les
# Go seuls ne suffisent pas sur les très gros. PURE/testable.
# ---------------------------------------------------------------------------
function Get-FreeSpaceVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int64]$FreeBytes,
        [Parameter(Mandatory)][int64]$TotalBytes,
        [int]$WarnPct = 15,
        [int]$ErrorPct = 5,
        [int]$WarnFloorGB = 20,
        [int]$ErrorFloorGB = 10
    )
    if ($TotalBytes -le 0) { return 'OK' }
    $pct = 100.0 * $FreeBytes / $TotalBytes
    $gb  = $FreeBytes / 1GB
    if ($pct -lt $ErrorPct -or $gb -lt $ErrorFloorGB) { return 'ERROR' }
    if ($pct -lt $WarnPct  -or $gb -lt $WarnFloorGB)  { return 'WARN' }
    return 'OK'
}

# ---------------------------------------------------------------------------
# Get-WinReVerdict : parse la sortie de reagentc /info. Les libellés sont
# localisés mais les VALEURS restent Enabled/Disabled dans toutes les langues.
# PURE/testable.
# ---------------------------------------------------------------------------
function Get-WinReVerdict {
    [CmdletBinding()]
    param([AllowNull()][string[]]$ReagentcOutput)
    foreach ($line in @($ReagentcOutput)) {
        if ($line -match '(?i)\bEnabled\b')  { return [PSCustomObject]@{ Status = 'Enabled';  Level = 'OK'   } }
        if ($line -match '(?i)\bDisabled\b') { return [PSCustomObject]@{ Status = 'Disabled'; Level = 'WARN' } }
    }
    return [PSCustomObject]@{ Status = 'Unknown'; Level = 'WARN' }
}

# ---------------------------------------------------------------------------
# Get-RecoveryEnabledVerdict : parse bcdedit /enum {default} pour la valeur
# recoveryenabled. bcdedit LOCALISE les valeurs (Yes -> Oui en français) :
# les deux formes sont acceptées. PURE/testable.
# ---------------------------------------------------------------------------
function Get-RecoveryEnabledVerdict {
    [CmdletBinding()]
    param([AllowNull()][string[]]$BcdOutput)
    foreach ($line in @($BcdOutput)) {
        if ($line -match '(?i)^\s*recoveryenabled\s+(\S+)') {
            $v = $Matches[1]
            if ($v -match '(?i)^(Yes|Oui)$') { return [PSCustomObject]@{ Status = 'Yes'; Level = 'OK' } }
            return [PSCustomObject]@{ Status = $v; Level = 'WARN' }
        }
    }
    return [PSCustomObject]@{ Status = 'Absent'; Level = 'WARN' }
}

# ---------------------------------------------------------------------------
# Test-ShadowStorageAdequate : le stockage de clichés VSS est-il assez grand
# pour constituer un filet réel ? MaxSpace vient de Win32_ShadowStorage (uint64,
# non localisé) ; UNBOUNDED = valeur maximale. $null = aucune association
# configurée = pas de filet. PURE/testable.
# ---------------------------------------------------------------------------
function Test-ShadowStorageAdequate {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$MaxSpaceBytes,
        [Parameter(Mandatory)][int64]$VolumeSizeBytes,
        [int]$MinPct = 5
    )
    if ($null -eq $MaxSpaceBytes) { return $false }
    $max = [uint64]$MaxSpaceBytes
    if ($max -eq [uint64]::MaxValue) { return $true }
    if ($VolumeSizeBytes -le 0) { return $false }
    return ((100.0 * $max / $VolumeSizeBytes) -ge $MinPct)
}

# ---------------------------------------------------------------------------
# Get-BitLockerResilienceVerdict : un volume chiffré sans protecteur de
# récupération détectable est une perte de données en attente (le mode secours
# WinRE serait aveugle). La sentinelle ne peut PAS vérifier hors ligne que la
# clé est sur le compte Microsoft : elle renvoie vers aka.ms/myrecoverykey.
# ProtectionStatus : 1 = protégé (convention Get-BitLockerVolume et WMI).
# PURE/testable.
# ---------------------------------------------------------------------------
function Get-BitLockerResilienceVerdict {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ProtectionStatus,
        [AllowNull()][string[]]$ProtectorTypes
    )
    $isOn = ($null -ne $ProtectionStatus -and [int]$ProtectionStatus -eq 1)
    if (-not $isOn) {
        return [PSCustomObject]@{ Level = 'OK'; Reason = 'volume non protégé par BitLocker' }
    }
    if (@($ProtectorTypes) -contains 'RecoveryPassword') {
        return [PSCustomObject]@{ Level = 'INFO'; Reason = 'chiffré, protecteur de récupération présent - vérifier que la clé est accessible au propriétaire (aka.ms/myrecoverykey)' }
    }
    return [PSCustomObject]@{ Level = 'ERROR'; Reason = 'chiffré SANS mot de passe de récupération détectable : sauvegarder la clé avant toute intervention' }
}

# ---------------------------------------------------------------------------
# Get-DirsToRotate : dossiers de coffre excédentaires (au-delà de Keep). Les
# noms hives-yyyyMMdd-HHmmss se trient par nom = ordre chronologique.
# ORDRE DE RETOUR : du plus RÉCENT au plus ancien parmi les excédentaires (tri
# décroissant puis Skip). Ne jamais annoncer « le plus ancien » depuis le
# premier élément. Contrat (b) : retour plain, l'appelant enveloppe @().
# PURE/testable.
# ---------------------------------------------------------------------------
function Get-DirsToRotate {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Dirs,
        [Parameter(Mandatory)][int]$Keep
    )
    if (-not $Dirs) { return @() }
    $sorted = @($Dirs | Sort-Object Name -Descending)
    if ($sorted.Count -le $Keep) { return @() }
    return @($sorted | Select-Object -Skip $Keep)
}

# ---------------------------------------------------------------------------
# ConvertTo-KitManifestLines / ConvertFrom-KitManifestLines : manifeste du
# coffre en clé=valeur ASCII, parsable côté WinRE par `for /f "tokens=1,2
# delims=="`. Tri des clés pour un diff stable. PURES/testables.
# ---------------------------------------------------------------------------
function ConvertTo-KitManifestLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $lines = @()
    foreach ($k in $Data.Keys) { $lines += ('{0}={1}' -f $k, $Data[$k]) }
    return ,@($lines | Sort-Object)
}

# ---------------------------------------------------------------------------
# ConvertTo-KitAsciiToken : réduit un texte libre (nom de machine) à un jeton
# ASCII utilisable À LA FOIS comme nom de dossier et comme valeur de manifeste.
# Le mode secours (secours.bat) tourne sous WinRE avec une page de codes OEM :
# il parse manifest.txt avec `for /f` et navigue le coffre en batch. Un nom de
# machine accentué y devient illisible, voire innavigable.
# Table fixe et déterministe : [A-Za-z0-9._-] conservés, TOUT le reste (accents,
# alphabets non latins, espaces, séparateurs de chemin, caractères interdits en
# nom de fichier) remplacé par '-'. Points finaux retirés (interdits en fin de
# nom sous Windows), noms de périphériques réservés préfixés.
# Deux noms très exotiques peuvent produire le même jeton : sans conséquence
# pour le secours, qui apparie un coffre à un PC par machineid, jamais par le
# nom du dossier. PURE/testable.
# ---------------------------------------------------------------------------
function ConvertTo-KitAsciiToken {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$Fallback = 'PC',
        [int]$MaxLength = 32
    )
    $reserved = @(
        'CON','PRN','AUX','NUL',
        'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
        'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in ([string]$Text).ToCharArray()) {
        if ([regex]::IsMatch([string]$ch, '^[A-Za-z0-9._-]$')) { [void]$sb.Append($ch) }
        else { [void]$sb.Append('-') }
    }
    $token = $sb.ToString()
    if ($MaxLength -gt 0 -and $token.Length -gt $MaxLength) { $token = $token.Substring(0, $MaxLength) }
    $token = $token.TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($token)) { return $Fallback }
    if ($reserved -contains $token.ToUpperInvariant()) { return "PC-$token" }
    return $token
}

function ConvertFrom-KitManifestLines {
    [CmdletBinding()]
    param([AllowNull()][string[]]$Lines)
    $h = @{}
    foreach ($l in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        $idx = $l.IndexOf('=')
        if ($idx -lt 1) { continue }
        $h[$l.Substring(0, $idx).Trim()] = $l.Substring($idx + 1).Trim()
    }
    return $h
}
