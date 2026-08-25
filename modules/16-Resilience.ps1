# modules/16-Resilience.ps1 - Filets de secours : réarmement des protections
# Windows + coffre de ruches registre (v2.4).
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\16-Resilience.ps1 [-WhatIf] [-ExportBitLockerKey]
<#
.SYNOPSIS
    Réarme les filets de récupération Windows (WinRE, auto-réparation au boot,
    stockage de clichés) et sauvegarde les 5 ruches registre dans un coffre
    daté (clé USB du kit + copie locale ProgramData), avec manifeste vérifiable
    depuis WinRE (machine-id + tailles exactes).
    Le coffre contient SAM et SECURITY : toute destination posée sur un système
    de fichiers à ACL (NTFS, ReFS) est refermée sur SYSTEM et Administrateurs
    avant la première écriture - coffre EXTERNE compris - et n'est pas écrite du
    tout si ce verrou échoue. Seul un support qui ne peut pas porter d'ACL
    (FAT32, exFAT) s'en remet à une protection physique, et le journal le dit.
.PARAMETER ExportBitLockerKey
    Si présent ET volume chiffré : écrit le mot de passe de récupération
    BitLocker dans le coffre EXTERNE uniquement, et seulement si ce coffre vit
    sur un support AMOVIBLE. Décoché par défaut.
#>

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [switch]$ExportBitLockerKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

# ---------------------------------------------------------------------------
# Verrou d'accès du coffre LOCAL.
# C:\ProgramData accorde par héritage un ReadAndExecute au groupe
# « Utilisateurs » : un coffre posé là sans rien faire livrerait SAM
# (empreintes des mots de passe locaux), SECURITY (secrets LSA : mots de passe
# de comptes de service, identifiants en cache, clés DPAPI) et SYSTEM (la
# bootkey qui les déchiffre) en LECTURE à n'importe quel compte standard de la
# machine. C'est l'élévation de privilèges locale de la famille HiveNightmare
# (CVE-2021-36934) que le kit CRÉERAIT lui-même, sur chaque PC, et laisserait
# en place (3 jeux conservés). Le dossier est donc refermé sur SYSTEM et
# Administrateurs AVANT le premier reg save.
# Une DACL ne suffit pas : C:\ProgramData\PC-Refresh-Kit accorde à
# « Utilisateurs » le droit de créer un sous-dossier, donc un compte standard
# peut poser HiveVault AVANT le kit. Il en resterait CRÉATEUR PROPRIÉTAIRE, et
# le propriétaire détient WRITE_DAC implicitement : il rouvrirait la DACL APRÈS
# l'écriture de SAM, quelle que soit la DACL posée. Le coffre reprend donc aussi
# la PROPRIÉTÉ, et refuse un dossier déjà là qui serait un point d'analyse.
# Le coffre EXTERNE tombe sous la MÊME règle dès que son volume porte des ACL.
# Le kit ne tourne pas forcément depuis une clé FAT32 : une seconde partition
# INTERNE en NTFS, ou une clé formatée en NTFS, hérite de la racine du volume un
# « Utilisateurs : lecture et exécution » qui rendrait D:\Coffre\<PC>\hives-*\SAM
# lisible par n'importe quel compte standard de la machine, en permanence (3 jeux
# conservés) - exactement la faille refermée côté ProgramData. La protection
# physique n'est donc pas un modèle valable en général : elle ne vaut que là où
# le système de fichiers ne peut RIEN porter (FAT, FAT32, exFAT). Sur ces
# supports-là, et là seulement, le kit écrit quand même et l'annonce : c'est le
# cas d'usage de la clé navette.
# ---------------------------------------------------------------------------

# PURE (aucun accès disque, donc testable) : referme une description de
# sécurité sur SYSTEM et le groupe Administrateurs local. Les deux identités
# sont désignées par SID universel et JAMAIS par nom : « Administrateurs » ici,
# « Administrators » ailleurs, et le kit tourne sur des machines de toutes
# langues - un nom en dur y viserait un groupe inexistant.
function Set-KitVaultAclRules {
    [CmdletBinding()]
    [OutputType([System.Security.AccessControl.DirectorySecurity])]
    param([Parameter(Mandatory)][System.Security.AccessControl.DirectorySecurity]$Acl)
    # $false en second argument : les ACE hérités ne sont PAS recopiés en ACE
    # explicites - c'est précisément lui qui évacue « Utilisateurs ».
    $Acl.SetAccessRuleProtection($true, $false)
    # Purge de ce qui resterait d'explicite (coffre créé par une version
    # antérieure du kit, ACE posé à la main) : sinon un accès déjà accordé
    # survivrait à la coupure d'héritage.
    # GetAccessRules et non la propriété .Access : cette dernière est une
    # extension de type ajoutée par PowerShell (Microsoft.PowerShell.Security),
    # absente tant qu'aucun Get-Acl n'a été appelé dans la session - sous
    # StrictMode, la lire lèverait alors PropertyNotFound.
    foreach ($ace in @($Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
        if ($ace.IsInherited) { continue }
        [void]$Acl.RemoveAccessRuleSpecific($ace)
    }
    $rights  = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propag  = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid  = New-Object System.Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rights, $inherit, $propag, $allow)
        $Acl.AddAccessRule($rule)
    }
    # Le PROPRIÉTAIRE en dernier, et il compte autant que la DACL : le
    # propriétaire d'un objet détient WRITE_DAC de façon implicite, donc un
    # coffre parfaitement refermé mais resté la propriété du compte standard qui
    # l'a pré-créé serait rouvert par lui APRÈS l'écriture de SAM. La propriété
    # revient au groupe Administrateurs local, désigné par SID comme le reste.
    $Acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    return $Acl
}

