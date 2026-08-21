# tests/Test-KitAnonymity.ps1 - garde-fou d'anonymat du depot public.
#
# Le depot est publie sous l'identite Trimko, sans nom de personne physique.
# Un fichier de travail aspire par un "git add -A" (notes de conception, log,
# capture, script local) peut y ramener un chemin utilisateur nominatif ou une
# adresse personnelle. Ce test echoue AVANT que cela n'atterrisse en ligne.
#
# Usage : .\tests\Test-KitAnonymity.ps1 [-CI] [-History]
#
# -CI       : sortie parseable et code de sortie (0 propre, 1 violation). Mode
#             utilisé par le workflow GitHub.
# -History  : scanne EN PLUS de l'arbre de travail les COMMITS de la plage
#             public-main..HEAD. Un nom effacé de l'arbre reste lisible dans les
#             blobs des commits qui l'ont porté : le scan de l'arbre seul ne voit
#             donc pas cette fuite. Outil LOCAL d'avant-publication (pré-push,
#             choix de la stratégie de fusion), volontairement hors du mode -CI
#             par défaut : le workflow distant n'a ni la liste locale de noms ni
#             la référence public-main. Lecture via git grep, côté objets git :
#             aucun checkout, aucun fichier touché.
[CmdletBinding()]
param([switch]$CI, [switch]$History)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Motifs generiques : aucun nom propre n'est ecrit ici, ce fichier est public.
$patterns = @(
    # Test et TestUser sont les profils fictifs utilises par les tests unitaires.
    @{ Name = 'Chemin utilisateur nominatif'; Regex = 'C:\\Users\\(?!Public\b|Default\b|All Users\b|Test\b|TestUser\b|%|\$)[A-Za-z0-9._-]+' }
    @{ Name = 'Adresse e-mail hors domaine du projet'; Regex = '[A-Za-z0-9._%+-]+@(?!trimko\.com|users\.noreply\.github\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}' }
    @{ Name = 'Nom de partage reseau personnel'; Regex = '\\\\[A-Za-z0-9._-]+\\Users\\' }
)

# Motifs interdits SUPPLÉMENTAIRES, lus dans un fichier local NON suivi par git
# (tests/anonymity-names.local.txt, une ligne = un motif, lignes vides et lignes
# commençant par # ignorées). Il porte les noms de personnes à bannir du dépôt
# public, que ce fichier public ne peut évidemment pas écrire lui-même. Fichier
# absent = contrôle sauté en silence : la CI distante n'en dépend pas.
$localNames = Join-Path $PSScriptRoot 'anonymity-names.local.txt'
$localCount = 0
$localState = 'liste locale absente'
if (Test-Path $localNames) {
    try {
        $localState = 'liste locale vide'
        foreach ($raw in @(Get-Content $localNames -Encoding UTF8 -ErrorAction Stop)) {
            $name = ([string]$raw).Trim()
            if ($name -eq '' -or $name.StartsWith('#')) { continue }
            # Motif littéral (échappé) : une liste de noms n'est pas une liste de regex.
            # La comparaison -match reste insensible à la casse par défaut.
            $patterns += @{ Name = 'Nom de personne interdit (liste locale)'; Regex = [regex]::Escape($name) }
            $localCount++
        }
        if ($localCount -gt 0) { $localState = '' }
    } catch {
        # Liste présente mais illisible : le contrôle tourne DÉSARMÉ sur les noms
        # de personnes. Silence interdit ici, c'est exactement le cas où la
        # sortie verte mentirait.
        $localState = 'liste locale ILLISIBLE'
    }
}

# État du contrôle, repris dans TOUTES les lignes de sortie : une sortie qui ne
# distingue pas armé de désarmé fabrique de la fausse assurance. La CI distante,
# elle, tourne toujours sans liste locale et l'annonce.
$armed = if ($localState -eq '') { "$localCount motif(s) local(aux)" } else { "$localCount motif local ($localState)" }
if ($localState -eq 'liste locale ILLISIBLE') {
    Write-Host "[ANONYMAT] AVERTISSEMENT : $localNames existe mais n'a pas pu être lu, les noms de personnes ne sont PAS contrôlés." -ForegroundColor Yellow
}

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

# ---------------------------------------------------------------------------
# Scan de l'HISTORIQUE (-History). L'arbre propre ne prouve rien sur les commits :
# un nom supprimé par un commit ultérieur reste dans le blob des précédents et
# partirait tel quel à la publication. On interroge les objets git (git grep sur
# chaque arbre de commit), jamais le disque : pas de checkout, rien à nettoyer.
# Une même ligne portée par 20 commits est UNE fuite, pas 20 : on déduplique par
# fichier + ligne + motif, en gardant le commit le plus ancien qui l'introduit.
# ---------------------------------------------------------------------------
$historyViolations = @()
$historyRun = $false
$historyNote = ''
$historyCommits = 0
# Scan demandé mais cassé (git sans PCRE, dépôt inaccessible) : distinct d'un
# scan sauté faute de public-main. Un contrôle qui n'a pas pu tourner ne rend
# jamais un verdict propre.
$historyError = $false

