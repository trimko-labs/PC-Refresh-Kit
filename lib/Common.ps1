# lib/Common.ps1 - Bibliothèque commune du PC-Refresh-Kit (chargeur).
# Dot-sourcer en tête de chaque module : . "$PSScriptRoot\..\lib\Common.ps1"
# Depuis v2.0 les fonctions sont réparties en sous-fichiers thématiques
# (Log/Hardware/Report/Undo) chargés ci-dessous ; ce fichier garde le bloc
# d'init du log et les fonctions transverses (admin, config, profil, antivirus,
# réseau, debloat, startup, backup, mot de passe).
# Encodage : UTF-8 avec BOM pour PowerShell 5.1.

# Variable globale du fichier de log.
# Priorité : valeur déjà définie (Run.ps1) > variable d'environnement KIT_LOG_FILE (GUI,
# héritée par les process enfants pour un log unifié) > nouveau fichier horodaté (module seul).
# Initialisé à $null si absent : StrictMode interdit de tester une variable non définie
# (chaque module enfant est un process frais ; la variable n'existe pas encore à l'entrée).
if (-not (Get-Variable -Name 'KitLogFile' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:KitLogFile = $null
}
if (-not $script:KitLogFile) {
    if ($env:KIT_LOG_FILE) {
        $script:KitLogFile = $env:KIT_LOG_FILE
    }
    else {
        $runtimeDir = Join-Path $PSScriptRoot '..\runtime\logs'
        if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:KitLogFile = Join-Path $runtimeDir "run-$env:COMPUTERNAME-$timestamp.log"
    }
    $logDir = Split-Path $script:KitLogFile -Parent
    if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
}

# ---------------------------------------------------------------------------
# Chargement des sous-fichiers thématiques (v2.0). Uniquement des définitions
# de fonctions : aucun appel au niveau top-level, donc l'ordre de chargement
# n'importe pas (résolution des fonctions à l'appel). Les modules continuent de
# ne dot-sourcer QUE ce fichier ; il tire les sous-fichiers à lui.
# ---------------------------------------------------------------------------
. "$PSScriptRoot\Log.ps1"
. "$PSScriptRoot\Hardware.ps1"
. "$PSScriptRoot\Report.ps1"
. "$PSScriptRoot\Undo.ps1"

# ---------------------------------------------------------------------------
# Test-IsAdmin : vérifie si la session est élevée
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Assert-Admin : interrompt si pas admin
# ---------------------------------------------------------------------------
function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Host "[ERROR] Ce script doit être lancé en tant qu'Administrateur." -ForegroundColor Red
        Write-Host "        Relancer PowerShell en administrateur et réessayer." -ForegroundColor Yellow
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Confirm-KitAction : gère le mode WhatIf et les confirmations interactives
# Retourne $true si l'action doit être exécutée, $false sinon
# ---------------------------------------------------------------------------
function Confirm-KitAction {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$WhatIf,
        [switch]$Force  # passe en -All : exécute sans demander
    )
    if ($WhatIf) {
        Write-KitLog -Message "WHATIF: $Message" -Level 'WHATIF'
        return $false
    }
    if ($Force) {
        Write-KitLog -Message "$Message" -Level 'INFO'
        return $true
    }
    # Mode interactif (module lancé seul)
    Write-Host ""
    Write-Host "[CONFIRMATION] $Message" -ForegroundColor Yellow
    $answer = Read-Host "Exécuter ? (O/N)"
    return ($answer -match '^[Oo]')
}

# ---------------------------------------------------------------------------
# Invoke-FileRotation : conserve les N fichiers les plus récents dans un dossier
# -Path    : dossier cible
# -Pattern : filtre (ex : '*.log', '*.reg')
# -Keep    : nombre de fichiers à conserver
# ---------------------------------------------------------------------------
function Invoke-FileRotation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][int]$Keep
    )
    if (-not (Test-Path $Path)) { return }

    $files = Get-ChildItem -Path $Path -Filter $Pattern -File |
             Sort-Object LastWriteTime -Descending

    if ($files.Count -le $Keep) { return }

    $toDelete = $files | Select-Object -Skip $Keep
    foreach ($f in $toDelete) {
        Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        Write-KitLog -Message "Rotation : supprimé $($f.Name)" -Level 'INFO'
    }
}