# PURE : le verdict d'après coup. Un Set-Acl sans exception ne prouve pas l'ACL
# réellement posée (support sans ACL, redirection, filtre tiers) ; on relit et
# on vérifie que plus personne d'autre n'a d'accès AVANT d'écrire une ruche.
function Test-KitVaultAclSafe {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Security.AccessControl.FileSystemSecurity]$Acl)
    if (-not $Acl.AreAccessRulesProtected) { return $false }
    # Le propriétaire AVANT la DACL : il détient WRITE_DAC quoi que dise la DACL,
    # donc un verrou parfait sur un dossier resté la propriété d'un compte
    # standard ne protège rien du tout - il le rouvrirait après coup.
    # GetOwner([SecurityIdentifier]) et JAMAIS la propriété .Owner : cette
    # dernière est une extension de type ajoutée par PowerShell, absente tant
    # qu'aucun Get-Acl n'a eu lieu dans la session (même piège que .Access).
    # Description sans propriétaire ($null) : refusée aussi, on ne suppose rien.
    $owner = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($null -eq $owner -or [string]$owner.Value -ne 'S-1-5-32-544') { return $false }
    # Identités relues en SID et jamais en nom : sur une machine hors domaine ou
    # devant un compte orphelin, la traduction en nom échoue et ferait passer un
    # ACE inconnu pour sûr. Héritées incluses : il ne doit plus en rester.
    $rules    = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $expected = @('S-1-5-18', 'S-1-5-32-544')
    $allow    = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($r in $rules) {
        if ($expected -notcontains [string]$r.IdentityReference.Value) { return $false }
        # Un ACE de REFUS sur l'une des deux identités attendues passerait le
        # contrôle d'identité ci-dessus tout en verrouillant le coffre contre ses
        # propres ayants droit : ni écriture des ruches, ni relecture en secours.
        # Un coffre inutilisable n'est pas un coffre sûr.
        if ($r.AccessControlType -ne $allow) { return $false }
    }
    $full   = [int][System.Security.AccessControl.FileSystemRights]::FullControl
    # Les indicateurs d'héritage font partie de l'assertion : sans eux, le
    # dossier serait bien fermé mais les RUCHES qu'on y écrit n'hériteraient de
    # rien - et ce sont elles qui portent les secrets.
    $inhAll = [int][System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sidText in $expected) {
        $match = @($rules | Where-Object {
            [string]$_.IdentityReference.Value -eq $sidText -and
            $_.AccessControlType -eq $allow -and
            (([int]$_.FileSystemRights -band $full) -eq $full) -and
            (([int]$_.InheritanceFlags -band $inhAll) -eq $inhAll)
        })
        if ($match.Count -eq 0) { return $false }
    }
    return $true
}

# PURE : ce système de fichiers peut-il porter des ACL ? C'est LUI qui décide du
# modèle de protection d'une destination, jamais le type de lecteur : une clé USB
# formatée en NTFS porte des ACL, et une partition interne aussi.
# La liste énumère les systèmes SANS ACL, et non l'inverse : un système de
# fichiers inconnu, ou que le disque n'a pas su rendre, est alors traité comme
# portant des ACL, donc verrouillé - et le coffre sauté si le verrou échoue.
# Le sens inverse promettrait une « protection physique » sur un volume qui, lui,
# porte peut-être des ACL laissées grandes ouvertes : c'est la faille même.
function Test-KitVaultFsSupportsAcl {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$FileSystem)
    $fs = ''
    if ($null -ne $FileSystem) { $fs = $FileSystem.Trim().ToUpperInvariant() }
    return (@('FAT', 'FAT12', 'FAT16', 'FAT32', 'EXFAT') -notcontains $fs)
}

# PURE : le support est-il AMOVIBLE ? Seule réponse qui autorise l'export de la
# clé de récupération BitLocker. Une clé à 48 chiffres, même dans un coffre
# verrouillé par ACL, n'a rien à faire sur une partition interne : elle y
# resterait des mois à côté du disque qu'elle ouvre, à portée du premier
# administrateur de passage ou d'un vol de machine. Un type non mesuré ('') vaut
# refus : on n'exporte pas une clé sur un support qu'on n'a pas identifié.
function Test-KitRemovableMedium {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$DriveType)
    if ($null -eq $DriveType) { return $false }
    return ($DriveType.Trim() -eq 'Removable')
}

# Système de fichiers d'un volume, mesuré sur le disque (donc pas pure). Deux
# sondes, la seconde n'étant pas un doublon : Get-Volume vient du module Storage
# et refuse une lettre non conforme (kit lancé depuis un partage monté), tandis
# que System.IO.DriveInfo appelle l'API Windows directement. Chaîne vide si
# aucune des deux ne répond : l'appelant traite alors le volume comme portant des
# ACL (fermeture par défaut).
function Get-KitVolumeFileSystem {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DriveRoot)
    # -match explicite et non -notmatch : $Matches n'est renseigné de façon
    # fiable que par la forme positive, et le lire à vide lèverait sous StrictMode.
    $letter = ''
    if ([string]$DriveRoot -match '^\s*([A-Za-z])') { $letter = [string]$Matches[1] }
    if ([string]::IsNullOrEmpty($letter)) { return '' }
    try {
        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        if ($vol -and $vol.PSObject.Properties['FileSystem']) {
            $fs = [string]$vol.FileSystem
            if (-not [string]::IsNullOrWhiteSpace($fs)) { return $fs.Trim() }
        }
    }
    catch { }
    try {
        $di = New-Object System.IO.DriveInfo($letter + ':')
        if ($di.IsReady) {
            $fmt = [string]$di.DriveFormat
            if (-not [string]::IsNullOrWhiteSpace($fmt)) { return $fmt.Trim() }
        }
    }
    catch { }
    return ''
}

