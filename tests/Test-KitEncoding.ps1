# tests/Test-KitEncoding.ps1 - Vérifie l'encodage des .ps1 et .md suivis du kit :
# BOM UTF-8 présent, aucun em-dash (U+2014) ni en-dash (U+2013).
# Fonction pure Test-KitEncoding + wrapper de scan réutilisable en local et CI.
# Encodage : UTF-8 avec BOM.
[CmdletBinding()]
param([switch]$CI)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Test-KitEncoding : valide un contenu de fichier. PURE/testable.
# ---------------------------------------------------------------------------
function Test-KitEncoding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][bool]$HasBom,
        [bool]$EndsWithNewline = $true
    )
    $forbidden = @()
    if ($Content.Contains([char]0x2014)) { $forbidden += 'U+2014 (em-dash)' }
    if ($Content.Contains([char]0x2013)) { $forbidden += 'U+2013 (en-dash)' }
    return [PSCustomObject]@{
        HasBom          = $HasBom
        EndsWithNewline = $EndsWithNewline
        ForbiddenChars  = $forbidden
        Ok              = ($HasBom -and $EndsWithNewline -and $forbidden.Count -eq 0)
    }
}

# ---------------------------------------------------------------------------
# Test-FileBom : $true si le fichier commence par le BOM UTF-8 (EF BB BF).
# ---------------------------------------------------------------------------
function Test-FileBom {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

# Wrapper de scan : les .ps1 et .md SUIVIS, hors vendor/. Retourne le nombre de violations.
function Invoke-EncodingScan {
    [CmdletBinding()]
    param()
    $root  = Split-Path $PSScriptRoot -Parent
    # Fichiers SUIVIS uniquement (.ps1 et .md), hors vendor/ : la convention BOM
    # + zéro tiret long protège ce qui est publié, pas les brouillons non suivis
    # (.superpowers, dist...). git ls-files rend le scan déterministe partout.
    Push-Location $root
    # core.quotepath=false : un nom de fichier accentue revient en clair (pas en
    # \303\251...), sinon Get-Item -LiteralPath echouerait sur un chemin echappe.
    try { $rel = @(git -c core.quotepath=false ls-files '*.ps1' '*.md') } finally { Pop-Location }
    $files = @($rel |
               Where-Object { $_ -notmatch '(^|/)vendor/' } |
               ForEach-Object { Get-Item -LiteralPath (Join-Path $root $_) })
    if ($files.Count -eq 0) {
        # Hors depot git ou depot vide : ne jamais rendre un vert vide (0 fichier,
        # 0 violation), qui masquerait un scan qui n'a rien regarde.
        throw "[ENCODING] aucun fichier .ps1/.md suivi : scan hors depot git ou depot vide."
    }
    $violations = 0
    foreach ($f in $files) {
        $hasBom  = Test-FileBom -Path $f.FullName
        $content = [System.IO.File]::ReadAllText($f.FullName)
        $endsNl  = ($content.Length -eq 0) -or $content.EndsWith("`n")
        $r = Test-KitEncoding -Content $content -HasBom $hasBom -EndsWithNewline $endsNl
        if (-not $r.Ok) {
            $why = @()
            if (-not $r.HasBom) { $why += 'BOM manquant' }
            if (-not $r.EndsWithNewline) { $why += 'newline finale manquante' }
            if ($r.ForbiddenChars.Count -gt 0) { $why += ($r.ForbiddenChars -join ', ') }
            Write-Host "[ENCODING] FAIL $($f.FullName.Substring($root.Length + 1)) : $($why -join ' ; ')" -ForegroundColor Red
            $violations++
        }
    }
    Write-Host "[ENCODING] $($files.Count) fichier(s) scannés, $violations violation(s)" -ForegroundColor $(if ($violations -eq 0) { 'Green' } else { 'Red' })
    return $violations
}

if ($MyInvocation.InvocationName -ne '.') {
    $v = Invoke-EncodingScan
    if ($CI) { exit ([math]::Min($v, 255)) }
}