# ---------------------------------------------------------------------------
# New-StrongPassword : génère un mot de passe robuste
# Garantit la présence d'au moins 1 caractère de chaque classe
# ---------------------------------------------------------------------------
function New-StrongPassword {
    param(
        [int]$Length = 16,
        [switch]$Passphrase,
        [int]$WordCount = 3
    )

    if ($Passphrase) {
        # Liste de mots français SANS accents (évite les pièges clavier).
        # Volontairement embarquée dans le code : pas de fichier externe à charger.
        $words = @(
            'chat','chien','tigre','lion','loup','ours','lapin','cheval','panda','renard',
            'dauphin','requin','faucon','corbeau','hibou','castor','belette','sanglier',
            'soleil','lune','nuage','vent','orage','brume','givre','sable','rocher','tunnel',
            'jardin','montagne','plage','prairie','ruisseau','cascade','volcan','canyon',
            'table','chaise','lampe','porte','pont','tour','phare','moulin','cabane','clocher',
            'pomme','poire','cerise','raisin','citron','banane','melon','carotte','tomate',
            'sucre','pain','miel','beurre','farine','poivre',
            'livre','stylo','papier','carton','coton','laine','cuir','verre','cuivre','bronze',
            'train','avion','bateau','moto','voile','ancre','cargo','wagon','chariot','fusee'
        )

        # RNG cryptographiquement sûr (PS 5.1 : RNGCryptoServiceProvider).
        # Tirage uniforme sans biais modulo via rejection sampling.
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rngBytes = New-Object byte[] 4
        $getIdx = {
            param([int]$Max)
            $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Max)
            do { $rng.GetBytes($rngBytes) } while ([BitConverter]::ToUInt32($rngBytes, 0) -ge $limit)
            return [int]([BitConverter]::ToUInt32($rngBytes, 0) % [uint32]$Max)
        }

        $digitChars = '23456789'
        $sb = New-Object System.Text.StringBuilder
        try {
            for ($i = 0; $i -lt $WordCount; $i++) {
                $w = $words[( & $getIdx $words.Length )]
                $cap = $w.Substring(0,1).ToUpper() + $w.Substring(1)
                if ($i -gt 0) { [void]$sb.Append('-') }
                [void]$sb.Append($cap)
            }
            # Deux chiffres finaux (sans 0 ni 1 pour éviter la confusion avec O et l)
            [void]$sb.Append('-')
            [void]$sb.Append($digitChars[( & $getIdx $digitChars.Length )])
            [void]$sb.Append($digitChars[( & $getIdx $digitChars.Length )])
        }
        finally { $rng.Dispose() }
        return $sb.ToString()
    }

    # --- Mode aléatoire (CSPRNG, aligné sur le mode passphrase) ---
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'    # sans I et O (confusion visuelle)
    $lower   = 'abcdefghjkmnpqrstuvwxyz'     # sans i, l, o (confusion visuelle)
    $digits  = '23456789'                    # sans 0 et 1 (confusion visuelle)
    $symbols = '@#$%&*!?+'
    $all     = $upper + $lower + $digits + $symbols

    # RNG cryptographiquement sûr, tirage uniforme sans biais modulo (rejection sampling).
    $rng      = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rngBytes = New-Object byte[] 4
    $pickInt  = {
        param([int]$Max)   # retourne un entier uniforme dans [0, Max)
        $m = [uint32]$Max
        $limit = [uint32]::MaxValue - ([uint32]::MaxValue % $m)
        do { $rng.GetBytes($rngBytes) } while ([BitConverter]::ToUInt32($rngBytes, 0) -ge $limit)
        return [int]([BitConverter]::ToUInt32($rngBytes, 0) % $m)
    }
    try {
        # Au moins 1 caractère de chaque classe
        $chars = @(
            $upper[  ( & $pickInt $upper.Length   ) ]
            $lower[  ( & $pickInt $lower.Length   ) ]
            $digits[ ( & $pickInt $digits.Length  ) ]
            $symbols[( & $pickInt $symbols.Length ) ]
        )
        # Compléter jusqu'à la longueur demandée
        for ($i = $chars.Count; $i -lt $Length; $i++) {
            $chars += $all[( & $pickInt $all.Length )]
        }
        # Mélange Fisher-Yates cryptographique : chaque indice j tiré via le même CSPRNG
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $pickInt ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
    }
    finally { $rng.Dispose() }
    return -join $chars
}

