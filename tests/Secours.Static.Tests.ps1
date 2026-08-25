# tests/Secours.Static.Tests.ps1 - contraintes WinRE de secours.bat, verrouillées.
#
# Chaque règle correspond à un piège PAYÉ pendant une réparation réelle de ruche
# de registre : findstr et vssadmin absents des WinRE dépouillés, tube qui tue le
# script sans un mot, lettre de volume qui bouge d'un démarrage à l'autre, accent
# illisible en page de codes OEM, pause qui vide l'entrée standard redirigée.
# secours.bat est le seul fichier du dépôt écrit en ASCII pur : ce fichier de
# tests est ce qui empêche de l'oublier, et il s'applique d'office à tout futur
# .bat destiné au WinRE ajouté dans $script:WinReBatchFiles.
#
# CONTRAT DE COLLECTION (le piège payé en v2.4, à ne jamais reproduire) : chaque
# fonction Get-KitBatch* et l'oracle agrégé retournent un tableau NU (`return $v`)
# et l'appelant enveloppe systématiquement avec @(...). Un `return ,@($v)` rendrait
# `@(...).Count` TOUJOURS égal à 1, sur un fichier propre comme sur un fichier qui
# viole tout : la suite entière serait verte sans rien vérifier. Le Describe
# « auto-vérification » prouve, pour chaque règle, que le compte vaut 0 sur du
# propre et qu'il varie avec le nombre de violations.
# Encodage : UTF-8 avec BOM, et mode strict comme les autres fichiers de tests.

Set-StrictMode -Version Latest

