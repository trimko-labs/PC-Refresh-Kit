# modules/15-Network.ps1 - Réinitialisation réseau (Winsock, pile IP, DNS, DHCP)
# Usage : powershell -ExecutionPolicy Bypass -File .\modules\15-Network.ps1 [-ResetNetwork] [-WhatIf] [-Unattended]
<#
.SYNOPSIS
    Réinitialise de façon NON RÉVERSIBLE la configuration réseau :
    - Réinitialisation Winsock        (netsh winsock reset)
    - Réinitialisation pile IP        (netsh int ip reset)
    - Vidage du cache DNS             (Clear-DnsClientCache)
    - Libération du bail DHCP         (ipconfig /release)
    - Renouvellement du bail DHCP     (ipconfig /renew)
    Décoché par défaut (sans -ResetNetwork, le module ne fait RIEN).
    Avertissement bloquant en mode automatique si IP statique détectée.
    Positionne le flag "REBOOT REQUIS" dans le log pour le module 10.
#>

param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Unattended,
    [switch]$ResetNetwork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\..\lib\Common.ps1"
Assert-Admin

Write-KitLog -Message "=== 15-Network : démarrage ===" -Level 'INFO'

if (-not $ResetNetwork) {
    Write-KitLog -Message "Reset réseau non demandé (case décochée) : rien à faire." -Level 'INFO'
    Write-KitLog -Message "=== 15-Network : terminé ===" -Level 'OK'
    exit 0
}

# ---------------------------------------------------------------------------
# Garde IP statique : un reset efface une config statique volontaire.
# ---------------------------------------------------------------------------
$staticFound = $false
try {
    $statics = @(Get-NetIPInterface -ErrorAction Stop | Where-Object { $_.Dhcp -eq 'Disabled' -and $_.ConnectionState -eq 'Connected' })
    if ($statics.Count -gt 0) { $staticFound = $true }
}
catch {
    # Détection impossible : par prudence, on traite comme "peut-être statique".
    $staticFound = $true
    Write-KitLog -Message "Impossible de vérifier la configuration IP : prudence, configuration statique possible." -Level 'WARN'
}
if ($staticFound) {
    Write-KitLog -Message "ATTENTION : une adresse IP statique semble configurée. Un reset la remettra en DHCP. Noter la config avant de continuer." -Level 'WARN'
}

if ($WhatIf) {
    Write-KitLog -Message "WHATIF: Aurait réinitialisé Winsock, la pile IP, le cache DNS et renouvelé le bail DHCP." -Level 'WHATIF'
    Write-KitLog -Message "=== 15-Network : terminé (WhatIf) ===" -Level 'INFO'
    exit 0
}

# ---------------------------------------------------------------------------
# Confirmation : non réversible. En mode surveillé (console interactive) on
# demande ; en -Unattended on refuse si IP statique détectée sans surveillance.
# ---------------------------------------------------------------------------
if ($Unattended) {
    if ($staticFound) {
        Write-KitLog -Message "Reset réseau ANNULÉ en mode automatique : IP statique détectée, intervention manuelle requise." -Level 'WARN'
        Write-KitLog -Message "=== 15-Network : terminé ===" -Level 'OK'
        exit 0
    }
}
else {
    $ans = Read-Host "Réinitialiser la configuration réseau ? Action NON RÉVERSIBLE (o/N)"
    if ($ans -notmatch '^(o|O|y|Y)') {
        Write-KitLog -Message "Reset réseau annulé par l'opérateur." -Level 'INFO'
        Write-KitLog -Message "=== 15-Network : terminé ===" -Level 'OK'
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Exécution des 5 étapes réseau
# ---------------------------------------------------------------------------
$steps = @(
    @{ Label = 'Réinitialisation Winsock';       Cmd = { netsh winsock reset } },
    @{ Label = 'Réinitialisation de la pile IP'; Cmd = { netsh int ip reset } },
    @{ Label = 'Vidage du cache DNS';             Cmd = { Clear-DnsClientCache } },
    @{ Label = 'Libération du bail DHCP';         Cmd = { ipconfig /release } },
    @{ Label = 'Renouvellement du bail DHCP';     Cmd = { ipconfig /renew } }
)
foreach ($s in $steps) {
    try {
        Write-KitLog -Message $s.Label -Level 'INFO'
        & $s.Cmd 2>&1 | Out-Null
        Write-KitLog -Message "  OK : $($s.Label)" -Level 'OK'
    }
    catch {
        Write-KitLog -Message "  Échec : $($s.Label) - $($_.Exception.Message)" -Level 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Réversibilité : le reset réseau n'est pas annulable. On ne peut pas l'inscrire
# dans le manifeste undo (aucune action de restauration possible) : on le trace.
# ---------------------------------------------------------------------------
Write-KitLog -Message "Reset réseau appliqué. Action NON RÉVERSIBLE (aucune entrée d'annulation)." -Level 'WARN'
Write-KitLog -Message "REBOOT REQUIS pour finaliser le reset réseau." -Level 'WARN'
Write-KitLog -Message "=== 15-Network : terminé ===" -Level 'OK'
exit 0