# ---------------------------------------------------------------------------
# Test-WingetAvailable : vérifie si winget est accessible
# ---------------------------------------------------------------------------
function Test-WingetAvailable {
    return ($null -ne (Get-Command winget -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------------------
# Test-InternetConnection : vérifie une vraie connexion sortante (TCP 443).
# N'utilise PAS ICMP (souvent bloqué). Retourne $true/$false.
# ---------------------------------------------------------------------------
function Test-InternetConnection {
    param([int]$TimeoutMs = 3000)
    $targets = @(
        @{ Host = 'www.msftconnecttest.com'; Port = 443 },
        @{ Host = 'cloudflare.com';          Port = 443 }
    )
    foreach ($t in $targets) {
        $client = $null
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $iar = $client.BeginConnect($t.Host, $t.Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) {
                return $true
            }
        }
        catch { }
        finally { if ($client) { $client.Close() } }
    }
    return $false
}

# ---------------------------------------------------------------------------
# ConvertFrom-AvProductState : décode le productState de SecurityCenter2.
# Format 6 hex : octet 2 = état produit (bit 0x10 = temps réel actif),
#                octet 1 = signatures (0x00 = à jour). PURE/testable.
# ---------------------------------------------------------------------------
function ConvertFrom-AvProductState {
    param([Parameter(Mandatory)][int]$State)
    $hex     = '{0:x6}' -f $State
    $rtByte  = [Convert]::ToInt32($hex.Substring(2,2),16)
    $defByte = [Convert]::ToInt32($hex.Substring(4,2),16)
    return [PSCustomObject]@{
        RealTimeEnabled = (($rtByte  -band 0x10) -ne 0)
        UpToDate        = (($defByte -band 0x10) -eq 0)
        Raw             = $State
    }
}

# ---------------------------------------------------------------------------
# Get-ActiveThirdPartyAv : liste les AV non-Defender avec temps réel actif.
# ---------------------------------------------------------------------------
function Get-ActiveThirdPartyAv {
    $list = @()
    try {
        $av = Get-CimInstance -Namespace root\SecurityCenter2 -Class AntiVirusProduct -ErrorAction Stop
        foreach ($a in $av) {
            if ($a.displayName -match 'Defender') { continue }
            if ((ConvertFrom-AvProductState -State $a.productState).RealTimeEnabled) {
                $list += $a.displayName
            }
        }
    }
    catch { }
    # Déduplication : SecurityCenter2 renvoie souvent plusieurs entrées pour la
    # même suite (vu au run réel : Kaspersky x4). Un nom unique suffit.
    $list = @($list | Sort-Object -Unique)
    # Retour tableau force (voir Get-RebootMarkersFromLogs) : sinon @() vide est
    # deroule en $null par le pipeline et .Count leve sous StrictMode Latest.
    return ,@($list)
}

# ---------------------------------------------------------------------------
# Get-DiagThirdPartyAv : AV tiers actifs lus depuis le JSON du module 00
# (source unique). La query SecurityCenter2 s'est montrée intermittente en
# session élevée au run réel : quand le diag existe, il fait foi. Retourne
# $null si le diag est absent/illisible (l'appelant retombe alors sur
# Get-ActiveThirdPartyAv). PURE vis-à-vis du chemin passé (testable).
# ---------------------------------------------------------------------------
function Get-DiagThirdPartyAv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DiagPath)
    if (-not (Test-Path $DiagPath)) { return $null }
    try {
        $diag = Get-Content $DiagPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Accès direct PSObject.Properties pour distinguer "clé absente" (return $null)
        # de "clé présente mais vide []" (return tableau vide). Get-JsonProp ne convient
        # pas ici : il retourne via le pipeline et unrolle @() en $null (même problème
        # que ,@() dans Get-RebootMarkersFromLogs).
        $prop = $diag.PSObject.Properties['ThirdPartyAvActive']
        if ($null -eq $prop) { return $null }
        $avList = @($prop.Value | Where-Object { $_ } | Sort-Object -Unique)
        return ,@($avList)
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Test-HasRecentKitRestorePoint : $true si un point de restauration créé par
# le kit ('PC-Refresh-Kit*') a moins de MaxAgeHours. Points = objets avec
# Description et CreationTime [datetime] (conversion WMI par l'appelant).
# PURE/testable.
# ---------------------------------------------------------------------------
function Test-HasRecentKitRestorePoint {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Points,
        [Parameter(Mandatory)][datetime]$Now,
        [int]$MaxAgeHours = 4
    )
    if (-not $Points) { return $false }
    foreach ($p in $Points) {
        if ($null -eq $p) { continue }
        if (-not $p.PSObject.Properties['Description'] -or -not $p.PSObject.Properties['CreationTime']) { continue }
        if ([string]$p.Description -notlike 'PC-Refresh-Kit*') { continue }
        try { $ct = [datetime]$p.CreationTime } catch { continue }
        if (($Now - $ct).TotalHours -lt $MaxAgeHours) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Get-ForeignFicheNames : fiches FICHE-PC-*.txt qui n'appartiennent PAS à
# l'ordinateur courant (fiche d'une intervention précédente restée sur la
# clé USB = mot de passe d'un autre PC qui voyage). PURE/testable.
# ---------------------------------------------------------------------------
function Get-ForeignFicheNames {
    # Contrat (b) : retour tableau PLAIN (initialisé @()) ; l'appelant DOIT
    # envelopper l'appel avec @(...). Ne pas utiliser ,@(...) ici : l'appelant
    # @() collecterait alors un tableau imbriqué (Count toujours >= 1).
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$FileNames,
        [Parameter(Mandatory)][string]$ComputerName
    )
    if (-not $FileNames) { return @() }
    $expected = "FICHE-PC-$ComputerName.txt"
    $foreign  = @($FileNames | Where-Object {
        $_ -and ($_ -notlike $expected)
    })
    return $foreign
}

# ---------------------------------------------------------------------------
# Get-JsonProp : accès défensif à une propriété d'un objet ConvertFrom-Json.
# PURE/testable. Sous StrictMode Latest, accéder à une propriété absente d'un
# PSCustomObject LÈVE (PropertyNotFoundStrict) : `if ($obj.cpu)` sur un objet
# sans 'cpu' jette au lieu d'être évalué comme faux. Ce helper renvoie $null
# quand l'objet est $null ou que la propriété n'existe pas, jamais d'exception.
# ---------------------------------------------------------------------------
function Get-JsonProp {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $prop = $InputObject.PSObject.Properties[$Name]
    if (-not $prop) { return $null }
    return $prop.Value
}

# ---------------------------------------------------------------------------
# Get-KitConfig : timeouts et seuils du kit (config/kit.json), avec valeurs
# par défaut si le fichier est absent, illisible ou incomplet. Le kit doit
# fonctionner sans ce fichier. PURE vis-à-vis du chemin passé (testable).
# ---------------------------------------------------------------------------
function Get-KitConfig {
    [CmdletBinding()]
    param([string]$Path)
    $cfg = @{
        wuSearchTimeoutMinutes  = 10
        wuInstallTimeoutMinutes = 60
        cleanmgrTimeoutMinutes  = 30
        downloadTimeoutSeconds  = 60
        diskWarnFreePct         = 15
        diskErrorFreePct        = 5
        restorePointMaxAgeHours = 4
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $PSScriptRoot '..\config\kit.json'
    }
    if (Test-Path $Path) {
        try {
            $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @($cfg.Keys)) {
                $val = Get-JsonProp $json $key
                if ($null -ne $val) { $cfg[$key] = [int]$val }
            }
        }
        catch { <# fichier illisible : on garde les défauts #> }
    }
    return $cfg
}

# ---------------------------------------------------------------------------
# Get-OptionalTool : chemin d'un binaire optionnel de tools/ SI il existe ET
# est signé Authenticode (Status 'Valid'), sinon $null. Support de
# l'enrichissement gracieux : aucun module ne DÉPEND d'un outil ; ceux qui en
# tirent parti ont toujours un fallback natif. PURE vis-à-vis du dossier passé.
# ---------------------------------------------------------------------------
function Get-OptionalTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ToolsDir
    )
    if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
        $ToolsDir = Join-Path $PSScriptRoot '..\tools'
    }
    $path = Join-Path $ToolsDir $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ($sig.Status -ne 'Valid') { return $null }
        return $path
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Read-KitProfile : lit un profil d'intervention depuis un fichier JSON et
# retourne un objet normalisé (toutes les clés présentes, défauts pour les
# absentes). Calqué sur Get-KitConfig : fichier absent ou illisible -> tous
# les défauts. PURE vis-à-vis du chemin passé (testable).
#
# Schéma de retour :
#   Modules     : hashtable Id -> bool (Ids '00'..'09','11','12','13','15','10')
#   Debloat     : 'Conservative' | 'Standard' | 'Aggressive' (défaut 'Standard')
#   KeepAdmin   : bool (défaut $false)
#   Recycle     : bool (défaut $false)
#   WinOld      : bool (défaut $false)
#   Cache       : bool (défaut $false)
#   OneDrive    : bool (défaut $false)
#   Oem         : bool (défaut $false)
#   NetReset    : bool (défaut $false)
#   BackupData  : bool (défaut $true)
#   ScanDefender: bool (défaut $true)
# ---------------------------------------------------------------------------
function Read-KitProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # Identifiants de modules connus (ordre de la GUI)
    $moduleIds = @('00','01','02','03','04','05','06','07','08','09','11','12','13','15','10')

    # Table des modules : tous activés par défaut
    $defModules = @{}
    foreach ($id in $moduleIds) { $defModules[$id] = $true }

    # Défauts des clés scalaires
    $defaults = [ordered]@{
        Debloat     = 'Standard'
        KeepAdmin   = $false
        Recycle     = $false
        WinOld      = $false
        Cache       = $false
        OneDrive    = $false
        Oem         = $false
        NetReset    = $false
        BackupData  = $true
        ScanDefender = $true
    }

    # Construction de l'objet résultat à partir des défauts
    $result = [ordered]@{}
    foreach ($k in @($defaults.Keys)) { $result[$k] = $defaults[$k] }
    $result['Modules'] = $defModules

    if (Test-Path $Path) {
        try {
            $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json

            # Écraser chaque clé scalaire si présente dans le fichier JSON
            # Cast explicite : Debloat -> string, toutes les autres clés -> bool
            foreach ($k in @($defaults.Keys)) {
                $val = Get-JsonProp $json $k
                if ($null -ne $val) {
                    if ($k -eq 'Debloat') { $result[$k] = [string]$val }
                    else                  { $result[$k] = [bool]$val }
                }
            }

            # Écraser les modules si la section Modules est présente
            $jsonModules = Get-JsonProp $json 'Modules'
            if ($null -ne $jsonModules) {
                foreach ($id in $moduleIds) {
                    $val = Get-JsonProp $jsonModules $id
                    if ($null -ne $val) { $defModules[$id] = [bool]$val }
                }
            }
        }
        catch { <# fichier illisible ou JSON invalide : on garde les défauts #> }
    }

    # Garde énumération : une valeur Debloat inconnue (faute, locale différente)
    # retombe sur le défaut pour ne pas casser la ComboBox de la GUI (Task 7)
    if ($result['Debloat'] -notin @('Conservative','Standard','Aggressive')) {
        $result['Debloat'] = 'Standard'
    }

    return [PSCustomObject]$result
}