BeforeAll {
    # MESURÉ : le Set-StrictMode du haut de fichier ne vaut que pour la phase de
    # DÉCOUVERTE de Pester 5. La phase d'exécution rejoue les blocs dans une
    # autre portée, où le mode strict serait retombé : posé au seul haut de
    # fichier, il ne protège aucun It. Les deux lignes sont nécessaires.
    Set-StrictMode -Version Latest

    # Le cache de l'inventaire de commandes se crée ICI, jamais à la volée : en
    # mode strict, lire une variable jamais affectée lève « cannot be retrieved
    # because it has not been set », et le `if ($null -eq $script:...)` d'origine
    # faisait donc échouer 30 tests sur 48, sur 5.1 comme sur 7.x.
    $script:KitBatchCommandCache = @{}

    # Liste extensible : tout futur .bat WinRE ajouté ici hérite de la totalité
    # des règles, sans toucher à un seul test.
    $script:WinReBatchFiles = @("$PSScriptRoot\..\secours.bat")

    $script:WinReBatches = @(
        foreach ($p in $script:WinReBatchFiles) {
            [PSCustomObject]@{
                Path  = $p
                Name  = (Split-Path $p -Leaf)
                Bytes = [System.IO.File]::ReadAllBytes($p)
                Raw   = [System.IO.File]::ReadAllText($p)
            }
        }
    )

    # -----------------------------------------------------------------------
    # Découpage bas niveau : lignes, énoncés, positions de commande.
    # -----------------------------------------------------------------------

    function Split-KitBatchLine {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        return ($Content -split "`r`n|`n")
    }

    function Test-KitBatchIgnorable {
        # Ligne sans position de commande : vide, commentaire REM, étiquette.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
        $t = $Line.Trim()
        if ($t -eq '') { return $true }
        if ($t.StartsWith(':')) { return $true }
        if ($t -match '^@?rem\b') { return $true }
        return $false
    }

    function Remove-KitBatchFirstToken {
        # Retire le premier jeton, guillemets compris. cmd.exe ne connaît pas
        # l'échappement \" : une chaîne entre guillemets s'arrête au guillemet
        # suivant, y compris dans "%1:\Windows\System32\config\".
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
        $t = $Text.TrimStart()
        if ($t -eq '') { return '' }
        if ($t.StartsWith('"')) {
            $end = $t.IndexOf('"', 1)
            if ($end -lt 0) { return '' }
            return $t.Substring($end + 1).TrimStart()
        }
        $m = [regex]::Match($t, '^\S+')
        return $t.Substring($m.Length).TrimStart()
    }

    function Split-KitBatchStatement {
        # Retire les redirections, qui ne sont pas des commandes, puis coupe la
        # ligne sur les & hors guillemets : `dir & powershell` porte DEUX
        # positions de commande. Les redirections partent en premier, sinon le &
        # de `2>&1` couperait la ligne au mauvais endroit. Un caractère précédé
        # d'un accent circonflexe est échappé pour cmd : il est laissé tel quel
        # (`2^>nul` dans un for /f n'est pas une redirection de la ligne).
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
        # Raccourci : sans redirection ni enchaînement, rien à découper. La
        # majorité des lignes sont dans ce cas et le parcours caractère par
        # caractère coûte cher sur 750 lignes relues par chaque règle.
        if ($Line.IndexOfAny([char[]]@('<', '>', '&')) -lt 0) {
            if ($Line.Trim() -eq '') { return @() }
            return @($Line)
        }
        $stmts   = New-Object System.Collections.Generic.List[string]
        $cur     = New-Object System.Text.StringBuilder
        $inQuote = $false
        $i       = 0
        while ($i -lt $Line.Length) {
            $c = $Line[$i]
            if ($c -eq '"') { $inQuote = -not $inQuote; [void]$cur.Append($c); $i++; continue }
            if ($inQuote -or ($i -gt 0 -and $Line[$i - 1] -eq '^')) { [void]$cur.Append($c); $i++; continue }
            if ($c -eq '&') {
                [void]$stmts.Add($cur.ToString())
                [void]$cur.Clear()
                $i++
                if ($i -lt $Line.Length -and $Line[$i] -eq '&') { $i++ }
                continue
            }
            $isRedir = ($c -eq '<' -or $c -eq '>')
            if (-not $isRedir -and [char]::IsDigit($c) -and ($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq '>') {
                $isRedir = $true
                $i++
            }
            if ($isRedir) {
                $i++
                if ($i -lt $Line.Length -and $Line[$i] -eq '>') { $i++ }
                while ($i -lt $Line.Length -and $Line[$i] -eq ' ') { $i++ }
                if ($i -lt $Line.Length -and $Line[$i] -eq '&') { $i++ }
                if ($i -lt $Line.Length -and $Line[$i] -eq '"') {
                    $i++
                    while ($i -lt $Line.Length -and $Line[$i] -ne '"') { $i++ }
                    if ($i -lt $Line.Length) { $i++ }
                }
                else {
                    while ($i -lt $Line.Length -and -not ([char]::IsWhiteSpace($Line[$i]) -or $Line[$i] -eq '&')) { $i++ }
                }
                [void]$cur.Append(' ')
                continue
            }
            [void]$cur.Append($c)
            $i++
        }
        [void]$stmts.Add($cur.ToString())
        return ($stmts | Where-Object { $_.Trim() -ne '' })
    }

    function Expand-KitBatchCommandPosition {
        # Épluche les préfixes qui ne sont pas la commande exécutée (%DO%, if,
        # for ... do, call) et retourne le ou les textes réellement en position
        # de commande. Le jeu d'un `for /f ... in ('cmd')` en est une : c'est
        # exactement la forme qui a tué le script d'origine sur un WinRE sans
        # findstr. Une construction non analysable rend un marqueur `?...` :
        # l'inconnu est refusé, jamais deviné.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Statement)
        $pos   = New-Object System.Collections.Generic.List[string]
        $s     = $Statement.Trim()
        $guard = 0
        while ($true) {
            $guard++
            if ($guard -gt 20) { [void]$pos.Add('?boucle'); break }
            $s = $s.TrimStart()
            if ($s -eq '') { break }
            if ($s.StartsWith('@'))    { $s = $s.Substring(1);  continue }
            if ($s.StartsWith('%DO%')) { $s = $s.Substring(4);  continue }
            if ($s -match '^if\s+') {
                $r = $s -replace '^if\s+', ''
                while ($r -match '^(/i|not)\s+') { $r = $r -replace '^(/i|not)\s+', '' }
                if ($r -match '^(exist|defined|errorlevel|cmdextversion)\s+') {
                    $r = $r -replace '^(exist|defined|errorlevel|cmdextversion)\s+', ''
                    $r = Remove-KitBatchFirstToken -Text $r
                }
                elseif ($r -match '^("[^"]*"|[^\s=]+)\s*==\s*("[^"]*"|\S+)\s*') {
                    $r = $r -replace '^("[^"]*"|[^\s=]+)\s*==\s*("[^"]*"|\S+)\s*', ''
                }
                elseif ($r -match '^("[^"]*"|\S+)\s+(equ|neq|lss|leq|gtr|geq)\s+("[^"]*"|\S+)\s*') {
                    $r = $r -replace '^("[^"]*"|\S+)\s+(equ|neq|lss|leq|gtr|geq)\s+("[^"]*"|\S+)\s*', ''
                }
                else {
                    [void]$pos.Add('?if')
                    break
                }
                $s = $r
                continue
            }
            if ($s -match '^for\s+') {
                $m = [regex]::Match($s, '(?i)^for\b.*?\bin\s*\((.*?)\)\s*do\s+')
                if (-not $m.Success) { [void]$pos.Add('?for'); break }
                $set = $m.Groups[1].Value.Trim()
                # usebackq inverse les quotes : sans lui 'cmd' est une commande,
                # avec lui c'est `cmd` qui en est une et 'texte' une chaîne.
                $cmdQuote = if ($s -match '(?i)usebackq') { [char]0x60 } else { [char]0x27 }
                if ($set.Length -ge 2 -and $set[0] -eq $cmdQuote -and $set[$set.Length - 1] -eq $cmdQuote) {
                    foreach ($inner in @(Expand-KitBatchCommandPosition -Statement $set.Substring(1, $set.Length - 2))) {
                        [void]$pos.Add($inner)
                    }
                }
                $s = $s.Substring($m.Length)
                continue
            }
            if ($s -match '^call\s+') {
                [void]$pos.Add($s)
                $r = ($s -replace '^call\s+', '').TrimStart()
                # `call :etiquette` reste dans le batch ; `call binaire.exe`
                # lance un binaire, donc une position de commande de plus.
                if ($r -eq '' -or $r.StartsWith(':')) { break }
                $s = $r
                continue
            }
            [void]$pos.Add($s)
            break
        }
        return $pos
    }

    function ConvertTo-KitBatchCommandName {
        # Nom canonique de la commande d'une position : sans chemin, sans
        # extension, sans la ponctuation collée des formes `echo.` et `goto:eof`.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Position)
        $s = $Position.TrimStart()
        if ($s -eq '') { return '' }
        if ($s.StartsWith('"')) {
            $end = $s.IndexOf('"', 1)
            $t = if ($end -lt 0) { $s.Substring(1) } else { $s.Substring(1, $end - 1) }
        }
        else {
            $t = ([regex]::Match($s, '^\S+')).Value
        }
        if ($t -match '^(?i)echo[\.\:\(\\/]') { return 'echo' }
        $t = ($t -split '[\\/]')[-1]
        $t = $t -replace '(?i)\.(exe|com|bat|cmd)$', ''
        if ($t -match '^(?i)(goto|set|exit|call|pause|rem|start)[\.\:]') { $t = ($t -split '[\.\:]')[0] }
        return $t.ToLowerInvariant()
    }

    function Get-KitBatchAllowedCommand {
        # Liste blanche assumée. Les internes de cmd.exe sont présentes par
        # définition, même dans un WinRE dépouillé. Les externes ont chacune été
        # VUES dans un WinRE réel : tout le reste est absent, ou dangereux ici.
        # `start` ET `cmd` sont volontairement HORS liste, pour la même raison :
        # `start binaire` comme `cmd /c binaire` lancent n'importe quoi et
        # videraient la liste blanche de son sens. Le vocabulaire réellement
        # employé par secours.bat n'en contient ni l'un ni l'autre : attrib,
        # call, chkdsk, copy, dir, echo, endlocal, exit, fsutil, goto, if, md,
        # mklink, pause, ren, rmdir, set, setlocal, ver, xcopy.
        return @(
            'assoc', 'break', 'call', 'cd', 'chdir', 'cls', 'color', 'copy', 'date',
            'del', 'dir', 'echo', 'endlocal', 'erase', 'exit', 'for', 'goto', 'if',
            'md', 'mkdir', 'mklink', 'move', 'path', 'pause', 'popd', 'prompt',
            'pushd', 'rd', 'rem', 'ren', 'rename', 'rmdir', 'set', 'setlocal',
            'shift', 'time', 'title', 'type', 'ver', 'verify', 'vol',
            'reg', 'xcopy', 'attrib', 'chkdsk', 'fsutil'
        )
    }

    function Get-KitBatchCommand {
        # Inventaire des commandes réellement exécutées : une entrée par position
        # de commande, avec son numéro de ligne, ses arguments et la ligne brute.
        # Mémoïsé par contenu : quatre règles et la mutation relisent le même
        # fichier de 750 lignes, et le parcours coûte une demi-seconde.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        if ($script:KitBatchCommandCache.ContainsKey($Content)) { return $script:KitBatchCommandCache[$Content] }
        $out   = New-Object System.Collections.Generic.List[object]
        $lines = @(Split-KitBatchLine -Content $Content)
        for ($n = 0; $n -lt $lines.Count; $n++) {
            $line = $lines[$n]
            if (Test-KitBatchIgnorable -Line $line) { continue }
            foreach ($stmt in @(Split-KitBatchStatement -Line $line)) {
                foreach ($position in @(Expand-KitBatchCommandPosition -Statement $stmt)) {
                    $name = ConvertTo-KitBatchCommandName -Position $position
                    if ($name -eq '') { continue }
                    # Les arguments, pour les règles qui lisent le texte affiché.
                    # `echo.Texte` colle son argument : il se coupe autrement.
                    $rest = $position -replace '^\s*\S+\s*', ''
                    if ($name -eq 'echo') { $rest = $position -replace '^\s*echo[\.\:\(\\/]?', '' }
                    [void]$out.Add([PSCustomObject]@{
                        Line      = $n + 1
                        Command   = $name
                        Arguments = $rest
                        Text      = $line.Trim()
                    })
                }
            }
        }
        $script:KitBatchCommandCache[$Content] = $out
        return $out
    }

    # -----------------------------------------------------------------------
    # Les règles. Une fonction pure par règle, tableau NU de violations.
    # -----------------------------------------------------------------------

    function Get-KitBatchNonAscii {
        # Règle 1 : un WinRE affiche en page de codes OEM, tout octet au-delà de
        # 0x7F y devient illisible.
        param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
        $v = @()
        for ($i = 0; $i -lt $Bytes.Length; $i++) {
            if ($Bytes[$i] -gt 0x7F) { $v += ('octet 0x{0:X2} en position {1}' -f $Bytes[$i], $i) }
        }
        return $v
    }

    function Get-KitBatchLoneLf {
        # Règle 2 : cmd.exe est le seul interpréteur du WinRE et un .bat en LF
        # seul est un pari. Chaque 0x0A doit être précédé d'un 0x0D.
        param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
        $v = @()
        for ($i = 0; $i -lt $Bytes.Length; $i++) {
            if ($Bytes[$i] -ne 0x0A) { continue }
            if ($i -eq 0 -or $Bytes[$i - 1] -ne 0x0D) { $v += "LF isolé en position $i" }
        }
        return $v
    }

    function Get-KitBatchPipe {
        # Règle 3 : un tube appelle findstr, more ou sort, absents des WinRE
        # dépouillés. Le script meurt net, sans le moindre message.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        $lines = @(Split-KitBatchLine -Content $Content)
        for ($n = 0; $n -lt $lines.Count; $n++) {
            if ($lines[$n].Contains('|')) { $v += "ligne $($n + 1) : tube présent : $($lines[$n].Trim())" }
        }
        return $v
    }

    function Get-KitBatchForbiddenExe {
        # Règle 4 : liste blanche stricte des commandes. Une mention dans un echo
        # ou dans un test `if exist` n'est pas une exécution et ne compte pas.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        $allowed = @(Get-KitBatchAllowedCommand)
        foreach ($c in @(Get-KitBatchCommand -Content $Content)) {
            if ($allowed -contains $c.Command) { continue }
            if ($c.Command.StartsWith('?')) {
                $v += "ligne $($c.Line) : position de commande non analysable [$($c.Command)] : $($c.Text)"
                continue
            }
            $v += "ligne $($c.Line) : commande hors liste blanche WinRE [$($c.Command)] : $($c.Text)"
        }
        return $v
    }

    function Get-KitBatchHardcodedLetter {
        # Règle 5 : vu depuis le WinRE, le volume Windows n'est pas toujours C:
        # et la clé change de lettre. Seul repli autorisé : X:\Windows\Temp, le
        # disque en mémoire du WinRE lui-même.
        # DEUX formes, et la seconde est la plus probable des deux : le chemin
        # complet `C:\Windows\...`, et la lettre NUE, sans le moindre backslash,
        # `set "WINVOL=C:"` ou `chkdsk C: /f`. La lettre nue est exactement la
        # rechute « de toute façon c'est C: », et elle tombe justement sur la
        # variable qui porte le volume. Elle ne se cherche qu'en POSITION DE
        # COMMANDE, hors echo : le LISEZMOI dit à l'opérateur d'essayer « c:
        # puis d: puis e: », et un mode d'emploi affiché n'est pas du code.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        $lines = @(Split-KitBatchLine -Content $Content)
        for ($n = 0; $n -lt $lines.Count; $n++) {
            $line = $lines[$n]
            if ($line.Trim() -match '^@?rem\b') { continue }
            foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9])([A-Za-z]:\\[^"\s]*)')) {
                $p = $m.Groups[1].Value
                if ($p -match '^(?i)X:\\Windows\\Temp') { continue }
                $v += "ligne $($n + 1) : lettre de volume en dur [$p] : $($line.Trim())"
            }
        }
        # Le backslash est exclu du lookahead : la forme chemin est déjà relevée
        # ci-dessus, avec sa seule exception X:\Windows\Temp. Reste ici la lettre
        # nue, celle que le passage précédent laissait filer.
        foreach ($c in @(Get-KitBatchCommand -Content $Content)) {
            if ($c.Command -eq 'echo') { continue }
            $texte = "$($c.Command) $($c.Arguments)"
            foreach ($m in [regex]::Matches($texte, '(?<![A-Za-z0-9])([A-Za-z]:)(?![A-Za-z0-9\\])')) {
                $v += "ligne $($c.Line) : lettre de volume nue [$($m.Groups[1].Value)] : $($c.Text)"
            }
        }
        return $v
    }

    function Measure-KitBatchLetterLoop {
        # Nombre de boucles de lettres de volume `for %%D in (C D E ...)`.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $n = 0
        foreach ($m in [regex]::Matches($Content, '(?i)\bin\s*\(([^)]*)\)')) {
            $tokens = @($m.Groups[1].Value -split '[\s,;]+' | Where-Object { $_ -ne '' })
            if ($tokens.Count -lt 5) { continue }
            if (@($tokens | Where-Object { $_ -notmatch '^[A-Za-z]$' }).Count -gt 0) { continue }
            $n++
        }
        return $n
    }

    function Get-KitBatchLetterLoopWithX {
        # Règle 5 bis : X est le disque en mémoire du WinRE. Le sonder revient à
        # proposer de réparer le WinRE avec lui-même.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        foreach ($m in [regex]::Matches($Content, '(?i)\bin\s*\(([^)]*)\)')) {
            $set    = $m.Groups[1].Value
            $tokens = @($set -split '[\s,;]+' | Where-Object { $_ -ne '' })
            if ($tokens.Count -lt 5) { continue }
            if (@($tokens | Where-Object { $_ -notmatch '^[A-Za-z]$' }).Count -gt 0) { continue }
            if (@($tokens | Where-Object { $_ -match '^(?i)x$' }).Count -gt 0) {
                $v += "boucle de lettres incluant X (disque en mémoire du WinRE) : ($set)"
            }
        }
        return $v
    }

    function Get-KitBatchUnguardedPause {
        # Règle 6 : PROUVÉ en local, pause consomme l'entrée standard quand elle
        # vient d'un fichier et désynchronise les set /p suivants. Sous crochet de
        # test elle doit donc être neutralisée, et elle doit précéder le retour au
        # menu ou la sortie, sinon l'écran défile et le message n'est jamais lu.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v     = @()
        $lines = @(Split-KitBatchLine -Content $Content)
        foreach ($c in @(Get-KitBatchCommand -Content $Content | Where-Object { $_.Command -eq 'pause' })) {
            if ($c.Text -notmatch '^(?i)if\s+not\s+defined\s+SECOURS_DRYRUN\s+pause$') {
                $v += "ligne $($c.Line) : pause non gardée par SECOURS_DRYRUN : $($c.Text)"
                continue
            }
            $next = ''
            for ($k = $c.Line; $k -lt $lines.Count; $k++) {
                $cand = $lines[$k].Trim()
                if ($cand -eq '' -or $cand -match '^@?rem\b') { continue }
                $next = $cand
                break
            }
            if ($next -notmatch '^(?i)goto\s+') {
                $v += "ligne $($c.Line) : pause non suivie d'un goto de sortie : [$next]"
            }
        }
        return $v
    }

    function Get-KitBatchOpenBlock {
        # Règle 7 : un bloc `if ... (` multiligne casse sur les chemins à
        # parenthèses, et le dossier Program Files (x86) en est un. Tous les
        # embranchements passent par goto ou call.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        $lines = @(Split-KitBatchLine -Content $Content)
        for ($n = 0; $n -lt $lines.Count; $n++) {
            $line = $lines[$n]
            if ($line.Trim() -match '^@?rem\b') { continue }
            if ($line.TrimEnd().EndsWith('(')) {
                $v += "ligne $($n + 1) : ligne terminée par une parenthèse ouvrante : $($line.Trim())"
            }
        }
        return $v
    }

    function Get-KitBatchEchoBang {
        # Règle 8 : le script tourne en EnableDelayedExpansion, un point
        # d'exclamation de ponctuation dans un echo est mangé à l'affichage.
        # Les références de variables !VAR! restent évidemment permises.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        foreach ($c in @(Get-KitBatchCommand -Content $Content | Where-Object { $_.Command -eq 'echo' })) {
            $txt = $c.Arguments -replace '![A-Za-z0-9_]+!', ''
            if ($txt.Contains('!')) {
                $v += "ligne $($c.Line) : point d'exclamation dans un echo : $($c.Text)"
            }
        }
        return $v
    }

    function Get-KitBatchTypeOnFile {
        # Règle 9 : `type` sur une ruche la tronque au premier octet de fin de
        # fichier et corrompt tout binaire. Les ruches se copient, jamais autrement.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        foreach ($c in @(Get-KitBatchCommand -Content $Content | Where-Object { $_.Command -eq 'type' })) {
            if ($c.Arguments -match '^"' -or $c.Arguments -match '[\\/]') {
                $v += "ligne $($c.Line) : type sur un fichier (corrompt les binaires) : $($c.Text)"
            }
        }
        return $v
    }

    function Get-KitBatchUnloggedDo {
        # Règle 10 : le préfixe %DO% neutralise une écriture système en la
        # transformant en echo. Tant que la ligne n'est pas redirigée vers le
        # journal de la clé, cet echo part sur la console d'un WinRE qui sera
        # refermée avant que quiconque la lise. C'est le journal qu'on rapporte
        # sur un PC sain, donc chaque ligne %DO% s'y déverse.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $v = @()
        $lines = @(Split-KitBatchLine -Content $Content)
        for ($n = 0; $n -lt $lines.Count; $n++) {
            $line = $lines[$n]
            if ($line -notmatch '%DO%') { continue }
            if ($line.Trim() -match '^@?rem\b') { continue }
            if ($line -match '>>"%LOG%"') { continue }
            $v += "ligne $($n + 1) : trace %DO% hors journal : $($line.Trim())"
        }
        return $v
    }

    function Get-WinReBatchViolations {
        # Oracle agrégé, réutilisable pour tout futur .bat WinRE. CONTRAT :
        # tableau NU, l'appelant enveloppe avec @(...). Le `return ,@($v)` du
        # squelette d'origine rendait ce compte égal à 1 en toutes circonstances.
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
            [byte[]]$Bytes
        )
        $v = @()
        if ($PSBoundParameters.ContainsKey('Bytes')) {
            $v += @(Get-KitBatchNonAscii -Bytes $Bytes)
            $v += @(Get-KitBatchLoneLf   -Bytes $Bytes)
        }
        $v += @(Get-KitBatchPipe            -Content $Content)
        $v += @(Get-KitBatchForbiddenExe    -Content $Content)
        $v += @(Get-KitBatchHardcodedLetter -Content $Content)
        $v += @(Get-KitBatchLetterLoopWithX -Content $Content)
        $v += @(Get-KitBatchUnguardedPause  -Content $Content)
        $v += @(Get-KitBatchOpenBlock       -Content $Content)
        $v += @(Get-KitBatchEchoBang        -Content $Content)
        $v += @(Get-KitBatchTypeOnFile      -Content $Content)
        $v += @(Get-KitBatchUnloggedDo      -Content $Content)
        return $v
    }

    function New-KitBatchFixture {
        # Fixture jetable, toujours dans $TestDrive, jamais dans le dépôt.
        param(
            [Parameter(Mandatory)][string]$Path,
            [string[]]$Line = @(),
            [byte[]]$Byte
        )
        if ($PSBoundParameters.ContainsKey('Byte')) {
            [System.IO.File]::WriteAllBytes($Path, $Byte)
        }
        else {
            $raw = ($Line -join "`r`n") + "`r`n"
            [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::ASCII.GetBytes($raw))
        }
        return $Path
    }
}

