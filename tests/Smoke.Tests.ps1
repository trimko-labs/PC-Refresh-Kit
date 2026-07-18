# tests/Smoke.Tests.ps1 - Tests Pester v5 des fonctions pures du harnais smoke.
# Lancer : Invoke-Pester .\tests\Smoke.Tests.ps1 -Output Detailed
# Encodage : UTF-8 avec BOM.

Set-StrictMode -Version Latest
BeforeAll {
    . "$PSScriptRoot\Invoke-SmokeTest.ps1"
}

Describe 'Get-ModuleSmokeArgs' {
    It 'inclut toujours -WhatIf' {
        $a = Get-ModuleSmokeArgs -SupportedParams @('WhatIf','Force')
        $a | Should -Contain '-WhatIf'
    }
    It 'ajoute -Unattended quand le module le supporte' {
        $a = Get-ModuleSmokeArgs -SupportedParams @('WhatIf','Unattended','Force')
        $a | Should -Contain '-Unattended'
    }
    It "n'ajoute pas -Unattended quand le module ne le supporte pas" {
        $a = Get-ModuleSmokeArgs -SupportedParams @('WhatIf','Force')
        $a | Should -Not -Contain '-Unattended'
    }
    It 'ne renvoie jamais $null et reste un tableau même sur entrée vide' {
        $a = Get-ModuleSmokeArgs -SupportedParams @()
        ,$a | Should -BeOfType [System.Object[]]
        $a | Should -Contain '-WhatIf'
    }
}

Describe 'Get-ScriptParamNames' {
    It 'extrait les noms de paramètres du param() de tête' {
        $tmp = Join-Path $TestDrive 'sample.ps1'
        Set-Content -Path $tmp -Value "param([switch]`$WhatIf,[switch]`$Unattended)`nWrite-Host 'x'" -Encoding UTF8
        $names = Get-ScriptParamNames -Path $tmp
        $names | Should -Contain 'WhatIf'
        $names | Should -Contain 'Unattended'
    }
    It 'renvoie un tableau vide (jamais $null) pour un script sans param()' {
        $tmp = Join-Path $TestDrive 'noparam.ps1'
        Set-Content -Path $tmp -Value "Write-Host 'x'" -Encoding UTF8
        $names = Get-ScriptParamNames -Path $tmp
        ,$names | Should -BeOfType [System.Object[]]
        @($names).Count | Should -Be 0
    }
}

Describe 'Invoke-SmokeTest (contrat)' {
    It 'expose le switch -CI sur la fonction' {
        (Get-Command Invoke-SmokeTest).Parameters.Keys | Should -Contain 'CI'
    }
}

Describe 'Get-SmokeStrictModeHits' {
    It 'compte les occurrences de PropertyNotFoundStrict dans le flux d''erreur' {
        $err = "bla`n    + FullyQualifiedErrorId : PropertyNotFoundStrict`nautre`n    + FullyQualifiedErrorId : PropertyNotFoundStrict"
        Get-SmokeStrictModeHits -StdErr $err | Should -Be 2
    }
    It 'retourne 0 sur un flux d''erreur vide, null ou sans erreur StrictMode' {
        Get-SmokeStrictModeHits -StdErr ''        | Should -Be 0
        Get-SmokeStrictModeHits -StdErr $null     | Should -Be 0
        Get-SmokeStrictModeHits -StdErr 'RAS ici' | Should -Be 0
    }
}