# ---------------------------------------------------------------------------
# Build-ModuleArgList : arguments CLI d'un module à partir de son Id et d'un
# objet d'options (état des contrôles GUI, déjà normalisé). PURE/testable :
# ne lit aucun contrôle. La plomberie -ExecutionPolicy/-File reste côté GUI.
# Garde : une policy debloat invalide/absente retombe sur Standard.
# ---------------------------------------------------------------------------
function Build-ModuleArgList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [switch]$DryRun,
        [AllowNull()][hashtable]$Options
    )
    if ($null -eq $Options) { $Options = @{} }
    $a = @('-Unattended')
    if ($DryRun) { $a += '-WhatIf' }
    switch ($Id) {
        '01' { if (-not [bool]$Options['BackupData'])   { $a += '-SkipDataBackup' } }
        '02' { if (-not [bool]$Options['ScanDefender']) { $a += '-SkipDefenderScan' } }
        '03' {
            if ([bool]$Options['Oem']) { $a += '-RemoveOemBloat' }
            $policy = [string]$Options['DebloatPolicy']
            if ($policy -notin @('Conservative', 'Standard', 'Aggressive')) { $policy = 'Standard' }
            $a += @('-DebloatPolicy', $policy)
        }
        '07' {
            if ([bool]$Options['Recycle']) { $a += '-EmptyRecycleBin' }
            if ([bool]$Options['WinOld'])  { $a += '-RemoveWindowsOld' }
            if ([bool]$Options['Cache'])   { $a += '-CleanBrowserCache' }
        }
        '08' { if ([bool]$Options['KeepAdmin']) { $a += '-KeepAdmin' } }
        '09' { if ([bool]$Options['OneDrive']) { $a += '-RemoveOneDrive' } }
        '15' { if ([bool]$Options['NetReset']) { $a += '-ResetNetwork' } }
    }
    $a
}