if ($History) {
    Push-Location $root
    try {
        $null = git rev-parse --verify --quiet public-main 2>$null
        if ($LASTEXITCODE -ne 0) {
            $historyNote = "référence public-main introuvable : scan d'historique sauté"
        } else {
            $shas = @(git rev-list --reverse public-main..HEAD)
            $historyCommits = $shas.Count
            if ($historyCommits -eq 0) {
                $historyNote = 'aucun commit dans public-main..HEAD'
            } else {
                $historyRun = $true
                $seen = @{}
                # git écrit en UTF-8 ; sans cela la console 5.1 décode en page de
                # code héritée et un extrait accentué revient illisible.
                $prevOut = [Console]::OutputEncoding
                $prevEap = $ErrorActionPreference
                [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
                # git grep sort en code 1 quand il ne trouve rien : sous 'Stop',
                # ce non-zéro accompagné de stderr ferait lever l'appel natif.
                $ErrorActionPreference = 'Continue'
                try {
                foreach ($p in $patterns) {
                    # -P : les motifs sont des regex .NET (lookahead négatif compris),
                    # que seul le moteur PCRE de git sait lire. -I écarte les binaires.
                    $out = @(git grep -P -i -I -n -e $p.Regex @shas -- . ':(exclude)tests/Test-KitAnonymity.ps1' 2>&1)
                    if ($LASTEXITCODE -gt 1) {
                        # Ni « trouvé » ni « rien trouvé » : le scan n'a pas eu lieu.
                        # Le dire, sinon un git sans PCRE rendrait un vert mensonger.
                        $historyRun = $false
                        $historyError = $true
                        $historyNote = "git grep a échoué sur « $($p.Name) » : $($out -join ' ')"
                        break
                    }
                    foreach ($line in $out) {
                        $parts = ([string]$line) -split ':', 4
                        if ($parts.Count -lt 4) { continue }
                        $key = '{0}|{1}|{2}' -f $parts[1], $parts[2], $p.Name
                        if ($seen.ContainsKey($key)) { $seen[$key].Commits++; continue }
                        $m = [regex]::Match($parts[3], $p.Regex, 'IgnoreCase')
                        $seen[$key] = [PSCustomObject]@{
                            Sha     = $parts[0].Substring(0, 7)
                            File    = $parts[1]
                            Line    = [int]$parts[2]
                            Rule    = $p.Name
                            Extract = if ($m.Success) { $m.Value } else { '(motif)' }
                            Commits = 1
                        }
                    }
                }
                } finally {
                    [Console]::OutputEncoding = $prevOut
                    $ErrorActionPreference = $prevEap
                }
                $historyViolations = @($seen.Values | Sort-Object File, Line)
            }
        }
    } finally { Pop-Location }
}

# Verdict de l'arbre, toujours écrit : même quand l'historique échoue à côté, on
# doit pouvoir lire ce que l'arbre a donné.
if ($violations.Count -gt 0) {
    Write-Host "[ANONYMAT] $($violations.Count) violation(s) :" -ForegroundColor Red
    $violations | ForEach-Object { Write-Host ("  {0}:{1} - {2} : {3}" -f $_.File, $_.Line, $_.Rule, $_.Extract) }
} else {
    Write-Host "[ANONYMAT] $($tracked.Count) fichier(s) suivis, $armed, 0 violation(s)" -ForegroundColor Green
}

if ($History) {
    if ($historyRun) {
        if ($historyViolations.Count -gt 0) {
            Write-Host "[ANONYMAT] HISTORIQUE : $($historyViolations.Count) violation(s) sur $historyCommits commit(s) de public-main..HEAD, $armed :" -ForegroundColor Red
            $historyViolations | ForEach-Object {
                Write-Host ("  {0} {1}:{2} - {3} : {4} (dans {5} commit(s))" -f $_.Sha, $_.File, $_.Line, $_.Rule, $_.Extract, $_.Commits)
            }
        } else {
            Write-Host "[ANONYMAT] HISTORIQUE : $historyCommits commit(s) de public-main..HEAD balayé(s), $armed, 0 violation(s)" -ForegroundColor Green
        }
    } else {
        Write-Host "[ANONYMAT] HISTORIQUE NON BALAYÉ : $historyNote" -ForegroundColor Yellow
    }
}

$total = $violations.Count + $historyViolations.Count
if ($total -gt 0 -or $historyError) {
    # -History est un contrôle d'avant-publication : il doit pouvoir bloquer un
    # push, donc il rend un code de sortie même sans -CI.
    if ($CI -or $History) { exit 1 }
    return $violations
}
if ($CI) { exit 0 }
