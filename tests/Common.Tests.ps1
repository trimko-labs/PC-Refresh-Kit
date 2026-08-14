# tests/Common.Tests.ps1 - Tests Pester v5 des fonctions pures de lib/Common.ps1
# Lancer : Invoke-Pester .\tests\Common.Tests.ps1 -Output Detailed

BeforeAll {
    # Charger la librairie - simuler un fichier log temporaire pour éviter la création de log réel
    $script:KitLogFile = Join-Path $env:TEMP "pester-test-$(New-Guid).log"
    . "$PSScriptRoot\..\lib\Common.ps1"
}

AfterAll {
    if (Test-Path $script:KitLogFile) { Remove-Item $script:KitLogFile -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-FileRotation' {

    BeforeEach {
        $testDir = Join-Path $env:TEMP "pester-rotation-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $testDir | Out-Null
    }

    AfterEach {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'conserve exactement N fichiers et supprime le reste' {
        # Créer 7 fichiers .log avec des dates espacées
        for ($i = 1; $i -le 7; $i++) {
            $f = New-Item -ItemType File -Path "$testDir\test-$i.log" -Force
            $f.LastWriteTime = (Get-Date).AddMinutes(-$i)
        }

        Invoke-FileRotation -Path $testDir -Pattern '*.log' -Keep 3

        $remaining = Get-ChildItem -Path $testDir -Filter '*.log'
        $remaining.Count | Should -Be 3
    }

    It 'garde les fichiers les plus récents' {
        for ($i = 1; $i -le 5; $i++) {
            $f = New-Item -ItemType File -Path "$testDir\test-$i.log" -Force
            $f.LastWriteTime = (Get-Date).AddMinutes(-$i)
        }

        Invoke-FileRotation -Path $testDir -Pattern '*.log' -Keep 2

        $remaining = Get-ChildItem -Path $testDir -Filter '*.log' | Sort-Object LastWriteTime -Descending
        $remaining[0].Name | Should -Be 'test-1.log'
        $remaining[1].Name | Should -Be 'test-2.log'
    }

    It 'ne supprime rien si le nombre de fichiers est inférieur ou égal à Keep' {
        for ($i = 1; $i -le 3; $i++) {
            New-Item -ItemType File -Path "$testDir\test-$i.log" -Force | Out-Null
        }

        Invoke-FileRotation -Path $testDir -Pattern '*.log' -Keep 5

        $remaining = Get-ChildItem -Path $testDir -Filter '*.log'
        $remaining.Count | Should -Be 3
    }

    It 'ne touche pas aux fichiers hors pattern' {
        New-Item -ItemType File -Path "$testDir\keep.txt" -Force | Out-Null
        for ($i = 1; $i -le 5; $i++) {
            $f = New-Item -ItemType File -Path "$testDir\test-$i.log" -Force
            $f.LastWriteTime = (Get-Date).AddMinutes(-$i)
        }

        Invoke-FileRotation -Path $testDir -Pattern '*.log' -Keep 2

        Test-Path "$testDir\keep.txt" | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
Describe 'New-StrongPassword' {

    It 'retourne un mot de passe de la longueur demandée' {
        $pwd = New-StrongPassword -Length 16
        $pwd.Length | Should -Be 16
    }

    It 'retourne un mot de passe de longueur personnalisée' {
        $pwd = New-StrongPassword -Length 24
        $pwd.Length | Should -Be 24
    }

    It 'contient au moins une majuscule' {
        $pwd = New-StrongPassword -Length 16
        $pwd | Should -Match '[A-Z]'
    }

    It 'contient au moins une minuscule' {
        $pwd = New-StrongPassword -Length 16
        $pwd | Should -Match '[a-z]'
    }

    It 'contient au moins un chiffre' {
        $pwd = New-StrongPassword -Length 16
        $pwd | Should -Match '[0-9]'
    }

    It 'contient au moins un symbole' {
        $pwd = New-StrongPassword -Length 16
        $pwd | Should -Match '[@#$%&*!?+]'
    }

    It 'deux appels produisent des mots de passe différents' {
        $pwd1 = New-StrongPassword -Length 16
        $pwd2 = New-StrongPassword -Length 16
        # Probabilité de collision astronomiquement faible
        $pwd1 | Should -Not -Be $pwd2
    }
}

# ---------------------------------------------------------------------------
Describe 'New-StrongPassword - mode aléatoire CSPRNG' {
    It 'garantit les 4 classes de caractères' {
        $pw = New-StrongPassword -Length 16
        $pw | Should -Match '[A-Z]'
        $pw | Should -Match '[a-z]'
        $pw | Should -Match '[2-9]'
        $pw | Should -Match '[@#\$%&\*!\?\+]'
    }
    It 'respecte la longueur demandée' {
        (New-StrongPassword -Length 20).Length | Should -Be 20
    }
    It "n'utilise plus Get-Random dans le corps de la fonction" {
        $src = (Get-Command New-StrongPassword).ScriptBlock.ToString()
        $src | Should -Not -Match 'Get-Random'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DiskType (via objet simulé)' {

    It 'retourne SSD pour un disque de type SSD' {
        $simSSD = [PSCustomObject]@{ MediaType = 'SSD' }
        Get-DiskType -SimulatedDisk $simSSD | Should -Be 'SSD'
    }

    It 'retourne HDD pour un disque de type HDD' {
        $simHDD = [PSCustomObject]@{ MediaType = 'HDD' }
        Get-DiskType -SimulatedDisk $simHDD | Should -Be 'HDD'
    }

    It 'retourne UNKNOWN pour un type non reconnu' {
        $simUnk = [PSCustomObject]@{ MediaType = 'Unspecified' }
        Get-DiskType -SimulatedDisk $simUnk | Should -Be 'UNKNOWN'
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertFrom-MediaType' {
    It 'mappe les libellés texte' {
        ConvertFrom-MediaType 'SSD' | Should -Be 'SSD'
        ConvertFrom-MediaType 'HDD' | Should -Be 'HDD'
    }
    It 'mappe les valeurs numériques MSFT_PhysicalDisk (3=HDD, 4=SSD, 5=SCM)' {
        ConvertFrom-MediaType '4' | Should -Be 'SSD'
        ConvertFrom-MediaType '3' | Should -Be 'HDD'
        ConvertFrom-MediaType '5' | Should -Be 'SSD'
    }
    It 'retourne UNKNOWN sur Unspecified, 0, null ou inconnu' {
        ConvertFrom-MediaType 'Unspecified' | Should -Be 'UNKNOWN'
        ConvertFrom-MediaType '0'           | Should -Be 'UNKNOWN'
        ConvertFrom-MediaType $null         | Should -Be 'UNKNOWN'
        ConvertFrom-MediaType 'Bidon'       | Should -Be 'UNKNOWN'
    }
}

# ---------------------------------------------------------------------------
Describe 'Parsing apps.json' {

    BeforeAll {
        $appsJsonPath = Join-Path $env:TEMP "pester-apps-$(New-Guid).json"
        $sample = @(
            @{ name = 'Firefox';    wingetId = 'Mozilla.Firefox';   optional = $false },
            @{ name = '7-Zip';      wingetId = '7zip.7zip';         optional = $false },
            @{ name = 'Brave';      wingetId = 'Brave.Brave';       optional = $true  }
        ) | ConvertTo-Json
        Set-Content -Path $appsJsonPath -Value $sample -Encoding UTF8
    }

    AfterAll {
        Remove-Item $appsJsonPath -Force -ErrorAction SilentlyContinue
    }

    It 'parse correctement le JSON et retourne 3 éléments' {
        $apps = Get-Content $appsJsonPath -Encoding UTF8 | ConvertFrom-Json
        $apps.Count | Should -Be 3
    }

    It 'identifie correctement les apps optionnelles' {
        $apps = Get-Content $appsJsonPath -Encoding UTF8 | ConvertFrom-Json
        # PS 5.1 + StrictMode : .Count sur un objet unique (Where-Object a 1 resultat) leve
        # PropertyNotFoundStrict ; on force un tableau avec @() pour un .Count/[0] robustes.
        $optional = @($apps | Where-Object { $_.optional -eq $true })
        $optional.Count | Should -Be 1
        $optional[0].wingetId | Should -Be 'Brave.Brave'
    }

    It 'identifie correctement les apps non optionnelles' {
        $apps = Get-Content $appsJsonPath -Encoding UTF8 | ConvertFrom-Json
        $required = $apps | Where-Object { $_.optional -eq $false }
        $required.Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
Describe 'New-StrongPassword -Passphrase' {

    It 'génère 3 mots et 2 chiffres séparés par des tirets par défaut' {
        $p = New-StrongPassword -Passphrase
        # Format attendu : Mot-Mot-Mot-NN. Chiffres dans [2-9] (le code exclut 0 et 1, confusion O/l).
        $p | Should -Match '^[A-Z][a-z]+-[A-Z][a-z]+-[A-Z][a-z]+-[2-9]{2}$'
    }

    It 'respecte le nombre de mots demandé' {
        $p = New-StrongPassword -Passphrase -WordCount 2
        # 2 mots + bloc de chiffres = 3 segments séparés par tirets
        ($p -split '-').Count | Should -Be 3
    }

    It 'capitalise chaque mot' {
        $p = New-StrongPassword -Passphrase -WordCount 4
        $words = ($p -split '-') | Select-Object -First 4
        foreach ($w in $words) { $w | Should -Match '^[A-Z][a-z]+$' }
    }

    It 'ne contient aucun caractère accentué' {
        $p = New-StrongPassword -Passphrase
        $p | Should -Match '^[A-Za-z0-9-]+$'
    }

    It 'deux appels produisent des résultats différents' {
        (New-StrongPassword -Passphrase) | Should -Not -Be (New-StrongPassword -Passphrase)
    }

    It 'conserve le mode aléatoire historique quand -Passphrase est absent' {
        (New-StrongPassword -Length 16).Length | Should -Be 16
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertFrom-AvProductState' {
    It 'décode Defender actif et à jour (0x061000)' {
        $r = ConvertFrom-AvProductState -State 397312   # 0x061000
        $r.RealTimeEnabled | Should -Be $true
        $r.UpToDate        | Should -Be $true
    }
    It 'décode un AV avec temps réel désactivé (0x060000)' {
        $r = ConvertFrom-AvProductState -State 393216    # 0x060000
        $r.RealTimeEnabled | Should -Be $false
    }
    It 'décode un AV actif mais signatures périmées (0x061010)' {
        $r = ConvertFrom-AvProductState -State 397328    # 0x061010
        $r.RealTimeEnabled | Should -Be $true
        $r.UpToDate        | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-RebootMarkersFromLogs' {
    It 'remonte les lignes contenant un marqueur de reboot' {
        $lines = @(
            '[2026-06-27 10:00:00] [OK] Rien a signaler',
            '[2026-06-27 10:01:00] [WARN] REBOOT REQUIS pour finaliser les mises a jour',
            '[2026-06-27 10:02:00] [OK] msiexec code 3010 reboot requis'
        )
        (Get-RebootMarkersFromLogs -Lines $lines).Count | Should -Be 2
    }
    It 'retourne un tableau vide si aucun marqueur' {
        (Get-RebootMarkersFromLogs -Lines @('[OK] tout va bien')).Count | Should -Be 0
    }
    It 'gère une entrée nulle sans planter' {
        (Get-RebootMarkersFromLogs -Lines $null).Count | Should -Be 0
    }
    It 'retourne un vrai tableau (pas $null) même à vide, sous StrictMode Latest' {
        # Régression run réel : @() retourné par une fonction est déroulé en $null
        # par le pipeline ; sous StrictMode Latest, $null.Count lève. On vérifie que
        # .Count fonctionne dans les deux cas sans erreur, strict mode actif.
        Set-StrictMode -Version Latest
        try {
            $empty = Get-RebootMarkersFromLogs -Lines @('[OK] rien')
            $empty.Count | Should -Be 0
            $none = Get-RebootMarkersFromLogs -Lines $null
            $none.Count | Should -Be 0
        }
        finally {
            Set-StrictMode -Version 1
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-JsonProp (accès défensif propriété JSON)' {
    It 'retourne la valeur quand la propriété existe' {
        $o = [pscustomobject]@{ Name = 'Kaspersky' }
        Get-JsonProp $o 'Name' | Should -Be 'Kaspersky'
    }
    It 'retourne $null quand la propriété est absente (au lieu de lever)' {
        $o = [pscustomobject]@{ Name = 'x' }
        Get-JsonProp $o 'displayName' | Should -Be $null
    }
    It 'retourne $null quand l objet est $null' {
        Get-JsonProp $null 'Name' | Should -Be $null
    }
    It 'ne lève pas sur propriété absente sous StrictMode Latest' {
        # Régression : `$diag.cpu` sur un diag sans 'cpu' lève sous StrictMode
        # (PropertyNotFoundStrict). Get-JsonProp doit renvoyer $null sans erreur.
        Set-StrictMode -Version Latest
        try {
            $diag = [pscustomobject]@{ machine = [pscustomobject]@{ Manufacturer = 'ASUS' } }
            Get-JsonProp $diag 'cpu' | Should -Be $null
            $mc = Get-JsonProp $diag 'machine'
            Get-JsonProp $mc 'Manufacturer' | Should -Be 'ASUS'
            Get-JsonProp $mc 'OSBuild' | Should -Be $null
        }
        finally {
            Set-StrictMode -Version 1
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DebloatDecision (classifieur conditionnel)' {
    It 'garde le groupe Xbox si Game Pass détecté' {
        (Get-DebloatDecision -Detect 'gamepass' -InUse $true -Unattended $true).Action | Should -Be 'KEEP'
    }
    It 'supprime le groupe Xbox en -All si pas de Game Pass' {
        (Get-DebloatDecision -Detect 'gamepass' -InUse $false -Unattended $true).Action | Should -Be 'REMOVE'
    }
    It 'garde une app usage en -All si données utilisateur présentes' {
        (Get-DebloatDecision -Detect 'usage' -InUse $true -Unattended $true).Action | Should -Be 'KEEP'
    }
    It 'demande (PROMPT) en interactif si non utilisé' {
        (Get-DebloatDecision -Detect 'usage' -InUse $false -Unattended $false).Action | Should -Be 'PROMPT'
    }
}

# ---------------------------------------------------------------------------
Describe '01-Backup.ps1 (module backup et point de restauration)' {
    It 'accepte le paramètre -SkipDataBackup sans erreur de syntaxe' {
        # Vérifier que le paramètre existe (test de syntaxe)
        $scriptContent = Get-Content "$PSScriptRoot\..\modules\01-Backup.ps1" -Raw
        $scriptContent | Should -Match '\[switch\]\$SkipDataBackup'
    }

    It 'gère -SkipDataBackup dans la logique conditionnelle' {
        # Vérifier que le code utilise le paramètre
        $scriptContent = Get-Content "$PSScriptRoot\..\modules\01-Backup.ps1" -Raw
        $scriptContent | Should -Match 'elseif\s*\(\s*\$SkipDataBackup\s*\)'
    }

    It 'affiche message quand -SkipDataBackup est utilisé' {
        $scriptContent = Get-Content "$PSScriptRoot\..\modules\01-Backup.ps1" -Raw
        $scriptContent | Should -Match 'Backup data ignoré.*mode -SkipDataBackup'
    }
}

# ---------------------------------------------------------------------------
Describe '05-Updates.ps1 (winget error handling)' {
    It 'inclut retry logic pour les erreurs winget' {
        $scriptContent = Get-Content "$PSScriptRoot\..\modules\05-Updates.ps1" -Raw
        $scriptContent | Should -Match 'for\s*\(\s*\$attempt\s*='
    }

    It 'gère le code erreur 0x8A150042 via Test-WingetRetryableExitCode (comparaison int32 correcte)' {
        $scriptContent = Get-Content "$PSScriptRoot\..\modules\05-Updates.ps1" -Raw
        $scriptContent | Should -Match 'Test-WingetRetryableExitCode'
        # Le littéral 0x8a150042 ne doit PLUS apparaître : en PS 5.1 c'est un
        # int64 jamais égal à $LASTEXITCODE (int32) - le retry était mort.
        $scriptContent | Should -Not -Match '0x8a150042'
    }

    It 'affiche message d''aide si winget échoue' {
        $scriptContent = Get-Content "$PSScriptRoot\..\modules\05-Updates.ps1" -Raw
        $scriptContent | Should -Match 'Vous pouvez relancer manuellement'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ShortcutVerdict' {
    It 'DEAD si cible locale absente' {
        Get-ShortcutVerdict -TargetPath 'C:\Program Files\Gone\app.exe' -TargetExists $false | Should -Be 'DEAD'
    }
    It 'ALIVE si cible locale présente' {
        Get-ShortcutVerdict -TargetPath 'C:\Windows\notepad.exe' -TargetExists $true | Should -Be 'ALIVE'
    }
    It 'SKIP si cible vide (raccourci shell/URL)' {
        Get-ShortcutVerdict -TargetPath '' -TargetExists $false | Should -Be 'SKIP'
    }
    It 'SKIP si cible UNC réseau' {
        Get-ShortcutVerdict -TargetPath '\\serveur\partage\app.exe' -TargetExists $false | Should -Be 'SKIP'
    }
    It 'SKIP si cible non-disque (shell:::CLSID)' {
        Get-ShortcutVerdict -TargetPath 'shell:::{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -TargetExists $false | Should -Be 'SKIP'
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-ResidualPathAllowed' {
    BeforeAll { $roots = @('C:\Program Files', 'C:\ProgramData', 'C:\Users\Test\AppData\Local') }
    It 'autorise un sous-dossier strict d''une racine' {
        Test-ResidualPathAllowed -Path 'C:\Program Files\McAfee' -AllowedRoots $roots | Should -Be $true
    }
    It 'refuse la racine elle-même' {
        Test-ResidualPathAllowed -Path 'C:\Program Files' -AllowedRoots $roots | Should -Be $false
    }
    It 'refuse un chemin hors racines' {
        Test-ResidualPathAllowed -Path 'C:\Windows\System32' -AllowedRoots $roots | Should -Be $false
    }
    It 'refuse un chemin vide' {
        Test-ResidualPathAllowed -Path '' -AllowedRoots $roots | Should -Be $false
    }
    It 'insensible à la casse et au backslash final' {
        Test-ResidualPathAllowed -Path 'c:\program files\McAfee\' -AllowedRoots $roots | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-RemovedAppsFromLog' {
    It 'extrait les apps Supprimé et Provisioning supprimé' {
        $lines = @(
            '[2026-06-29 22:00:00] [OK] Supprimé : Microsoft.XboxApp',
            '[2026-06-29 22:00:01] [OK] Provisioning supprimé : Microsoft.BingNews',
            '[2026-06-29 22:00:02] [INFO] SKIP (absent) : Microsoft.GetHelp'
        )
        $r = Get-RemovedAppsFromLog -Lines $lines
        $r.Count | Should -Be 2
        $r | Should -Contain 'Microsoft.XboxApp'
        $r | Should -Contain 'Microsoft.BingNews'
    }
    It 'ignore les lignes "Service orphelin ... supprimé"' {
        $lines = @('[2026-06-29 22:00:00] [OK]   Service orphelin Foo supprimé : 0')
        (Get-RemovedAppsFromLog -Lines $lines).Count | Should -Be 0
    }
    It 'gère une entrée nulle sans planter' {
        (Get-RemovedAppsFromLog -Lines $null).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
Describe '11-DeepClean.ps1 (structure)' {
    It 'ne touche jamais au registre' {
        $c = Get-Content "$PSScriptRoot\..\modules\11-DeepClean.ps1" -Raw
        $c | Should -Not -Match 'Remove-Item.*HK(LM|CU):'
        $c | Should -Not -Match 'Remove-ItemProperty'
    }
    It 'utilise le garde-fou Test-ResidualPathAllowed avant toute suppression de dossier' {
        $c = Get-Content "$PSScriptRoot\..\modules\11-DeepClean.ps1" -Raw
        $c | Should -Match 'Test-ResidualPathAllowed'
    }
    It 'lit la liste blanche JSON' {
        $c = Get-Content "$PSScriptRoot\..\modules\11-DeepClean.ps1" -Raw
        $c | Should -Match 'deepclean-residuals\.json'
    }
    It 'n''invoque aucune commande DISM (déjà couvert par 07)' {
        # On cible un APPEL DISM ("DISM /..."), pas le mot dans un commentaire de synopsis.
        $c = Get-Content "$PSScriptRoot\..\modules\11-DeepClean.ps1" -Raw
        $c | Should -Not -Match 'DISM\s+/'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-StartupMatch' {
    BeforeAll {
        $bl = @(
            [PSCustomObject]@{ match = 'Spotify';      label = 'Spotify' },
            [PSCustomObject]@{ match = 'AdobeAAMUpdater'; label = 'Adobe Updater' }
        )
    }
    It 'matche par Name' {
        (Get-StartupMatch -Name 'Spotify' -Command 'C:\x\Spotify.exe' -Blacklist $bl).label | Should -Be 'Spotify'
    }
    It 'matche par Command si Name ne matche pas' {
        (Get-StartupMatch -Name 'Updater' -Command 'C:\Adobe\AdobeAAMUpdater\x.exe' -Blacklist $bl).label | Should -Be 'Adobe Updater'
    }
    It 'retourne $null si aucun match' {
        Get-StartupMatch -Name 'Steam' -Command 'C:\Steam.exe' -Blacklist $bl | Should -Be $null
    }
    It 'insensible à la casse' {
        (Get-StartupMatch -Name 'spotify' -Command '' -Blacklist $bl).label | Should -Be 'Spotify'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-StartupApprovedDisabledBytes' {
    It 'retourne 12 octets avec 0x03 en tête (désactivé)' {
        $b = Get-StartupApprovedDisabledBytes
        $b.Count | Should -Be 12
        $b[0] | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-StartupHiveFromLocation' {
    It 'HKLM Run -> HKLM' {
        Get-StartupHiveFromLocation -Location 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' | Should -Be 'HKLM-Run'
    }
    It 'HKU/HKCU Run -> HKCU' {
        Get-StartupHiveFromLocation -Location 'HKU\S-1-5-21-x\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' | Should -Be 'HKCU-Run'
    }
    It 'dossier Démarrage -> Folder' {
        Get-StartupHiveFromLocation -Location 'Startup' | Should -Be 'Folder'
    }
    It 'inconnu -> Unknown' {
        Get-StartupHiveFromLocation -Location 'Services' | Should -Be 'Unknown'
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-IsLogonOrBootTrigger' {
    It 'reconnaît un déclencheur logon' {
        Test-IsLogonOrBootTrigger -Trigger ([PSCustomObject]@{ CimClass = [PSCustomObject]@{ CimClassName = 'MSFT_TaskLogonTrigger' } }) | Should -Be $true
    }
    It 'reconnaît un déclencheur boot' {
        Test-IsLogonOrBootTrigger -Trigger ([PSCustomObject]@{ CimClass = [PSCustomObject]@{ CimClassName = 'MSFT_TaskBootTrigger' } }) | Should -Be $true
    }
    It 'rejette un autre type de déclencheur (time)' {
        Test-IsLogonOrBootTrigger -Trigger ([PSCustomObject]@{ CimClass = [PSCustomObject]@{ CimClassName = 'MSFT_TaskTimeTrigger' } }) | Should -Be $false
    }
    It 'retourne $false sur un déclencheur SANS propriété CimClass (bug réel DESKTOP-UHSEK7M)' {
        Test-IsLogonOrBootTrigger -Trigger ([PSCustomObject]@{ Foo = 'bar' }) | Should -Be $false
    }
    It 'gère CimClass présent mais sans CimClassName' {
        Test-IsLogonOrBootTrigger -Trigger ([PSCustomObject]@{ CimClass = [PSCustomObject]@{ Other = 1 } }) | Should -Be $false
    }
    It 'gère $null sans planter' {
        Test-IsLogonOrBootTrigger -Trigger $null | Should -Be $false
    }
    It 'ne lève JAMAIS sous StrictMode Latest, même sans propriété CimClass (cause racine du crash 12-Startup)' {
        Set-StrictMode -Version Latest
        { Test-IsLogonOrBootTrigger -Trigger ([PSCustomObject]@{ Foo = 'bar' }) } | Should -Not -Throw
        { Test-IsLogonOrBootTrigger -Trigger $null }                              | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-SearchEngineHijacked' {
    BeforeAll { $good = @('google.com','bing.com','duckduckgo.com','qwant.com','ecosia.org','yahoo.com') }
    It 'NON détourné pour un moteur connu' {
        Test-SearchEngineHijacked -Url 'https://www.google.com/search?q={searchTerms}' -KnownGood $good | Should -Be $false
    }
    It 'détourné pour un domaine inconnu' {
        Test-SearchEngineHijacked -Url 'https://search.mysearch-xyz.com/?q={searchTerms}' -KnownGood $good | Should -Be $true
    }
    It 'NON détourné si URL vide (rien à juger)' {
        Test-SearchEngineHijacked -Url '' -KnownGood $good | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-PupExtensionMatch' {
    BeforeAll { $bl = @('aaaabbbbccccddddeeeeffffgggghhhh','11112222333344445555666677778888') }
    It 'matche un ID dans la liste noire' {
        Get-PupExtensionMatch -ExtensionId 'aaaabbbbccccddddeeeeffffgggghhhh' -Blacklist $bl | Should -Be $true
    }
    It 'ne matche pas un ID hors liste' {
        Get-PupExtensionMatch -ExtensionId 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' -Blacklist $bl | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-KitConfig' {
    It 'retourne les valeurs par défaut si le fichier est absent' {
        $cfg = Get-KitConfig -Path (Join-Path $TestDrive 'absent.json')
        $cfg.wuSearchTimeoutMinutes  | Should -Be 10
        $cfg.wuInstallTimeoutMinutes | Should -Be 60
        $cfg.cleanmgrTimeoutMinutes  | Should -Be 30
        $cfg.downloadTimeoutSeconds  | Should -Be 60
        $cfg.diskWarnFreePct         | Should -Be 15
        $cfg.diskErrorFreePct        | Should -Be 5
        $cfg.restorePointMaxAgeHours | Should -Be 4
    }
    It 'les clés du fichier écrasent les défauts, les absentes restent aux défauts' {
        $p = Join-Path $TestDrive 'kit.json'
        Set-Content -Path $p -Value '{ "wuSearchTimeoutMinutes": 3, "diskWarnFreePct": 20 }' -Encoding UTF8
        $cfg = Get-KitConfig -Path $p
        $cfg.wuSearchTimeoutMinutes | Should -Be 3
        $cfg.diskWarnFreePct        | Should -Be 20
        $cfg.cleanmgrTimeoutMinutes | Should -Be 30
    }
    It 'retourne les défauts sur un fichier JSON invalide' {
        $p = Join-Path $TestDrive 'bad.json'
        Set-Content -Path $p -Value '{ pas du json' -Encoding UTF8
        (Get-KitConfig -Path $p).wuSearchTimeoutMinutes | Should -Be 10
    }
    It 'sans -Path, résout config/kit.json relatif à lib/ sans lever' {
        { Get-KitConfig } | Should -Not -Throw
    }
    It 'le fichier config/kit.json livré est du JSON valide avec BOM' {
        $kitJsonPath = Join-Path $PSScriptRoot '..\config\kit.json'
        $raw = [System.IO.File]::ReadAllBytes($kitJsonPath)
        # Vérifie le BOM UTF-8 : EF BB BF
        $raw[0] | Should -Be 0xEF
        $raw[1] | Should -Be 0xBB
        $raw[2] | Should -Be 0xBF
        # Vérifie que ConvertFrom-Json parse sans erreur et retourne la bonne valeur
        $parsed = (Get-Content $kitJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        $parsed.wuSearchTimeoutMinutes | Should -Be 10
    }
}

# ---------------------------------------------------------------------------
Describe '12-Startup.ps1 (structure)' {
    It 'ne supprime jamais de clé de registre (désactivation réversible)' {
        $c = Get-Content "$PSScriptRoot\..\modules\12-Startup.ps1" -Raw
        $c | Should -Not -Match 'Remove-ItemProperty'
        $c | Should -Match 'StartupApproved'
    }
    It 'déplace les .lnk au lieu de les supprimer' {
        $c = Get-Content "$PSScriptRoot\..\modules\12-Startup.ps1" -Raw
        $c | Should -Match 'Move-Item'
        $c | Should -Not -Match 'Remove-Item -LiteralPath \$lnk'
    }
    It 'désactive les tâches sans les supprimer' {
        $c = Get-Content "$PSScriptRoot\..\modules\12-Startup.ps1" -Raw
        $c | Should -Match 'Disable-ScheduledTask'
        $c | Should -Not -Match 'Unregister-ScheduledTask'
    }
}

# ---------------------------------------------------------------------------
Describe '13-BrowserPUP.ps1 (structure)' {
    It 'sauvegarde en .reg avant toute suppression' {
        $c = Get-Content "$PSScriptRoot\..\modules\13-BrowserPUP.ps1" -Raw
        $c | Should -Match 'reg\.exe export|Backup-RegKey'
    }
    It 'ne touche qu''aux chemins de policy ciblés' {
        $c = Get-Content "$PSScriptRoot\..\modules\13-BrowserPUP.ps1" -Raw
        $c | Should -Match 'Software\\Policies'
    }
}

# ---------------------------------------------------------------------------
Describe '09-Comfort.ps1 (OneDrive opt-in)' {
    It 'ne touche à OneDrive que si -RemoveOneDrive (sinon rien)' {
        $c = Get-Content "$PSScriptRoot\..\modules\09-Comfort.ps1" -Raw
        $c | Should -Match 'if \(-not \$RemoveOneDrive\)'
    }
    It 'pose la stratégie de blocage durable (résiste aux MAJ)' {
        $c = Get-Content "$PSScriptRoot\..\modules\09-Comfort.ps1" -Raw
        $c | Should -Match 'DisableFileSyncNGSC'
    }
    It 'coupe les rappels/notifications natifs OneDrive' {
        $c = Get-Content "$PSScriptRoot\..\modules\09-Comfort.ps1" -Raw
        $c | Should -Match 'ShowSyncProviderNotifications'
    }
    It 'ne demande plus interactivement (Read-Host) la désinstallation OneDrive' {
        $c = Get-Content "$PSScriptRoot\..\modules\09-Comfort.ps1" -Raw
        # La section OneDrive ne doit plus contenir de Read-Host (décision = case GUI uniquement)
        ($c -split '--- 2\.')[0] | Should -Not -Match 'Read-Host'
    }
}

# ---------------------------------------------------------------------------
Describe '07-Cleanup.ps1 (SFC anti-deadlock)' {
    It 'redirige SFC vers un fichier (évite le gel en GUI sans console)' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        $c | Should -Match 'sfc /scannow >'
    }
    It 'ne capture plus SFC via un pipe PowerShell direct' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        $c | Should -Not -Match '&\s*sfc /scannow 2>&1'
    }
}

# ---------------------------------------------------------------------------
Describe '07-Cleanup.ps1 (DISM anti-deadlock)' {
    It 'redirige DISM vers un fichier (évite le gel en GUI sans console, comme SFC)' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        $c | Should -Match 'DISM \$Arguments >'
    }
    It 'ne lance plus DISM via un pipe PowerShell direct (& DISM /...)' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        $c | Should -Not -Match '&\s*DISM\s+/'
    }
    It 'utilise le helper Invoke-DismToFile pour les deux appels DISM' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        ([regex]::Matches($c, 'Invoke-DismToFile -Arguments')).Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
Describe '07-Cleanup.ps1 (nettoyage rapide -SkipRepair)' {
    It 'accepte le switch -SkipRepair' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        $c | Should -Match '\[switch\]\$SkipRepair'
    }
    It 'court-circuite DISM et SFC quand -SkipRepair (les deux sections gardees)' {
        $c = Get-Content "$PSScriptRoot\..\modules\07-Cleanup.ps1" -Raw
        ([regex]::Matches($c, 'if \(\$SkipRepair\)')).Count | Should -BeGreaterOrEqual 2
    }
}

# ---------------------------------------------------------------------------
Describe '08-Accounts.ps1 (durcissement UAC sans mot de passe)' {
    It 'force EnableLUA=1 (UAC active)' {
        $c = Get-Content "$PSScriptRoot\..\modules\08-Accounts.ps1" -Raw
        $c | Should -Match 'EnableLUA\s*=\s*1'
    }
    It 'met l''admin en mode consentement Oui/Non (pas en demande de mot de passe)' {
        $c = Get-Content "$PSScriptRoot\..\modules\08-Accounts.ps1" -Raw
        $c | Should -Match 'ConsentPromptBehaviorAdmin\s*=\s*2'
        # 1 ou 3 = demande de credentials (mot de passe) : interdit, on veut du sans-mot-de-passe
        $c | Should -Not -Match 'ConsentPromptBehaviorAdmin\s*=\s*[13]\b'
    }
    It 'active le bureau securise pour les prompts UAC' {
        $c = Get-Content "$PSScriptRoot\..\modules\08-Accounts.ps1" -Raw
        $c | Should -Match 'PromptOnSecureDesktop\s*=\s*1'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-LogLineParts' {
    It 'parse une ligne de log valide' {
        $r = Get-LogLineParts -Line '[2026-06-30 03:21:34] [WARN] Quelque chose'
        $r.Level     | Should -Be 'WARN'
        $r.Message   | Should -Be 'Quelque chose'
        $r.Timestamp | Should -Be '2026-06-30 03:21:34'
    }
    It 'retourne $null pour une ligne non-kit' {
        Get-LogLineParts -Line 'juste du texte libre' | Should -Be $null
    }
    It 'retourne $null pour une ligne vide' {
        Get-LogLineParts -Line '' | Should -Be $null
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertTo-HtmlEncoded' {
    It 'echappe les caracteres dangereux' {
        ConvertTo-HtmlEncoded -Text '<script>alert("x")</script>' | Should -Be '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;'
    }
    It 'echappe le & en premier (pas de double-echappement)' {
        ConvertTo-HtmlEncoded -Text 'a & b < c' | Should -Be 'a &amp; b &lt; c'
    }
    It 'retourne une chaine vide pour null' {
        ConvertTo-HtmlEncoded -Text $null | Should -Be ''
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertTo-PrintableText' {
    It 'laisse le texte normal intact' {
        ConvertTo-PrintableText -Text 'GoogleDriveFS' | Should -Be 'GoogleDriveFS'
    }
    It 'conserve les accents francais' {
        ConvertTo-PrintableText -Text 'Démarrage réussi' | Should -Be 'Démarrage réussi'
    }
    It 'retire les caracteres de controle' {
        ConvertTo-PrintableText -Text "a`tb`0c" | Should -Be 'abc'
    }
    It 'remplace une entree entierement illisible par le libelle par defaut' {
        ConvertTo-PrintableText -Text ([string][char]0x00 + [char]0x01) | Should -Be '(entrée illisible)'
    }
    It 'honore un placeholder personnalise' {
        ConvertTo-PrintableText -Text ([string][char]0x00) -Placeholder '' | Should -Be ''
    }
    It 'retourne une chaine vide pour null' {
        ConvertTo-PrintableText -Text $null | Should -Be ''
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ReportSummary' {
    It 'compte les niveaux et regroupe par module' {
        $lines = @(
            '[t] [INFO] === 07-Cleanup : début ===',
            '[t] [OK] TEMP vidé',
            '[t] [WARN] cache occupé',
            '[t] [INFO] === 08-Accounts : début ===',
            '[t] [OK] compte créé',
            '[t] [ERROR] echec X'
        )
        $s = Get-ReportSummary -Lines $lines
        $s.CountOK    | Should -Be 2
        $s.CountWarn  | Should -Be 1
        $s.CountError | Should -Be 1
        $s.Modules.Count | Should -Be 2
        $s.Modules[0].Name  | Should -Be '07-Cleanup'
        $s.Modules[0].OK    | Should -Be 1
        $s.Modules[0].Warn  | Should -Be 1
        $s.Modules[1].Name  | Should -Be '08-Accounts'
        $s.Modules[1].Error | Should -Be 1
    }
    It 'gère une entrée nulle sans planter' {
        (Get-ReportSummary -Lines $null).TotalLines | Should -Be 0
    }
    It 'place les lignes avant tout module dans un préambule' {
        $s = Get-ReportSummary -Lines @('[t] [INFO] demarrage du run')
        $s.Modules[0].Name | Should -Be '(préambule)'
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertTo-ReportHtml' {
    BeforeAll {
        $lines = @(
            '[t] [INFO] === 07-Cleanup : début ===',
            '[t] [OK] TEMP vidé',
            '[t] [WARN] <dangereux> & co'
        )
        $sum  = Get-ReportSummary -Lines $lines
        $html = ConvertTo-ReportHtml -Summary $sum `
                    -Meta @{ ComputerName = 'PC-TEST'; Generated = '2026-06-30 03:00'; OS = 'Windows 11'; KitVersion = 'v1.6' } `
                    -RebootNeeded $true -RebootReasons @('CBS') -Lines $lines
    }
    It 'produit un document HTML complet et autonome' {
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match '</html>'
        $html | Should -Not -Match '<link '   # aucune ressource externe
    }
    It 'inclut le nom de la machine' {
        $html | Should -Match 'PC-TEST'
    }
    It 'affiche la banniere de redemarrage quand requis' {
        $html | Should -Match 'REDÉMARRAGE REQUIS'
    }
    It 'echappe le contenu dangereux du journal (anti-injection)' {
        $html | Should -Not -Match '<dangereux>'
        $html | Should -Match '&lt;dangereux&gt;'
    }
    It 'liste les modules détectés' {
        $html | Should -Match '07-Cleanup'
    }
    It 'affiche l''absence de reboot quand non requis' {
        $h2 = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'X' } -RebootNeeded $false -Lines @()
        $h2 | Should -Match 'Aucun redémarrage requis'
    }
    It 'colore en rouge la ligne d''un module en erreur' {
        $errLines = @('[t] [INFO] === 08-Accounts : début ===', '[t] [ERROR] echec creation compte')
        $errSum = Get-ReportSummary -Lines $errLines
        $h3 = ConvertTo-ReportHtml -Summary $errSum -Meta @{ ComputerName = 'X' } -Lines $errLines
        $h3 | Should -Match 'background:#fef2f2'
    }
    It 'inclut les volumes et l''antivirus quand fournis' {
        $h4 = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'X' } -Lines @() `
                  -Volumes @('C: NTFS - 256 GB total, 64 GB libre (SSD)') -Antivirus @('Windows Defender')
        $h4 | Should -Match '<h2>Volumes</h2>'
        $h4 | Should -Match '256 GB total'
        $h4 | Should -Match 'Windows Defender'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-StartupApprovedEnabledBytes' {
    It 'retourne 12 octets avec 0x02 en tête (activé)' {
        $b = Get-StartupApprovedEnabledBytes
        $b.Count | Should -Be 12
        $b[0]    | Should -Be 2
    }
    It 'est symétrique de la version désactivée (0x02 actif vs 0x03 désactivé)' {
        (Get-StartupApprovedEnabledBytes)[0]  | Should -Be 2
        (Get-StartupApprovedDisabledBytes)[0] | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
Describe 'New-UndoEntry / Test-UndoEntryValid' {
    It 'construit une entrée RunKeyDisabled valide' {
        $e = New-UndoEntry -Module '12-Startup' -Action 'RunKeyDisabled' -Data @{ ApprovedKeyPath = 'HKCU:\x\Run'; ValueName = 'Spotify' }
        $e.Action    | Should -Be 'RunKeyDisabled'
        $e.ValueName | Should -Be 'Spotify'
        Test-UndoEntryValid -Entry $e | Should -Be $true
    }
    It 'lève si un champ requis manque' {
        { New-UndoEntry -Module '12-Startup' -Action 'RunKeyDisabled' -Data @{ ApprovedKeyPath = 'HKCU:\x' } } | Should -Throw
    }
    It 'valide les 4 types d''action' {
        (Test-UndoEntryValid -Entry (New-UndoEntry -Module 'm' -Action 'ShortcutMoved'    -Data @{ OriginalPath = 'a'; DisabledPath = 'b' })) | Should -Be $true
        (Test-UndoEntryValid -Entry (New-UndoEntry -Module 'm' -Action 'TaskDisabled'     -Data @{ TaskName = 't'; TaskPath = '\' }))         | Should -Be $true
        (Test-UndoEntryValid -Entry (New-UndoEntry -Module 'm' -Action 'RegBackupRestore' -Data @{ RegBackupFile = 'c:\x.reg' }))            | Should -Be $true
    }
    It 'rejette une entrée sans Action ou à action inconnue' {
        Test-UndoEntryValid -Entry ([PSCustomObject]@{ Foo = 'bar' })                       | Should -Be $false
        Test-UndoEntryValid -Entry ([PSCustomObject]@{ Action = 'Inexistant'; X = 1 })      | Should -Be $false
        Test-UndoEntryValid -Entry $null                                                    | Should -Be $false
    }
    It 'rejette une entrée dont un champ requis est vide' {
        Test-UndoEntryValid -Entry ([PSCustomObject]@{ Action = 'RegBackupRestore'; RegBackupFile = '' }) | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-UndoPlan' {
    It 'retourne les entrées valides en ordre inverse (LIFO)' {
        $entries = @(
            (New-UndoEntry -Module 'm' -Action 'RegBackupRestore' -Data @{ RegBackupFile = 'first.reg' }),
            (New-UndoEntry -Module 'm' -Action 'RegBackupRestore' -Data @{ RegBackupFile = 'second.reg' })
        )
        $plan = Get-UndoPlan -Entries $entries
        $plan.Count            | Should -Be 2
        $plan[0].RegBackupFile | Should -Be 'second.reg'
        $plan[1].RegBackupFile | Should -Be 'first.reg'
    }
    It 'filtre les entrées invalides' {
        $entries = @(
            (New-UndoEntry -Module 'm' -Action 'RegBackupRestore' -Data @{ RegBackupFile = 'ok.reg' }),
            ([PSCustomObject]@{ Action = 'Inconnu' })
        )
        (Get-UndoPlan -Entries $entries).Count | Should -Be 1
    }
    It 'gère une entrée nulle sans planter' {
        (Get-UndoPlan -Entries $null).Count | Should -Be 0
    }
    It 'survit à un aller-retour JSON (manifeste réel simulé)' {
        $entries = @(
            (New-UndoEntry -Module '12-Startup'   -Action 'TaskDisabled'     -Data @{ TaskName = 'Foo'; TaskPath = '\' }),
            (New-UndoEntry -Module '13-BrowserPUP' -Action 'RegBackupRestore' -Data @{ RegBackupFile = 'k.reg'; KeyPath = 'HKLM:\x' })
        )
        $json = ConvertTo-Json @($entries) -Depth 6
        # PS 5.1 : assigner le resultat de ConvertFrom-Json AVANT de l'envelopper avec @()
        # (sur 5.1, @(pipe | ConvertFrom-Json) collapse un tableau JSON en 1 element).
        $parsedBack = $json | ConvertFrom-Json
        $back = @($parsedBack)
        $plan = Get-UndoPlan -Entries $back
        $plan.Count            | Should -Be 2
        $plan[0].Action        | Should -Be 'RegBackupRestore'
        $plan[0].RegBackupFile | Should -Be 'k.reg'
        $plan[1].Action        | Should -Be 'TaskDisabled'
        $plan[1].TaskName      | Should -Be 'Foo'
        $plan[1].TaskPath      | Should -Be '\'
    }
}

# ---------------------------------------------------------------------------
Describe 'Add-UndoEntry / Resolve-UndoManifestPath' {
    BeforeEach {
        $undoTmp = Join-Path $env:TEMP "pester-undo-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path (Join-Path $undoTmp 'runtime\logs') | Out-Null
        $script:KitLogFile = Join-Path $undoTmp 'runtime\logs\gui-PESTER-20260630-000000.log'
    }
    AfterEach {
        Remove-Item $undoTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'dérive le chemin du manifeste depuis le log unifié' {
        Resolve-UndoManifestPath | Should -Match 'runtime[\\/]undo[\\/]undo-gui-PESTER-20260630-000000\.json'
    }
    It 'accumule les entrées dans l''ordre d''ajout et alimente Get-UndoPlan en LIFO' {
        (Add-UndoEntry -Module '12-Startup'   -Action 'TaskDisabled'     -Data @{ TaskName = 'A'; TaskPath = '\' })                 | Should -Be $true
        (Add-UndoEntry -Module '13-BrowserPUP' -Action 'RegBackupRestore' -Data @{ RegBackupFile = 'b.reg'; KeyPath = 'HKLM:\x' })  | Should -Be $true
        $manifest = Resolve-UndoManifestPath
        Test-Path $manifest | Should -Be $true
        # PS 5.1 : assigner AVANT @() (sinon un tableau JSON est collapse en 1 element).
        $parsedEntries = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = @($parsedEntries)
        $entries.Count       | Should -Be 2
        $entries[0].TaskName | Should -Be 'A'                 # ordre d'ajout préservé dans le fichier
        (Get-UndoPlan -Entries $entries)[0].Action | Should -Be 'RegBackupRestore'  # LIFO : dernière ajoutée = première annulée
    }
    It 'reste défensif : une entrée invalide (champ requis manquant) ne lève pas et retourne $false' {
        Add-UndoEntry -Module 'x' -Action 'TaskDisabled' -Data @{ TaskName = 'OnlyName' } | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe '12-Startup.ps1 (manifeste annulation)' {
    It 'enregistre les 3 types d''action réversibles dans le manifeste' {
        $c = Get-Content "$PSScriptRoot\..\modules\12-Startup.ps1" -Raw
        $c | Should -Match "Add-UndoEntry .*-Action 'RunKeyDisabled'"
        $c | Should -Match "Add-UndoEntry .*-Action 'ShortcutMoved'"
        $c | Should -Match "Add-UndoEntry .*-Action 'TaskDisabled'"
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-WingetRetryableExitCode' {
    It 'reconnaît le code int32 signé de 0x8A150042' {
        Test-WingetRetryableExitCode -ExitCode (-1978335166) | Should -BeTrue
    }
    It 'refuse 0 et les autres codes' {
        Test-WingetRetryableExitCode -ExitCode 0  | Should -BeFalse
        Test-WingetRetryableExitCode -ExitCode 1  | Should -BeFalse
        Test-WingetRetryableExitCode -ExitCode -1 | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-WingetAbsentAdvice' {
    It 'oriente vers le PATH/App Installer sur Windows 11' {
        Get-WingetAbsentAdvice -IsWin11 $true | Should -Match 'Windows 11'
    }
    It 'oriente vers le Store sur Windows 10' {
        Get-WingetAbsentAdvice -IsWin11 $false | Should -Match 'Windows 10'
    }
    It 'traite $null comme non-Win11 sans lever' {
        { Get-WingetAbsentAdvice -IsWin11 $null } | Should -Not -Throw
        Get-WingetAbsentAdvice -IsWin11 $null | Should -Match 'Windows 10'
    }
}

# ---------------------------------------------------------------------------
Describe '13-BrowserPUP.ps1 (manifeste annulation)' {
    It 'enregistre la restauration registre dans le manifeste' {
        $c = Get-Content "$PSScriptRoot\..\modules\13-BrowserPUP.ps1" -Raw
        $c | Should -Match "Add-UndoEntry .*-Action 'RegBackupRestore'"
    }
}

# ---------------------------------------------------------------------------
Describe '14-Undo.ps1 (structure)' {
    It 'charge un manifeste et construit un plan via Get-UndoPlan' {
        $c = Get-Content "$PSScriptRoot\..\modules\14-Undo.ps1" -Raw
        $c | Should -Match 'Get-UndoPlan'
        $c | Should -Match 'ConvertFrom-Json'
    }
    It 'gère les 5 types d''action d''annulation' {
        $c = Get-Content "$PSScriptRoot\..\modules\14-Undo.ps1" -Raw
        $c | Should -Match "'RunKeyDisabled'"
        $c | Should -Match "'ShortcutMoved'"
        $c | Should -Match "'TaskDisabled'"
        $c | Should -Match "'RegBackupRestore'"
        $c | Should -Match "'reg-value'"
    }
    It 'restaure sans rien supprimer (réactive / déplace / réimporte, jamais Remove-Item)' {
        $c = Get-Content "$PSScriptRoot\..\modules\14-Undo.ps1" -Raw
        $c | Should -Match 'Enable-ScheduledTask'
        $c | Should -Match 'reg\.exe import'
        $c | Should -Not -Match 'Remove-Item'
    }
    It 'supporte le mode -WhatIf' {
        $c = Get-Content "$PSScriptRoot\..\modules\14-Undo.ps1" -Raw
        $c | Should -Match '\[switch\]\$WhatIf'
        $c | Should -Match 'if \(\$WhatIf\)'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-LogLevelColor' {
    It 'mappe chaque niveau à une couleur connue' {
        Get-LogLevelColor -Line '[t] [OK] x'     | Should -Be 'Green'
        Get-LogLevelColor -Line '[t] [WARN] x'   | Should -Be 'DarkOrange'
        Get-LogLevelColor -Line '[t] [ERROR] x'  | Should -Be 'Red'
        Get-LogLevelColor -Line '[t] [WHATIF] x' | Should -Be 'Teal'
        Get-LogLevelColor -Line '[t] [INFO] x'   | Should -Be 'DimGray'
    }
    It 'retourne DimGray (INFO) pour une ligne non-kit' {
        Get-LogLevelColor -Line 'texte libre' | Should -Be 'DimGray'
    }
}

# ---------------------------------------------------------------------------
Describe 'Format-Elapsed' {
    It 'formate mm:ss sous une heure' {
        Format-Elapsed -Seconds 65 | Should -Be '01:05'
        Format-Elapsed -Seconds 5  | Should -Be '00:05'
    }
    It 'formate h:mm:ss au-delà d''une heure' {
        Format-Elapsed -Seconds 3661 | Should -Be '1:01:01'
    }
    It 'gère zéro et négatif sans planter' {
        Format-Elapsed -Seconds 0   | Should -Be '00:00'
        Format-Elapsed -Seconds -10 | Should -Be '00:00'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-BackupSourceFolders' {
    It 'retourne un tableau non vide de chemins existants' {
        $folders = @(Get-BackupSourceFolders)
        $folders.Count | Should -BeGreaterThan 0
        foreach ($f in $folders) { Test-Path $f | Should -BeTrue }
    }
    It 'ne contient aucun doublon (insensible à la casse)' {
        $folders = @(Get-BackupSourceFolders)
        $unique  = @($folders | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
        $unique.Count | Should -Be $folders.Count
    }
    It 'contient un dossier Downloads' {
        @(Get-BackupSourceFolders) -match 'Downloads' | Should -Not -BeNullOrEmpty
    }
    It 'ne lève pas sous StrictMode même appelée deux fois' {
        { Get-BackupSourceFolders; Get-BackupSourceFolders } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-BatteryCapacityFromHtml' {
    It 'extrait design et full depuis un rapport anglais' {
        $html = '<tr><td>DESIGN CAPACITY</td><td>76,000 mWh</td></tr><tr><td>FULL CHARGE CAPACITY</td><td>60,542 mWh</td></tr>'
        $r = Get-BatteryCapacityFromHtml -Html $html
        $r.DesignCapacityMWh | Should -Be 76000
        $r.FullCapacityMWh   | Should -Be 60542
    }
    It 'extrait design et full depuis un rapport français (libellés localisés, espace en séparateur de milliers)' {
        $html = '<tr><td>CAPACIT&Eacute; TH&Eacute;ORIQUE</td><td>76 000 mWh</td></tr><tr><td>CAPACIT&Eacute; DE CHARGE COMPL&Egrave;TE</td><td>60 542 mWh</td></tr>'
        $r = Get-BatteryCapacityFromHtml -Html $html
        $r.DesignCapacityMWh | Should -Be 76000
        $r.FullCapacityMWh   | Should -Be 60542
    }
    It 'retourne $null si moins de deux valeurs mWh' {
        Get-BatteryCapacityFromHtml -Html '<td>52 000 mWh</td>' | Should -BeNullOrEmpty
    }
    It 'retourne $null sur HTML vide ou null' {
        Get-BatteryCapacityFromHtml -Html ''    | Should -BeNullOrEmpty
        Get-BatteryCapacityFromHtml -Html $null | Should -BeNullOrEmpty
    }
    It 'retourne $null si une valeur est zéro' {
        $html = '<td>0 mWh</td><td>60 542 mWh</td>'
        Get-BatteryCapacityFromHtml -Html $html | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-GUI.ps1 (cockpit v1.6)' {
    It 'utilise une RichTextBox et colore le journal via Get-LogLevelColor' {
        $c = Get-Content "$PSScriptRoot\..\Run-GUI.ps1" -Raw
        $c | Should -Match 'System\.Windows\.Forms\.RichTextBox'
        $c | Should -Match 'Get-LogLevelColor'
    }
    It 'affiche le temps écoulé via Format-Elapsed' {
        $c = Get-Content "$PSScriptRoot\..\Run-GUI.ps1" -Raw
        $c | Should -Match 'Format-Elapsed'
    }
    It 'ouvre le rapport HTML dans le navigateur si disponible' {
        $c = Get-Content "$PSScriptRoot\..\Run-GUI.ps1" -Raw
        $c | Should -Match "ReportFile -like '\*\.html'"
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DiagThirdPartyAv' {
    It 'retourne la liste dédupliquée depuis un diag valide' {
        $p = Join-Path $TestDrive 'diag.json'
        Set-Content -Path $p -Value '{ "ThirdPartyAvActive": ["Kaspersky", "Kaspersky", "Norton"] }' -Encoding UTF8
        # Contrat (a) : la fonction retourne ,@(...) -> appel par ASSIGNATION,
        # jamais @(Get-DiagThirdPartyAv ...) qui collecterait un tableau imbriqué.
        $r = Get-DiagThirdPartyAv -DiagPath $p
        @($r).Count | Should -Be 2
        @($r) -contains 'Kaspersky' | Should -BeTrue
        @($r) -contains 'Norton'    | Should -BeTrue
    }
    It 'retourne un tableau vide (pas $null) si la liste du diag est vide' {
        $p = Join-Path $TestDrive 'diag2.json'
        Set-Content -Path $p -Value '{ "ThirdPartyAvActive": [] }' -Encoding UTF8
        $r = Get-DiagThirdPartyAv -DiagPath $p
        $null -ne $r  | Should -BeTrue
        @($r).Count   | Should -Be 0
    }
    It 'retourne $null si le fichier est absent' {
        Get-DiagThirdPartyAv -DiagPath (Join-Path $TestDrive 'absent.json') | Should -BeNullOrEmpty
    }
    It 'retourne $null si le JSON est invalide ou sans la clé' {
        $p = Join-Path $TestDrive 'diag3.json'
        Set-Content -Path $p -Value '{ "autre": 1 }' -Encoding UTF8
        Get-DiagThirdPartyAv -DiagPath $p | Should -BeNullOrEmpty
    }
    It 'retourne $null sur un JSON malformé sans lever' {
        $p = Join-Path $TestDrive 'diagbad.json'
        Set-Content -Path $p -Value '{ pas du json' -Encoding UTF8
        { Get-DiagThirdPartyAv -DiagPath $p } | Should -Not -Throw
        Get-DiagThirdPartyAv -DiagPath $p | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ActiveThirdPartyAv - déduplication' {
    It 'la fonction contient une déduplication Sort-Object -Unique' {
        $src = Get-Content "$PSScriptRoot\..\lib\Common.ps1" -Raw
        # La query WMI n'est pas mockable simplement : on vérifie la présence
        # structurelle de la dédup dans la fonction (complément du test terrain).
        $src | Should -Match '(?s)function Get-ActiveThirdPartyAv.*?Sort-Object -Unique.*?\n\}'
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertFrom-JobLogLine' {
    It 'parse une ligne KITLOG avec niveau' {
        $r = ConvertFrom-JobLogLine -Line 'KITLOG|WARN|message avec | pipe'
        $r.Kind    | Should -Be 'LOG'
        $r.Level   | Should -Be 'WARN'
        $r.Message | Should -Be 'message avec | pipe'
    }
    It 'parse une ligne KITPHASE' {
        $r = ConvertFrom-JobLogLine -Line 'KITPHASE|SEARCH_DONE'
        $r.Kind    | Should -Be 'PHASE'
        $r.Message | Should -Be 'SEARCH_DONE'
    }
    It 'traite une ligne brute comme LOG INFO' {
        $r = ConvertFrom-JobLogLine -Line 'sortie inattendue'
        $r.Kind  | Should -Be 'LOG'
        $r.Level | Should -Be 'INFO'
    }
    It 'refuse un niveau inconnu et retombe en INFO' {
        (ConvertFrom-JobLogLine -Line 'KITLOG|BIZARRE|x').Level | Should -Be 'INFO'
    }
    It 'retourne $null sur ligne vide ou null' {
        ConvertFrom-JobLogLine -Line ''    | Should -BeNullOrEmpty
        ConvertFrom-JobLogLine -Line $null | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DebloatDecision - politique' {
    It 'Conservative garde tout, même non utilisé en unattended' {
        (Get-DebloatDecision -Detect 'usage' -InUse $false -Unattended $true -Policy 'Conservative').Action | Should -Be 'KEEP'
    }
    It 'Standard reste le comportement historique (compat sans -Policy)' {
        (Get-DebloatDecision -Detect 'usage' -InUse $true  -Unattended $true).Action  | Should -Be 'KEEP'
        (Get-DebloatDecision -Detect 'usage' -InUse $false -Unattended $true).Action  | Should -Be 'REMOVE'
        (Get-DebloatDecision -Detect 'usage' -InUse $false -Unattended $false).Action | Should -Be 'PROMPT'
    }
    It 'Aggressive supprime même une app usage utilisée' {
        (Get-DebloatDecision -Detect 'usage' -InUse $true -Unattended $true -Policy 'Aggressive').Action | Should -Be 'REMOVE'
    }
    It 'Aggressive ne touche JAMAIS au Game Pass détecté' {
        (Get-DebloatDecision -Detect 'gamepass' -InUse $true -Unattended $true -Policy 'Aggressive').Action | Should -Be 'KEEP'
    }
    It 'Aggressive supprime sans prompt même en interactif' {
        (Get-DebloatDecision -Detect 'usage' -InUse $false -Unattended $false -Policy 'Aggressive').Action | Should -Be 'REMOVE'
    }
}

# ---------------------------------------------------------------------------
Describe 'Add-UndoEntry - écriture atomique' {
    BeforeEach {
        $savedKitLogFile = $script:KitLogFile
    }
    AfterEach {
        $script:KitLogFile = $savedKitLogFile
    }
    It 'ne laisse pas de fichier .tmp après écriture' {
        $logsDir = Join-Path $TestDrive 'runtime\logs'
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        $script:KitLogFile = Join-Path $logsDir 'run-atomic.log'
        # Schéma réel : Get-UndoRequiredFields('RunKeyDisabled') exige
        # ApprovedKeyPath et ValueName (lib/Common.ps1:833).
        Add-UndoEntry -Module '12' -Action 'RunKeyDisabled' -Data @{
            ApprovedKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            ValueName       = 'TestEntry'
        } | Should -BeTrue
        $undoPath = Resolve-UndoManifestPath
        Test-Path $undoPath          | Should -BeTrue
        Test-Path "$undoPath.tmp"    | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DiskSpaceLevel' {
    It 'INFO au-dessus du seuil warn' {
        Get-DiskSpaceLevel -FreePct 40 | Should -Be 'INFO'
        Get-DiskSpaceLevel -FreePct 15 | Should -Be 'INFO'
    }
    It 'WARN entre error et warn' {
        Get-DiskSpaceLevel -FreePct 12 | Should -Be 'WARN'
        Get-DiskSpaceLevel -FreePct 5  | Should -Be 'WARN'
    }
    It 'ERROR sous le seuil error' {
        Get-DiskSpaceLevel -FreePct 4 | Should -Be 'ERROR'
        Get-DiskSpaceLevel -FreePct 0 | Should -Be 'ERROR'
    }
    It 'respecte des seuils personnalisés' {
        Get-DiskSpaceLevel -FreePct 18 -WarnPct 20 -ErrorPct 10 | Should -Be 'WARN'
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-HasRecentKitRestorePoint' {
    BeforeAll { $script:trpNow = Get-Date '2026-07-15 12:00:00' }
    It 'détecte un point du kit récent' {
        $pts = @([PSCustomObject]@{ Description = 'PC-Refresh-Kit avant intervention'; CreationTime = $script:trpNow.AddHours(-1) })
        Test-HasRecentKitRestorePoint -Points $pts -Now $script:trpNow -MaxAgeHours 4 | Should -BeTrue
    }
    It 'ignore un point du kit trop vieux' {
        $pts = @([PSCustomObject]@{ Description = 'PC-Refresh-Kit avant intervention'; CreationTime = $script:trpNow.AddHours(-5) })
        Test-HasRecentKitRestorePoint -Points $pts -Now $script:trpNow -MaxAgeHours 4 | Should -BeFalse
    }
    It 'ignore les points étrangers même récents' {
        $pts = @([PSCustomObject]@{ Description = 'Windows Update'; CreationTime = $script:trpNow.AddMinutes(-10) })
        Test-HasRecentKitRestorePoint -Points $pts -Now $script:trpNow | Should -BeFalse
    }
    It 'gère $null et les objets incomplets sans lever' {
        Test-HasRecentKitRestorePoint -Points $null -Now $script:trpNow | Should -BeFalse
        $pts = @([PSCustomObject]@{ Autre = 1 })
        { Test-HasRecentKitRestorePoint -Points $pts -Now $script:trpNow } | Should -Not -Throw
        Test-HasRecentKitRestorePoint -Points $pts -Now $script:trpNow | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ForeignFicheNames' {
    It 'signale les fiches des autres PC' {
        $r = @(Get-ForeignFicheNames -FileNames @('FICHE-PC-AUTREPC.txt', 'FICHE-PC-MONPC.txt') -ComputerName 'MONPC')
        $r.Count | Should -Be 1
        $r[0]    | Should -Be 'FICHE-PC-AUTREPC.txt'
    }
    It 'insensible à la casse sur le nom du PC' {
        @(Get-ForeignFicheNames -FileNames @('FICHE-PC-monpc.txt') -ComputerName 'MONPC').Count | Should -Be 0
    }
    It 'retourne un tableau vide sur liste vide ou null' {
        @(Get-ForeignFicheNames -FileNames @()   -ComputerName 'X').Count | Should -Be 0
        @(Get-ForeignFicheNames -FileNames $null -ComputerName 'X').Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DefaultBrowserLabel' {
    It 'reconnait Firefox et positionne IsFirefox' {
        $r = Get-DefaultBrowserLabel -ProgId 'FirefoxURL-308046B0AF4A39CB'
        $r.Label     | Should -Match 'Firefox'
        $r.IsFirefox | Should -BeTrue
    }
    It 'reconnait Chrome et Edge sans IsFirefox' {
        (Get-DefaultBrowserLabel -ProgId 'ChromeHTML').IsFirefox | Should -BeFalse
        (Get-DefaultBrowserLabel -ProgId 'MSEdgeHTM').Label      | Should -Match 'Edge'
    }
    It 'retombe sur le ProgId brut si inconnu, IsFirefox faux' {
        $r = Get-DefaultBrowserLabel -ProgId 'BiduleHTML'
        $r.IsFirefox | Should -BeFalse
        $r.Label     | Should -Match 'BiduleHTML'
    }
    It 'ne leve pas sur null ou vide' {
        { Get-DefaultBrowserLabel -ProgId $null } | Should -Not -Throw
        (Get-DefaultBrowserLabel -ProgId '').IsFirefox | Should -BeFalse
    }
}

Describe 'Test-SmartDriveAlert' {
    It 'alerte au-dela de 80% d usure' {
        (Test-SmartDriveAlert -WearPct 85 -UncorrectedErrors 0).IsAlert | Should -BeTrue
    }
    It 'alerte des la premiere erreur non corrigee' {
        (Test-SmartDriveAlert -WearPct 10 -UncorrectedErrors 1).IsAlert | Should -BeTrue
    }
    It 'pas d alerte sur un disque sain' {
        (Test-SmartDriveAlert -WearPct 10 -UncorrectedErrors 0).IsAlert | Should -BeFalse
    }
    It 'traite null comme non alertant (materiel muet), sans lever' {
        { Test-SmartDriveAlert -WearPct $null -UncorrectedErrors $null } | Should -Not -Throw
        (Test-SmartDriveAlert -WearPct $null -UncorrectedErrors $null).IsAlert | Should -BeFalse
    }
}

Describe 'Get-BitLockerStatusLabel' {
    It 'chiffre a 100%' {
        Get-BitLockerStatusLabel -ProtectionStatus 1 -EncryptionPercentage 100 | Should -Match 'Chiffr'
    }
    It 'chiffrement en cours affiche le pourcentage' {
        Get-BitLockerStatusLabel -ProtectionStatus 0 -EncryptionPercentage 42 | Should -Match '42'
    }
    It 'non chiffre' {
        Get-BitLockerStatusLabel -ProtectionStatus 0 -EncryptionPercentage 0 | Should -Match 'Non chiffr'
    }
    It 'inconnu sur null, sans lever' {
        { Get-BitLockerStatusLabel -ProtectionStatus $null -EncryptionPercentage $null } | Should -Not -Throw
    }
}

Describe 'Format-BootDuration' {
    It 'formate des millisecondes en secondes avec une decimale' {
        Format-BootDuration -Milliseconds 12300 | Should -Be '12,3 s'
    }
    It 'non mesure sur null ou zero' {
        Format-BootDuration -Milliseconds $null | Should -Match 'non mesur'
        Format-BootDuration -Milliseconds 0     | Should -Match 'non mesur'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-Win32AppNames' {
    It 'retourne un tableau (jamais null) sans lever' {
        { Get-Win32AppNames } | Should -Not -Throw
        $null -ne (Get-Win32AppNames) | Should -BeTrue
    }
    It 'les noms sont uniques (dedup)' {
        $n = @(Get-Win32AppNames)
        @($n | Sort-Object -Unique).Count | Should -Be $n.Count
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ReportDelta' {
    BeforeAll {
        $script:grdBefore = [PSCustomObject]@{
            Volumes        = @([PSCustomObject]@{ DriveLetter='C'; FreeBytes=100GB }, [PSCustomObject]@{ DriveLetter='D'; FreeBytes=50GB })
            StartupCount   = 14
            Win32Apps      = @('Spotify','Skype','Firefox','Java 8')
            BootDurationMs = 42000
        }
        $script:grdAfter = [PSCustomObject]@{
            Volumes        = @([PSCustomObject]@{ DriveLetter='C'; FreeBytes=112GB }, [PSCustomObject]@{ DriveLetter='D'; FreeBytes=50GB })
            StartupCount   = 6
            Win32Apps      = @('Firefox','LibreOffice','VLC')
            BootDurationMs = $null
        }
    }
    It 'calcule l espace recupere par somme des volumes' {
        (Get-ReportDelta -Before $script:grdBefore -After $script:grdAfter).SpaceReclaimedBytes | Should -Be ([int64]12GB)
    }
    It 'calcule le delta d autostarts' {
        $d = Get-ReportDelta -Before $script:grdBefore -After $script:grdAfter
        $d.StartupBefore | Should -Be 14
        $d.StartupAfter  | Should -Be 6
        $d.StartupDelta  | Should -Be -8
    }
    It 'distingue apps retirees et installees (ensembles, insensible a la casse)' {
        $d = Get-ReportDelta -Before $script:grdBefore -After $script:grdAfter
        @($d.AppsRemoved).Count | Should -Be 3   # Spotify, Skype, Java 8
        @($d.AppsAdded).Count   | Should -Be 2   # LibreOffice, VLC
        $d.AppsRemoved -contains 'Spotify' | Should -BeTrue
        $d.AppsAdded   -contains 'VLC'     | Should -BeTrue
    }
    It 'produit des lignes de synthese non vides' {
        @((Get-ReportDelta -Before $script:grdBefore -After $script:grdAfter).Lines).Count | Should -BeGreaterThan 0
    }
    It 'ne leve pas si Before ou After est null (rapport rejoue sans snapshot)' {
        { Get-ReportDelta -Before $null -After $script:grdAfter }  | Should -Not -Throw
        { Get-ReportDelta -Before $script:grdBefore -After $null } | Should -Not -Throw
    }
    It 'espace negatif possible (installation nette) sans crash' {
        $b = [PSCustomObject]@{ Volumes=@([PSCustomObject]@{ DriveLetter='C'; FreeBytes=100GB }); StartupCount=1; Win32Apps=@(); BootDurationMs=$null }
        $a = [PSCustomObject]@{ Volumes=@([PSCustomObject]@{ DriveLetter='C'; FreeBytes=95GB  }); StartupCount=1; Win32Apps=@(); BootDurationMs=$null }
        (Get-ReportDelta -Before $b -After $a).SpaceReclaimedBytes | Should -Be ([int64](-5GB))
    }
}

Describe 'Undo reg-value - validation' {
    It 'New-UndoEntry accepte reg-value avec tous les champs' {
        $e = New-UndoEntry -Module '04' -Action 'reg-value' -Data @{
            RegPath='HKCU:\X'; ValueName='V'; ValueType='DWord'; OldValueData=0; ValueWasAbsent=$false
        }
        $e.Action | Should -Be 'reg-value'
    }
    It 'New-UndoEntry rejette reg-value si un champ requis manque' {
        { New-UndoEntry -Module '04' -Action 'reg-value' -Data @{ RegPath='HKCU:\X' } } | Should -Throw
    }
    It 'Test-UndoEntryValid valide une entrée reg-value complète' {
        $e = New-UndoEntry -Module '04' -Action 'reg-value' -Data @{
            RegPath='HKCU:\X'; ValueName='V'; ValueType='DWord'; OldValueData=1; ValueWasAbsent=$false
        }
        Test-UndoEntryValid -Entry $e | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ExtensionClassification' {
    It 'reconnaît un ID de la liste blanche' {
        $r = Get-ExtensionClassification -Id 'abc' -Whitelist @('abc','def')
        $r.IsKnown | Should -BeTrue
    }
    It 'marque un ID inconnu avec un lien chromewebstore' {
        $r = Get-ExtensionClassification -Id 'zzz' -Whitelist @('abc')
        $r.IsKnown | Should -BeFalse
        $r.Url     | Should -Match 'chromewebstore.google.com/detail/zzz'
    }
    It 'ne lève pas sur liste blanche vide ou null' {
        { Get-ExtensionClassification -Id 'zzz' -Whitelist @() }   | Should -Not -Throw
        { Get-ExtensionClassification -Id 'zzz' -Whitelist $null } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-BackupPauseNeeded' {
    It 'demande la pause quand un backup a réellement eu lieu (hors WhatIf)' {
        $lines = @('...', 'Backup data terminé dans : E:\Backup-PC', '...')
        Test-BackupPauseNeeded -LogLines $lines -IsWhatIf $false | Should -BeTrue
    }
    It 'pas de pause si le backup a été sauté (pas de disque externe)' {
        $lines = @('Pas de disque externe détecté. Backup data ignoré (non bloquant).')
        Test-BackupPauseNeeded -LogLines $lines -IsWhatIf $false | Should -BeFalse
    }
    It 'pas de pause en mode WhatIf même si la ligne est présente' {
        $lines = @('Backup data terminé dans : E:\Backup-PC')
        Test-BackupPauseNeeded -LogLines $lines -IsWhatIf $true | Should -BeFalse
    }
    It 'ne lève pas sur liste vide ou null' {
        { Test-BackupPauseNeeded -LogLines @() -IsWhatIf $false }   | Should -Not -Throw
        { Test-BackupPauseNeeded -LogLines $null -IsWhatIf $false } | Should -Not -Throw
    }
}

Describe 'Get-HeartbeatMessage' {
    It 'formate le module et les minutes (plancher, min 1)' {
        Get-HeartbeatMessage -ModuleLabel '07 Cleanup' -ElapsedSeconds 130 | Should -Match '07 Cleanup'
        Get-HeartbeatMessage -ModuleLabel '07 Cleanup' -ElapsedSeconds 130 | Should -Match '2 min'
        Get-HeartbeatMessage -ModuleLabel '07 Cleanup' -ElapsedSeconds 20  | Should -Match '1 min'
    }
    It 'ne lève pas sur elapsed null' {
        { Get-HeartbeatMessage -ModuleLabel 'X' -ElapsedSeconds $null } | Should -Not -Throw
    }
}

Describe 'Get-EndChecklistItems' {
    It 'retourne une liste non vide' {
        @(Get-EndChecklistItems -RebootRequired $false).Count | Should -BeGreaterThan 5
    }
    It 'insiste sur le redémarrage quand requis' {
        (Get-EndChecklistItems -RebootRequired $true)  -join "`n" | Should -Match 'REDÉMARR|REBOOT'
    }
    It 'mentionne toujours le nettoyage de la clé (fiche PC)' {
        (Get-EndChecklistItems -RebootRequired $false) -join "`n" | Should -Match 'fiche|FICHE'
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-KitProfile' {
    It 'retourne tous les défauts si le fichier est absent' {
        $p = Read-KitProfile -Path (Join-Path $TestDrive 'absent.json')
        $p.Debloat      | Should -Be 'Standard'
        $p.BackupData   | Should -BeTrue
        $p.ScanDefender | Should -BeTrue
        $p.NetReset     | Should -BeFalse
        $p.KeepAdmin    | Should -BeFalse
    }
    It 'les clés du fichier écrasent les défauts' {
        $p = Join-Path $TestDrive 'prof.json'
        Set-Content -Path $p -Value '{ "Debloat": "Conservative", "BackupData": false }' -Encoding UTF8
        $r = Read-KitProfile -Path $p
        $r.Debloat      | Should -Be 'Conservative'
        $r.BackupData   | Should -BeFalse
        $r.ScanDefender | Should -BeTrue
    }
    It 'retombe sur les défauts sur JSON invalide' {
        $p = Join-Path $TestDrive 'bad.json'
        Set-Content -Path $p -Value '{ pas du json' -Encoding UTF8
        (Read-KitProfile -Path $p).Debloat | Should -Be 'Standard'
    }
    It 'expose une table Modules avec des bool' {
        $r = Read-KitProfile -Path (Join-Path $TestDrive 'absent2.json')
        $r.Modules['00'] | Should -BeTrue
    }
    It 'les 3 profils livrés sont du JSON valide' {
        foreach ($n in @('standard','senior','gamer')) {
            $path = Join-Path $PSScriptRoot "..\config\profiles\$n.json"
            { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } | Should -Not -Throw
        }
    }
    It 'Debloat invalide dans le fichier retombe sur Standard' {
        $p = Join-Path $TestDrive 'debloat-bad.json'
        Set-Content -Path $p -Value '{"Debloat":"Invalide"}' -Encoding UTF8
        (Read-KitProfile -Path $p).Debloat | Should -Be 'Standard'
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-InKeepList' {
    It 'match unidirectionnel: le nom matche un pattern de la keep-list' {
        Test-InKeepList -Name 'Microsoft.WindowsStore' -KeepList @('Microsoft.WindowsStore*') | Should -BeTrue
    }
    It 'ne matche pas si absent' {
        Test-InKeepList -Name 'Some.Bloat' -KeepList @('Microsoft.Xbox*') | Should -BeFalse
    }
    It 'match bidirectionnel: un pattern large matche une entrée keep étroite' {
        Test-InKeepList -Name 'Microsoft.*' -KeepList @('Microsoft.WindowsStore') -Bidirectional | Should -BeTrue
    }
    It 'unidirectionnel ne matche PAS dans le sens inverse (garde-fou de non-régression)' {
        Test-InKeepList -Name 'Microsoft.*' -KeepList @('Microsoft.WindowsStore') | Should -BeFalse
    }
    It 'tolère une keep-list nulle, vide, ou avec entrées vides' {
        Test-InKeepList -Name 'x' -KeepList $null      | Should -BeFalse
        Test-InKeepList -Name 'x' -KeepList @()         | Should -BeFalse
        Test-InKeepList -Name 'x' -KeepList @('', 'y')  | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-KitVersion' {
    It 'retourne la version courante du kit' {
        Get-KitVersion | Should -Be 'v2.1'
    }
}

# ---------------------------------------------------------------------------
Describe 'Remove-PasswordLines' {
    It 'retire le mot de passe de la fiche PC recopiee dans le rapport' {
        $fiche = @"
=== FICHE PC - POSTE01 ===
COMPTE ADMIN LOCAL CREE PAR PC-REFRESH-KIT
  Nom du compte : Admin-Local
  Mot de passe  : Chien-Brume-Pomme-86
IMPORTANT : noter ce mot de passe en lieu sur.
"@
        $out = Remove-PasswordLines -Text $fiche
        $out | Should -Not -Match 'Chien-Brume-Pomme-86'
        $out | Should -Match 'Nom du compte : Admin-Local'
        $out | Should -Match 'voir la fiche PC'
    }

    It 'traite aussi passphrase, password et mdp, quelle que soit la casse' {
        foreach ($libelle in @('Passphrase', 'PASSWORD', 'mdp')) {
            $texte = "  $libelle : SecretAbc123"
            (Remove-PasswordLines -Text $texte) | Should -Not -Match 'SecretAbc123'
        }
    }

    It 'ne touche pas aux lignes qui parlent du mot de passe sans en porter un' {
        $texte = 'Communiquer le mot de passe admin au proprietaire'
        Remove-PasswordLines -Text $texte | Should -Be $texte
    }

    It 'renvoie une chaine vide ou nulle telle quelle' {
        Remove-PasswordLines -Text ''   | Should -Be ''
        Remove-PasswordLines -Text $null | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-MetaFromDiag' {
    It 'extrait machine/cpu/ram depuis un diag JSON' {
        $diag = [PSCustomObject]@{
            machine = [PSCustomObject]@{ Manufacturer='ASUSTeK'; Model='G14'; BiosSerial='ABC'; OSCaption='Windows 11 Pro'; OSBuild=22631 }
            cpu     = [PSCustomObject]@{ Name='AMD Ryzen 9' }
            ram     = [PSCustomObject]@{ TotalGB=32 }
        }
        $m = Get-MetaFromDiag -Diag $diag
        $m.Manufacturer | Should -Be 'ASUSTeK'
        $m.Serial       | Should -Be 'ABC'
        $m.OS           | Should -Be 'Windows 11 Pro (build 22631)'
        $m.CPU          | Should -Be 'AMD Ryzen 9'
        $m.RAM          | Should -Be '32 GB'
    }
    It 'formate les volumes en texte lisible' {
        $diag = [PSCustomObject]@{ volumes = @([PSCustomObject]@{ DriveLetter='C'; FileSystem='NTFS'; SizeGB=500; FreeGB=120; DiskType='SSD' }) }
        $m = Get-MetaFromDiag -Diag $diag
        @($m.Volumes).Count | Should -Be 1
        $m.Volumes[0].Text  | Should -Be 'C: NTFS - 500 GB total, 120 GB libre (SSD)'
    }
    It 'lit le nom antivirus sous la clé Name (le bug historique)' {
        $diag = [PSCustomObject]@{ antivirus = @([PSCustomObject]@{ Name='Windows Defender' }) }
        (Get-MetaFromDiag -Diag $diag).Antivirus | Should -Contain 'Windows Defender'
    }
    It 'tolère un diag null (rapport rejoué sans diagnostic)' {
        $m = Get-MetaFromDiag -Diag $null
        $m.Manufacturer     | Should -BeNullOrEmpty
        @($m.Volumes).Count | Should -Be 0
    }
    It 'ne lève pas sous StrictMode sur un diag incomplet' {
        { Get-MetaFromDiag -Diag ([PSCustomObject]@{ machine = [PSCustomObject]@{ Manufacturer='X' } }) } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Build-ModuleArgList' {
    It 'inclut toujours -Unattended' {
        Build-ModuleArgList -Id '00' | Should -Contain '-Unattended'
    }
    It 'ajoute -WhatIf en mode dry-run' {
        Build-ModuleArgList -Id '00' -DryRun | Should -Contain '-WhatIf'
    }
    It '01 ajoute -SkipDataBackup quand BackupData est faux' {
        Build-ModuleArgList -Id '01' -Options @{ BackupData = $false } | Should -Contain '-SkipDataBackup'
    }
    It "01 n'ajoute pas -SkipDataBackup quand BackupData est vrai" {
        Build-ModuleArgList -Id '01' -Options @{ BackupData = $true } | Should -Not -Contain '-SkipDataBackup'
    }
    It '02 ajoute -SkipDefenderScan quand ScanDefender est faux' {
        Build-ModuleArgList -Id '02' -Options @{ ScanDefender = $false } | Should -Contain '-SkipDefenderScan'
    }
    It '03 passe la policy debloat demandée' {
        (Build-ModuleArgList -Id '03' -Options @{ DebloatPolicy = 'Aggressive' }) -join ' ' | Should -Match '-DebloatPolicy Aggressive'
    }
    It '03 retombe sur Standard si la policy est invalide ou absente' {
        (Build-ModuleArgList -Id '03' -Options @{ DebloatPolicy = 'Bidon' }) -join ' ' | Should -Match '-DebloatPolicy Standard'
        (Build-ModuleArgList -Id '03') -join ' ' | Should -Match '-DebloatPolicy Standard'
    }
    It '03 ajoute -RemoveOemBloat seulement si Oem est vrai' {
        Build-ModuleArgList -Id '03' -Options @{ Oem = $true }  | Should -Contain '-RemoveOemBloat'
        Build-ModuleArgList -Id '03' -Options @{ Oem = $false } | Should -Not -Contain '-RemoveOemBloat'
    }
    It '07 mappe les options de nettoyage' {
        $a = Build-ModuleArgList -Id '07' -Options @{ Recycle = $true; WinOld = $true; Cache = $true }
        $a | Should -Contain '-EmptyRecycleBin'
        $a | Should -Contain '-RemoveWindowsOld'
        $a | Should -Contain '-CleanBrowserCache'
    }
    It "08 ajoute -KeepAdmin selon l'option" {
        Build-ModuleArgList -Id '08' -Options @{ KeepAdmin = $true } | Should -Contain '-KeepAdmin'
    }
    It '15 ajoute -ResetNetwork seulement si demandé' {
        Build-ModuleArgList -Id '15' -Options @{ NetReset = $true }  | Should -Contain '-ResetNetwork'
        Build-ModuleArgList -Id '15' -Options @{ NetReset = $false } | Should -Not -Contain '-ResetNetwork'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-OptionalTool' {
    It 'retourne $null si le fichier est absent' {
        Get-OptionalTool -Name 'nexistepas.exe' -ToolsDir $TestDrive | Should -BeNullOrEmpty
    }
    It 'retourne $null si la signature n est pas Valid' {
        $f = Join-Path $TestDrive 'unsigned.exe'
        Set-Content -Path $f -Value 'x' -Encoding Ascii
        Mock Get-AuthenticodeSignature { [PSCustomObject]@{ Status = 'NotSigned' } }
        Get-OptionalTool -Name 'unsigned.exe' -ToolsDir $TestDrive | Should -BeNullOrEmpty
    }
    It 'retourne le chemin quand le fichier existe et est signe Valid' {
        $f = Join-Path $TestDrive 'signed.exe'
        Set-Content -Path $f -Value 'x' -Encoding Ascii
        Mock Get-AuthenticodeSignature { [PSCustomObject]@{ Status = 'Valid' } }
        Get-OptionalTool -Name 'signed.exe' -ToolsDir $TestDrive | Should -Be $f
    }
}

# ---------------------------------------------------------------------------
Describe 'Découpe lib/ (non-régression)' {
    It 'charge un échantillon représentatif de chaque sous-fichier via Common.ps1' {
        $expected = @(
            'Write-KitLog',             # Log.ps1
            'Get-MachineInfo',          # Hardware.ps1
            'ConvertFrom-MediaType',    # Hardware.ps1
            'ConvertTo-ReportHtml',     # Report.ps1
            'Get-MetaFromDiag',         # Report.ps1
            'Add-UndoEntry',            # Undo.ps1
            'Test-ResidualPathAllowed', # Undo.ps1
            'Assert-Admin',             # Common.ps1
            'Build-ModuleArgList',      # Common.ps1
            'Get-OptionalTool'          # Common.ps1
        )
        foreach ($fn in $expected) {
            Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$fn doit rester accessible après découpe"
        }
    }
    It 'ne définit aucune fonction en double à travers lib/' {
        $libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
        $names = @()
        foreach ($f in (Get-ChildItem -Path $libDir -Filter '*.ps1')) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $names += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                        ForEach-Object { $_.Name })
        }
        $dups = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $dups | Should -BeNullOrEmpty -Because "chaque fonction ne doit exister qu'à un seul endroit ; doublons: $($dups -join ', ')"
    }
}