# ---------------------------------------------------------------------------
# Get-BackupSourceFolders : dossiers utilisateur à sauvegarder, résolus via la
# redirection des dossiers connus (OneDrive KFM, dossiers déplacés).
# $env:USERPROFILE\Documents pointe sur le dossier local, potentiellement VIDE
# quand OneDrive a déplacé le vrai contenu ; GetFolderPath suit la redirection.
# Downloads n'a pas de SpecialFolder : registre User Shell Folders en premier.
# Retour : tableau forcé de chemins existants dédupliqués, jamais $null.
# ---------------------------------------------------------------------------
function Get-BackupSourceFolders {
    [CmdletBinding()]
    param()
    $candidates = @()
    foreach ($sf in @('MyDocuments', 'Desktop', 'MyPictures', 'MyVideos', 'MyMusic')) {
        try {
            $p = [Environment]::GetFolderPath($sf)
            if (-not [string]::IsNullOrWhiteSpace($p)) { $candidates += $p }
        }
        catch { }
    }
    $downloads = $null
    try {
        $usfKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $usf = Get-ItemProperty -Path $usfKey -ErrorAction SilentlyContinue
        # {374DE290-...} = GUID du dossier connu Downloads
        if ($usf -and $usf.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}']) {
            $downloads = [Environment]::ExpandEnvironmentVariables(
                [string]$usf.'{374DE290-123F-4565-9164-39C4925E467B}')
        }
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($downloads)) {
        $downloads = Join-Path $env:USERPROFILE 'Downloads'
    }
    $candidates += $downloads

    $seen   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = @()
    foreach ($c in $candidates) {
        $norm = $c.TrimEnd('\')
        if ($seen.Add($norm) -and (Test-Path $norm)) { $result += $norm }
    }
    # Contrat d'appel : toujours envelopper avec @() côté appelant.
    # $result est @() si aucun dossier trouvé : l'appelant @() collecte 0 objets -> Count=0, correct.
    # Ne pas utiliser ,@($result) : @() de l'appelant collecterait 1 élément (le tableau interne)
    # au lieu des N chemins.
    return $result
}

