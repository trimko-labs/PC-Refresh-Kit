# tests/Test-KitAnonymity.ps1 - garde-fou d'anonymat du depot public.
#
# Le depot est publie sous l'identite Trimko, sans nom de personne physique.
# Un fichier de travail aspire par un "git add -A" (notes de conception, log,
# capture, script local) peut y ramener un chemin utilisateur nominatif ou une
# adresse personnelle. Ce test echoue AVANT que cela n'atterrisse en ligne.
#
# Usage : .\tests\Test-KitAnonymity.ps1 [-CI]
[CmdletBinding()]
param([switch]$CI)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Motifs generiques : aucun nom propre n'est ecrit ici, ce fichier est public.
$patterns = @(
    # Test et TestUser sont les profils fictifs utilises par les tests unitaires.
    @{ Name = 'Chemin utilisateur nominatif'; Regex = 'C:\\Users\\(?!Public\b|Default\b|All Users\b|Test\b|TestUser\b|%|\$)[A-Za-z0-9._-]+' }
    @{ Name = 'Adresse e-mail hors domaine du projet'; Regex = '[A-Za-z0-9._%+-]+@(?!trimko\.com|users\.noreply\.github\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}' }
    @{ Name = 'Nom de partage reseau personnel'; Regex = '\\\\[A-Za-z0-9._-]+\\Users\\' }
)

# Fichiers suivis par git uniquement : le reste n'est pas publie.
Push-Location $root
try { $tracked = @(git ls-files) } finally { Pop-Location }

$binary = '\.(png|jpg|jpeg|gif|ico|zip|exe|dll|pdf|webp)$'
$violations = @()

foreach ($rel in $tracked) {
    if ($rel -match $binary) { continue }
    if ($rel -eq 'tests/Test-KitAnonymity.ps1') { continue }   # ce fichier porte les motifs
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    $lines = Get-Content $full -Encoding UTF8 -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($p in $patterns) {
            if ($lines[$i] -match $p.Regex) {
                $violations += [PSCustomObject]@{
                    File    = $rel
                    Line    = $i + 1
                    Rule    = $p.Name
                    Extract = $Matches[0]
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "[ANONYMAT] $($violations.Count) violation(s) :" -ForegroundColor Red
    $violations | ForEach-Object { Write-Host ("  {0}:{1} - {2} : {3}" -f $_.File, $_.Line, $_.Rule, $_.Extract) }
    if ($CI) { exit 1 }
    return $violations
}

Write-Host "[ANONYMAT] $($tracked.Count) fichier(s) suivis, 0 violation(s)" -ForegroundColor Green
if ($CI) { exit 0 }
