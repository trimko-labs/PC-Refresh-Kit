# tests/Resilience.Tests.ps1 - fonctions pures de la sentinelle résilience et du coffre
BeforeAll {
    . "$PSScriptRoot\..\lib\Common.ps1"
}

Describe 'Test-HiveFreshnessAlert' {
    It 'OK quand SYSTEM suit SOFTWARE de près' {
        $r = Test-HiveFreshnessAlert -SystemLastWrite (Get-Date '2026-08-20 10:00') -SoftwareLastWrite (Get-Date '2026-08-20 18:00')
        $r.Level | Should -Be 'OK'
    }
    It 'WARN au-delà de 48 h de retard' {
        $r = Test-HiveFreshnessAlert -SystemLastWrite (Get-Date '2026-08-17 10:00') -SoftwareLastWrite (Get-Date '2026-08-20 10:00')
        $r.Level | Should -Be 'WARN'
        $r.LagHours | Should -Be 72
    }
    It 'ERROR au-delà de 7 jours (signature pré-crash)' {
        $r = Test-HiveFreshnessAlert -SystemLastWrite (Get-Date '2026-08-08 10:00') -SoftwareLastWrite (Get-Date '2026-08-20 10:00')
        $r.Level | Should -Be 'ERROR'
    }
    It 'OK quand SYSTEM est plus récent que SOFTWARE (lag négatif)' {
        $r = Test-HiveFreshnessAlert -SystemLastWrite (Get-Date '2026-08-20 18:00') -SoftwareLastWrite (Get-Date '2026-08-20 10:00')
        $r.Level | Should -Be 'OK'
        $r.LagHours | Should -Be 0
    }
    It 'borne exacte : 48 h pile bascule déjà en WARN' {
        # Comparateur épinglé : `$lagH -ge 48`, borne INCLUSE. 48,0 h pile est
        # donc un avertissement, pas encore un OK.
        $r = Test-HiveFreshnessAlert -SystemLastWrite (Get-Date '2026-08-18 10:00') -SoftwareLastWrite (Get-Date '2026-08-20 10:00')
        $r.LagHours | Should -Be 48
        $r.Level    | Should -Be 'WARN'
    }
    It 'borne exacte : 168 h pile bascule déjà en ERROR' {
        # Comparateur épinglé : `$lagH -ge 168`, borne INCLUSE et testée AVANT
        # le seuil des 48 h. 7 jours pile est donc ERROR, pas WARN.
        $r = Test-HiveFreshnessAlert -SystemLastWrite (Get-Date '2026-08-13 10:00') -SoftwareLastWrite (Get-Date '2026-08-20 10:00')
        $r.LagHours | Should -Be 168
        $r.Level    | Should -Be 'ERROR'
    }
}

Describe 'Get-FreeSpaceVerdict' {
    It 'ERROR sous le plancher absolu même avec un pourcentage sain' {
        # 9 Go libres sur 2 To = 0,45% ... prendre un cas où le POURCENT est bon : 9 Go sur 60 Go = 15%
        Get-FreeSpaceVerdict -FreeBytes (9GB) -TotalBytes (60GB) -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'ERROR'
    }
    It 'WARN entre les deux planchers' {
        Get-FreeSpaceVerdict -FreeBytes (15GB) -TotalBytes (100GB) -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'WARN'
    }
    It 'OK au-dessus des seuils' {
        Get-FreeSpaceVerdict -FreeBytes (200GB) -TotalBytes (500GB) -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'OK'
    }
    It 'ERROR sous le pourcentage critique même avec beaucoup de Go (très gros disque)' {
        Get-FreeSpaceVerdict -FreeBytes (80GB) -TotalBytes (4TB) -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'ERROR'
    }
    It 'INFO neutre impossible : total nul rend OK sans division par zéro' {
        Get-FreeSpaceVerdict -FreeBytes 0 -TotalBytes 0 -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'OK'
    }
    It 'borne exacte : 20 Go pile sur le plancher d''avertissement reste OK' {
        # Comparateur épinglé : `$gb -lt $WarnFloorGB`, borne EXCLUE - être PILE
        # sur le plancher ne déclenche pas l'avertissement, il faut passer dessous.
        # 20 Go sur 100 Go = 20% libre : les deux seuils en pourcentage (15/5) sont
        # muets, seul le plancher en Go décide, donc le verdict isole bien -lt.
        Get-FreeSpaceVerdict -FreeBytes (20GB) -TotalBytes (100GB) -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'OK'
    }
    It 'borne exacte : 10 Go pile sur le plancher critique reste WARN, pas ERROR' {
        # Même comparateur EXCLUANT côté critique : `$gb -lt $ErrorFloorGB` est faux
        # à 10 Go pile, donc pas d'ERROR ; le WARN vient alors du plancher
        # d'avertissement (10 -lt 20). 10 Go sur 40 Go = 25% libre : les
        # pourcentages sont muets, le verdict isole les deux planchers en Go.
        Get-FreeSpaceVerdict -FreeBytes (10GB) -TotalBytes (40GB) -WarnPct 15 -ErrorPct 5 -WarnFloorGB 20 -ErrorFloorGB 10 | Should -Be 'WARN'
    }
}

Describe 'Get-WinReVerdict' {
    It 'Enabled -> OK (sortie FR, valeur anglaise)' {
        $out = @('Informations de configuration de l''Environnement de recuperation Windows :', '    Statut de WinRE :             Enabled', '    Emplacement de WinRE :        \\?\GLOBALROOT\device\harddisk0')
        $r = Get-WinReVerdict -ReagentcOutput $out
        $r.Status | Should -Be 'Enabled'
        $r.Level  | Should -Be 'OK'
    }
    It 'Disabled -> WARN' {
        (Get-WinReVerdict -ReagentcOutput @('    Statut de WinRE :             Disabled')).Level | Should -Be 'WARN'
    }
    It 'sortie vide -> Unknown WARN' {
        (Get-WinReVerdict -ReagentcOutput $null).Status | Should -Be 'Unknown'
    }
}

Describe 'Get-RecoveryEnabledVerdict' {
    It 'Yes -> OK' {
        (Get-RecoveryEnabledVerdict -BcdOutput @('recoveryenabled         Yes')).Level | Should -Be 'OK'
    }
    It 'Oui (bcdedit localisé) -> OK' {
        (Get-RecoveryEnabledVerdict -BcdOutput @('recoveryenabled         Oui')).Status | Should -Be 'Yes'
    }
    It 'No -> WARN' {
        (Get-RecoveryEnabledVerdict -BcdOutput @('recoveryenabled         No')).Level | Should -Be 'WARN'
    }
    It 'ligne absente -> Absent WARN' {
        (Get-RecoveryEnabledVerdict -BcdOutput @('device        partition=C:')).Status | Should -Be 'Absent'
    }
}

Describe 'Test-ShadowStorageAdequate' {
    It 'UNBOUNDED est adéquat' {
        Test-ShadowStorageAdequate -MaxSpaceBytes ([uint64]::MaxValue) -VolumeSizeBytes (500GB) -MinPct 5 | Should -BeTrue
    }
    It '10 pourcent est adéquat' {
        Test-ShadowStorageAdequate -MaxSpaceBytes (50GB) -VolumeSizeBytes (500GB) -MinPct 5 | Should -BeTrue
    }
    It '1 pourcent est insuffisant' {
        Test-ShadowStorageAdequate -MaxSpaceBytes (5GB) -VolumeSizeBytes (500GB) -MinPct 5 | Should -BeFalse
    }
    It 'pas de configuration = pas de filet' {
        Test-ShadowStorageAdequate -MaxSpaceBytes $null -VolumeSizeBytes (500GB) -MinPct 5 | Should -BeFalse
    }
    It 'borne exacte : 5% pile est adéquat' {
        # Comparateur épinglé : `-ge $MinPct`, borne INCLUSE - la réserve pile au
        # minimum passe. 5 Go sur 100 Go donne exactement 5,0 en virgule flottante
        # (100.0 * 5368709120 / 107374182400 = 5.0 exact), la borne est donc
        # réellement atteinte et non approchée.
        Test-ShadowStorageAdequate -MaxSpaceBytes (5GB) -VolumeSizeBytes (100GB) -MinPct 5 | Should -BeTrue
    }
}

