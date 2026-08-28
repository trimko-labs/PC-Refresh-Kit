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

Describe 'Get-HelpHeaderInfo' {
    It 'classe une cle module' {
        $i = Get-HelpHeaderInfo -Key 'module.03'
        $i.Kind | Should -Be 'module'
        $i.KindText | Should -Be 'ÉTAPE'
        $i.Breadcrumb | Should -Be 'Intervention > Étapes'
    }
    It 'classe profil, debloatage, comptes, options, actions, etat' {
        (Get-HelpHeaderInfo -Key 'profile.gamer').KindText   | Should -Be 'PROFIL'
        (Get-HelpHeaderInfo -Key 'debloat.standard').Breadcrumb | Should -Be 'Réglages > Débloatage'
        (Get-HelpHeaderInfo -Key 'account.standard').Breadcrumb | Should -Be 'Réglages > Comptes'
        (Get-HelpHeaderInfo -Key 'option.recycle').KindText  | Should -Be 'RÉGLAGE'
        (Get-HelpHeaderInfo -Key 'action.run').KindText      | Should -Be 'ACTION'
        (Get-HelpHeaderInfo -Key 'status.backupnet').KindText | Should -Be 'ÉTAT'
    }
    It 'replie toute cle inconnue sur AIDE / General' {
        $i = Get-HelpHeaderInfo -Key 'welcome'
        $i.Kind | Should -Be 'general'
        $i.KindText | Should -Be 'AIDE'
        $i.Breadcrumb | Should -Be 'Général'
    }
}

Describe 'Get-HelpBadges' {
    It 'rend les trois badges dans l ordre reversible, data, duration' {
        $e = [PSCustomObject]@{ title = 't'; badges = [PSCustomObject]@{ reversible = 'store'; data = 'untouched'; duration = '5-15 min' } }
        $b = @(Get-HelpBadges -Entry $e)
        $b.Count | Should -Be 3
        $b[0].Text | Should -Be 'RÉVERSIBLE VIA STORE'
        $b[0].Level | Should -Be 'Accent'
        $b[1].Text | Should -Be 'DONNÉES PERSO : INTACTES'
        $b[1].Level | Should -Be 'Ok'
        $b[2].Text | Should -Be 'DURÉE : 5-15 min'
        $b[2].Level | Should -Be 'Neutral'
    }
    It 'mappe chaque niveau de reversibilite' {
        foreach ($case in @(
            @{ v = 'yes';      t = 'RÉVERSIBLE';               l = 'Ok' }
            @{ v = 'partial';  t = 'PARTIELLEMENT RÉVERSIBLE'; l = 'Warn' }
            @{ v = 'no';       t = 'IRRÉVERSIBLE';             l = 'Err' }
            @{ v = 'readonly'; t = 'LECTURE SEULE';            l = 'Ok' }
        )) {
            $e = [PSCustomObject]@{ badges = [PSCustomObject]@{ reversible = $case.v } }
            $b = @(Get-HelpBadges -Entry $e)
            $b[0].Text | Should -Be $case.t
            $b[0].Level | Should -Be $case.l
        }
    }
    It 'mappe copyonly et optin' {
        $e = [PSCustomObject]@{ badges = [PSCustomObject]@{ data = 'copyonly' } }
        (@(Get-HelpBadges -Entry $e))[0].Text | Should -Be 'DONNÉES PERSO : COPIE SEULE'
        $e = [PSCustomObject]@{ badges = [PSCustomObject]@{ data = 'optin' } }
        (@(Get-HelpBadges -Entry $e))[0].Level | Should -Be 'Warn'
    }
    It 'ignore une valeur inconnue et un champ vide sans erreur' {
        $e = [PSCustomObject]@{ badges = [PSCustomObject]@{ reversible = 'nimporte'; duration = '   ' } }
        @(Get-HelpBadges -Entry $e).Count | Should -Be 0
    }
    It 'rend une liste vide sans champ badges' {
        $e = [PSCustomObject]@{ title = 'sans badges' }
        @(Get-HelpBadges -Entry $e).Count | Should -Be 0
    }
    It 'rend une liste vide si badges est null' {
        $e = [PSCustomObject]@{ badges = $null }
        @(Get-HelpBadges -Entry $e).Count | Should -Be 0
    }
}

Describe 'Catalogue reel : badges valides' {
    BeforeAll {
        $script:cheminCatalogue = Join-Path $PSScriptRoot '..\config\help.fr.json'
        $script:catalogue = Get-HelpCatalog -Path $script:cheminCatalogue
    }
    It 'les badges couvrent exactement les 28 rubriques décidées' {
        # Égalité d'ensemble : fige le plancher (28), attrape une disparition en
        # masse et interdit un badge hors liste (revue Task 4 v2.5). La valeur
        # est exigée non nulle : un "badges": null ne compte pas comme porteur.
        $attendues = @(
            'module.00', 'module.01', 'module.16', 'module.02', 'module.03', 'module.04',
            'module.05', 'module.06', 'module.07', 'module.08', 'module.09', 'module.10',
            'module.11', 'module.12', 'module.13', 'module.14', 'module.15',
            'option.backupdata', 'option.scandefender', 'option.recycle', 'option.winold',
            'option.cache', 'option.onedrive', 'option.oem', 'option.netreset',
            'option.bitlockerkey', 'option.dryrun', 'action.delfiche'
        )
        $porteuses = @($script:catalogue.Keys | Where-Object {
            $e = $script:catalogue[$_]
            $e.PSObject.Properties['badges'] -and $null -ne $e.badges
        } | Sort-Object)
        $porteuses | Should -Be @($attendues | Sort-Object)
    }
    It 'toutes les valeurs badges du catalogue sont des enums connus' {
        $revOk  = @('yes', 'store', 'partial', 'no', 'readonly')
        $dataOk = @('untouched', 'copyonly', 'optin')
        foreach ($key in $script:catalogue.Keys) {
            $e = $script:catalogue[$key]
            if (-not $e.PSObject.Properties['badges'] -or $null -eq $e.badges) { continue }
            $b = $e.badges
            if ($b.PSObject.Properties['reversible']) { [string]$b.reversible | Should -BeIn $revOk -Because "$key" }
            if ($b.PSObject.Properties['data'])       { [string]$b.data       | Should -BeIn $dataOk -Because "$key" }
        }
    }
    It 'chaque rubrique module porte des badges' {
        foreach ($id in @('00','01','16','02','03','04','05','06','07','08','09','11','12','13','15','10','14')) {
            $e = $script:catalogue["module.$id"]
            $e.PSObject.Properties['badges'] | Should -Not -BeNullOrEmpty -Because "module.$id"
        }
    }
    It 'le fichier catalogue n a pas de BOM' {
        $octets = [System.IO.File]::ReadAllBytes($script:cheminCatalogue)
        ($octets[0] -eq 0xEF -and $octets[1] -eq 0xBB) | Should -BeFalse
    }
}