# ---------------------------------------------------------------------------
# Test-WingetRetryableExitCode : $true si le code de sortie winget est
# 0x8A150042 (prompt interactif détecté), qui justifie un retry silencieux.
# $LASTEXITCODE est un Int32 : le littéral 0x8A150042 déborde en Int64
# (2316632130) et n'est JAMAIS égal ; la valeur Int32 signée correcte est
# -1978335166. PURE/testable.
# ---------------------------------------------------------------------------
function Test-WingetRetryableExitCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ExitCode)
    return ($ExitCode -eq -1978335166)
}

# ---------------------------------------------------------------------------
# Get-WingetAbsentAdvice : message de diagnostic quand winget est introuvable,
# selon la version de Windows. Sur Windows 11, winget est fourni d'office :
# son absence signale un App Installer désactivé ou un PATH de session admin
# incomplet, pas un vieux Windows. PURE/testable.
# ---------------------------------------------------------------------------
function Get-WingetAbsentAdvice {
    [CmdletBinding()]
    param([AllowNull()][object]$IsWin11)
    if ($IsWin11 -eq $true) {
        return "winget introuvable alors que Windows 11 l'embarque : App Installer est peut-être désactivé, ou le PATH de la session admin est incomplet. Ouvrir le Microsoft Store, chercher 'App Installer' et le mettre à jour, puis relancer."
    }
    return "winget absent : sur ce Windows 10, installer 'App Installer' depuis le Microsoft Store pour l'activer, puis relancer."
}