Describe 'Get-BitLockerResilienceVerdict' {
    It 'non chiffré -> OK' {
        (Get-BitLockerResilienceVerdict -ProtectionStatus 0 -ProtectorTypes @()).Level | Should -Be 'OK'
    }
    It 'chiffré avec RecoveryPassword -> INFO avec renvoi aka.ms' {
        $r = Get-BitLockerResilienceVerdict -ProtectionStatus 1 -ProtectorTypes @('Tpm','RecoveryPassword')
        $r.Level  | Should -Be 'INFO'
        $r.Reason | Should -Match 'aka\.ms/myrecoverykey'
    }
    It 'chiffré sans protecteur de récupération -> ERROR' {
        (Get-BitLockerResilienceVerdict -ProtectionStatus 1 -ProtectorTypes @('Tpm')).Level | Should -Be 'ERROR'
    }
    It 'statut null -> OK (volume non protégé)' {
        (Get-BitLockerResilienceVerdict -ProtectionStatus $null -ProtectorTypes $null).Level | Should -Be 'OK'
    }
}

Describe 'Get-DirsToRotate' {
    It 'garde les Keep plus récents (tri par nom yyyyMMdd = chronologique)' {
        $dirs = @(
            [PSCustomObject]@{ Name = 'hives-20260801-120000' }
            [PSCustomObject]@{ Name = 'hives-20260815-120000' }
            [PSCustomObject]@{ Name = 'hives-20260810-120000' }
            [PSCustomObject]@{ Name = 'hives-20260820-120000' }
        )
        $old = @(Get-DirsToRotate -Dirs $dirs -Keep 3)
        $old.Count | Should -Be 1
        $old[0].Name | Should -Be 'hives-20260801-120000'
    }
    It 'rien à supprimer sous le seuil' {
        @(Get-DirsToRotate -Dirs @([PSCustomObject]@{ Name = 'hives-20260801-120000' }) -Keep 3).Count | Should -Be 0
    }
    It 'liste vide tolérée' {
        @(Get-DirsToRotate -Dirs $null -Keep 3).Count | Should -Be 0
    }
    It 'borne exacte : autant de dossiers que Keep ne fait rien tourner' {
        # Comparateur épinglé : `$sorted.Count -le $Keep`, borne INCLUSE - à
        # égalité stricte le coffre est plein mais rien n'est encore excédentaire.
        $dirs = @(
            [PSCustomObject]@{ Name = 'hives-20260801-120000' }
            [PSCustomObject]@{ Name = 'hives-20260810-120000' }
            [PSCustomObject]@{ Name = 'hives-20260820-120000' }
        )
        @(Get-DirsToRotate -Dirs $dirs -Keep 3).Count | Should -Be 0
    }
}