Describe 'secours.bat : contraintes WinRE payées sur le terrain' {

    It 'la liste des batchs WinRE surveillés n''est pas vide' {
        # Sans ce garde, toutes les règles passeraient à vide.
        @($script:WinReBatches).Count | Should -BeGreaterThan 0
        foreach ($b in $script:WinReBatches) { Test-Path $b.Path | Should -BeTrue }
    }

    It 'règle 1 : ASCII strict, aucun octet au-delà de 0x7F' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchNonAscii -Bytes $b.Bytes)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 2 : CRLF strict, aucun LF isolé' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchLoneLf -Bytes $b.Bytes)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 3 : aucun tube' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchPipe -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 4 : toute commande exécutée appartient à la liste blanche WinRE' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchForbiddenExe -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 4 bis : manage-bde et wpeutil sont cités mais jamais exécutés' {
        foreach ($b in $script:WinReBatches) {
            # Le fichier les mentionne vraiment : sans cela le test ne prouverait rien.
            $b.Raw | Should -Match 'manage-bde'
            $b.Raw | Should -Match 'wpeutil'
            $noms = @(Get-KitBatchCommand -Content $b.Raw | ForEach-Object { $_.Command })
            $noms | Should -Not -Contain 'manage-bde'
            $noms | Should -Not -Contain 'wpeutil'
        }
    }

    It 'règle 5 : aucune lettre de volume en dur hors le repli X:\Windows\Temp' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchHardcodedLetter -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 5 bis : les boucles de lettres existent et excluent X' {
        foreach ($b in $script:WinReBatches) {
            (Measure-KitBatchLetterLoop -Content $b.Raw) | Should -BeGreaterThan 0 -Because "$($b.Name) doit sonder les volumes"
            $viol = @(Get-KitBatchLetterLoopWithX -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 6 : une pause existe, gardée, et précède chaque retour au menu' {
        foreach ($b in $script:WinReBatches) {
            $pauses = @(Get-KitBatchCommand -Content $b.Raw | Where-Object { $_.Command -eq 'pause' })
            $pauses.Count | Should -BeGreaterThan 0 -Because "$($b.Name) doit laisser l'opérateur lire l'écran"
            $viol = @(Get-KitBatchUnguardedPause -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 7 : aucune ligne ne se termine par une parenthèse ouvrante' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchOpenBlock -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 8 : aucun point d''exclamation de ponctuation dans un echo' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchEchoBang -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 9 : type n''est jamais utilisé sur un fichier' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-KitBatchTypeOnFile -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'oracle agrégé : zéro violation sur les batchs livrés' {
        foreach ($b in $script:WinReBatches) {
            $viol = @(Get-WinReBatchViolations -Content $b.Raw -Bytes $b.Bytes)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }

    It 'règle 10 : les traces de dry-run partent dans le journal, pas sur la sortie standard' {
        foreach ($b in $script:WinReBatches) {
            # Le garde qui manquait : sans lui, la règle passerait à vide et donc
            # au vert le jour où %DO% disparaîtrait du fichier, exactement comme
            # une boucle sans itération. Le fichier DOIT en porter.
            $b.Raw | Should -Match '%DO%'
            $viol = @(Get-KitBatchUnloggedDo -Content $b.Raw)
            $viol.Count | Should -Be 0 -Because "$($b.Name) : $($viol -join ' ; ')"
        }
    }
}

Describe 'auto-vérification de l''oracle : chaque règle mord' {
    # Sans ce Describe, la suite entière pourrait être verte sur un batch qui
    # viole tout : c'est précisément ce que faisait l'oracle d'origine avec son
    # `return ,@($v)`. Chaque règle reçoit ici un .bat minuscule qui la viole,
    # et un extrait propre qui ne la viole pas.

    It 'contrat de collection : le compte vaut 0 sur du propre et suit le nombre de violations' {
        $propre = New-KitBatchFixture -Path "$TestDrive\propre.bat" -Line @(
            '@echo off', 'echo bonjour', 'set "A=1"', 'goto :eof'
        )
        @(Get-WinReBatchViolations -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0

        $une = New-KitBatchFixture -Path "$TestDrive\une.bat" -Line @('echo bonjour', 'dir | more')
        @(Get-WinReBatchViolations -Content ([System.IO.File]::ReadAllText($une))).Count | Should -Be 1

        $trois = New-KitBatchFixture -Path "$TestDrive\trois.bat" -Line @(
            'findstr /i x fichier.txt', 'dir | more', 'pause'
        )
        @(Get-WinReBatchViolations -Content ([System.IO.File]::ReadAllText($trois))).Count | Should -Be 3
    }

    It 'règle 1 : un octet accentué est détecté, un fichier ASCII ne l''est pas' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r1-sale.bat" -Byte ([byte[]](0x65, 0x63, 0x68, 0x6F, 0x20, 0xE9, 0x0D, 0x0A))
        @(Get-KitBatchNonAscii -Bytes ([System.IO.File]::ReadAllBytes($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r1-propre.bat" -Line @('echo e')
        @(Get-KitBatchNonAscii -Bytes ([System.IO.File]::ReadAllBytes($propre))).Count | Should -Be 0
    }

    It 'règle 2 : un LF isolé est détecté, du CRLF ne l''est pas' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r2-sale.bat" -Byte ([System.Text.Encoding]::ASCII.GetBytes("echo a`necho b`r`n"))
        @(Get-KitBatchLoneLf -Bytes ([System.IO.File]::ReadAllBytes($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r2-propre.bat" -Line @('echo a', 'echo b')
        @(Get-KitBatchLoneLf -Bytes ([System.IO.File]::ReadAllBytes($propre))).Count | Should -Be 0
    }

    It 'règle 3 : un tube est détecté, une redirection ne l''est pas' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r3-sale.bat" -Line @('dir /b | more')
        @(Get-KitBatchPipe -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r3-propre.bat" -Line @('dir /b > "%LOG%" 2>&1')
        @(Get-KitBatchPipe -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'règle 4 : les binaires absents du WinRE sont détectés, y compris dans un for /f' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r4-sale.bat" -Line @(
            'findstr /i toto fichier.txt',
            'vssadmin list shadows',
            'wmic os get name',
            'powershell -c exit'
        )
        $viol = @(Get-KitBatchForbiddenExe -Content ([System.IO.File]::ReadAllText($sale)))
        $viol.Count | Should -Be 4
        ($viol -join ' ') | Should -Match 'findstr'
        ($viol -join ' ') | Should -Match 'vssadmin'

        $cache = New-KitBatchFixture -Path "$TestDrive\r4-cache.bat" -Line @(
            'for /f "delims=" %%X in (''findstr /c:"x" f.txt'') do echo %%X'
        )
        @(Get-KitBatchForbiddenExe -Content ([System.IO.File]::ReadAllText($cache))).Count | Should -Be 1

        $chaine = New-KitBatchFixture -Path "$TestDrive\r4-chaine.bat" -Line @('dir /b & diskpart /s x.txt')
        @(Get-KitBatchForbiddenExe -Content ([System.IO.File]::ReadAllText($chaine))).Count | Should -Be 1
    }

    It 'règle 4 : cmd est hors liste blanche, cmd /c relancerait n''importe quel binaire' {
        # `cmd /c vssadmin ...` lance vssadmin. Tant que cmd est resté dans la
        # liste blanche, la règle 4 ne voyait rien : elle lit le nom de la
        # commande, et ce nom valait cmd. C'est la propriété pour laquelle
        # `start` avait été exclu d'emblée, et cmd la partage entièrement.
        $sale = New-KitBatchFixture -Path "$TestDrive\r4-cmd.bat" -Line @(
            'cmd /c vssadmin list shadows'
        )
        $viol = @(Get-KitBatchForbiddenExe -Content ([System.IO.File]::ReadAllText($sale)))
        $viol.Count | Should -Be 1
        ($viol -join ' ') | Should -Match 'cmd'

        @(Get-KitBatchAllowedCommand) | Should -Not -Contain 'cmd'
        @(Get-KitBatchAllowedCommand) | Should -Not -Contain 'start'
    }

    It 'règle 4 : une mention dans un echo ou un if exist n''est pas une exécution' {
        # Exactement les deux formes présentes dans secours.bat : elles doivent
        # rester permises, sinon la règle serait inutilisable sur le vrai fichier.
        $propre = New-KitBatchFixture -Path "$TestDrive\r4-propre.bat" -Line @(
            '@echo off',
            'setlocal EnableDelayedExpansion',
            'if not exist "%SystemRoot%\System32\manage-bde.exe" goto :eof',
            'echo    manage-bde -unlock LETTRE: -RecoveryPassword CLE',
            'echo   3. Tapez :  wpeutil reboot',
            '>>"%LOG%" fsutil volume diskfree %WINVOL% <nul',
            'xcopy /h /k /y "%SRC%" "%DST%\" <nul 2>&1',
            'chkdsk %WINVOL% /f',
            'for /f "delims=" %%X in (''dir /b /a "%LNK%\" 2^>nul'') do if not defined ALIVE set "ALIVE=1"',
            'for /f "usebackq tokens=1,2 delims==" %%A in ("%JEU%\manifest.txt") do call :lit "%%A" "%%B"',
            '%DO%copy /b /y "%A%" "%B%" >>"%LOG%" 2>&1',
            'if /i not "!MFID!"=="!MIDVOL!" goto :eof',
            'if !VIDE! geq 3 goto menu_fin_vide',
            'endlocal',
            'exit /b 0'
        )
        $viol = @(Get-KitBatchForbiddenExe -Content ([System.IO.File]::ReadAllText($propre)))
        $viol.Count | Should -Be 0 -Because ($viol -join ' ; ')
    }

    It 'règle 5 : une lettre en dur est détectée, le repli TEMP ne l''est pas' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r5-sale.bat" -Line @('copy "D:\fichier.txt" "E:\"')
        @(Get-KitBatchHardcodedLetter -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 2

        $propre = New-KitBatchFixture -Path "$TestDrive\r5-propre.bat" -Line @(
            'if not defined TEMP set "TEMP=X:\Windows\Temp"',
            'if not exist "%1:\Windows\System32\config\" goto :eof',
            'copy "%WINVOL%\Windows\System32\config\SYSTEM" "%SDIR%\"'
        )
        @(Get-KitBatchHardcodedLetter -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'règle 5 : une lettre nue est détectée en position de commande, pas dans un echo' {
        # La forme la plus naturelle de la rechute « de toute façon c'est C: »,
        # et sur la variable qui porte justement le volume. Sans backslash,
        # l'ancien motif de la règle 5 ne la voyait pas.
        $sale = New-KitBatchFixture -Path "$TestDrive\r5-nue.bat" -Line @(
            'set "WINVOL=C:"',
            'chkdsk C: /f'
        )
        $viol = @(Get-KitBatchHardcodedLetter -Content ([System.IO.File]::ReadAllText($sale)))
        $viol.Count | Should -Be 2 -Because ($viol -join ' ; ')

        # Les mêmes lignes écrites correctement, plus les deux formes que
        # secours.bat porte vraiment : la consigne affichée à l'opérateur et le
        # repli TEMP du disque en mémoire du WinRE.
        $propre = New-KitBatchFixture -Path "$TestDrive\r5-nue-propre.bat" -Line @(
            'set "WINVOL=%SECOURS_FORCE_WIN%"',
            'chkdsk %WINVOL% /f',
            'if not defined TEMP set "TEMP=X:\Windows\Temp"',
            'if not exist "%1:\Windows\System32\config\" goto :eof',
            '>>"%SDIR%\LISEZMOI.txt" echo    essayant c: puis d: puis e: suivis de dir, puis taper la'
        )
        $viol = @(Get-KitBatchHardcodedLetter -Content ([System.IO.File]::ReadAllText($propre)))
        $viol.Count | Should -Be 0 -Because ($viol -join ' ; ')
    }

    It 'règle 5 bis : une boucle de lettres avec X est détectée, sans X non' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r5b-sale.bat" -Line @(
            'for %%D in (C D E F G H X) do call :sonde %%D'
        )
        @(Get-KitBatchLetterLoopWithX -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r5b-propre.bat" -Line @(
            'for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :sonde %%D',
            'for %%N in (1 2 3 4 5 6 7 8 9) do call :libre %%N'
        )
        @(Get-KitBatchLetterLoopWithX -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
        (Measure-KitBatchLetterLoop -Content ([System.IO.File]::ReadAllText($propre))) | Should -Be 1
    }

    It 'règle 6 : une pause nue ou orpheline est détectée, la pause gardée non' {
        $nue = New-KitBatchFixture -Path "$TestDrive\r6-nue.bat" -Line @('echo fini', 'pause', 'goto menu')
        @(Get-KitBatchUnguardedPause -Content ([System.IO.File]::ReadAllText($nue))).Count | Should -Be 1

        $orpheline = New-KitBatchFixture -Path "$TestDrive\r6-orpheline.bat" -Line @(
            'if not defined SECOURS_DRYRUN pause',
            'echo la suite defile sans que rien ne soit lu'
        )
        @(Get-KitBatchUnguardedPause -Content ([System.IO.File]::ReadAllText($orpheline))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r6-propre.bat" -Line @(
            'echo REFUS : rien n''a ete fait.',
            'if not defined SECOURS_DRYRUN pause',
            'goto menu'
        )
        @(Get-KitBatchUnguardedPause -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'règle 7 : une ligne finissant par une parenthèse ouvrante est détectée' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r7-sale.bat" -Line @(
            'if exist "%CFG%\%HIVE%" (', '  copy "%A%" "%B%"', ')'
        )
        @(Get-KitBatchOpenBlock -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r7-propre.bat" -Line @(
            'if exist "%CFG%\%HIVE%" goto r_copie_avant',
            'for %%F in ("%SRC%") do set "SZ=%%~zF"'
        )
        @(Get-KitBatchOpenBlock -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'règle 8 : un point d''exclamation de ponctuation est détecté, pas une variable !VAR!' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r8-sale.bat" -Line @('echo  ATTENTION ! ne redemarrez pas')
        @(Get-KitBatchEchoBang -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r8-propre.bat" -Line @(
            'echo  REFUS : %HIVE% du coffre fait !SZ! octets au lieu de !MFTAILLE!',
            '>>"%LOG%" echo Sauvegarde !CASSE! : !SZBACK! octets pour !SZORIG! attendus'
        )
        @(Get-KitBatchEchoBang -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'règle 9 : type sur un fichier est détecté, le mot type dans un echo non' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r9-sale.bat" -Line @('type "%CFG%\SYSTEM"')
        @(Get-KitBatchTypeOnFile -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r9-propre.bat" -Line @(
            'echo Ne tapez jamais type "%CFG%\SYSTEM" sur une ruche',
            'set /p MIDVOL=<"%WINVOL%\ProgramData\PC-Refresh-Kit\machine-id.txt"'
        )
        @(Get-KitBatchTypeOnFile -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'règle 10 : une trace %DO% hors journal est détectée, la même redirigée non' {
        $sale = New-KitBatchFixture -Path "$TestDrive\r10-sale.bat" -Line @(
            '%DO%copy /b /y "%SRC%" "%CFG%\%HIVE%"'
        )
        @(Get-KitBatchUnloggedDo -Content ([System.IO.File]::ReadAllText($sale))).Count | Should -Be 1

        $propre = New-KitBatchFixture -Path "$TestDrive\r10-propre.bat" -Line @(
            '%DO%copy /b /y "%SRC%" "%CFG%\%HIVE%" >>"%LOG%" 2>&1',
            'REM le prefixe %DO% cite dans un commentaire ne compte pas'
        )
        @(Get-KitBatchUnloggedDo -Content ([System.IO.File]::ReadAllText($propre))).Count | Should -Be 0
    }

    It 'un batch qui viole tout est relevé règle par règle' {
        # La contre-épreuve de bout en bout : le fichier de la honte doit faire
        # crier CHAQUE règle, sinon une règle dort.
        $honte = New-KitBatchFixture -Path "$TestDrive\honte.bat" -Line @(
            'findstr /i x "C:\Windows\System32\config\SYSTEM"',
            'cmd /c vssadmin list shadows',
            'dir | more',
            'for %%D in (C D E F X) do call :sonde %%D',
            'pause',
            'if exist "C:\x" (',
            'echo  ATTENTION !',
            'type "C:\Windows\System32\config\SYSTEM"',
            'set "WINVOL=C:"',
            '%DO%copy /b /y "%SRC%" "%CFG%\SYSTEM"'
        )
        $raw = [System.IO.File]::ReadAllText($honte)
        @(Get-KitBatchNonAscii        -Bytes ([byte[]](0xE9))).Count | Should -BeGreaterThan 0
        @(Get-KitBatchLoneLf          -Bytes ([byte[]](0x61, 0x0A))).Count | Should -BeGreaterThan 0
        @(Get-KitBatchPipe            -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchForbiddenExe    -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchHardcodedLetter -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchLetterLoopWithX -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchUnguardedPause  -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchOpenBlock       -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchEchoBang        -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchTypeOnFile      -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-KitBatchUnloggedDo      -Content $raw).Count | Should -BeGreaterThan 0
        @(Get-WinReBatchViolations    -Content $raw).Count | Should -BeGreaterThan 7
    }
}

Describe 'l''oracle mord sur le vrai secours.bat muté' {
    # Une fixture de trois lignes ne prouve pas qu'une règle survit à 750 lignes
    # de contexte. Ici le défaut est injecté dans le CONTENU RÉEL, et le compte
    # doit passer de 0 à au moins 1. C'est la contre-épreuve qui manquait à
    # l'oracle d'origine, celui dont le compte valait 1 quoi qu'il arrive.

    It 'muté par <Nom>, <Regle> passe de 0 à au moins une violation' -ForEach @(
        @{ Nom = 'un binaire absent du WinRE';          Regle = 'Get-KitBatchForbiddenExe';    Ligne = 'findstr /i x fichier.txt' }
        @{ Nom = 'une commande enchaînée par &';        Regle = 'Get-KitBatchForbiddenExe';    Ligne = 'dir /b & diskpart /s script.txt' }
        @{ Nom = 'un binaire caché dans un for /f';     Regle = 'Get-KitBatchForbiddenExe';    Ligne = 'for /f "delims=" %%X in (''vssadmin list shadows'') do echo %%X' }
        @{ Nom = 'wpeutil exécuté au lieu d''affiché';  Regle = 'Get-KitBatchForbiddenExe';    Ligne = 'wpeutil reboot' }
        @{ Nom = 'manage-bde exécuté';                  Regle = 'Get-KitBatchForbiddenExe';    Ligne = 'manage-bde -unlock %WINVOL% -RecoveryPassword %CLE%' }
        @{ Nom = 'un cmd /c qui relance un binaire';    Regle = 'Get-KitBatchForbiddenExe';    Ligne = 'cmd /c vssadmin list shadows' }
        @{ Nom = 'un tube';                             Regle = 'Get-KitBatchPipe';            Ligne = 'dir | more' }
        @{ Nom = 'une lettre de volume en dur';         Regle = 'Get-KitBatchHardcodedLetter'; Ligne = 'copy "D:\fichier" "E:\"' }
        @{ Nom = 'une lettre nue sur WINVOL';           Regle = 'Get-KitBatchHardcodedLetter'; Ligne = 'set "WINVOL=C:"' }
        @{ Nom = 'un chkdsk sur une lettre nue';        Regle = 'Get-KitBatchHardcodedLetter'; Ligne = 'chkdsk C: /f' }
        @{ Nom = 'une trace %DO% hors journal';         Regle = 'Get-KitBatchUnloggedDo';      Ligne = '%DO%copy /b /y "%SRC%" "%CFG%\%HIVE%"' }
        @{ Nom = 'une exclamation de ponctuation';      Regle = 'Get-KitBatchEchoBang';        Ligne = 'echo  Attention ! ne redemarrez pas' }
        @{ Nom = 'un type sur une ruche';               Regle = 'Get-KitBatchTypeOnFile';      Ligne = 'type "%CFG%\SYSTEM"' }
        @{ Nom = 'un bloc if à parenthèse';             Regle = 'Get-KitBatchOpenBlock';       Ligne = 'if exist "%CFG%\%HIVE%" (' }
        @{ Nom = 'une pause nue';                       Regle = 'Get-KitBatchUnguardedPause';  Ligne = 'pause' }
    ) {
        foreach ($b in $script:WinReBatches) {
            @(& $Regle -Content $b.Raw).Count | Should -Be 0 -Because "$($b.Name) est propre au départ"
            $mute = $b.Raw + $Ligne + "`r`n"
            @(& $Regle -Content $mute).Count | Should -BeGreaterThan 0 -Because "$Regle doit relever [$Ligne]"
        }
    }

    It 'muté en ajoutant X aux boucles de lettres, la règle 5 bis crie' {
        foreach ($b in $script:WinReBatches) {
            @(Get-KitBatchLetterLoopWithX -Content $b.Raw).Count | Should -Be 0
            $mute = $b.Raw -replace '\(C D E F', '(C D E F X'
            $mute | Should -Not -Be $b.Raw -Because 'la mutation doit vraiment mordre dans le fichier'
            @(Get-KitBatchLetterLoopWithX -Content $mute).Count | Should -BeGreaterThan 0
        }
    }

    It 'muté en retirant la garde SECOURS_DRYRUN des pause, la règle 6 crie' {
        foreach ($b in $script:WinReBatches) {
            @(Get-KitBatchUnguardedPause -Content $b.Raw).Count | Should -Be 0
            $mute = $b.Raw -replace '(?i)if not defined SECOURS_DRYRUN pause', 'pause'
            $mute | Should -Not -Be $b.Raw -Because 'la mutation doit vraiment mordre dans le fichier'
            @(Get-KitBatchUnguardedPause -Content $mute).Count | Should -BeGreaterThan 0
        }
    }

    It 'muté d''un octet accentué ou d''un LF isolé, les règles 1 et 2 crient' {
        foreach ($b in $script:WinReBatches) {
            @(Get-KitBatchNonAscii -Bytes $b.Bytes).Count | Should -Be 0
            @(Get-KitBatchNonAscii -Bytes ([byte[]]($b.Bytes + [byte]0xE9))).Count | Should -Be 1
            @(Get-KitBatchLoneLf   -Bytes $b.Bytes).Count | Should -Be 0
            @(Get-KitBatchLoneLf   -Bytes ([byte[]]($b.Bytes + [byte]0x61 + [byte]0x0A))).Count | Should -Be 1
        }
    }
}