# ---------------------------------------------------------------------------
# Test-GamePassPresent : signal fort que l'utilisateur joue sur ce PC
# (Gaming Services + jeux installés, ou dossier C:\XboxGames non vide).
# ---------------------------------------------------------------------------
function Test-GamePassPresent {
    if (Get-AppxPackage -Name 'Microsoft.GamingServices' -ErrorAction SilentlyContinue) {
        $gameConfig = 'HKLM:\SOFTWARE\Microsoft\GamingServices\GameConfig'
        if (Test-Path $gameConfig) {
            if (@(Get-ChildItem $gameConfig -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
        }
    }
    if (Test-Path 'C:\XboxGames') {
        if (@(Get-ChildItem 'C:\XboxGames' -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Test-AppxInUse : heuristique "appli utilisée" = données utilisateur non
# triviales dans LocalState (fichiers modifiés dans les 90 derniers jours).
# ---------------------------------------------------------------------------
function Test-AppxInUse {
    param([Parameter(Mandatory)][string]$PackageFamilyName)
    $local = Join-Path $env:LOCALAPPDATA "Packages\$PackageFamilyName\LocalState"
    if (-not (Test-Path $local)) { return $false }
    $recent = Get-ChildItem -Path $local -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-90) }
    return (@($recent).Count -gt 0)
}

# ---------------------------------------------------------------------------
# Get-DebloatDecision : décide KEEP / REMOVE / PROMPT pour une app
# conditionnelle. PURE/testable (toute la détection est passée en paramètres).
#   -Detect     : 'gamepass' | 'usage' (informatif)
#   -InUse      : résultat de la détection d'usage (bool)
#   -Unattended : $true en -All/-Force, $false en interactif
# ---------------------------------------------------------------------------
function Get-DebloatDecision {
    param(
        [Parameter(Mandatory)][string]$Detect,
        [Parameter(Mandatory)][bool]$InUse,
        [Parameter(Mandatory)][bool]$Unattended,
        [ValidateSet('Conservative', 'Standard', 'Aggressive')][string]$Policy = 'Standard'
    )
    if ($Policy -eq 'Conservative') {
        return [PSCustomObject]@{ Action = 'KEEP'   ; Reason = 'politique conservatrice' }
    }
    if ($InUse) {
        if ($Policy -eq 'Aggressive' -and $Detect -ne 'gamepass') {
            return [PSCustomObject]@{ Action = 'REMOVE' ; Reason = 'politique agressive (usage ignore)' }
        }
        return [PSCustomObject]@{ Action = 'KEEP'   ; Reason = 'usage detecte' }
    }
    if ($Unattended -or $Policy -eq 'Aggressive') {
        return [PSCustomObject]@{ Action = 'REMOVE' ; Reason = 'non utilise, mode automatique' }
    }
    return [PSCustomObject]@{ Action = 'PROMPT' ; Reason = 'non utilise, confirmation requise' }
}

# ---------------------------------------------------------------------------
# Test-InKeepList : $true si $Name figure dans la keep-list (patterns -like).
# -Bidirectional : teste aussi si un pattern de la keep-list matche $Name
# (nécessaire quand $Name est lui-même un pattern large, cas boucle 1 du
# module 03). Tolérant au null/vide. PURE/testable.
# ---------------------------------------------------------------------------
function Test-InKeepList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [AllowNull()][string[]]$KeepList,
        [switch]$Bidirectional
    )
    if (-not $KeepList) { return $false }
    foreach ($k in $KeepList) {
        if ([string]::IsNullOrEmpty($k)) { continue }
        if ($Name -like $k) { return $true }
        if ($Bidirectional -and ($k -like $Name)) { return $true }
    }
    return $false
}

function Get-StartupMatch {
    # Retourne l'entrée de liste noire qui matche (Name OU Command), sinon $null. Pur.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Command,
        [object[]]$Blacklist
    )
    if ($null -eq $Blacklist) { return $null }
    foreach ($entry in $Blacklist) {
        if (-not $entry.PSObject.Properties['match']) { continue }
        $rx = [regex]::Escape([string]$entry.match)
        if (($Name -and $Name -match $rx) -or ($Command -and $Command -match $rx)) { return $entry }
    }
    return $null
}

function Get-StartupApprovedDisabledBytes {
    # 12 octets ; 1er octet 0x03 = désactivé (mécanisme onglet Démarrage). Réversible (0x02 = activé). Pur.
    return ,([byte[]](0x03,0,0,0,0,0,0,0,0,0,0,0))
}

function Get-StartupHiveFromLocation {
    # Mappe la colonne Location de Win32_StartupCommand vers une cible de désactivation. Pur.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return 'Unknown' }
    if ($Location -match '\\Run$' -or $Location -match '\\Run\\') {
        if ($Location -match '^HKLM') { return 'HKLM-Run' }
        if ($Location -match '^(HKU|HKCU)') { return 'HKCU-Run' }
    }
    if ($Location -match 'Startup') { return 'Folder' }
    return 'Unknown'
}

function Test-IsLogonOrBootTrigger {
    # $true si le déclencheur de tâche planifiée est de type logon ou boot, de façon
    # StrictMode-safe : un déclencheur peut NE PAS porter la propriété CimClass, et sous
    # Set-StrictMode -Version Latest l'accès direct $_.CimClass lève alors (PropertyNotFoundStrict)
    # AVANT toute comparaison - d'où les gardes PSObject.Properties. Pur/testable.
    [CmdletBinding()]
    param([AllowNull()]$Trigger)
    if ($null -eq $Trigger) { return $false }
    if (-not $Trigger.PSObject.Properties['CimClass']) { return $false }
    if ($null -eq $Trigger.CimClass) { return $false }
    if (-not $Trigger.CimClass.PSObject.Properties['CimClassName']) { return $false }
    return ([string]$Trigger.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger','MSFT_TaskBootTrigger'))
}

# ===========================================================================
# Réversibilité (v1.6) - manifeste d'annulation lu par le module 14-Undo
# ===========================================================================

function Get-StartupApprovedEnabledBytes {
    # 12 octets ; 1er octet 0x02 = activé (mécanisme onglet Démarrage). Symétrique de la
    # version disabled (0x03). Pur. Sert au module 14-Undo pour réactiver un autostart.
    return ,([byte[]](0x02,0,0,0,0,0,0,0,0,0,0,0))
}