Describe 'Manifeste du coffre' {
    It 'aller-retour clé=valeur' {
        $data = [ordered]@{ machineid = 'abc-123'; computername = 'PC-TEST'; taille_system = '22282240' }
        $lines = ConvertTo-KitManifestLines -Data $data
        $h = ConvertFrom-KitManifestLines -Lines $lines
        $h['machineid']     | Should -Be 'abc-123'
        $h['taille_system'] | Should -Be '22282240'
        $h.Keys.Count       | Should -Be 3
    }
    It 'lignes vides et sans égal ignorées en lecture' {
        $h = ConvertFrom-KitManifestLines -Lines @('', 'pasdegal', 'a=1')
        $h.Keys.Count | Should -Be 1
    }
    It 'les lignes produites sont pur ASCII' {
        $lines = ConvertTo-KitManifestLines -Data ([ordered]@{ computername = 'PC-TEST' })
        foreach ($l in $lines) {
            # Garde @() obligatoire : sous StrictMode Latest, .Count sur un
            # pipeline vide (cas nominal ici) lève PropertyNotFoundStrict.
            @([System.Text.Encoding]::UTF8.GetBytes($l) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }
}

Describe 'Get-KitConfig planchers disque (v2.4)' {
    It 'expose les défauts diskWarnFloorGB=20 et diskErrorFloorGB=10' {
        $cfg = Get-KitConfig -Path 'Z:\inexistant\kit.json'
        $cfg.diskWarnFloorGB  | Should -Be 20
        $cfg.diskErrorFloorGB | Should -Be 10
    }
}

Describe '00-Diagnostic : section Resilience presente dans le code' {
    BeforeAll {
        $script:diagSrc = Get-Content "$PSScriptRoot\..\modules\00-Diagnostic.ps1" -Raw -Encoding UTF8
    }
    It 'collecte reagentc, bcdedit, Win32_ShadowStorage et la fraîcheur des ruches' {
        $src = $script:diagSrc
        $src | Should -Match 'reagentc'
        $src | Should -Match 'bcdedit'
        $src | Should -Match 'Win32_ShadowStorage'
        $src | Should -Match 'Test-HiveFreshnessAlert'
        $src | Should -Match "Resilience\s*="
    }
    It 'plafonne le journal de la sentinelle à WARN (la porte smoke échoue sur [ERROR])' {
        # Le verdict ERROR reste dans le JSON et la carte ; seul le JOURNAL est
        # plafonné, sinon une machine malade fait échouer le smoke du module.
        $src = $script:diagSrc
        $src | Should -Match 'function Write-SentinelLog'
        # Aucun appel direct à Write-KitLog en ERROR dans le bloc sentinelle :
        # tout passe par le plafond.
        $sentinel = [regex]::Match($src, '(?s)Sentinelle r.silience \(v2\.4\).*?\$resilience = \[PSCustomObject\]').Value
        $sentinel | Should -Not -BeNullOrEmpty
        $sentinel | Should -Not -Match "Write-KitLog[^\r\n]*-Level 'ERROR'"
    }
    It 'applique la même doctrine hors sentinelle : aucun Write-KitLog en ERROR' {
        # La boucle des volumes journalisait un [ERROR] « Espace critique » qui
        # décrit la MACHINE et pas l'exécution du module : il faisait rougir la
        # porte smoke sur un PC réellement saturé, hors du plafond de la
        # sentinelle. Seul Write-SentinelLog (plafonné) accepte encore ERROR.
        $script:diagSrc | Should -Not -Match "Write-KitLog[^\r\n]*-Level 'ERROR'"
    }
    It 'sonde honnêtement la restauration : null si non mesuré, pas zéro' {
        $src = $script:diagSrc
        $src | Should -Match 'Get-ComputerRestorePoint -ErrorAction Stop'
    }
    It 'ne conclut pas depuis une sortie bcdedit inexploitable' {
        $script:diagSrc | Should -Match "\`$bcdExit -ne 0"
    }
    It 'ne conclut pas « réserve insuffisante » sur une sonde VSS refusée' {
        # Sans élévation, Win32_ShadowStorage lève : en SilentlyContinue le refus
        # se lisait comme « aucune réserve configurée ».
        $script:diagSrc | Should -Match 'Get-CimInstance Win32_ShadowStorage -ErrorAction Stop'
    }
}

Describe 'Carte Filets de sécurité du rapport HTML' {
    BeforeAll {
        $sum = Get-ReportSummary -Lines @()
        $resDown = [PSCustomObject]@{
            FreeSpaceLevel        = 'ERROR'
            HiveLagHours          = 190.5
            HiveLevel             = 'ERROR'
            HiveReason            = 'ruche SYSTEM figée depuis plus de 7 jours'
            RestoreEnabled        = $false
            RestorePointCount     = 0
            ShadowMaxBytes        = $null
            ShadowAdequate        = $false
            WinReStatus           = 'Disabled'
            WinReLevel            = 'WARN'
            RecoveryEnabledStatus = 'No'
            RecoveryEnabledLevel  = 'WARN'
            BitLockerC            = [PSCustomObject]@{ Level = 'ERROR'; Reason = 'chiffré SANS mot de passe de récupération détectable' }
        }
        $resUp = [PSCustomObject]@{
            FreeSpaceLevel        = 'OK'
            HiveLagHours          = 1.2
            HiveLevel             = 'OK'
            HiveReason            = ''
            RestoreEnabled        = $true
            RestorePointCount     = 3
            ShadowMaxBytes        = 50GB
            ShadowAdequate        = $true
            WinReStatus           = 'Enabled'
            WinReLevel            = 'OK'
            RecoveryEnabledStatus = 'Yes'
            RecoveryEnabledLevel  = 'OK'
            BitLockerC            = [PSCustomObject]@{ Level = 'OK'; Reason = 'volume non protégé par BitLocker' }
        }
        $htmlDown = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() -Resilience $resDown
        $htmlUp   = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() -Resilience $resUp
    }
    It 'liste chaque filet quand la sentinelle a tourné' {
        $htmlUp | Should -Match 'Filets de sécurité'
        $htmlUp | Should -Match 'Espace libre C:'
        $htmlUp | Should -Match 'Écritures du registre'
        $htmlUp | Should -Match 'Restauration système'
        $htmlUp | Should -Match 'Réserve de clichés'
        $htmlUp | Should -Match 'Environnement de récupération'
        $htmlUp | Should -Match 'Auto-réparation au démarrage'
        $htmlUp | Should -Match 'BitLocker C:'
    }
    It 'rend les filets vivants en vert avec leur état' {
        $htmlUp | Should -Match 'récentes'
        $htmlUp | Should -Match 'active, 3 point'
        $htmlUp | Should -Match 'adéquate'
        $htmlUp | Should -Match 'Enabled'
        # 'pill p-ok' et pas 'p-ok' seul : la feuille de style déclare toutes les
        # pastilles, seul l'attribut class rendu prouve le niveau affiché.
        $htmlUp | Should -Match 'pill p-ok'
        $htmlUp | Should -Not -Match 'pill p-err'
        $htmlUp | Should -Not -Match 'pill p-warn'
    }
    It 'signale les filets morts avec la raison et la pastille d''alerte' {
        $htmlDown | Should -Match 'ruche SYSTEM figée depuis plus de 7 jours'
        $htmlDown | Should -Match 'désactivée'
        $htmlDown | Should -Match 'insuffisante'
        $htmlDown | Should -Match 'Disabled'
        $htmlDown | Should -Match 'chiffré SANS mot de passe'
        $htmlDown | Should -Match 'pill p-err'
        $htmlDown | Should -Match 'pill p-warn'
    }
    It 'traduit les jetons des outils Windows sans perdre la valeur technique' {
        $htmlUp   | Should -Match 'armé \(Enabled\)'
        $htmlUp   | Should -Match 'active \(Yes\)'
        $htmlDown | Should -Match 'désarmé \(Disabled\)'
        $htmlDown | Should -Match 'inactive \(No\)'
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ WinReStatus = 'Unknown'; WinReLevel = 'WARN'; RecoveryEnabledStatus = 'Absent'; RecoveryEnabledLevel = 'WARN' })
        $h | Should -Match 'état non lisible'
        $h | Should -Match 'absente du BCD'
    }
    It 'alerte quand la restauration est active mais sans aucun point (zéro mesuré)' {
        # Un service actif sans un seul point n'est pas un filet : le rapport doit
        # le dire, sinon la ligne verte « active » rassure à tort.
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ RestoreEnabled = $true; RestorePointCount = 0 })
        $h | Should -Match 'Restauration système'
        $h | Should -Match 'aucun point présent'
        $h | Should -Match 'pill p-warn'
        $h | Should -Not -Match 'pill p-ok'
    }
    It 'alerte aussi quand la restauration est désactivée avec zéro point' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ RestoreEnabled = $false; RestorePointCount = 0 })
        $h | Should -Match 'désactivée, aucun point présent'
        $h | Should -Match 'pill p-warn'
    }
    It 'n''affirme rien quand le comptage des points n''a pas pu être mesuré (null)' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ RestoreEnabled = $true; RestorePointCount = $null })
        $h | Should -Match 'Restauration système'
        $h | Should -Match 'non lisible'
        $h | Should -Match 'pill p-info'
        $h | Should -Not -Match 'active, '
        $h | Should -Not -Match 'aucun point présent'
        $h | Should -Not -Match 'désactivée'
    }
    It 'n''affirme rien quand l''état du service est absent de la section' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ RestorePointCount = 4 })
        $h | Should -Match 'Restauration système'
        $h | Should -Match 'non lisible'
        $h | Should -Not -Match 'active, '
        $h | Should -Not -Match 'désactivée'
    }
    It 'rend l''espace libre non mesuré en ligne neutre (volume C: absent)' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ FreeSpaceLevel = 'Unknown' })
        $h | Should -Match 'Espace libre C:'
        $h | Should -Match 'non mesurable'
        $h | Should -Match 'pill p-info'
        $h | Should -Not -Match 'pill p-ok'
        $h | Should -Not -Match 'suffisant'
    }
    It 'ne conclut pas « insuffisante » quand la réserve de clichés n''a pas été mesurée' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ ShadowAdequate = $null })
        $h | Should -Match 'Réserve de clichés'
        $h | Should -Match 'non lisible'
        $h | Should -Match 'pill p-info'
        $h | Should -Not -Match 'insuffisante'
        $h | Should -Not -Match 'adéquate'
    }
    It 'rend le BitLocker chiffré avec clé en pastille neutre (INFO, pas une alerte)' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ BitLockerC = [PSCustomObject]@{ Level = 'INFO'; Reason = 'chiffré, protecteur de récupération présent - vérifier aka.ms/myrecoverykey' } })
        $h | Should -Match 'pill p-info'
        $h | Should -Not -Match 'pill p-err'
        $h | Should -Not -Match 'pill p-warn'
        $h | Should -Match 'aka\.ms/myrecoverykey'
    }
    It 'omet la carte sur un diagnostic antérieur à v2.4 (section absente)' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @()
        $h | Should -Not -Match 'Filets de sécurité'
    }
    It 'tolère une section Resilience partielle sans lever (StrictMode)' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ FreeSpaceLevel = 'OK' })
        $h | Should -Match 'Filets de sécurité'
        $h | Should -Match 'Espace libre C:'
    }
    It 'échappe l''état renvoyé par les outils système (anti-injection)' {
        $h = ConvertTo-ReportHtml -Summary $sum -Meta @{ ComputerName = 'PC-TEST' } -Lines @() `
                 -Resilience ([PSCustomObject]@{ WinReStatus = '<script>alert(1)</script>'; WinReLevel = 'WARN' })
        $h | Should -Not -Match '<script>'
        $h | Should -Match '&lt;script&gt;'
    }
}

Describe 'ConvertTo-KitAsciiToken' {
    It 'laisse intact un nom de machine déjà ASCII' {
        ConvertTo-KitAsciiToken -Text 'PC-BUREAU_01' | Should -Be 'PC-BUREAU_01'
    }
    It 'remplace chaque caractère non ASCII par un tiret (nom accentué)' {
        ConvertTo-KitAsciiToken -Text 'PC-CHÂTEAU' | Should -Be 'PC-CH-TEAU'
    }
    It 'remplace les caractères interdits dans un nom de dossier' {
        ConvertTo-KitAsciiToken -Text 'POSTE 1:\SALLE?' | Should -Be 'POSTE-1--SALLE-'
    }
    It 'retombe sur le repli quand il ne reste rien (vide, null, points)' {
        ConvertTo-KitAsciiToken -Text ''    | Should -Be 'PC'
        ConvertTo-KitAsciiToken -Text $null | Should -Be 'PC'
        ConvertTo-KitAsciiToken -Text '...' | Should -Be 'PC'
    }
    It 'coupe les points finaux (interdits en fin de nom de dossier Windows)' {
        ConvertTo-KitAsciiToken -Text 'PC.' | Should -Be 'PC'
    }
    It 'préfixe les noms de périphériques réservés de Windows' {
        ConvertTo-KitAsciiToken -Text 'NUL'  | Should -Be 'PC-NUL'
        ConvertTo-KitAsciiToken -Text 'com1' | Should -Be 'PC-com1'
    }
    It 'tronque à la longueur maximale' {
        (ConvertTo-KitAsciiToken -Text ('A' * 60)).Length | Should -Be 32
    }
    It 'produit toujours du pur ASCII, quel que soit l''alphabet d''entrée' {
        foreach ($nom in @('ПК-ДОМ', '家のパソコン', 'PC-ÉLÈVE', 'PC-BUREAU')) {
            $t = ConvertTo-KitAsciiToken -Text $nom
            # Garde @() obligatoire sous StrictMode Latest : .Count sur un pipeline
            # vide (cas nominal) lèverait PropertyNotFoundStrict.
            @([System.Text.Encoding]::UTF8.GetBytes($t) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
            $t | Should -Not -BeNullOrEmpty
        }
    }
    It 'est déterministe (même entrée, même sortie)' {
        $a = ConvertTo-KitAsciiToken -Text 'PC-CHÂTEAU'
        $b = ConvertTo-KitAsciiToken -Text 'PC-CHÂTEAU'
        $a | Should -Be $b
    }
}

Describe 'Module 16-Resilience : invariants de code' {
    BeforeAll { $script:m16 = Get-Content "$PSScriptRoot\..\modules\16-Resilience.ps1" -Raw -Encoding UTF8 }
    It 'existe et expose -ExportBitLockerKey' {
        $script:m16 | Should -Match '\[switch\]\$ExportBitLockerKey'
    }
    It 'ne reduit JAMAIS le shadowstorage (agrandissement conditionne par Test-ShadowStorageAdequate)' {
        $script:m16 | Should -Match 'Test-ShadowStorageAdequate'
        # le resize n'apparait que dans la branche inadequate
        $script:m16 | Should -Match 'vssadmin resize shadowstorage'
    }
    It 'sauvegarde les 5 ruches via reg save (table hiveSpecs + appel)' {
        foreach ($h in @('HKLM\SYSTEM','HKLM\SOFTWARE','HKLM\SAM','HKLM\SECURITY','HKU\.DEFAULT')) {
            $script:m16 | Should -Match ([regex]::Escape($h))
        }
        $script:m16 | Should -Match '&\s+reg\s+save'
    }
    It 'ecrit le manifeste en ASCII' {
        $script:m16 | Should -Match 'ConvertTo-KitManifestLines'
        $script:m16 | Should -Match "Encoding Ascii"
    }
    It 'ne met JAMAIS la cle BitLocker dans le coffre local' {
        # la variable du chemin local ne doit pas apparaitre dans le bloc export
        $script:m16 | Should -Match 'bitlocker-recovery\.txt'
        ($script:m16 -split 'bitlocker-recovery\.txt')[0] | Should -Match '\$externalSet'
    }
    It 'assainit le nom de la machine avant tout chemin ou manifeste (garantie ASCII cote WinRE)' {
        # secours.bat parse manifest.txt avec `for /f` sous une page de codes OEM :
        # un nom de machine accentue y deviendrait illisible, et le dossier du
        # coffre innavigable. Le nom brut ne doit jamais atterrir dans un chemin.
        $script:m16 | Should -Match 'ConvertTo-KitAsciiToken'
        $script:m16 | Should -Not -Match 'Coffre\\\$env:COMPUTERNAME'
    }
    It 'ne journalise jamais le mot de passe de recuperation BitLocker' {
        $script:m16 | Should -Not -Match 'Write-KitLog[^\r\n]*\$recoveryPass'
    }
    It 'fait tourner separement les jeux complets et les jeux incomplets' {
        # Un jeu incomplet (reg save en echec, pas de manifeste) ne doit jamais
        # evincer un jeu complet encore utilisable : deux rotations distinctes.
        @([regex]::Matches($script:m16, 'Get-DirsToRotate')).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Coffre de ruches : verrou d''accès (local ET externe à ACL)' {
    BeforeAll {
        # Les fonctions du verrou vivent dans modules/16-Resilience.ps1, qui ne
        # peut pas être dot-sourcé ici : il exige l'élévation et écrirait pour de
        # vrai. On en extrait les seules définitions par l'AST, sans exécuter une
        # ligne du corps du module.
        $script:m16AclPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\16-Resilience.ps1'
        $m16AclAst = [System.Management.Automation.Language.Parser]::ParseFile($script:m16AclPath, [ref]$null, [ref]$null)
        foreach ($fnName in @('Set-KitVaultAclRules', 'Test-KitVaultAclSafe', 'Protect-KitVaultDir',
                              'Test-KitVaultFsSupportsAcl', 'Test-KitRemovableMedium',
                              'Get-KitVolumeFileSystem', 'Test-KitReparsePoint')) {
            $fnAst = @($m16AclAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true))
            if ($fnAst.Count -ne 1) { throw "$fnName : $($fnAst.Count) définition(s) dans 16-Resilience.ps1 (attendu 1)" }
            . ([scriptblock]::Create($fnAst[0].Extent.Text))
        }
        $script:m16AclSrc = Get-Content $script:m16AclPath -Raw -Encoding UTF8

        # SID d'un compte standard fictif : celui qui aurait pré-créé le coffre et
        # en serait resté CRÉATEUR PROPRIÉTAIRE (donc WRITE_DAC implicite).
        $script:sidCompteStandard = 'S-1-5-21-1111111111-2222222222-3333333333-1001'

        # ACL de départ : celle qu'un dossier créé sous C:\ProgramData reçoit par
        # héritage. Utilisateurs y a un ReadAndExecute - c'est très exactement la
        # faille (SAM et SECURITY lisibles par tout compte standard) à refermer.
        # Propriétaire : le compte standard, comme après une pré-création hostile.
        function New-KitAclOuverteDeTest {
            $sd = New-Object System.Security.AccessControl.DirectorySecurity
            $sd.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:sidCompteStandard)))
            $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            foreach ($s in @('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11')) {
                $sd.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($s)),
                    [System.Security.AccessControl.FileSystemRights]::ReadAndExecute, $inh,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            foreach ($s in @('S-1-5-18', 'S-1-5-32-544')) {
                $sd.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($s)),
                    [System.Security.AccessControl.FileSystemRights]::FullControl, $inh,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            return $sd
        }
        function Get-KitAclSids {
            param($Acl)
            return @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                     ForEach-Object { [string]$_.IdentityReference.Value })
        }
        function Get-KitAclOwnerSid {
            param($Acl)
            $o = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier])
            if ($null -eq $o) { return '' }
            return [string]$o.Value
        }
    }

    Context 'Set-KitVaultAclRules (pure, aucun accès disque)' {
        It 'coupe l''héritage' {
            $r = Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)
            $r.AreAccessRulesProtected | Should -BeTrue
        }
        It 'ne laisse que SYSTEM et Administrateurs, désignés par SID' {
            $r = Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)
            ((Get-KitAclSids -Acl $r) | Sort-Object -Unique) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544'
        }
        It 'évacue Utilisateurs, Tout le monde et Utilisateurs authentifiés' {
            $sids = Get-KitAclSids -Acl (Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest))
            $sids | Should -Not -Contain 'S-1-5-32-545'   # BUILTIN\Utilisateurs
            $sids | Should -Not -Contain 'S-1-1-0'        # Tout le monde
            $sids | Should -Not -Contain 'S-1-5-11'       # Utilisateurs authentifiés
        }
        It 'pose exactement deux ACE, toutes deux en contrôle total héritable' {
            $r     = Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)
            $rules = @($r.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $rules.Count | Should -Be 2
            foreach ($ace in $rules) {
                $ace.FileSystemRights   | Should -Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
                $ace.AccessControlType  | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow)
                $ace.InheritanceFlags   | Should -Be ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')
            }
        }
        It 'reprend la PROPRIÉTÉ au groupe Administrateurs local' {
            # Sans cette reprise, la DACL ne protège rien : le compte standard qui
            # a pré-créé le dossier en reste propriétaire, garde WRITE_DAC de façon
            # implicite, et rouvre le coffre APRÈS l'écriture de SAM.
            $ouverte = New-KitAclOuverteDeTest
            Get-KitAclOwnerSid -Acl $ouverte | Should -Be $script:sidCompteStandard
            Get-KitAclOwnerSid -Acl (Set-KitVaultAclRules -Acl $ouverte) | Should -Be 'S-1-5-32-544'
        }
    }

    Context 'Test-KitVaultAclSafe (le verdict d''après coup)' {
        It 'accepte la sortie de Set-KitVaultAclRules' {
            Test-KitVaultAclSafe -Acl (Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)) | Should -BeTrue
        }
        It 'refuse une ACL restée ouverte (héritage non coupé)' {
            Test-KitVaultAclSafe -Acl (New-KitAclOuverteDeTest) | Should -BeFalse
        }
        It 'refuse une ACL protégée mais encore partagée avec un tiers' {
            $acl = Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')),
                [System.Security.AccessControl.FileSystemRights]::Read,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
            Test-KitVaultAclSafe -Acl $acl | Should -BeFalse
        }
        It 'refuse un accès partiel là où le contrôle total est attendu' {
            $sd = New-Object System.Security.AccessControl.DirectorySecurity
            $sd.SetAccessRuleProtection($true, $false)
            $sd.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')),
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
            $sd.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')),
                [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
            Test-KitVaultAclSafe -Acl $sd | Should -BeFalse
        }
        It 'refuse un coffre à la DACL parfaite mais resté la propriété du compte qui l''a pré-créé' {
            # Le cas HiveNightmare exact : DACL impeccable, propriétaire hostile.
            # Le propriétaire détient WRITE_DAC quoi que dise la DACL.
            $acl = Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)
            $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:sidCompteStandard)))
            Test-KitVaultAclSafe -Acl $acl | Should -BeFalse
        }
        It 'refuse une description sans propriétaire (on ne suppose rien)' {
            # DACL exacte, mais propriétaire absent : la fonction ne doit ni lever
            # (déréférencement de $null sous StrictMode) ni conclure au vert.
            $nu = New-Object System.Security.AccessControl.DirectorySecurity
            $nu.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $nu.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($sid)),
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            Get-KitAclOwnerSid -Acl $nu   | Should -Be ''
            Test-KitVaultAclSafe -Acl $nu | Should -BeFalse
        }
        It 'refuse un ACE de REFUS posé sur une identité pourtant attendue' {
            # Un Deny sur SYSTEM ou Administrateurs passe un simple contrôle
            # d'identité (le SID est dans la liste attendue) tout en verrouillant
            # le coffre contre ses propres ayants droit : ni écriture, ni secours.
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $acl = Set-KitVaultAclRules -Acl (New-KitAclOuverteDeTest)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($sid)),
                    [System.Security.AccessControl.FileSystemRights]::Write,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Deny)))
                Test-KitVaultAclSafe -Acl $acl | Should -BeFalse
            }
        }
        It 'refuse un verrou non héritable (les RUCHES n''en hériteraient pas)' {
            # Le dossier serait fermé, mais SAM et SECURITY écrits dedans
            # n'hériteraient d'aucun ACE : les secrets resteraient lisibles.
            $sd = New-Object System.Security.AccessControl.DirectorySecurity
            $sd.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            $sd.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $sd.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($sid)),
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            Test-KitVaultAclSafe -Acl $sd | Should -BeFalse
        }
    }

    Context 'Test-KitVaultFsSupportsAcl (le système de fichiers décide, pas le type de lecteur)' {
        It 'NTFS et ReFS portent des ACL : le coffre y est verrouillé, externe compris' {
            foreach ($fs in @('NTFS', 'ntfs', ' NTFS ', 'ReFS', 'REFS')) {
                Test-KitVaultFsSupportsAcl -FileSystem $fs | Should -BeTrue -Because "$fs porte des ACL"
            }
        }
        It 'FAT, FAT32 et exFAT n''en portent pas : protection physique assumée' {
            foreach ($fs in @('FAT', 'FAT16', 'FAT32', 'fat32', 'exFAT', 'EXFAT')) {
                Test-KitVaultFsSupportsAcl -FileSystem $fs | Should -BeFalse -Because "$fs ne peut porter aucune ACL"
            }
        }
        It 'un système de fichiers non mesuré est traité comme portant des ACL (fermeture par défaut)' {
            # Le sens inverse promettrait une « protection physique » sur un
            # volume qui, peut-être, porte des ACL grandes ouvertes : c'est
            # exactement la faille que cette correction referme.
            foreach ($fs in @('', '   ', $null, 'systeme-inconnu')) {
                Test-KitVaultFsSupportsAcl -FileSystem $fs | Should -BeTrue
            }
        }
    }

    Context 'Test-KitRemovableMedium (la clé BitLocker ne quitte pas l''amovible)' {
        It 'accepte le support amovible, quelle que soit la casse rendue par la sonde' {
            # La comparaison est celle de PowerShell, insensible à la casse :
            # refuser « removable » sur la casse ferait sauter l'export sur une
            # source qui rend le type autrement que Get-Volume.
            foreach ($t in @('Removable', ' Removable ', 'removable', 'REMOVABLE')) {
                Test-KitRemovableMedium -DriveType $t | Should -BeTrue
            }
        }
        It 'refuse un support non amovible, fût-il externe (SSD ou disque USB vus « Fixed »)' {
            foreach ($t in @('Fixed', 'Network', 'CD-ROM', 'Unknown')) {
                Test-KitRemovableMedium -DriveType $t | Should -BeFalse -Because "$t n'est pas un support amovible identifié"
            }
        }
        It 'refuse un type non mesuré (48 chiffres n''atterrissent pas sur un support non identifié)' {
            Test-KitRemovableMedium -DriveType ''    | Should -BeFalse
            Test-KitRemovableMedium -DriveType $null | Should -BeFalse
        }
    }

    Context 'Get-KitVolumeFileSystem (sonde réelle, en lecture seule)' {
        It 'lit le système de fichiers du volume système' {
            # Sonde en lecture pure : aucune écriture, aucun privilège requis.
            Get-KitVolumeFileSystem -DriveRoot $env:SystemDrive | Should -Match '^(NTFS|ReFS)$'
        }
        It 'accepte les formes « C », « C: » et « C:\ »' {
            $ref = Get-KitVolumeFileSystem -DriveRoot $env:SystemDrive
            $l   = $env:SystemDrive.Substring(0, 1)
            foreach ($forme in @($l, ($l + ':'), ($l + ':\'))) {
                Get-KitVolumeFileSystem -DriveRoot $forme | Should -Be $ref
            }
        }
        It 'rend une chaîne vide sur ce qui n''est pas une lettre de lecteur' {
            Get-KitVolumeFileSystem -DriveRoot ''              | Should -Be ''
            Get-KitVolumeFileSystem -DriveRoot '1:'            | Should -Be ''
            Get-KitVolumeFileSystem -DriveRoot '\\serveur\part' | Should -Be ''
        }
        It 'enchaînée à la décision, elle rend « à verrouiller » sur un volume Windows' {
            # La chaîne complète telle que le module l'exécute pour le coffre
            # externe : sonde du système de fichiers, puis politique.
            Test-KitVaultFsSupportsAcl -FileSystem (Get-KitVolumeFileSystem -DriveRoot $env:SystemDrive) | Should -BeTrue
        }
    }

    Context 'Ordre imposé dans le module' {
        It 'referme le coffre local AVANT le premier reg save' {
            $iProt = $script:m16AclSrc.IndexOf('Protect-KitVaultDir -Path')
            $iSave = $script:m16AclSrc.IndexOf('& reg save')
            $iProt | Should -BeGreaterThan 0
            $iSave | Should -BeGreaterThan $iProt
        }
        It 'coupe court à chaque verrou local en échec, avant tout reg save' {
            # Assertion de STRUCTURE et non de libellé : entre chaque pose du
            # verrou et le premier reg save, le module doit sortir de la boucle
            # (continue) et marquer l'échec (exitCode). Un libellé peut être
            # reformulé sans rien casser ; supprimer la sortie de boucle, non.
            $iSave = $script:m16AclSrc.IndexOf('& reg save')
            $iSave | Should -BeGreaterThan 0
            $sites = @([regex]::Matches($script:m16AclSrc, 'Protect-KitVaultDir -Path'))
            $sites.Count | Should -Be 2
            foreach ($m in $sites) {
                $segment = $script:m16AclSrc.Substring($m.Index, $iSave - $m.Index)
                $segment | Should -Match '\bcontinue\b'
                $segment | Should -Match '\$exitCode = 1'
            }
        }
        It 'ne pose aucun verrou (donc ne modifie aucune ACL) sous -WhatIf' {
            # Structure : dans la boucle des destinations, la branche -WhatIf
            # sort par continue AVANT d'atteindre la moindre pose de verrou.
            $iWhatIf   = $script:m16AclSrc.IndexOf('WHATIF: Aurait restreint')
            $iProtect  = $script:m16AclSrc.IndexOf('Protect-KitVaultDir -Path')
            $iWhatIf   | Should -BeGreaterThan 0
            $iProtect  | Should -BeGreaterThan $iWhatIf
            $script:m16AclSrc.Substring($iWhatIf, $iProtect - $iWhatIf) | Should -Match '\bcontinue\b'
        }
        It 'verrouille le coffre EXTERNE comme le local dès que son volume porte des ACL' {
            # Les deux poses du verrou sont gardées par « $dest.Acl », et non
            # plus par « -not $dest.External » : une seconde partition interne en
            # NTFS, ou une clé formatée en NTFS, livrerait sinon SAM, SECURITY et
            # SYSTEM en lecture à tout compte standard de la machine, en
            # permanence (3 jeux conservés).
            @([regex]::Matches($script:m16AclSrc, 'Protect-KitVaultDir -Path')).Count | Should -Be 2
            @([regex]::Matches($script:m16AclSrc, 'if \(\$dest\.Acl\) \{')).Count | Should -BeGreaterOrEqual 2
            # Aucune pose de verrou ne reste réservée au seul coffre local.
            $script:m16AclSrc | Should -Not -Match '(?s)if \(-not \$dest\.External\)[^\r\n]*\r?\n[^\r\n]*Protect-KitVaultDir'
            # Et le drapeau vient de la sonde du système de fichiers, jamais du
            # type de lecteur (une clé USB peut être en NTFS, un disque interne aussi).
            $script:m16AclSrc | Should -Match 'Acl = \$externalAcl'
            $script:m16AclSrc | Should -Match '\$externalAcl\s*=\s*Test-KitVaultFsSupportsAcl -FileSystem \$externalFs'
            $script:m16AclSrc | Should -Match '\$externalFs\s*=\s*Get-KitVolumeFileSystem -DriveRoot \$externalRoot'
        }
        It 'coupe court sur un coffre externe non verrouillable là où le verrou est dû' {
            # Même fermeture par défaut que le coffre local : message qui nomme le
            # volume à ACL, sortie de boucle, échec du module, aucune ruche écrite.
            $script:m16AclSrc | Should -Match 'coffre \$destLabel NON protégé sur un volume à ACL'
            $iSave = $script:m16AclSrc.IndexOf('& reg save')
            foreach ($m in @([regex]::Matches($script:m16AclSrc, 'coffre \$destLabel NON protégé sur un volume à ACL'))) {
                $m.Index | Should -BeLessThan $iSave
                $segment = $script:m16AclSrc.Substring($m.Index, $iSave - $m.Index)
                $segment | Should -Match '\bcontinue\b'
            }
            @([regex]::Matches($script:m16AclSrc, '\$exitCode = 1')).Count | Should -BeGreaterThan 2
        }
        It 'écrit quand même, en avertissant, sur un support qui ne peut porter aucune ACL' {
            # Seul cas où la protection reste physique : la clé navette en FAT32
            # ou exFAT. Le module l'annonce AVANT la boucle et n'abandonne pas le
            # coffre, sinon la clé de secours ne serait jamais remplie.
            $iWarn = $script:m16AclSrc.IndexOf("ne porte pas d'ACL, la protection est PHYSIQUE")
            $iLoop = $script:m16AclSrc.IndexOf('foreach ($dest in $destinations)')
            $iWarn | Should -BeGreaterThan 0
            $iLoop | Should -BeGreaterThan $iWarn
            $script:m16AclSrc | Should -Match 'conservez la clé comme un trousseau'
        }
        It 'avertit que le coffre externe porte SAM et SECURITY, verrouillé ou non' {
            @([regex]::Matches($script:m16AclSrc, 'Le coffre externe contient SAM et SECURITY')).Count |
                Should -BeGreaterOrEqual 2
        }
        It 'refuse la clé de récupération BitLocker à un coffre externe non amovible' {
            # Défense en profondeur : 48 chiffres qui ouvrent le disque n'ont rien
            # à faire sur une partition interne, fût-elle verrouillée par ACL. La
            # décision précède l'écriture du fichier.
            $avantEcriture = ($script:m16AclSrc -split 'bitlocker-recovery\.txt')[0]
            $avantEcriture | Should -Match '\$externalSet'
            $avantEcriture | Should -Match 'Test-KitRemovableMedium -DriveType \$externalType'
            $avantEcriture | Should -Match 'Clé BitLocker NON exportée'
        }
        It 'ne sort pas en 0 quand aucune destination de coffre n''est disponible' {
            # La fiche de clôture annonce « Coffre de ruches à jour (module
            # Filets de secours en OK) » : un module qui n'a sauvegardé aucune
            # ruche doit échouer, sinon la ligne se coche à tort.
            $i = $script:m16AclSrc.IndexOf('aucune destination de coffre')
            $i | Should -BeGreaterThan 0
            $bloc = $script:m16AclSrc.Substring($i, [math]::Min(500, $script:m16AclSrc.Length - $i))
            $bloc | Should -Match 'PAS sauvegardées'
            $bloc | Should -Match '\$exitCode = 1'
        }
        It 'refuse un dossier ProgramData qui est un point d''analyse, avant tout usage' {
            # C:\ProgramData laisse « Utilisateurs » créer un sous-dossier :
            # PC-Refresh-Kit peut donc avoir été posé en jonction AVANT le kit, et
            # l'empreinte machine comme le coffre local partiraient chez celui qui
            # l'a posée - le verrou d'ACL s'appliquant à la cible sans le dire.
            $iDef   = $script:m16AclSrc.IndexOf('$pdDir     = Join-Path')
            $iCheck = $script:m16AclSrc.IndexOf('Test-KitReparsePoint -Path $pdDir')
            $iRead  = $script:m16AclSrc.IndexOf('[System.IO.File]::ReadAllBytes($midPath)')
            $iWrite = $script:m16AclSrc.IndexOf('Set-Content -Path $midPath')
            $iDef   | Should -BeGreaterThan 0
            $iCheck | Should -BeGreaterThan $iDef
            $iRead  | Should -BeGreaterThan $iCheck
            $iWrite | Should -BeGreaterThan $iCheck
            # Le coffre LOCAL n'est proposé que si ce dossier est sain.
            $script:m16AclSrc | Should -Match '\$localUsable\s*=\s*\(\$localOk -and \$pdSafe\)'
            $script:m16AclSrc | Should -Match 'if \(\$localUsable\) \{ \$destinations \+='
        }
        It 'écarte les points d''analyse de la rotation au lieu de les supprimer' {
            $script:m16AclSrc | Should -Match 'ReparsePoint'
            # La liste soumise à la rotation est filtrée AVANT le partage
            # complets/incomplets, donc avant tout Remove-Item.
            $iFiltre = $script:m16AclSrc.IndexOf('$sets       = @($tousSets')
            $iPurge  = $script:m16AclSrc.IndexOf('Rotation du coffre : supprimé')
            $iFiltre | Should -BeGreaterThan 0
            $iPurge  | Should -BeGreaterThan $iFiltre
        }
    }

    # -----------------------------------------------------------------------
    # Sur DISQUE RÉEL. Les descriptions de sécurité fabriquées en mémoire ne
    # peuvent pas porter d'ACE HÉRITÉ : seul un vrai dossier le peut. Or c'est
    # exactement l'héritage que SetAccessRuleProtection($true, $false) doit
    # couper pour évacuer « Utilisateurs » - le mécanisme même de la correction.
    # Ces tests s'exécutent SANS élévation : Set-Acl sur un dossier dont on est
    # propriétaire ne demande aucun privilège.
    # -----------------------------------------------------------------------
    Context 'Sur disque réel (le mécanisme d''éviction, pas seulement la description)' {
        BeforeAll {
            $script:estEleve = (New-Object System.Security.Principal.WindowsPrincipal(
                [System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
                [System.Security.Principal.WindowsBuiltInRole]::Administrator)
            $script:sidMoi = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value

            # Rend au compte courant l'accès que le verrou vient de lui retirer,
            # sinon le ménage de fin de test (et celui de TestDrive) échoue.
            # icacls et NON Set-Acl : une fois le verrou posé, le compte courant
            # n'a plus le moindre accès par la DACL, il n'est plus que
            # propriétaire ; Set-Acl échoue alors en réclamant SeSecurityPrivilege
            # alors qu'icacls se contente du WRITE_DAC implicite du propriétaire.
            # Rustine de TEST uniquement : le kit tourne élevé et garde le
            # contrôle total par son propre ACE Administrateurs.
            function Restore-KitTestDirAcl {
                param([AllowEmptyString()][string]$Path)
                if ([string]::IsNullOrEmpty($Path)) { return }
                if (-not (Test-Path -LiteralPath $Path)) { return }
                & icacls "$Path" /grant "*$($script:sidMoi):(OI)(CI)F" /T /C 2>&1 | Out-Null
            }
        }
        BeforeEach {
            # Un PARENT qui lègue un ACE « Utilisateurs » héritable, un ENFANT qui
            # en hérite : la situation exacte d'un dossier posé sous C:\ProgramData.
            $script:parent = (New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
            $pa = Get-Acl -LiteralPath $script:parent
            $pa.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')),
                [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
            Set-Acl -LiteralPath $script:parent -AclObject $pa
            $script:coffre = (New-Item -ItemType Directory -Force -Path (Join-Path $script:parent 'HiveVault')).FullName
            $script:voisin = (New-Item -ItemType Directory -Force -Path (Join-Path $script:parent 'temoin')).FullName
            # Renseigné par le test du coffre EXTERNE : le ménage doit rendre
            # l'accès à CE sous-arbre aussi, sinon TestDrive resterait verrouillé.
            $script:coffreExterne = ''
        }
        AfterEach {
            Restore-KitTestDirAcl -Path $script:coffre
            Restore-KitTestDirAcl -Path $script:coffreExterne
            Remove-Item -LiteralPath $script:parent -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'évacue un ACE Utilisateurs réellement HÉRITÉ et referme le dossier' {
            # Point de départ vérifié : Utilisateurs est là, et par HÉRITAGE.
            $avant = Get-Acl -LiteralPath $script:coffre
            $avant.AreAccessRulesProtected | Should -BeFalse
            @($avant.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
              Where-Object { [string]$_.IdentityReference.Value -eq 'S-1-5-32-545' -and $_.IsInherited }
             ).Count | Should -BeGreaterThan 0

            $res = Protect-KitVaultDir -Path $script:coffre
            if (-not $res.Ok) {
                # Hors élévation, Windows refuse de donner la propriété au groupe
                # Administrateurs (il n'est présent dans le jeton filtré qu'en
                # refus). Set-Acl échoue alors EN BLOC, sans rien appliquer :
                # c'est la fermeture par défaut voulue, on la vérifie.
                $res.Reparse | Should -BeFalse
                (Get-Acl -LiteralPath $script:coffre).AreAccessRulesProtected | Should -BeFalse
                # Puis on rejoue les mêmes règles avec la propriété laissée au
                # compte courant, pour prouver quand même l'éviction sur disque.
                $acl = Get-Acl -LiteralPath $script:coffre
                [void](Set-KitVaultAclRules -Acl $acl)
                $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:sidMoi)))
                Set-Acl -LiteralPath $script:coffre -AclObject $acl -ErrorAction Stop
            }

            $apres = Get-Acl -LiteralPath $script:coffre
            $apres.AreAccessRulesProtected | Should -BeTrue
            $regles = @($apres.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            (@($regles | ForEach-Object { [string]$_.IdentityReference.Value }) | Sort-Object -Unique) -join ',' |
                Should -Be 'S-1-5-18,S-1-5-32-544'
            foreach ($sid in @('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11')) {
                @($regles | Where-Object { [string]$_.IdentityReference.Value -eq $sid }).Count | Should -Be 0
            }
            foreach ($ace in $regles) {
                $ace.AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow)
                ([int]$ace.FileSystemRights -band [int][System.Security.AccessControl.FileSystemRights]::FullControl) |
                    Should -Be ([int][System.Security.AccessControl.FileSystemRights]::FullControl)
                ([int]$ace.InheritanceFlags -band [int][System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit') |
                    Should -Be ([int][System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')
            }

            if ($res.Ok) {
                # Chemin élevé (celui du kit, qui exige l'élévation) : propriété
                # reprise et verdict au vert.
                Get-KitAclOwnerSid -Acl $apres | Should -Be 'S-1-5-32-544'
                Test-KitVaultAclSafe -Acl $apres | Should -BeTrue
            }
            else {
                # Chemin non élevé : propriété restée au compte courant, et le
                # verdict le REFUSE - contre-preuve que le garde-fou propriétaire
                # fonctionne sur une ACL relue du disque, pas juste en mémoire.
                Get-KitAclOwnerSid -Acl $apres | Should -Be $script:sidMoi
                Test-KitVaultAclSafe -Acl $apres | Should -BeFalse
                $script:estEleve | Should -BeFalse   # sinon l'échec est une vraie régression
            }
            # Contre-preuve : le dossier voisin, laissé ouvert, est bien refusé.
            Test-KitVaultAclSafe -Acl (Get-Acl -LiteralPath $script:voisin) | Should -BeFalse
        }

        It 'fait hériter le verrou aux FICHIERS du coffre (les ruches elles-mêmes)' {
            # Le fichier est créé AVANT le verrou : Windows propage les ACE
            # héritables aux enfants existants. C'est ce que vit une ruche déjà
            # écrite, et c'est elle qui porte les empreintes de mots de passe.
            $ruche = Join-Path $script:coffre 'SAM'
            Set-Content -LiteralPath $ruche -Value 'ruche factice' -Encoding Ascii
            @((Get-Acl -LiteralPath $ruche).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
              Where-Object { [string]$_.IdentityReference.Value -eq 'S-1-5-32-545' }).Count | Should -BeGreaterThan 0

            $res = Protect-KitVaultDir -Path $script:coffre
            if (-not $res.Ok) {
                $acl = Get-Acl -LiteralPath $script:coffre
                [void](Set-KitVaultAclRules -Acl $acl)
                $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:sidMoi)))
                Set-Acl -LiteralPath $script:coffre -AclObject $acl -ErrorAction Stop
            }
            # Le verrou a exclu le compte courant : il ne peut plus même LIRE
            # l'ACL du fichier (le dossier lui refuse la liste). On se redonne un
            # droit de parcours sur le DOSSIER seul - explicite, sans (OI)(CI),
            # donc sans toucher à l'ACL du fichier qu'on s'apprête à observer.
            & icacls "$script:coffre" /grant "*$($script:sidMoi):(RX)" /C 2>&1 | Out-Null
            $aclRuche = Get-Acl -LiteralPath $ruche
            $sidsRuche = @($aclRuche.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                           ForEach-Object { [string]$_.IdentityReference.Value })
            ($sidsRuche | Sort-Object -Unique) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544'
            @($sidsRuche | Where-Object { $_ -eq 'S-1-5-32-545' }).Count | Should -Be 0
        }

        It 'verrouille un coffre EXTERNE posé sur un volume NTFS (partition interne ou clé NTFS)' {
            # $TestDrive vit sur le volume système, donc en NTFS : c'est très
            # exactement ce qu'est une seconde partition interne, ou une clé USB
            # formatée en NTFS - le cas où l'ancien code écrivait
            # D:\Coffre\<PC>\hives-*\SAM lisible par tout compte standard.
            Get-KitVolumeFileSystem -DriveRoot $script:parent | Should -Match '^(NTFS|ReFS)$'
            Test-KitVaultFsSupportsAcl -FileSystem (Get-KitVolumeFileSystem -DriveRoot $script:parent) | Should -BeTrue

            $script:coffreExterne = (New-Item -ItemType Directory -Force -Path (Join-Path $script:parent 'Coffre\PC-TEST')).FullName
            $jeu = (New-Item -ItemType Directory -Force -Path (Join-Path $script:coffreExterne 'hives-20260822-120000')).FullName
            $sam = Join-Path $jeu 'SAM'
            Set-Content -LiteralPath $sam -Value 'ruche factice' -Encoding Ascii
            # Point de départ mesuré : Utilisateurs lit SAM par HÉRITAGE. La faille.
            @((Get-Acl -LiteralPath $sam).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
              Where-Object { [string]$_.IdentityReference.Value -eq 'S-1-5-32-545' }).Count | Should -BeGreaterThan 0

            # Le module verrouille la racine du coffre PUIS le jeu du jour, dans
            # cet ordre, avant le premier reg save. On rejoue les deux poses.
            foreach ($d in @($script:coffreExterne, $jeu)) {
                $r = Protect-KitVaultDir -Path $d
                if (-not $r.Ok) {
                    # Hors élévation, Windows refuse de donner la propriété au
                    # groupe Administrateurs : Set-Acl échoue EN BLOC et le module
                    # sauterait la destination (fermeture par défaut, voulue). On
                    # rejoue les mêmes règles en gardant la propriété pour prouver
                    # quand même l'éviction sur disque.
                    $r.Reparse | Should -BeFalse
                    $acl = Get-Acl -LiteralPath $d
                    [void](Set-KitVaultAclRules -Acl $acl)
                    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:sidMoi)))
                    Set-Acl -LiteralPath $d -AclObject $acl -ErrorAction Stop
                }
                else { Test-KitVaultAclSafe -Acl (Get-Acl -LiteralPath $d) | Should -BeTrue }
                # Rustine de TEST, tout de suite après chaque pose : le verrou
                # vient d'exclure le compte courant, qui n'atteindrait plus le
                # dossier suivant du coffre ni l'ACL de la ruche. Droit de
                # PARCOURS seul, sans (OI)(CI), donc sans rien changer aux ACL
                # observées ensuite. Le kit, lui, tourne élevé et garde le
                # contrôle total par son ACE Administrateurs.
                & icacls "$d" /grant "*$($script:sidMoi):(RX)" /C 2>&1 | Out-Null
            }
            $sids = @((Get-Acl -LiteralPath $sam).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                      ForEach-Object { [string]$_.IdentityReference.Value })
            ($sids | Sort-Object -Unique) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544'
            # Utilisateurs, Tout le monde et Utilisateurs authentifiés évacués du
            # fichier SAM lui-même, sur le coffre EXTERNE comme sur le local.
            foreach ($sid in @('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11')) {
                @($sids | Where-Object { $_ -eq $sid }).Count | Should -Be 0
            }
        }

        It 'Test-KitReparsePoint distingue jonction, vrai dossier et chemin absent' {
            # Le même contrôle sert au coffre (local et externe) et au dossier
            # C:\ProgramData\PC-Refresh-Kit, qu'un compte standard peut pré-poser
            # en jonction puisque ProgramData l'autorise à créer un sous-dossier.
            $cible    = (New-Item -ItemType Directory -Force -Path (Join-Path $script:parent 'cible-reparse')).FullName
            $jonction = Join-Path $script:parent 'pd-jonction'
            New-Item -ItemType Junction -Path $jonction -Target $cible -ErrorAction Stop | Out-Null
            Test-KitReparsePoint -Path $jonction      | Should -BeTrue
            Test-KitReparsePoint -Path $script:coffre | Should -BeFalse
            Test-KitReparsePoint -Path (Join-Path $script:parent 'jamais-cree') | Should -BeFalse
        }

        It 'refuse un coffre déjà là qui est un point d''analyse (jonction pré-posée)' {
            # Get-Acl, Set-Acl et l'écriture traversent une jonction sans le dire :
            # sans ce refus, le kit verrouillerait - et remplirait de SAM et
            # SECURITY - un dossier choisi par le compte qui a posé la jonction.
            $cible  = (New-Item -ItemType Directory -Force -Path (Join-Path $script:parent 'cible-hors-coffre')).FullName
            $temoin = Join-Path $cible 'ne-pas-toucher.txt'
            Set-Content -LiteralPath $temoin -Value 'x' -Encoding Ascii
            $jonction = Join-Path $script:parent 'hives-2020-01-01'
            New-Item -ItemType Junction -Path $jonction -Target $cible -ErrorAction Stop | Out-Null

            $res = Protect-KitVaultDir -Path $jonction
            $res.Ok      | Should -BeFalse
            $res.Reparse | Should -BeTrue
            $res.Reason  | Should -Match "point d'analyse"
            # Ni verrouillée, ni suivie : la cible hors coffre est intacte.
            Test-Path -LiteralPath $temoin | Should -BeTrue
            (Get-Acl -LiteralPath $cible).AreAccessRulesProtected | Should -BeFalse
            # Et un vrai dossier, lui, n'est pas pris pour un point d'analyse.
            (Protect-KitVaultDir -Path $script:coffre).Reparse | Should -BeFalse
        }
    }
}
