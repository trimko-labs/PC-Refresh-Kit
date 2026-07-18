# modules/08-Accounts.ps1 - Cloisonnement des comptes (standard + admin local séparé)
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\08-Accounts.ps1 [-WhatIf]
# SÉCURITÉ : jamais retire les droits admin du compte courant avant d'avoir créé et vérifié l'admin.

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [string]$AdminName = 'Admin-Local',
    [switch]$KeepAdmin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 08-Accounts : début ===" -Level 'INFO'

$runtimeDir = Join-Path $PSScriptRoot '..\runtime'
if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# SID universels (indépendants de la langue de l'OS)
$sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$sidUsers  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

# Nom localisé du groupe Administrateurs (traduit depuis le SID)
function Get-LocalGroupName {
    param([System.Security.Principal.SecurityIdentifier]$Sid)
    try {
        return $Sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    }
    catch {
        return $null
    }
}

$adminsGroupName = Get-LocalGroupName $sidAdmins
$usersGroupName  = Get-LocalGroupName $sidUsers
Write-KitLog -Message "Groupe Administrateurs : '$adminsGroupName' | Utilisateurs : '$usersGroupName'" -Level 'INFO'

# ---------------------------------------------------------------------------
# Identifier le compte utilisateur courant interactif (non-système)
# ---------------------------------------------------------------------------
$currentUser = $env:USERNAME
$currentSid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User

Write-KitLog -Message "Compte courant : $currentUser (SID : $currentSid)" -Level 'INFO'

# Vérifier si le compte courant est admin
$isCurrentAdmin = $false
try {
    $adminsMembers = Get-LocalGroupMember -SID $sidAdmins -ErrorAction Stop
    $isCurrentAdmin = $adminsMembers | Where-Object { $_.SID -eq $currentSid }
}
catch {
    Write-KitLog -Message "Impossible de lister les membres du groupe admins : $_" -Level 'WARN'
}

if (-not $isCurrentAdmin) {
    Write-KitLog -Message "Le compte courant ($currentUser) n'est pas dans le groupe Administrateurs. Étape accounts ignorée." -Level 'WARN'
    Write-KitLog -Message "Relancer en tant que compte admin, ou exécuter manuellement après le kit." -Level 'WARN'
    exit 0
}

# ---------------------------------------------------------------------------
# Étape 1 : Créer le compte admin local séparé
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Étape 1 : Création du compte admin local ($AdminName) ---" -Level 'INFO'

$adminExists = Get-LocalUser -Name $AdminName -ErrorAction SilentlyContinue
$adminPassword = $null