# Un chemin est-il un point d'analyse (jonction, lien symbolique) plutôt qu'un
# vrai dossier ? Get-Acl, Set-Acl et l'écriture le traversent sans le dire : un
# dossier pré-posé en jonction ferait verrouiller - et REMPLIR de SAM et
# SECURITY - une cible choisie par celui qui l'a posée. Un chemin absent rend
# $false (rien à détourner) ; une erreur d'accès REMONTE à l'appelant, qui
# décide, plutôt que de se lire comme un « ce n'est pas une jonction ».
function Test-KitReparsePoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return ((([int]$item.Attributes) -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Applique le verrou à un dossier existant. Rend Ok/Reason : l'appelant décide,
# et l'écriture des ruches ne part JAMAIS sur un Ok à $false.
function Protect-KitVaultDir {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        # Un dossier DÉJÀ là n'a pas forcément été créé par le kit : sous
        # C:\ProgramData\PC-Refresh-Kit, « Utilisateurs » peut créer un
        # sous-dossier, donc un compte standard peut poser HiveVault (ou un
        # hives-<horodatage>) à l'avance, et le poser comme JONCTION vers un
        # dossier qu'il contrôle. Mesuré : Get-Acl et Set-Acl suivent la jonction
        # sans le dire (même SDDL que la cible) et l'écriture la traverse - le
        # kit croirait avoir refermé son coffre alors qu'il aurait verrouillé, et
        # surtout REMPLI de SAM et SECURITY, un dossier choisi par l'attaquant.
        # Un point d'analyse n'est donc jamais un coffre : on refuse, on ne
        # cherche ni à le réparer ni à le supprimer (selon la version de Windows
        # PowerShell, un Remove-Item -Recurse peut traverser une jonction).
        if (Test-KitReparsePoint -Path $Path) {
            return [PSCustomObject]@{ Ok = $false; Reparse = $true; Reason = "point d'analyse (jonction ou lien) au lieu d'un vrai dossier" }
        }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        [void](Set-KitVaultAclRules -Acl $acl)
        # Set-Acl persiste en un seul appel toutes les sections marquées : DACL
        # ET propriétaire. Une reprise de propriété refusée (jeton sans le groupe
        # Administrateurs en accès, typiquement non élevé) fait donc échouer tout
        # le Set-Acl sans rien appliquer - le catch ci-dessous rend Ok à $false
        # et l'appelant n'écrit aucune ruche. Fermeture par défaut, voulue.
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        $after = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (-not (Test-KitVaultAclSafe -Acl $after)) {
            return [PSCustomObject]@{ Ok = $false; Reparse = $false; Reason = "ACL relue encore ouverte à d'autres comptes ou propriété non reprise" }
        }
        return [PSCustomObject]@{ Ok = $true; Reparse = $false; Reason = '' }
    }
    catch { return [PSCustomObject]@{ Ok = $false; Reparse = $false; Reason = ([string]$_) } }
}

Write-KitLog -Message "=== 16-Resilience : début ===" -Level 'INFO'
$exitCode = 0

# ---------------------------------------------------------------------------
# 1/3 Réarmement des filets (jamais dans le sens de la réduction)
# ---------------------------------------------------------------------------
# WinRE (reagentc) : Disabled -> enable. Un état non lisible ne déclenche AUCUNE
# action : on ne réarme que ce qu'on a mesuré désarmé.
try {
    $reOut = @(& reagentc /info 2>&1 | ForEach-Object { [string]$_ })
    $reV = Get-WinReVerdict -ReagentcOutput $reOut
    if ($reV.Status -eq 'Disabled') {
        if ($WhatIf) { Write-KitLog -Message "WHATIF: Aurait exécuté reagentc /enable (WinRE désarmé)" -Level 'WHATIF' }
        else {
            & reagentc /enable 2>&1 | Out-Null
            # Le verdict après coup fait foi, pas le code de retour : reagentc
            # rend 0 dans des cas où WinRE reste indisponible (image absente).
            $reV2 = Get-WinReVerdict -ReagentcOutput @(& reagentc /info 2>&1 | ForEach-Object { [string]$_ })
            Write-KitLog -Message "WinRE réarmé : $($reV2.Status) (avant : Disabled)" -Level $(if ($reV2.Status -eq 'Enabled') { 'OK' } else { 'WARN' })
        }
    }
    elseif ($reV.Status -eq 'Enabled') {
        Write-KitLog -Message "WinRE : Enabled (aucune action)" -Level 'OK'
    }
    else {
        Write-KitLog -Message "WinRE : état non lisible ($($reV.Status)) - aucune action, rien n'a été mesuré comme désarmé." -Level 'WARN'
    }
}
catch { Write-KitLog -Message "reagentc inaccessible : $_" -Level 'WARN' }

# Auto-réparation au boot (recoveryenabled).
try {
    $bcdOut  = @(& bcdedit /enum '{default}' 2>&1 | ForEach-Object { [string]$_ })
    $bcdExit = $LASTEXITCODE
    if ($bcdExit -ne 0 -or @($bcdOut).Count -eq 0) {
        # Sortie inexploitable : la fonction pure y lirait « Absent » alors que
        # rien n'a été mesuré. Aucune écriture dans le BCD sur cette base.
        Write-KitLog -Message "Auto-réparation au démarrage : bcdedit n'a rien renvoyé d'exploitable (code $bcdExit), aucune action." -Level 'WARN'
    }
    else {
        $recV = Get-RecoveryEnabledVerdict -BcdOutput $bcdOut
        if ($recV.Status -ne 'Yes') {
            if ($WhatIf) { Write-KitLog -Message "WHATIF: Aurait exécuté bcdedit /set {default} recoveryenabled Yes (état : $($recV.Status))" -Level 'WHATIF' }
            else {
                & bcdedit /set '{default}' recoveryenabled Yes 2>&1 | Out-Null
                $setExit = $LASTEXITCODE
                if ($setExit -eq 0) {
                    Write-KitLog -Message "Auto-réparation au démarrage réarmée (recoveryenabled Yes, avant : $($recV.Status))" -Level 'OK'
                }
                else {
                    Write-KitLog -Message "Auto-réparation au démarrage : bcdedit a refusé l'écriture (code $setExit), état inchangé ($($recV.Status))." -Level 'WARN'
                }
            }
        }
        else { Write-KitLog -Message "Auto-réparation au démarrage : déjà armée." -Level 'OK' }
    }
}
catch { Write-KitLog -Message "bcdedit inaccessible : $_" -Level 'WARN' }

# Stockage de clichés : agrandir à 10% si inadéquat. JAMAIS réduire (une
# réduction purge des clichés existants).
try {
    $volCim = Get-CimInstance Win32_Volume -Filter "DriveLetter = 'C:'" -ErrorAction Stop | Select-Object -First 1
    # Requête sans erreur mais sans volume : rien n'a été mesuré. Sortir par le
    # catch plutôt que de conclure « réserve insuffisante » sur du vide.
    if ($null -eq $volCim) { throw "volume C: absent de Win32_Volume" }
    # -ErrorAction Stop volontaire : sans élévation la classe Win32_ShadowStorage
    # refuse la requête ; en SilentlyContinue ce refus deviendrait un tableau vide,
    # donc un agrandissement décidé sans avoir rien mesuré.
    $ss = @(Get-CimInstance Win32_ShadowStorage -ErrorAction Stop) | Where-Object {
        $_.Volume.DeviceID -eq $volCim.DeviceID
    } | Select-Object -First 1
    $maxNow = $null
    if ($ss) { $maxNow = [uint64]$ss.MaxSpace }
    # Capacity nulle : StrictMode reste muet (la propriété existe, sa valeur est
    # nulle) et [int64]$null vaut 0, ce que la fonction pure traduit en « inadéquat ».
    # L'agrandissement partirait alors sur un volume jamais mesuré : sur un PC dont
    # la réserve dépasse déjà 10%, le resize la RÉDUIRAIT et purgerait les clichés
    # existants, c'est-à-dire le seul sens interdit ici.
    if ($null -eq $volCim.Capacity -or [int64]$volCim.Capacity -le 0) { throw "capacité du volume C: non mesurable" }
    if (-not (Test-ShadowStorageAdequate -MaxSpaceBytes $maxNow -VolumeSizeBytes ([int64]$volCim.Capacity) -MinPct 5)) {
        if ($WhatIf) { Write-KitLog -Message "WHATIF: Aurait agrandi le stockage de clichés VSS de C: à 10% (vssadmin resize/add)" -Level 'WHATIF' }
        else {
            $rz     = @(& vssadmin resize shadowstorage /for=C: /on=C: /maxsize=10% 2>&1 | ForEach-Object { [string]$_ })
            $rzExit = $LASTEXITCODE
            if ($rzExit -ne 0) {
                # Aucune association existante : la créer (cas restauration jamais activée).
                $rz     = @(& vssadmin add shadowstorage /for=C: /on=C: /maxsize=10% 2>&1 | ForEach-Object { [string]$_ })
                $rzExit = $LASTEXITCODE
            }
            $avant = if ($null -eq $maxNow) { 'non configuré' } else { [math]::Round($maxNow / 1GB, 1).ToString() + ' Go' }
            if ($rzExit -eq 0) {
                Write-KitLog -Message "Stockage de clichés VSS de C: porté à 10% (état avant : $avant)." -Level 'OK'
            }
            else {
                # Jamais de « porté à 10% » sur un vssadmin en échec : la réserve
                # est restée telle quelle, et le dire est le seul compte rendu honnête.
                $detail = @($rz | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
                $motif  = if ($detail.Count -gt 0) { $detail[0].Trim() } else { 'aucun détail' }
                Write-KitLog -Message "Stockage de clichés VSS : vssadmin a refusé (code $rzExit, $motif). Réserve INCHANGÉE (état : $avant), aucune réduction n'a été tentée." -Level 'WARN'
            }
        }
    }
    else { Write-KitLog -Message "Stockage de clichés VSS : déjà adéquat (aucune réduction, jamais)." -Level 'OK' }
}
catch { Write-KitLog -Message "Stockage de clichés non gérable : $_" -Level 'WARN' }

# ---------------------------------------------------------------------------
# 2/3 Empreinte machine (clef de voûte du garde-fou de restauration WinRE :
# en WinRE, COMPUTERNAME vaut MININT-xxx et le registre peut être cassé ;
# seul ce fichier posé sur le volume Windows fait foi).
# ---------------------------------------------------------------------------
$pdDir     = Join-Path $env:ProgramData 'PC-Refresh-Kit'
$midPath   = Join-Path $pdDir 'machine-id.txt'
# C:\ProgramData laisse « Utilisateurs » créer un sous-dossier : PC-Refresh-Kit
# lui-même peut donc avoir été posé AVANT le kit, et posé comme JONCTION vers un
# dossier que ce compte contrôle. Tout ce qui vit dessous - l'empreinte machine
# ET le coffre local avec SAM et SECURITY - serait alors écrit ailleurs, dans un
# dossier choisi par l'attaquant, et le verrou du coffre s'appliquerait à la
# cible de la jonction sans que rien ne le signale (Get-Acl et Set-Acl la
# traversent en silence). Le contrôle a donc lieu UNE fois, avant le premier
# usage du dossier - lecture de l'empreinte comprise - et il ne répare rien :
# un point d'analyse n'est jamais assaini, il est refusé.
$pdSafe = $true
try {
    if (Test-KitReparsePoint -Path $pdDir) {
        $pdSafe = $false
        Write-KitLog -Message "ERREUR : $pdDir est un point d'analyse (jonction ou lien), pas un vrai dossier : il a été posé avant le kit pour détourner l'écriture ailleurs. Empreinte machine et coffre LOCAL abandonnés, le dossier est laissé tel quel (le supprimer risquerait d'effacer sa cible). Le coffre externe reste la sauvegarde." -Level 'ERROR'
        $exitCode = 1
    }
}
catch {
    # Dossier illisible : rien n'a été mesuré, donc rien n'est présumé sain.
    $pdSafe = $false
    Write-KitLog -Message "ERREUR : $pdDir non inspectable ($_) : impossible de vérifier que ce n'est pas un point d'analyse. Empreinte machine et coffre LOCAL abandonnés." -Level 'ERROR'
    $exitCode = 1
}
$machineId = ''
$midRaw    = $null
$midAction = ''
if ($pdSafe -and (Test-Path $midPath)) {
    try {
        # Lecture en OCTETS : secours.bat lit ce fichier avec `set /p`, qui rend
        # la ligne brute. Un BOM ou un accent y serait lu tel quel et ne
        # concorderait plus avec le manifeste : l'empreinte doit être pur ASCII.
        $midBytes  = [System.IO.File]::ReadAllBytes($midPath)
        $pureAscii = $true
        foreach ($b in $midBytes) { if ($b -gt 0x7F) { $pureAscii = $false; break } }
        if ($pureAscii) {
            $midRaw = ([System.Text.Encoding]::ASCII.GetString($midBytes) -split "`r|`n")[0]
        }
        else {
            Write-KitLog -Message "Empreinte machine illisible depuis WinRE (octets non ASCII) : elle est régénérée, les coffres plus anciens de ce PC ne seront plus reconnus." -Level 'WARN'
        }
    }
    catch { Write-KitLog -Message "Empreinte machine non lisible : $_" -Level 'WARN' }
}
if ($null -ne $midRaw) { $machineId = $midRaw.Trim() }
# Garde de forme : une empreinte vide, tronquée ou fantaisiste ne servirait à
# rien comme preuve d'appartenance du coffre. GUID par défaut, 8 à 64 caractères.
if ($machineId -notmatch '^[A-Za-z0-9-]{8,64}$') { $machineId = '' }

$midNeedsWrite = $false
if ([string]::IsNullOrEmpty($machineId)) {
    $machineId     = [guid]::NewGuid().ToString()
    $midNeedsWrite = $true
    $midAction     = 'créée'
}
elseif ($machineId -ne $midRaw) {
    # Espaces parasites autour de l'empreinte : `set /p` les lirait, la
    # comparaison avec le manifeste échouerait et le secours refuserait le coffre.
    $midNeedsWrite = $true
    $midAction     = 'normalisée'
}
else { Write-KitLog -Message "Empreinte machine existante réutilisée." -Level 'INFO' }

if ($midNeedsWrite) {
    if (-not $pdSafe) {
        # Écrire ici traverserait la jonction : l'empreinte partirait chez celui
        # qui l'a posée, et le manifeste du coffre externe annoncerait une
        # empreinte qui n'est nulle part sur le volume Windows.
        Write-KitLog -Message "Empreinte machine NON écrite : $pdDir est un point d'analyse (voir l'erreur ci-dessus). Assainir ce dossier puis relancer, sinon le mode secours refusera de poser une ruche du coffre." -Level 'ERROR'
        $exitCode = 1
    }
    elseif ($WhatIf) { Write-KitLog -Message "WHATIF: Aurait écrit l'empreinte machine $midPath" -Level 'WHATIF' }
    else {
        try {
            if (-not (Test-Path $pdDir)) { New-Item -ItemType Directory -Force -Path $pdDir | Out-Null }
            Set-Content -Path $midPath -Value $machineId -Encoding Ascii
            Write-KitLog -Message "Empreinte machine $midAction : $midPath" -Level 'OK'
        }
        catch {
            Write-KitLog -Message "ERREUR : empreinte machine non écrite ($midPath) : $_ - sans elle, le mode secours refusera de poser une ruche du coffre." -Level 'ERROR'
            $exitCode = 1
        }
    }
}

# ---------------------------------------------------------------------------
# 3/3 Coffre de ruches : reg save des 5 ruches vers 1-2 destinations + manifeste.
# reg save produit une ruche défragmentée propre, sans verrou (méthode canonique).
# ---------------------------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
# Nom de machine assaini : il sert de nom de dossier ET de valeur de manifeste,
# tous deux lus depuis WinRE en page de codes OEM (cf. ConvertTo-KitAsciiToken).
$pcToken = ConvertTo-KitAsciiToken -Text $env:COMPUTERNAME
$hiveSpecs = @(
    @{ Key = 'HKLM\SYSTEM';   File = 'SYSTEM' },
    @{ Key = 'HKLM\SOFTWARE'; File = 'SOFTWARE' },
    @{ Key = 'HKLM\SAM';      File = 'SAM' },
    @{ Key = 'HKLM\SECURITY'; File = 'SECURITY' },
    @{ Key = 'HKU\.DEFAULT';  File = 'DEFAULT' }
)

# Destination externe : d'abord le volume DEPUIS LEQUEL LE KIT TOURNE, dès qu'il
# n'est pas le volume système, quel que soit son type. Une clé USB se présente en
# « Removable » mais un SSD ou un disque dur USB se présente en « Fixed » :
# n'accepter que « Removable » écarterait le support que l'opérateur a lui-même
# branché pour l'intervention. Risque assumé : un kit copié sur une seconde
# partition INTERNE donne un coffre qui meurt avec le disque - mais ce volume-là
# reste, par construction, celui que l'opérateur a apporté.
# Le balayage aveugle des autres volumes, lui, reste limité aux AMOVIBLES : sans
# le repère du volume du kit, un « Fixed » non système est le plus souvent une
# partition interne de données, et un coffre posé là meurt avec le disque à secourir.
$externalRoot = $null
$externalType = ''
try {
    $kitRoot  = Split-Path $PSScriptRoot -Parent
    $kitDrive = (Get-Item $kitRoot -ErrorAction Stop).PSDrive
    if ($kitDrive) {
        # Try imbriqué : un PSDrive au nom non conforme (kit lancé depuis un
        # partage réseau monté) fait échouer la liaison de -DriveLetter ; le
        # repli sur les volumes amovibles doit quand même être tenté.
        $kitVol = $null
        try { $kitVol = Get-Volume -DriveLetter $kitDrive.Name -ErrorAction SilentlyContinue } catch { $kitVol = $null }
        if ($kitVol -and "$($kitDrive.Name):" -ne $env:SystemDrive) {
            $externalRoot = "$($kitDrive.Name):"
            if ($kitVol.PSObject.Properties['DriveType']) { $externalType = [string]$kitVol.DriveType }
            Write-KitLog -Message "Coffre externe sur $externalRoot [$externalType] : volume du kit, hors volume système - présumé apporté pour l'intervention (non vérifiable : une seconde partition interne serait acceptée aussi)." -Level 'INFO'
        }
    }
    if (-not $externalRoot) {
        $candidates = @(Get-Volume -ErrorAction Stop | Where-Object {
            $_.DriveType -eq 'Removable' -and $_.DriveLetter -and $_.DriveLetter -ne 'C'
        } | Sort-Object DriveLetter)
        if ($candidates.Count -gt 0) {
            $externalRoot = "$($candidates[0].DriveLetter):"
            $externalType = [string]$candidates[0].DriveType
            Write-KitLog -Message "Coffre externe sur $externalRoot : le kit ne tourne pas depuis un volume externe, premier volume amovible monté retenu." -Level 'INFO'
        }
    }
}
catch {
    $externalRoot = $null
    $externalType = ''
    Write-KitLog -Message "Recherche d'un support externe impossible ($_) : le coffre externe est sauté." -Level 'WARN'
}

# Modèle de protection du coffre EXTERNE : c'est le système de fichiers du
# support qui tranche, jamais son type de lecteur. NTFS et ReFS portent des ACL,
# donc le coffre externe s'y referme exactement comme le coffre local - sans
# quoi une seconde partition interne, ou une clé formatée en NTFS, livrerait
# SAM, SECURITY et SYSTEM en lecture à tout compte standard de la machine.
# FAT32 et exFAT ne peuvent rien porter : là, la protection est physique, le
# kit écrit quand même (c'est la clé navette) et l'opérateur en est averti.
$externalFs  = ''
$externalAcl = $true
if ($externalRoot) {
    $externalFs  = Get-KitVolumeFileSystem -DriveRoot $externalRoot
    $externalAcl = Test-KitVaultFsSupportsAcl -FileSystem $externalFs
    $fsLabel     = if ([string]::IsNullOrWhiteSpace($externalFs)) { 'système de fichiers non mesuré' } else { $externalFs }
    if ($externalAcl) {
        Write-KitLog -Message "Coffre externe sur $externalRoot [$fsLabel] : ce système de fichiers porte des ACL, le coffre y sera refermé sur SYSTEM et Administrateurs comme le coffre local." -Level 'INFO'
    }
    else {
        Write-KitLog -Message "Coffre externe sur $externalRoot [$fsLabel] : ce système de fichiers ne porte pas d'ACL, la protection est PHYSIQUE - conservez la clé comme un trousseau." -Level 'WARN'
    }
}

# Garde d'espace du coffre LOCAL : un jeu pèse la taille des 5 ruches (souvent
# 200 à 400 Mo). Sur un disque déjà saturé - la cause même du sinistre qui a
# motivé ce module - l'écrire aggraverait la panne. Le coffre externe, lui,
# n'est jamais sauté : c'est le seul qui survive à la mort du disque.
$needBytes = [int64]0
foreach ($hs in $hiveSpecs) {
    try {
        $srcHive = Get-Item (Join-Path "$env:SystemRoot\System32\config" $hs.File) -ErrorAction Stop
        $needBytes += [int64]$srcHive.Length
    }
    catch { }
}
if ($needBytes -le 0) { $needBytes = [int64]500MB }   # mesure impossible : estimation prudente
$localOk   = $true
$freeBytes = $null
try {
    # System.IO.DriveInfo (GetDiskFreeSpaceEx) et non (Get-PSDrive).Free : sous
    # PowerShell 5.1 cette propriété passe par CIM, muette précisément sur les
    # machines malades que ce module vise. Ici, appel direct à l'API Windows.
    $di = [System.IO.DriveInfo]::new("$env:SystemDrive\")
    if ($di.IsReady) { $freeBytes = [int64]$di.AvailableFreeSpace }
}
catch { }
if ($null -eq $freeBytes) {
    Write-KitLog -Message "Espace libre de $env:SystemDrive non mesurable : le coffre local est tenté quand même." -Level 'WARN'
}
elseif ($freeBytes -lt ($needBytes + 2GB)) {
    $localOk = $false
    Write-KitLog -Message "Coffre local SAUTÉ : $([math]::Round($freeBytes / 1GB, 1)) Go libres sur $env:SystemDrive alors qu'un jeu de ruches pèse $([math]::Round($needBytes / 1MB)) Mo. Écrire le coffre sur un disque déjà plein aggraverait la panne. Brancher une clé USB (coffre externe) ou lancer le nettoyage, puis relancer." -Level 'WARN'
}

# Acl : cette destination doit-elle être verrouillée avant la première ruche ?
# Le coffre local vit sous ProgramData, toujours NTFS, donc toujours $true ; le
# coffre externe suit le système de fichiers mesuré de son support.
$destinations = @()
$localBase    = Join-Path $pdDir 'HiveVault'
$localUsable  = ($localOk -and $pdSafe)
if ($localUsable) { $destinations += [PSCustomObject]@{ Base = $localBase; External = $false; Acl = $true } }
$externalSet = $false
if ($externalRoot) {
    $destinations += [PSCustomObject]@{ Base = (Join-Path $externalRoot "Coffre\$pcToken"); External = $true; Acl = $externalAcl }
    $externalSet = $true
}
elseif ($localUsable) {
    Write-KitLog -Message "Aucun support externe : coffre local uniquement (le coffre externe survivrait à la mort du disque)." -Level 'WARN'
}
else {
    Write-KitLog -Message "Aucun support externe : brancher une clé USB donnerait un coffre malgré le coffre local indisponible." -Level 'WARN'
}
if (@($destinations).Count -eq 0) {
    # ERROR et code de sortie 1, pas un simple avertissement : la fiche de
    # clôture annonce « Coffre de ruches à jour (module Filets de secours en
    # OK) ». Sortir en 0 sans une seule ruche sauvegardée ferait cocher cette
    # ligne à tort, et le PC repartirait sans le filet qui justifie l'étape.
    Write-KitLog -Message "ERREUR : aucune destination de coffre (coffre local indisponible - disque système plein ou dossier ProgramData détourné - et aucun support externe). Les ruches ne sont PAS sauvegardées." -Level 'ERROR'
    $exitCode = 1
}

# Build Windows : valeur informative du manifeste (le mode secours ne s'en sert
# pas). Lecture défensive : sous StrictMode, une valeur absente lèverait.
$osBuild = 'inconnu'
try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($cv -and $cv.PSObject.Properties['CurrentBuildNumber']) {
        $osBuild = ConvertTo-KitAsciiToken -Text ([string]$cv.CurrentBuildNumber) -Fallback 'inconnu' -MaxLength 16
    }
    else { throw "valeur CurrentBuildNumber absente" }
}
catch { Write-KitLog -Message "Numéro de build Windows non lisible ($_) : le manifeste portera la valeur inconnu." -Level 'WARN' }

foreach ($dest in $destinations) {
    $setDir    = Join-Path $dest.Base "hives-$stamp"
    $destLabel = if ($dest.External) { 'externe' } else { 'local' }
    # Repli annoncé à l'opérateur : il n'existe que pour le coffre local (l'autre
    # destination lui survit). Un coffre externe en échec n'a rien à promettre.
    $repli     = if ($dest.External) { '' } else { ' Le coffre externe reste la sauvegarde.' }
    if ($WhatIf) {
        if ($dest.Acl) {
            Write-KitLog -Message "WHATIF: Aurait restreint l'accès du coffre $destLabel à SYSTEM et Administrateurs, repris la propriété du dossier, et refusé un coffre déjà présent qui serait un point d'analyse" -Level 'WHATIF'
        }
        else {
            Write-KitLog -Message "WHATIF: N'aurait posé aucun verrou sur le coffre $destLabel (son système de fichiers ne porte pas d'ACL) : protection physique, clé à conserver comme un trousseau" -Level 'WHATIF'
        }
        Write-KitLog -Message "WHATIF: Aurait sauvegardé les 5 ruches vers $setDir (reg save + manifeste + rotation à 3 jeux)" -Level 'WHATIF'
        continue
    }
    try {
        # Ordre imposé : créer, VERROUILLER, puis seulement écrire. La racine du
        # coffre d'abord (elle referme aussi les jeux plus anciens qui en héritent),
        # le jeu du jour ensuite. Un coffre qu'on n'a pas pu refermer ne reçoit
        # aucune ruche : mieux vaut pas de coffre du tout qu'un SAM lisible par
        # tous - la règle vaut pour le coffre EXTERNE dès que son volume porte des
        # ACL, une clé NTFS ou une seconde partition interne n'ayant aucun verrou
        # physique à opposer tant qu'elle est branchée.
        if ($dest.Acl) {
            if (-not (Test-Path $dest.Base)) { New-Item -ItemType Directory -Force -Path $dest.Base | Out-Null }
            $protBase = Protect-KitVaultDir -Path $dest.Base
            if (-not $protBase.Ok) {
                if ($protBase.Reparse) {
                    Write-KitLog -Message "ERREUR : coffre $destLabel suspect (point d'analyse) : $($dest.Base) est une jonction ou un lien, pas un vrai dossier. Il a donc été posé avant le kit pour détourner l'écriture ailleurs : ruches non écrites, dossier laissé tel quel.$repli" -Level 'ERROR'
                }
                else {
                    Write-KitLog -Message "ERREUR : coffre $destLabel NON protégé sur un volume à ACL ($($dest.Base) : $($protBase.Reason)), ruches sensibles non écrites (SAM/SECURITY exposées sinon).$repli" -Level 'ERROR'
                }
                $exitCode = 1
                continue
            }
        }
        New-Item -ItemType Directory -Force -Path $setDir | Out-Null
        if ($dest.Acl) {
            $protSet = Protect-KitVaultDir -Path $setDir
            if (-not $protSet.Ok) {
                $exitCode = 1
                if ($protSet.Reparse) {
                    # Surtout PAS de Remove-Item ici : le jeu du jour n'a pas été
                    # créé par le kit (il était déjà là, en jonction), et selon la
                    # version de Windows PowerShell une suppression récursive peut
                    # traverser le point d'analyse et effacer hors du coffre.
                    Write-KitLog -Message "ERREUR : coffre $destLabel suspect (point d'analyse) : $setDir est une jonction ou un lien posé avant le kit, pas un vrai dossier. Ruches non écrites, et le dossier est laissé intact (le supprimer risquerait d'effacer sa cible, hors du coffre)." -Level 'ERROR'
                    continue
                }
                Write-KitLog -Message "ERREUR : coffre $destLabel NON protégé sur un volume à ACL ($setDir : $($protSet.Reason)), ruches sensibles non écrites (SAM/SECURITY exposées sinon)." -Level 'ERROR'
                # Le dossier vide part avec : il ne contient aucun secret, et le
                # laisser ferait compter un jeu incomplet de plus à la rotation.
                Remove-Item -LiteralPath $setDir -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }
        }
        $manifest = [ordered]@{
            machineid    = $machineId
            computername = $pcToken
            build        = $osBuild
            date         = $stamp
        }
        $allOk = $true
        foreach ($hs in $hiveSpecs) {
            $out = Join-Path $setDir $hs.File
            # Sortie capturée : un « code 1 » sans motif n'aide personne à
            # comprendre pourquoi la ruche n'est pas au coffre (accès refusé,
            # support plein, chemin trop long).
            $regOut  = @(& reg save "$($hs.Key)" "$out" /y 2>&1 | ForEach-Object { [string]$_ })
            $regExit = $LASTEXITCODE
            if ($regExit -ne 0 -or -not (Test-Path $out)) {
                $regDetail = @($regOut | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
                $regMotif  = if ($regDetail.Count -gt 0) { $regDetail[0].Trim() } else { 'aucun détail' }
                Write-KitLog -Message "ERREUR reg save $($hs.Key) vers $out (code $regExit, $regMotif)" -Level 'ERROR'
                $allOk = $false
                continue
            }
            $sz = (Get-Item $out).Length
            # ToLowerInvariant et non ToLower : sous une culture turque, le « I »
            # de SECURITY donnerait un « ı » non ASCII dans la clé du manifeste.
            $manifest[('taille_' + $hs.File.ToLowerInvariant())] = [string]$sz
        }
        if ($allOk) {
            $lines = ConvertTo-KitManifestLines -Data $manifest
            Set-Content -Path (Join-Path $setDir 'manifest.txt') -Value $lines -Encoding Ascii
            Write-KitLog -Message "Coffre écrit : $setDir ($destLabel)" -Level 'OK'
        }
        else {
            Write-KitLog -Message "Coffre INCOMPLET dans $setDir : manifeste non écrit (jeu inutilisable en secours, volontaire)." -Level 'ERROR'
            $exitCode = 1
        }
        if ($dest.External) {
            if ($dest.Acl) {
                Write-KitLog -Message "Le coffre externe contient SAM et SECURITY (secrets de comptes) : son volume porte des ACL, il a donc été refermé sur SYSTEM et Administrateurs comme le coffre local." -Level 'INFO'
            }
            else {
                # Ici, et ici seulement, aucune ACL n'est opposable (FAT32/exFAT
                # n'en porte pas) : la protection est physique, l'opérateur doit
                # le savoir puisque c'est lui qui la met en oeuvre.
                Write-KitLog -Message "Le coffre externe contient SAM et SECURITY (secrets de comptes) et son système de fichiers ne porte pas d'ACL : conservez la clé USB comme un trousseau." -Level 'INFO'
            }
        }
        # Rotation : 3 jeux COMPLETS par destination. Les jeux incomplets sont
        # comptés à part (1 conservé, le plus récent) pour deux raisons : un jeu
        # raté ne doit jamais évincer un jeu complet encore posable, et les jeux
        # ratés ne doivent pas s'empiler puisque chacun pèse les ruches déjà copiées.
        # Les points d'analyse sont écartés de la rotation : une jonction nommée
        # hives-<horodatage> posée avant le kit compterait comme un jeu (et
        # évincerait un vrai jeu encore posable), et sa suppression viserait une
        # cible hors du coffre. On ne l'efface pas, on refuse de la compter.
        $tousSets   = @(Get-ChildItem -Path $dest.Base -Directory -Filter 'hives-*' -ErrorAction SilentlyContinue)
        $sets       = @($tousSets | Where-Object { ([int]$_.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0 })
        if ($sets.Count -lt $tousSets.Count) {
            Write-KitLog -Message "Coffre $destLabel : $($tousSets.Count - $sets.Count) entrée(s) hives-* sont des points d'analyse (jonctions), écartées de la rotation et jamais supprimées. À inspecter : le kit n'en crée pas." -Level 'WARN'
        }
        $complets   = @($sets | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.txt') })
        $incomplets = @($sets | Where-Object { -not (Test-Path (Join-Path $_.FullName 'manifest.txt')) })
        # -ErrorAction SilentlyContinue avale l'échec (jeu verrouillé, clé USB en
        # lecture seule) : la suppression se vérifie donc avant d'être annoncée,
        # sinon le journal ferait croire à une place libérée qui ne l'est pas.
        foreach ($old in @(Get-DirsToRotate -Dirs $complets -Keep 3)) {
            Remove-Item -Path $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $old.FullName)) {
                Write-KitLog -Message "Rotation du coffre : supprimé $($old.Name)" -Level 'INFO'
            }
            else {
                Write-KitLog -Message "Rotation du coffre impossible (fichier verrouillé ou support en lecture seule) : $($old.Name)" -Level 'WARN'
            }
        }
        foreach ($old in @(Get-DirsToRotate -Dirs $incomplets -Keep 1)) {
            Remove-Item -Path $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $old.FullName)) {
                Write-KitLog -Message "Rotation du coffre : supprimé le jeu incomplet $($old.Name)" -Level 'INFO'
            }
            else {
                Write-KitLog -Message "Rotation du coffre impossible (fichier verrouillé ou support en lecture seule) : jeu incomplet $($old.Name)" -Level 'WARN'
            }
        }
    }
    catch {
        Write-KitLog -Message "ERREUR coffre vers $setDir : $_" -Level 'ERROR'
        $exitCode = 1
    }
}

# Option : export de la clé de récupération BitLocker (coffre EXTERNE uniquement,
# jamais HiveVault local qui vit sur le disque qu'elle est censée déverrouiller).
# Deuxième condition, indépendante du verrou d'ACL : le support doit être
# AMOVIBLE. Les 48 chiffres ouvrent le disque entier ; même dans un coffre
# refermé sur les administrateurs, les poser sur une partition interne les
# laisserait à demeure à côté de ce qu'ils déverrouillent - un vol de machine ou
# un futur administrateur suffirait. Sur une clé qu'on retire et qu'on range,
# non. Le mot de passe n'est JAMAIS journalisé : le log part avec le rapport.
if ($ExportBitLockerKey) {
    if (-not $externalSet) {
        Write-KitLog -Message "Export BitLocker demandé mais aucun coffre externe : rien n'est écrit (la clé n'a rien à faire sur le disque chiffré lui-même)." -Level 'WARN'
    }
    elseif (-not (Test-KitRemovableMedium -DriveType $externalType)) {
        $typeLabel = if ([string]::IsNullOrWhiteSpace($externalType)) { 'type non mesuré' } else { $externalType }
        Write-KitLog -Message "Clé BitLocker NON exportée : le coffre externe n'est pas un support amovible ($externalRoot [$typeLabel]). Une clé de récupération à 48 chiffres reste lisible des mois à côté du disque qu'elle ouvre : brancher une clé USB et relancer l'étape pour l'exporter. Les ruches, elles, ont bien été écrites." -Level 'WARN'
    }
    else {
        $recoveryPass = $null
        try {
            $blv = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            if ($blv -and $blv.PSObject.Properties['KeyProtector']) {
                $kp = @($blv.KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' }) | Select-Object -First 1
                if ($kp -and $kp.PSObject.Properties['RecoveryPassword']) { $recoveryPass = [string]$kp.RecoveryPassword }
            }
        }
        catch {
            # Fallback Home : manage-bde -protectors -get C: (parse du bloc Mot de passe numérique)
            try {
                $mb = @(& manage-bde -protectors -get C: 2>&1 | ForEach-Object { [string]$_ })
                foreach ($line in $mb) {
                    if ($line -match '^\s*(\d{6}-){7}\d{6}\s*$') { $recoveryPass = $line.Trim(); break }
                }
            }
            catch { }
        }
        if ($recoveryPass) {
            $blDir  = Join-Path $externalRoot "Coffre\$pcToken"
            $blPath = Join-Path $blDir 'bitlocker-recovery.txt'
            if ($WhatIf) { Write-KitLog -Message "WHATIF: Aurait écrit la clé de récupération BitLocker dans $blPath" -Level 'WHATIF' }
            else {
                try {
                    if (-not (Test-Path $blDir)) { New-Item -ItemType Directory -Force -Path $blDir | Out-Null }
                    Set-Content -Path $blPath -Value @(
                        "Cle de recuperation BitLocker - $pcToken - $stamp",
                        "ATTENTION : cette cle ouvre le disque. Conserver la cle USB comme un trousseau.",
                        $recoveryPass
                    ) -Encoding Ascii
                    Write-KitLog -Message "Clé de récupération BitLocker exportée dans le coffre externe (à protéger physiquement)." -Level 'OK'
                }
                catch {
                    # Échec d'une action explicitement demandée : le taire ferait
                    # croire la clé sauvegardée alors que le disque reste sans issue.
                    Write-KitLog -Message "ERREUR : clé de récupération BitLocker NON écrite dans $blPath : $_" -Level 'ERROR'
                    $exitCode = 1
                }
            }
        }
        else {
            Write-KitLog -Message "Export BitLocker : aucun mot de passe de récupération détecté (volume non chiffré, ou protecteur absent - voir la sentinelle du diagnostic)." -Level 'WARN'
        }
    }
}

if ($exitCode -eq 0) {
    Write-KitLog -Message "=== 16-Resilience : terminé ===" -Level 'OK'
}
else {
    Write-KitLog -Message "=== 16-Resilience : terminé en échec (coffre ou empreinte incomplets, voir les lignes ERROR ci-dessus) ===" -Level 'ERROR'
}
exit $exitCode
