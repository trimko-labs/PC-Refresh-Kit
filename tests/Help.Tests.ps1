# tests/Help.Tests.ps1 - Tests Pester v5 des fonctions d'aide de lib/Help.ps1
BeforeAll {
    . "$PSScriptRoot\..\lib\Help.ps1"
    $script:CatalogPath = Join-Path $PSScriptRoot '..\config\help.fr.json'
}

Describe 'Get-HelpCatalog' {
    It 'renvoie une hashtable vide si le fichier est absent' {
        $c = Get-HelpCatalog -Path (Join-Path $env:TEMP "absent-$(New-Guid).json")
        $c | Should -BeOfType [hashtable]
        $c.Count | Should -Be 0
    }

    It 'renvoie une hashtable vide sur un JSON invalide, sans lever' {
        $tmp = Join-Path $env:TEMP "invalide-$(New-Guid).json"
        Set-Content -Path $tmp -Value '{ ceci nest pas du json' -Encoding UTF8
        { Get-HelpCatalog -Path $tmp } | Should -Not -Throw
        (Get-HelpCatalog -Path $tmp).Count | Should -Be 0
        Remove-Item $tmp -Force
    }

    It 'renvoie une hashtable vide si entries vaut null, sans lever' {
        $tmp = Join-Path $env:TEMP "entries-null-$(New-Guid).json"
        Set-Content -Path $tmp -Value '{"entries": null}' -Encoding UTF8
        { Get-HelpCatalog -Path $tmp } | Should -Not -Throw
        $c = Get-HelpCatalog -Path $tmp
        $c | Should -BeOfType [hashtable]
        $c.Count | Should -Be 0
        Remove-Item $tmp -Force
    }

    It 'renvoie une hashtable vide si entries n est pas un objet, sans lever' {
        $tmp = Join-Path $env:TEMP "entries-texte-$(New-Guid).json"
        Set-Content -Path $tmp -Value '{"entries": "texte"}' -Encoding UTF8
        { Get-HelpCatalog -Path $tmp } | Should -Not -Throw
        $c = Get-HelpCatalog -Path $tmp
        $c | Should -BeOfType [hashtable]
        $c.Count | Should -Be 0
        Remove-Item $tmp -Force
    }

    It 'charge les entrées du catalogue du kit' {
        $c = Get-HelpCatalog -Path $script:CatalogPath
        $c.Count | Should -BeGreaterThan 0
        $c['module.03'].title | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-HelpEntry' {
    It 'renvoie l entrée demandée' {
        $c = Get-HelpCatalog -Path $script:CatalogPath
        (Get-HelpEntry -Catalog $c -Key 'module.03').title | Should -Match 'Désencombrement'
    }

    It 'renvoie une entrée de repli sur une clé inconnue' {
        $c = Get-HelpCatalog -Path $script:CatalogPath
        $e = Get-HelpEntry -Catalog $c -Key 'module.zz'
        $e | Should -Not -BeNullOrEmpty
        $e.short | Should -Match 'Aide indisponible'
    }

    It 'renvoie une entrée de repli si le catalogue est vide' {
        $e = Get-HelpEntry -Catalog @{} -Key 'module.03'
        $e.short | Should -Match 'Aide indisponible'
    }
}

Describe 'Format-HelpPanel' {
    It 'compose le titre puis les sections présentes' {
        $entry = [PSCustomObject]@{
            title = '03 Debloat'; short = 'Résumé.'; what = 'Fait ceci.'
            protects = 'Garde cela.'; reversible = 'Non.'; duration = '5 minutes'
            whenNot = 'Poste d entreprise.'
        }
        $txt = Format-HelpPanel -Entry $entry
        $txt | Should -Match '03 Debloat'
        $txt | Should -Match 'Ce qu.il fait|Ce que fait ce module'
        $txt | Should -Match 'Fait ceci\.'
        $txt | Should -Match 'Durée'
    }

    It 'omet proprement les sections absentes' {
        $entry = [PSCustomObject]@{
            title = 'Titre'; short = 'Résumé.'; what = 'Effet.'
            reversible = 'Oui.'; duration = 'Immédiat'
        }
        $txt = Format-HelpPanel -Entry $entry
        $txt | Should -Not -Match 'À décocher si'
    }
}

Describe 'Format-HelpTooltip' {
    It 'replie sans couper de mot et renvoie vers l onglet Aide' {
        $entry = [PSCustomObject]@{ title = 'T'; short = ('mot ' * 40).Trim() }
        $txt = Format-HelpTooltip -Entry $entry -Width 40
        foreach ($ligne in ($txt -split "`n")) { $ligne.Length | Should -BeLessOrEqual 45 }
        $txt | Should -Match 'onglet Aide'
    }

    It 'ne coupe pas un résumé plus court que la largeur' {
        $entry = [PSCustomObject]@{ title = 'T'; short = 'Court résumé.' }
        (Format-HelpTooltip -Entry $entry -Width 90) | Should -Match 'Court résumé\.'
    }
}

Describe 'Get-KitHelpDecision' {
    It 'renvoie <Expected> pour <Source>/pinned=<Pinned>/frozen=<Frozen>' -ForEach @(
        @{ Source='Hover';  Pinned=$true;  Frozen=$true;  Expected='Ignore' }
        @{ Source='Hover';  Pinned=$true;  Frozen=$false; Expected='Ignore' }
        @{ Source='Direct'; Pinned=$true;  Frozen=$true;  Expected='Ignore' }
        @{ Source='Direct'; Pinned=$true;  Frozen=$false; Expected='Ignore' }
        @{ Source='Direct'; Pinned=$false; Frozen=$true;  Expected='Show' }
        @{ Source='Direct'; Pinned=$false; Frozen=$false; Expected='Show' }
        @{ Source='Hover';  Pinned=$false; Frozen=$true;  Expected='Ignore' }
        @{ Source='Hover';  Pinned=$false; Frozen=$false; Expected='Defer' }
    ) {
        Get-KitHelpDecision -Source $Source -Pinned $Pinned -Frozen $Frozen | Should -Be $Expected
    }
}

Describe 'Couverture du catalogue' {
    BeforeAll {
        $script:Catalog = Get-HelpCatalog -Path (Join-Path $PSScriptRoot '..\config\help.fr.json')
        # Les clés module.* sont dérivées du disque : un module ajouté demain fait
        # échouer ce test tant qu'il n'a pas sa rubrique, ce qu'une liste écrite en
        # dur ne ferait jamais.
        $script:Modules = @(Get-ChildItem (Join-Path $PSScriptRoot '..\modules') -Filter '*.ps1' |
            ForEach-Object { 'module.' + $_.BaseName.Substring(0, 2) })
        $script:Attendues = $script:Modules + @(
            'option.backupdata','option.scandefender','option.recycle','option.winold',
            'option.cache','option.onedrive','option.oem','option.netreset','option.dryrun',
            'option.bitlockerkey',
            'debloat.conservative','debloat.standard','debloat.aggressive',
            'account.standard','account.keepadmin',
            'profile.custom',
            'action.run','action.cancel','action.report','action.delfiche',
            'action.copypassword','action.saveprofile',
            'action.pwdshow','action.newrun'
        )
    }

    It 'trouve bien les modules du kit sur le disque' {
        $script:Modules.Count | Should -BeGreaterThan 0
    }

    It 'documente tous les contrôles attendus' {
        $manquantes = @($script:Attendues | Where-Object { -not $script:Catalog.ContainsKey($_) })
        $manquantes -join ', ' | Should -Be ''
    }

    It 'documente chaque profil livré dans config\profiles' {
        $profils = @(Get-ChildItem (Join-Path $PSScriptRoot '..\config\profiles') -Filter '*.json')
        $profils.Count | Should -BeGreaterThan 0 -Because 'un dossier de profils vide ferait passer ce test sans rien vérifier'
        foreach ($p in $profils) {
            $script:Catalog.ContainsKey("profile.$($p.BaseName)") | Should -BeTrue -Because "profile.$($p.BaseName) doit exister dans le catalogue"
        }
    }

    It 'remplit les cinq champs obligatoires de chaque entrée' {
        foreach ($cle in $script:Catalog.Keys) {
            $e = $script:Catalog[$cle]
            foreach ($champ in @('title','short','what','reversible','duration')) {
                [string]$e.$champ | Should -Not -BeNullOrEmpty -Because "$cle.$champ est obligatoire"
            }
        }
    }

    It 'garde les résumés sous 200 caractères' {
        foreach ($cle in $script:Catalog.Keys) {
            ([string]$script:Catalog[$cle].short).Length | Should -BeLessOrEqual 200 -Because "$cle a un résumé trop long pour une infobulle"
        }
    }

    It 'module.16 existe avec le titre en etape 3' {
        [string]$script:Catalog['module.16'].title | Should -Match '^Étape 3 - Filets de secours'
    }

    It 'les titres d''etapes sont renumerotes sans collision (1..16 uniques)' {
        # Un module inséré dans le pipeline sans renumérotation du catalogue crée
        # deux « Étape N » identiques : la suite triée le révèle aussitôt.
        $nums = @()
        foreach ($cle in $script:Catalog.Keys) {
            if ($cle -like 'module.*' -and [string]$script:Catalog[$cle].title -match '^Étape (\d+) -') {
                $nums += [int]$Matches[1]
            }
        }
        (@($nums | Sort-Object) -join ',') | Should -Be ((1..16) -join ',')
    }

    It 'ne contient aucun tiret cadratin ni demi-cadratin' {
        $brut = Get-Content (Join-Path $PSScriptRoot '..\config\help.fr.json') -Raw -Encoding UTF8
        ($brut -match "[$([char]0x2013)$([char]0x2014)]") | Should -BeFalse
    }

    It 'est enregistré sans BOM, comme les autres JSON du kit' {
        # Un BOM en tête ferait échouer ConvertFrom-Json sous Windows PowerShell
        # 5.1 dès qu'un lecteur ouvre le fichier autrement qu'avec -Encoding UTF8.
        $octets = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\config\help.fr.json'))
        $octets[0] | Should -Not -Be 0xEF -Because 'config\help.fr.json doit rester en UTF-8 sans BOM'
    }
}