if ($adminExists) {
    Write-KitLog -Message "Compte '$AdminName' déjà existant (SKIP création)." -Level 'OK'
}
elseif ($WhatIf) {
    Write-KitLog -Message "WHATIF: New-LocalUser '$AdminName' + mot de passe fort + Add-LocalGroupMember Administrateurs" -Level 'WHATIF'
}
else {
    $adminPassword = New-StrongPassword -Passphrase -WordCount 3
    $securePwd     = ConvertTo-SecureString $adminPassword -AsPlainText -Force

    try {
        New-LocalUser -Name $AdminName -Password $securePwd -FullName 'Administrateur local' `
            -Description 'Compte administrateur créé par PC-Refresh-Kit' `
            -PasswordNeverExpires -ErrorAction Stop | Out-Null
        Write-KitLog -Message "Compte '$AdminName' créé." -Level 'OK'
    }
    catch {
        Write-KitLog -Message "ERREUR création compte '$AdminName' : $_" -Level 'ERROR'
        exit 1
    }

    # Ajouter au groupe Administrateurs
    try {
        Add-LocalGroupMember -SID $sidAdmins -Member $AdminName -ErrorAction Stop
        Write-KitLog -Message "Compte '$AdminName' ajouté au groupe Administrateurs." -Level 'OK'
    }
    catch {
        Write-KitLog -Message "ERREUR ajout au groupe admins : $_" -Level 'ERROR'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Vérification : au moins 2 admins avant de retirer les droits du compte courant
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Vérification : comptes administrateurs présents ---" -Level 'INFO'

$adminsAfter = @(Get-LocalGroupMember -SID $sidAdmins -ErrorAction SilentlyContinue)
$adminCount  = $adminsAfter.Count
Write-KitLog -Message "Membres du groupe Administrateurs : $adminCount" -Level 'INFO'
foreach ($m in $adminsAfter) { Write-KitLog -Message "  > $($m.Name) (SID: $($m.SID))" -Level 'INFO' }

# Garde-fou : ne jamais retirer si un seul admin restant
if ($adminCount -lt 2) {
    Write-KitLog -Message "GARDE-FOU : seulement $adminCount admin(s) détecté(s). Impossible de retirer les droits de $currentUser sans risquer de perdre l'accès admin." -Level 'ERROR'
    Write-KitLog -Message "Vérifier manuellement que '$AdminName' est bien admin avant de relancer." -Level 'WARN'
    exit 1
}

# ---------------------------------------------------------------------------
# Étape 2 : Basculer le compte courant en STANDARD
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Étape 2 : Passage de '$currentUser' en compte standard ---" -Level 'INFO'

# Initialisé avant le if/else : sous -KeepAdmin le bloc else est sauté, et la
# vérification finale (StrictMode) lirait sinon une variable non initialisée.
$isAlreadyStandard = $false

if ($KeepAdmin) {
    Write-KitLog -Message "Profil 'Garder admin' : '$currentUser' reste administrateur (UAC actif). Rétrogradation ignorée." -Level 'OK'
}
else {
    $isAlreadyStandard = -not ($adminsAfter | Where-Object { $_.SID -eq $currentSid })

    if ($isAlreadyStandard) {
        Write-KitLog -Message "Compte '$currentUser' est déjà standard (SKIP)." -Level 'OK'
    }
    elseif ($WhatIf) {
        Write-KitLog -Message "WHATIF: Remove-LocalGroupMember Administrateurs -Member $currentUser" -Level 'WHATIF'
        Write-KitLog -Message "WHATIF: Vérifier présence dans groupe Utilisateurs" -Level 'WHATIF'
    }
    else {
        try {
            Remove-LocalGroupMember -SID $sidAdmins -Member $currentUser -ErrorAction Stop
            Write-KitLog -Message "Compte '$currentUser' retiré du groupe Administrateurs." -Level 'OK'
        }
        catch {
            Write-KitLog -Message "ERREUR retrait du groupe admins : $_" -Level 'ERROR'
        }

        # S'assurer que le compte reste dans Utilisateurs
        $inUsers = Get-LocalGroupMember -SID $sidUsers -ErrorAction SilentlyContinue |
                   Where-Object { $_.SID -eq $currentSid }
        if (-not $inUsers) {
            try {
                Add-LocalGroupMember -SID $sidUsers -Member $currentUser -ErrorAction Stop
                Write-KitLog -Message "Compte '$currentUser' ajouté au groupe Utilisateurs." -Level 'OK'
            }
            catch {
                Write-KitLog -Message "Avertissement : impossible d'ajouter $currentUser au groupe Utilisateurs : $_" -Level 'WARN'
            }
        }
        else {
            Write-KitLog -Message "Compte '$currentUser' est déjà dans le groupe Utilisateurs." -Level 'OK'
        }
    }
}

# ---------------------------------------------------------------------------
# Étape 3 : Consigner le mot de passe admin
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Étape 3 : Consignation du mot de passe admin ---" -Level 'INFO'

if ($adminPassword -and -not $WhatIf) {
    $ficheFile = Join-Path $runtimeDir "FICHE-PC-$env:COMPUTERNAME.txt"
    $statutCompte = if ($KeepAdmin) { 'administrateur (Keep-Admin actif)' } else { 'standard (admin retiré)' }

    $ficheContent = @"
=== FICHE PC - $env:COMPUTERNAME ===
Date d'intervention : $(Get-Date -Format 'yyyy-MM-dd HH:mm')

COMPTE ADMIN LOCAL CRÉÉ PAR PC-REFRESH-KIT
  Nom du compte : $AdminName
  Mot de passe  : $adminPassword

IMPORTANT : noter ce mot de passe en lieu sûr (gestionnaire de mots de passe).
Ce fichier est stocké localement uniquement. Ne pas partager, ne pas committer.

COMPTE UTILISATEUR
  Nom : $currentUser
  Statut : $statutCompte
"@

    Set-Content -Path $ficheFile -Value $ficheContent -Encoding UTF8
    Write-KitLog -Message "Fiche PC écrite dans : $ficheFile" -Level 'OK'

    # Bannière dans le log unifié = visible dans le journal coloré de la GUI.
    # JAMAIS le mot de passe lui-même dans le log : le rapport TXT livré
    # embarque le log complet. Le cockpit l'affiche en fin de run via la fiche.
    Write-KitLog -Message "============================================================" -Level 'WARN'
    Write-KitLog -Message "MOT DE PASSE ADMIN GÉNÉRÉ pour le compte '$AdminName'." -Level 'WARN'
    Write-KitLog -Message "Le récupérer en fin de run : bouton 'Copier le mot de passe' du cockpit, ou fiche $ficheFile" -Level 'WARN'
    Write-KitLog -Message "Ne pas rendre le PC sans avoir noté ce mot de passe, puis supprimer la fiche de la clé." -Level 'WARN'
    Write-KitLog -Message "============================================================" -Level 'WARN'

    # Affichage console (mode Run.ps1) : le mot de passe en clair, à l'écran
    # uniquement, jamais dans le log.
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  NOTER CE MOT DE PASSE MAINTENANT" -ForegroundColor Yellow
    Write-Host "  Compte admin : $AdminName" -ForegroundColor Yellow
    Write-Host "  Mot de passe : $adminPassword" -ForegroundColor Green
    Write-Host "  Fiche locale : $ficheFile" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
}
elseif ($adminExists) {
    Write-KitLog -Message "Compte '$AdminName' pré-existant - mot de passe non régénéré. Vérifier la fiche existante si disponible." -Level 'WARN'
}

# Vérification finale
Write-KitLog -Message "--- Vérification finale ---" -Level 'INFO'
$finalAdmins = @(Get-LocalGroupMember -SID $sidAdmins -ErrorAction SilentlyContinue)
Write-KitLog -Message "Admins après opération ($($finalAdmins.Count)) :" -Level 'INFO'
foreach ($m in $finalAdmins) { Write-KitLog -Message "  > $($m.Name)" -Level 'INFO' }

$finalCurrentIsAdmin = $finalAdmins | Where-Object { $_.SID -eq $currentSid }
if (-not $KeepAdmin -and $finalCurrentIsAdmin -and -not $isAlreadyStandard -and -not $WhatIf) {
    Write-KitLog -Message "ATTENTION : $currentUser est toujours dans le groupe Administrateurs. Vérifier manuellement." -Level 'WARN'
}

# ---------------------------------------------------------------------------
# Étape 4 : Durcissement UAC (protection sans mot de passe)
#   Garantit que l'UAC est bien actif, en mode CONSENTEMENT (Oui/Non, donc AUCUN
#   mot de passe a taper) sur bureau securise. Un compte qui reste administrateur
#   garde ainsi une protection forte contre toute elevation silencieuse (malware,
#   install sournoise), sans aucun mot de passe a gerer. On force ces valeurs au cas
#   ou le defaut Windows aurait ete affaibli (tweak, malware, "optimiseur").
# ---------------------------------------------------------------------------
Write-KitLog -Message "--- Étape 4 : Durcissement UAC ---" -Level 'INFO'

$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacSettings = [ordered]@{
    EnableLUA                  = 1   # UAC active (1 = oui)
    ConsentPromptBehaviorAdmin = 2   # admin : consentement Oui/Non (PAS de mot de passe) sur bureau securise
    PromptOnSecureDesktop      = 1   # bureau securise : empeche l'usurpation du prompt par un malware
}

if ($WhatIf) {
    foreach ($name in $uacSettings.Keys) {
        Write-KitLog -Message "WHATIF: $name = $($uacSettings[$name]) ($uacKey)" -Level 'WHATIF'
    }
}
else {
    try {
        if (-not (Test-Path $uacKey)) { New-Item -Path $uacKey -Force | Out-Null }
        foreach ($name in $uacSettings.Keys) {
            Set-ItemProperty -Path $uacKey -Name $name -Value $uacSettings[$name] -Type DWord -Force
            Write-KitLog -Message "UAC : $name = $($uacSettings[$name])" -Level 'OK'
        }
        Write-KitLog -Message "UAC durci : prompt Oui/Non a chaque elevation, sans mot de passe (protection active meme en restant admin)." -Level 'OK'
        Write-KitLog -Message "Prend pleinement effet apres un redemarrage." -Level 'INFO'
    }
    catch {
        Write-KitLog -Message "Echec durcissement UAC : $_" -Level 'WARN'
    }
}

Write-KitLog -Message "=== 08-Accounts : terminé ===" -Level 'OK'
exit 0
