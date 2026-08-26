Set-StrictMode -Version Latest
BeforeAll {
    . "$PSScriptRoot\Test-KitAnonymity.ps1"
}

Describe 'Test-IsRegistryHive' {
    It 'reconnait une ruche de registre (entête regf)' {
        $p = Join-Path $TestDrive 'SYSTEM'
        [System.IO.File]::WriteAllBytes($p, [byte[]](0x72, 0x65, 0x67, 0x66, 0x00, 0x01, 0x02, 0x03))
        Test-IsRegistryHive -LiteralPath $p | Should -BeTrue
    }
    It 'traite un nom a crochets sans interpretation wildcard' {
        $p = Join-Path $TestDrive 'SAM[old]'
        [System.IO.File]::WriteAllBytes($p, [byte[]](0x72, 0x65, 0x67, 0x66, 0x00, 0x01, 0x02, 0x03))
        Test-IsRegistryHive -LiteralPath $p | Should -BeTrue
    }
    It 'ignore un fichier texte' {
        $p = Join-Path $TestDrive 'notes.txt'
        [System.IO.File]::WriteAllText($p, "juste du texte, aucun secret")
        Test-IsRegistryHive -LiteralPath $p | Should -BeFalse
    }
    It 'ignore un binaire non-ruche (entête PNG)' {
        $p = Join-Path $TestDrive 'image.png'
        [System.IO.File]::WriteAllBytes($p, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        Test-IsRegistryHive -LiteralPath $p | Should -BeFalse
    }
    It 'ignore un fichier trop court pour porter l''entête' {
        $p = Join-Path $TestDrive 'court'
        [System.IO.File]::WriteAllBytes($p, [byte[]](0x72, 0x65))
        Test-IsRegistryHive -LiteralPath $p | Should -BeFalse
    }
    It 'renvoie faux sur un chemin absent, sans lever d''exception' {
        Test-IsRegistryHive -LiteralPath (Join-Path $TestDrive 'inexistant.bin') | Should -BeFalse
    }
    It 'leve sur un fichier present mais verrouille (fail-closed, pas de faux negatif)' {
        $p = Join-Path $TestDrive 'lockedhive'
        [System.IO.File]::WriteAllBytes($p, [byte[]](0x72, 0x65, 0x67, 0x66, 0x00, 0x00, 0x00, 0x00))
        $lock = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try { { Test-IsRegistryHive -LiteralPath $p } | Should -Throw }
        finally { $lock.Dispose() }
    }
}
