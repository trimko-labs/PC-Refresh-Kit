# tests/Invoke-SmokeTest.ps1 - Harnais smoke-test des modules du kit.
# Lance chaque module en process enfant -WhatIf (lecture seule, aucune action modifiante) et vérifie
# exit 0 + absence de [ERROR] dans le log produit. Cible la classe de bugs
# StrictMode (PropertyNotFoundStrict) que les tests regex ne voient pas.
# Requiert une session ADMIN (les modules font Assert-Admin) : conçu pour le
# runner GitHub Actions windows-latest (admin d'office), jamais un poste de production.
# Encodage : UTF-8 avec BOM.
[CmdletBinding()]
param(
    [string[]]$Exclude = @('05', '06', '08'),   # 05/06 : appels réseau/winget lourds. 08-Accounts : son garde-fou anti-lockout sort en 1 sur une machine mono-admin (le runner CI n'a qu'un seul compte admin), comportement correct et non testable en smoke ici. Exclusions loguées dans le bilan (jamais silencieuses).
    [int]$TimeoutSec = 180,
    [switch]$CI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Get-ModuleSmokeArgs : arguments de smoke selon les paramètres supportés.
# Toujours -WhatIf (lecture seule) ; -Unattended si le module l'accepte (évite
# tout Read-Host résiduel). PURE/testable.
# ---------------------------------------------------------------------------
function Get-ModuleSmokeArgs {
    [CmdletBinding()]
    param([AllowNull()][string[]]$SupportedParams)
    $names = @($SupportedParams | ForEach-Object { [string]$_ })
    $result = @('-WhatIf')
    if ($names -contains 'Unattended') { $result += '-Unattended' }
    return ,@($result)
}

# ---------------------------------------------------------------------------
# Get-ScriptParamNames : noms des paramètres du param() de tête via AST.
# PURE/testable (pas d'exécution du script cible). Retour tableau forcé.
# ---------------------------------------------------------------------------
function Get-ScriptParamNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $names = @()
    if ($ast.ParamBlock -and $ast.ParamBlock.Parameters) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $names += [string]$p.Name.VariablePath.UserPath
        }
    }
    return ,@($names)
}

# ---------------------------------------------------------------------------
# Get-SmokeStrictModeHits : nombre d'erreurs StrictMode PropertyNotFoundStrict
# dans le flux d'erreur d'un module (accès à une propriété absente au runtime).
# C'est LA classe de bug que ce harnais cible : elle ne va pas dans le log KIT
# mais sur le flux d'erreur. PURE/testable. Le FullyQualifiedErrorId est
# indépendant de la langue du runner.
# ---------------------------------------------------------------------------
function Get-SmokeStrictModeHits {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$StdErr)
    if ([string]::IsNullOrEmpty($StdErr)) { return 0 }
    return @([regex]::Matches($StdErr, 'PropertyNotFoundStrict')).Count
}

# ---------------------------------------------------------------------------
# Invoke-SmokeTest : lance le smoke sur tous les modules non exclus.
# Retourne le nombre de modules en échec (0 = succès). Écrit un résumé.
# ---------------------------------------------------------------------------
function Invoke-SmokeTest {
    [CmdletBinding()]
    param(
        [string[]]$Exclude = @('05', '06', '08'),   # voir la note du param de tete : 08 exclu (garde-fou anti-lockout sur runner mono-admin)
        [int]$TimeoutSec = 180,
        [switch]$CI
    )
    $root       = Split-Path $PSScriptRoot -Parent
    $modulesDir = Join-Path $root 'modules'
    $smokeRoot  = Join-Path $root 'runtime\smoke'
    if (-not (Test-Path $smokeRoot)) { New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null }

    $modules = @(Get-ChildItem -Path $modulesDir -Filter '*.ps1' | Sort-Object Name)
    $failures = 0
    $ran = 0

    foreach ($m in $modules) {
        $id = $m.Name.Substring(0, 2)
        if ($Exclude -contains $id) {
            Write-Host "[SMOKE] SKIP $($m.Name) (exclu)" -ForegroundColor DarkGray
            continue
        }
        $ran++
        $params  = Get-ScriptParamNames -Path $m.FullName
        $modArgs = Get-ModuleSmokeArgs -SupportedParams $params
        $logFile = Join-Path $smokeRoot ("smoke-{0}.log" -f $m.BaseName)
        if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }

        $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $m.FullName) + $modArgs
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'powershell.exe'
        $psi.Arguments              = ($cliArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardError  = $true   # capture le flux d'erreur pour détecter les erreurs StrictMode runtime
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $root
        $psi.EnvironmentVariables['KIT_LOG_FILE'] = $logFile

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()   # tout Read-Host résiduel reçoit EOF (anti-blocage)
        # Lecture asynchrone du flux d'erreur : évite le deadlock si le buffer se remplit
        # pendant que le harnais attend la fin du process.
        $stdErrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            Write-Host "[SMOKE] FAIL $($m.Name) : TIMEOUT ($TimeoutSec s)" -ForegroundColor Red
            $failures++
            continue
        }
        $exit = $proc.ExitCode
        $stdErr = ''
        try { $stdErr = [string]$stdErrTask.Result } catch { }

        $errLines = @()
        if (Test-Path $logFile) {
            $errLines = @(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\[ERROR\]' })
        }
        # Erreurs StrictMode PropertyNotFoundStrict au runtime : LA classe de bug ciblée par ce
        # harnais. Elles vont sur le flux d'erreur (pas dans le log KIT) et sont non terminantes,
        # donc un module peut sortir 0 tout en étant bogué. On les traite comme un échec.
        $strictHits = Get-SmokeStrictModeHits -StdErr $stdErr
        if ($exit -eq 0 -and $errLines.Count -eq 0 -and $strictHits -eq 0) {
            Write-Host "[SMOKE] OK   $($m.Name) (args: $($modArgs -join ' '))" -ForegroundColor Green
        }
        else {
            Write-Host "[SMOKE] FAIL $($m.Name) : exit=$exit, [ERROR]=$($errLines.Count), StrictMode=$strictHits" -ForegroundColor Red
            foreach ($e in ($errLines | Select-Object -First 5)) { Write-Host "         $e" -ForegroundColor Red }
            if ($strictHits -gt 0) {
                $strictLines = @($stdErr -split "`r?`n" | Where-Object { $_ -match 'cannot be found|introuvable|PropertyNotFoundStrict' } | Select-Object -First 6)
                foreach ($e in $strictLines) { Write-Host "         [StrictMode] $($e.Trim())" -ForegroundColor Red }
            }
            $failures++
        }
    }

    Write-Host ""
    Write-Host "[SMOKE] Bilan : $($ran - $failures)/$ran OK, $failures échec(s), $(@($Exclude).Count) exclu(s) : $($Exclude -join ', ')" -ForegroundColor $(if ($failures -eq 0) { 'Green' } else { 'Red' })
    if ($CI) { exit ([math]::Min($failures, 255)) }
    return $failures
}

# Point d'entrée : exécuté seulement si le script est lancé directement
# (pas quand il est dot-sourcé par les tests Pester).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SmokeTest -Exclude $Exclude -TimeoutSec $TimeoutSec -CI:$CI
}
