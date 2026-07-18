# tests/Test-KitParse.ps1 - Vérifie que tous les .ps1 du kit parsent sans
# erreur de syntaxe (AST). Rejoue en CI et en local. Encodage : UTF-8 avec BOM.
[CmdletBinding()]
param([switch]$CI)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-KitParse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    $msgs = @()
    if ($errors) { $msgs = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) }
    return [PSCustomObject]@{ Path = $Path; Ok = ($msgs.Count -eq 0); Errors = $msgs }
}

if ($MyInvocation.InvocationName -ne '.') {
    $root  = Split-Path $PSScriptRoot -Parent
    $files = @(Get-ChildItem -Path $root -Recurse -Filter '*.ps1' -File |
               Where-Object { $_.FullName -notmatch '\\vendor\\' -and $_.FullName -notmatch '\\\.git\\' })
    $bad = 0
    foreach ($f in $files) {
        $r = Test-KitParse -Path $f.FullName
        if (-not $r.Ok) {
            Write-Host "[PARSE] FAIL $($f.Name)" -ForegroundColor Red
            foreach ($e in $r.Errors) { Write-Host "        $e" -ForegroundColor Red }
            $bad++
        }
    }
    Write-Host "[PARSE] $($files.Count) fichier(s), $bad en erreur" -ForegroundColor $(if ($bad -eq 0) { 'Green' } else { 'Red' })
    if ($CI) { exit ([math]::Min($bad, 255)) }
}
