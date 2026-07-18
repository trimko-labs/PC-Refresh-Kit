Set-StrictMode -Version Latest
BeforeAll {
    . "$PSScriptRoot\Test-KitEncoding.ps1"
}

Describe 'Test-KitEncoding' {
    It 'valide un contenu propre avec BOM' {
        $r = Test-KitEncoding -Content "param()`nWrite-Host 'ok'`n" -HasBom $true
        $r.Ok | Should -BeTrue
    }
    It 'rejette un contenu sans BOM' {
        $r = Test-KitEncoding -Content "Write-Host 'ok'" -HasBom $false
        $r.Ok | Should -BeFalse
        $r.HasBom | Should -BeFalse
    }
    It 'détecte un em-dash (U+2014)' {
        $r = Test-KitEncoding -Content ("a" + [char]0x2014 + "b") -HasBom $true
        $r.Ok | Should -BeFalse
        $r.ForbiddenChars | Should -Not -BeNullOrEmpty
    }
    It 'détecte un en-dash (U+2013)' {
        $r = Test-KitEncoding -Content ("a" + [char]0x2013 + "b") -HasBom $true
        $r.Ok | Should -BeFalse
    }
    It 'accepte les accents francais et le tiret simple' {
        $r = Test-KitEncoding -Content "échéance régularisée - ok à Paris" -HasBom $true
        $r.Ok | Should -BeTrue
    }
    It 'rejette un contenu sans newline finale' {
        $r = Test-KitEncoding -Content "param()" -HasBom $true -EndsWithNewline $false
        $r.Ok | Should -BeFalse
    }
}
