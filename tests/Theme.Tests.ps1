# tests/Theme.Tests.ps1 - Tests Pester v5 de lib/Theme.ps1 (palette, helpers purs, fabriques).
# Les fabriques WinForms sont instanciées SANS ShowDialog : propriétés vérifiées puis Dispose.
BeforeAll {
    $script:KitLogFile = Join-Path $env:TEMP "pester-theme-$(New-Guid).log"
    . "$PSScriptRoot\..\lib\Common.ps1"
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
AfterAll {
    if (Test-Path $script:KitLogFile) { Remove-Item $script:KitLogFile -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-KitPalette' {
    BeforeAll { $script:P = Get-KitPalette }

    It 'expose les couleurs de la charte Trimko (spec 3.1)' {
        $script:P.Accent     | Should -Be '#0d9488'
        $script:P.AccentDark | Should -Be '#0f766e'
        $script:P.Ink        | Should -Be '#1e293b'
        $script:P.Ground     | Should -Be '#f8fafc'
        $script:P.Card       | Should -Be '#ffffff'
        $script:P.Line       | Should -Be '#e2e8f0'
        $script:P.Ok         | Should -Be '#16a34a'
        $script:P.Warn       | Should -Be '#d97706'
        $script:P.Err        | Should -Be '#dc2626'
        $script:P.JournalBg  | Should -Be '#0f172a'
    }

    It 'aligne les couleurs de journal sur celles du rapport HTML' {
        $script:P.LogOK     | Should -Be '#4ade80'
        $script:P.LogWarn   | Should -Be '#fbbf24'
        $script:P.LogError  | Should -Be '#f87171'
        $script:P.LogWhatIf | Should -Be '#22d3ee'
        $script:P.LogInfo   | Should -Be '#cbd5e1'
    }

    It 'ne contient que des hex valides' {
        foreach ($k in $script:P.Keys) {
            $script:P[$k] | Should -Match '^#[0-9a-f]{6}$' -Because "$k doit être un hex minuscule"
        }
    }
}

Describe 'Get-KitBadgeLevelColors' {
    It 'mappe chaque niveau sur des couleurs de la palette' {
        $p = Get-KitPalette
        foreach ($niveau in @('Ok', 'Accent', 'Warn', 'Err')) {
            $c = Get-KitBadgeLevelColors -Level $niveau
            $c.Back | Should -Be $p[$niveau] -Because $niveau
            $c.Fore | Should -Be '#ffffff' -Because "$niveau : texte blanc sur couleur pleine"
        }
    }
    It 'replie un niveau inconnu sur le badge neutre' {
        $p = Get-KitPalette
        $c = Get-KitBadgeLevelColors -Level 'Neutral'
        $c.Back | Should -Be $p.Line
        $c.Fore | Should -Be $p.InkSoft
        (Get-KitBadgeLevelColors -Level 'zzz').Back | Should -Be $p.Line
    }
}

Describe 'Get-KitLogLevelColorHex' {
    It 'mappe chaque niveau sur la couleur du rapport' {
        Get-KitLogLevelColorHex -Line '[2026-08-21 10:00:00] [OK] fait'      | Should -Be '#4ade80'
        Get-KitLogLevelColorHex -Line '[2026-08-21 10:00:00] [WARN] gare'    | Should -Be '#fbbf24'
        Get-KitLogLevelColorHex -Line '[2026-08-21 10:00:00] [ERROR] rate'   | Should -Be '#f87171'
        Get-KitLogLevelColorHex -Line '[2026-08-21 10:00:00] [WHATIF] simule'| Should -Be '#22d3ee'
        Get-KitLogLevelColorHex -Line '[2026-08-21 10:00:00] [INFO] note'    | Should -Be '#cbd5e1'
    }
    It 'traite une ligne hors format comme INFO' {
        Get-KitLogLevelColorHex -Line 'ligne brute' | Should -Be '#cbd5e1'
        Get-KitLogLevelColorHex -Line ''            | Should -Be '#cbd5e1'
    }
}

Describe 'Get-ModuleStateGlyph' {
    It 'renvoie glyphe MDL2 et couleur pour chaque état quand MDL2 est disponible' {
        (Get-ModuleStateGlyph -State 'Ok'      -Mdl2Available $true).Glyph    | Should -Be ([string][char]0xE73E)
        (Get-ModuleStateGlyph -State 'Running' -Mdl2Available $true).Glyph    | Should -Be ([string][char]0xE768)
        (Get-ModuleStateGlyph -State 'Error'   -Mdl2Available $true).Glyph    | Should -Be ([string][char]0xE711)
        (Get-ModuleStateGlyph -State 'Warn'    -Mdl2Available $true).ColorHex | Should -Be '#d97706'
        (Get-ModuleStateGlyph -State 'Ok'      -Mdl2Available $true).ColorHex | Should -Be '#16a34a'
    }
    It 'replie sur des caractères Unicode sans MDL2' {
        (Get-ModuleStateGlyph -State 'Ok'      -Mdl2Available $false).Glyph | Should -Be ([string][char]0x2713)
        (Get-ModuleStateGlyph -State 'Running' -Mdl2Available $false).Glyph | Should -Be ([string][char]0x25B6)
        (Get-ModuleStateGlyph -State 'Error'   -Mdl2Available $false).Glyph | Should -Be 'x'
        (Get-ModuleStateGlyph -State 'Warn'    -Mdl2Available $false).Glyph | Should -Be '!'
    }
    It 'Skipped prend le tiret MDL2, jamais un tiret ASCII' {
        # La police MDL2 n'a pas de glyphe pour « - » : la ligne « ignoré »
        # affichait un carré vide (caractère manquant) au lieu d'un tiret.
        (Get-ModuleStateGlyph -State 'Skipped' -Mdl2Available $true).Glyph  | Should -Be ([string][char]0xE738)
        (Get-ModuleStateGlyph -State 'Skipped' -Mdl2Available $false).Glyph | Should -Be '-'
    }
    It 'Pending garde un cercle Unicode (glyphe jamais peint : la case le remplace)' {
        (Get-ModuleStateGlyph -State 'Pending' -Mdl2Available $true).Glyph | Should -Be ([string][char]0x25CB)
    }
    It 'Queued prend le cercle MDL2, jamais le ○ Unicode absent de cette police' {
        # Même piège que le tiret de Skipped : Segoe MDL2 Assets n'a pas U+25CB,
        # la ligne « en attente » affichait un carré vide.
        (Get-ModuleStateGlyph -State 'Queued' -Mdl2Available $true).Glyph     | Should -Be ([string][char]0xEA3A)
        (Get-ModuleStateGlyph -State 'Queued' -Mdl2Available $false).Glyph    | Should -Be ([string][char]0x25CB)
        (Get-ModuleStateGlyph -State 'Queued' -Mdl2Available $true).ColorHex  | Should -Be '#94a3b8'
    }
}

Describe 'Get-RunSummaryText' {
    It 'compose le résumé de préparation au format de la spec 4.4' {
        Get-RunSummaryText -ModuleCount 14 -SensitiveCount 0 -ProfileName 'standard' -IsDryRun $true |
            Should -Be '14 étapes sélectionnées - 0 action sensible - profil standard - SIMULATION'
    }
    It 'gère singulier, absence de profil et mode réel' {
        Get-RunSummaryText -ModuleCount 1 -SensitiveCount 2 -ProfileName '' -IsDryRun $false |
            Should -Be '1 étape sélectionnée - 2 actions sensibles - INTERVENTION RÉELLE'
    }
    It 'accorde vraiment, sans « (s) » : zéro reste au singulier' {
        $t = Get-RunSummaryText -ModuleCount 0 -SensitiveCount 1 -ProfileName '' -IsDryRun $true
        $t | Should -Be '0 étape sélectionnée - 1 action sensible - SIMULATION'
        $t | Should -Not -Match '\(s\)'
    }
}

Describe 'Get-RunDoneText' {
    It 'accorde le bilan de clôture, sans « (s) »' {
        Get-RunDoneText -CountOK 13 -CountWarn 1 -CountError 0 -Elapsed '1:05:12' |
            Should -Be 'Terminé : 13 OK - 1 avertissement - 0 erreur - durée 1:05:12'
    }
    It 'met au pluriel au-delà de un, « OK » restant invariable' {
        Get-RunDoneText -CountOK 1 -CountWarn 3 -CountError 2 -Elapsed '00:42' |
            Should -Be 'Terminé : 1 OK - 3 avertissements - 2 erreurs - durée 00:42'
    }
    It 'garde zéro au singulier et remplace une durée absente par un tiret' {
        $t = Get-RunDoneText -CountOK 0 -CountWarn 0 -CountError 0 -Elapsed ''
        $t | Should -Be 'Terminé : 0 OK - 0 avertissement - 0 erreur - durée -'
        $t | Should -Not -Match '\(s\)'
    }
}

Describe 'Get-ModuleTrancheState' {
    It 'Error si le code de sortie est non nul, quel que soit le log' {
        Get-ModuleTrancheState -ExitCode 3 -TrancheLines @('[2026-08-21 10:00:00] [OK] tout va bien') | Should -Be 'Error'
    }
    It 'Error si la tranche contient un ERROR' {
        Get-ModuleTrancheState -ExitCode 0 -TrancheLines @('[2026-08-21 10:00:00] [ERROR] echec') | Should -Be 'Error'
    }
    It 'Warn si la tranche contient un WARN sans ERROR' {
        Get-ModuleTrancheState -ExitCode 0 -TrancheLines @(
            '[2026-08-21 10:00:00] [OK] etape 1',
            '[2026-08-21 10:00:01] [WARN] detail') | Should -Be 'Warn'
    }
    It 'Ok sinon, y compris sur tranche vide ou nulle' {
        Get-ModuleTrancheState -ExitCode 0 -TrancheLines @('[2026-08-21 10:00:00] [OK] fait') | Should -Be 'Ok'
        Get-ModuleTrancheState -ExitCode 0 -TrancheLines @()    | Should -Be 'Ok'
        Get-ModuleTrancheState -ExitCode 0 -TrancheLines $null  | Should -Be 'Ok'
    }
}

Describe 'ConvertTo-KitColor' {
    It 'convertit un hex en Color' {
        $c = ConvertTo-KitColor -Hex '#0d9488'
        $c.R | Should -Be 13 ; $c.G | Should -Be 148 ; $c.B | Should -Be 136
    }
}

Describe 'New-KitButton et Set-KitButtonStyle' {
    It 'Primary : fond accent, texte blanc, flat sans bordure' {
        $b = New-KitButton -Text 'LANCER' -Kind Primary
        try {
            $b.FlatStyle | Should -Be 'Flat'
            $b.FlatAppearance.BorderSize | Should -Be 0
            $b.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#0d9488').ToArgb()
            $b.ForeColor.ToArgb() | Should -Be ([System.Drawing.Color]::White).ToArgb()
            $b.Font.Bold | Should -BeTrue
        } finally { $b.Dispose() }
    }
    It 'Ghost : fond carte, bordure fine, texte doux' {
        $b = New-KitButton -Text 'Annuler' -Kind Ghost
        try {
            $b.FlatAppearance.BorderSize | Should -Be 1
            $b.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#ffffff').ToArgb()
        } finally { $b.Dispose() }
    }
    It 'Danger : texte rouge sur fond carte' {
        $b = New-KitButton -Text 'Supprimer' -Kind Danger
        try { $b.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#dc2626').ToArgb() }
        finally { $b.Dispose() }
    }
    It 'Set-KitButtonStyle restyle un bouton existant sans le remplacer' {
        $b = New-Object System.Windows.Forms.Button
        try {
            Set-KitButtonStyle -Button $b -Kind Primary
            $b.FlatStyle | Should -Be 'Flat'
            $b.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#0d9488').ToArgb()
        } finally { $b.Dispose() }
    }
    It 'désactivé : fond ligne et texte estompé, couleurs restaurées à la réactivation' {
        # Un bouton FlatStyle à fond imposé ne se grise pas tout seul : LANCER
        # désactivé restait teal et se lisait comme cliquable.
        $b = New-KitButton -Text 'LANCER' -Kind Primary
        try {
            $b.Enabled = $false
            $b.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#e2e8f0').ToArgb()
            $b.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#64748b').ToArgb()
            $b.Enabled = $true
            $b.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#0d9488').ToArgb()
            $b.ForeColor.ToArgb() | Should -Be ([System.Drawing.Color]::White).ToArgb()
        } finally { $b.Dispose() }
    }
    It 'un bouton déjà désactivé est grisé dès la pose du style, bordure comprise' {
        # Les boutons Copier / Supprimer la fiche naissent désactivés, puis sont
        # stylés : sans repeinte immédiate, ils partiraient en couleurs actives.
        # La bordure suit le même sort : un Danger désactivé gardait son liseré
        # rouge, seul élément vif d'un bouton par ailleurs grisé.
        $b = New-Object System.Windows.Forms.Button
        $b.Enabled = $false
        try {
            Set-KitButtonStyle -Button $b -Kind Danger
            $b.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#e2e8f0').ToArgb()
            $b.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#64748b').ToArgb()
            $b.FlatAppearance.BorderColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#e2e8f0').ToArgb()
            $b.Enabled = $true
            $b.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#dc2626').ToArgb()
            $b.FlatAppearance.BorderColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#fca5a5').ToArgb()
        } finally { $b.Dispose() }
    }
    It 'un restyle ne réempile pas de handler : les couleurs du dernier style gagnent' {
        # Les couleurs vivent dans le Tag et non dans une closure : deux poses de
        # style laisseraient sinon deux handlers concurrents sur EnabledChanged.
        $b = New-KitButton -Text 'Annuler' -Kind Ghost
        try {
            Set-KitButtonStyle -Button $b -Kind Danger
            $b.Enabled = $false
            $b.Enabled = $true
            $b.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#dc2626').ToArgb()
            $b.FlatAppearance.BorderColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#fca5a5').ToArgb()
        } finally { $b.Dispose() }
    }
}

Describe 'New-KitCard' {
    It 'carte blanche avec padding' {
        $c = New-KitCard
        try {
            $c.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#ffffff').ToArgb()
            $c.Padding.Left | Should -BeGreaterThan 0
        } finally { $c.Dispose() }
    }
    It 'liseré d avertissement en option' {
        $c = New-KitCard -WarnAccent
        try { $c.Padding.Left | Should -BeGreaterThan (New-KitCard).Padding.Left }
        finally { $c.Dispose() }
    }
    It 'bordure Line par défaut, remplaçable par -BorderHex' {
        # L'encadré passphrase de la page Clôture veut une bordure AccentPale
        # assortie à son fond (spec 4.3) : la bordure se peint au Paint, donc
        # seule une capture du rendu prouve la couleur réellement tracée.
        $defaut = New-KitCard
        $pale   = New-KitCard -BorderHex '#99f6e4'
        try {
            foreach ($c in @($defaut, $pale)) { $c.Size = New-Object System.Drawing.Size(40, 20) }
            $bmpDefaut = New-Object System.Drawing.Bitmap 40, 20
            $bmpPale   = New-Object System.Drawing.Bitmap 40, 20
            try {
                $defaut.DrawToBitmap($bmpDefaut, (New-Object System.Drawing.Rectangle 0, 0, 40, 20))
                $pale.DrawToBitmap($bmpPale, (New-Object System.Drawing.Rectangle 0, 0, 40, 20))
                $bmpDefaut.GetPixel(0, 10).ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#e2e8f0').ToArgb()
                $bmpPale.GetPixel(0, 10).ToArgb()   | Should -Be (ConvertTo-KitColor -Hex '#99f6e4').ToArgb()
            } finally { $bmpDefaut.Dispose() ; $bmpPale.Dispose() }
        } finally { $defaut.Dispose() ; $pale.Dispose() }
    }
}

Describe 'New-KitEyebrow' {
    It 'label majuscules gris' {
        $l = New-KitEyebrow -Text 'Modules'
        try {
            $l.Text | Should -Be 'MODULES'
            $l.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#64748b').ToArgb()
            $l.Font.Bold | Should -BeTrue
        } finally { $l.Dispose() }
    }
}

Describe 'New-KitBand et Set-KitBadgeMode' {
    It 'bandeau teal avec nom produit, machine et badge' {
        $band = New-KitBand -Machine 'PC-TEST'
        try {
            $band.Panel.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#0d9488').ToArgb()
            $band.BadgeLabel | Should -Not -BeNullOrEmpty
            ($band.Panel.Controls | ForEach-Object { $_.Text }) -join ' ' | Should -Match 'PC-TEST'
        } finally { $band.Panel.Dispose() }
    }
    It 'le badge change avec le mode' {
        $band = New-KitBand -Machine 'PC-TEST'
        try {
            Set-KitBadgeMode -Band $band -Mode Real
            $band.BadgeLabel.Text | Should -Be 'INTERVENTION RÉELLE'
            $band.BadgeLabel.BackColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#d97706').ToArgb()
            Set-KitBadgeMode -Band $band -Mode Simulation
            $band.BadgeLabel.Text | Should -Be 'SIMULATION'
            Set-KitBadgeMode -Band $band -Mode Preview
            $band.BadgeLabel.Text | Should -Be 'APERÇU'
        } finally { $band.Panel.Dispose() }
    }
}

Describe 'New-KitModuleRow et Set-KitModuleRowState' {
    It 'ligne avec case cochée par défaut, numéro d''étape et nom' {
        $r = New-KitModuleRow -Index '4' -Name 'Désencombrement' -Mdl2Available $false
        try {
            $r.Index | Should -Be '4'
            $r.CheckBox.Checked | Should -BeTrue
            $r.CheckBox.Visible | Should -BeTrue
            $r.GlyphLabel.Visible | Should -BeFalse
            $r.NameLabel.Text | Should -Be 'Désencombrement'
        } finally { $r.Panel.Dispose() }
    }
    It 'affiche le numéro d''étape et le label français' {
        $r = New-KitModuleRow -Index '15' -Name 'Rapport' -Mdl2Available $false
        try {
            $r.IdLabel.Text   | Should -Be '15'
            $r.NameLabel.Text | Should -Be 'Rapport'
        } finally { $r.Panel.Dispose() }
    }
    It 'Running : glyphe visible, case masquée, nom en gras, détail affiché' {
        $r = New-KitModuleRow -Index '4' -Name 'Désencombrement' -Mdl2Available $false
        try {
            Set-KitModuleRowState -Row $r -State Running -Detail 'en cours - 01:12' -Mdl2Available $false
            $r.CheckBox.Visible | Should -BeFalse
            $r.GlyphLabel.Visible | Should -BeTrue
            $r.GlyphLabel.Text | Should -Be ([string][char]0x25B6)
            $r.NameLabel.Font.Bold | Should -BeTrue
            $r.DetailLabel.Text | Should -Be 'en cours - 01:12'
        } finally { $r.Panel.Dispose() }
    }
    It 'Ok puis Skipped : glyphes, couleurs et graisse cohérents' {
        $r = New-KitModuleRow -Index '6' -Name 'Mises à jour' -Mdl2Available $false
        try {
            Set-KitModuleRowState -Row $r -State Ok -Detail '08:05' -Mdl2Available $false
            $r.GlyphLabel.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#16a34a').ToArgb()
            $r.NameLabel.Font.Bold | Should -BeFalse
            Set-KitModuleRowState -Row $r -State Skipped -Detail 'ignoré' -Mdl2Available $false
            $r.NameLabel.ForeColor.ToArgb() | Should -Be (ConvertTo-KitColor -Hex '#94a3b8').ToArgb()
        } finally { $r.Panel.Dispose() }
    }
    It 'Queued masque la case au profit du glyphe d''attente (module en file pendant un run)' {
        # Pendant un run, plus aucune case ne doit subsister dans la colonne :
        # une case à cocher promet une modification possible, elle est fausse ici.
        $r = New-KitModuleRow -Index '8' -Name 'Nettoyage' -Mdl2Available $true
        try {
            Set-KitModuleRowState -Row $r -State Queued -Detail 'en attente' -Mdl2Available $true
            $r.CheckBox.Visible | Should -BeFalse
            $r.GlyphLabel.Visible | Should -BeTrue
            $r.GlyphLabel.Text | Should -Be ([string][char]0xEA3A)
            $r.NameLabel.Font.Bold | Should -BeFalse
            $r.DetailLabel.Text | Should -Be 'en attente'
        } finally { $r.Panel.Dispose() }
    }
    It 'Pending remet la case visible (retour préparation)' {
        $r = New-KitModuleRow -Index '6' -Name 'Mises à jour' -Mdl2Available $false
        try {
            Set-KitModuleRowState -Row $r -State Ok -Detail '08:05' -Mdl2Available $false
            Set-KitModuleRowState -Row $r -State Pending -Detail '' -Mdl2Available $false
            $r.CheckBox.Visible | Should -BeTrue
            $r.GlyphLabel.Visible | Should -BeFalse
            $r.DetailLabel.Text | Should -Be ''
        } finally { $r.Panel.Dispose() }
    }
    It 'le détail reste dans le panneau à chaque changement de texte' {
        # Un Label AutoSize ancré à droite ne se repositionne pas quand son texte
        # s'allonge : sans recalage, le détail sort du panneau et devient invisible.
        $r = New-KitModuleRow -Index '15' -Name 'Rapport' -Mdl2Available $false
        try {
            $r.Panel.Width = 300
            Set-KitModuleRowState -Row $r -State Running -Detail 'en cours - 01:12' -Mdl2Available $false
            $r.DetailLabel.Width | Should -BeGreaterThan 0
            $r.DetailLabel.Bounds.Right | Should -BeLessOrEqual $r.Panel.Width
            Set-KitModuleRowState -Row $r -State Ok -Detail '08:05' -Mdl2Available $false
            $r.DetailLabel.Bounds.Right | Should -BeLessOrEqual $r.Panel.Width
            $r.DetailLabel.Bounds.Right | Should -BeGreaterThan ($r.Panel.Width - 20)
        } finally { $r.Panel.Dispose() }
    }
}

Describe 'Ancre d''aide de la timeline' {
    It 'New-KitModuleRow expose un AnchorStripe invisible par défaut' {
        $r = New-KitModuleRow -Index '5' -Name 'Test' -Mdl2Available $false
        try {
            $r.PSObject.Properties['AnchorStripe'] | Should -Not -BeNullOrEmpty
            $r.AnchorStripe.Visible | Should -BeFalse
            $r.AnchorStripe.Width | Should -Be 3
            # Ordre de plan : le liseré doit rester au premier plan (index 0), sinon
            # le GlyphLabel opaque le recouvre pendant les runs (revue Task 3 v2.5).
            $r.Panel.Controls.GetChildIndex($r.AnchorStripe) | Should -Be 0
        } finally { $r.Panel.Dispose() }
    }
    It 'Set-KitRowHelpAnchor pose et retire le liseré' {
        $r = New-KitModuleRow -Index '5' -Name 'Test' -Mdl2Available $false
        try {
            Set-KitRowHelpAnchor -Row $r -On $true
            $r.AnchorStripe.Visible | Should -BeTrue
            $r.AnchorStripe.Tag | Should -BeTrue
            Set-KitRowHelpAnchor -Row $r -On $false
            $r.AnchorStripe.Visible | Should -BeFalse
            $r.AnchorStripe.Tag | Should -BeFalse
        } finally { $r.Panel.Dispose() }
    }
    It 'les états d''exécution ne touchent pas l''ancre' {
        $r = New-KitModuleRow -Index '5' -Name 'Test' -Mdl2Available $false
        try {
            Set-KitRowHelpAnchor -Row $r -On $true
            Set-KitModuleRowState -Row $r -State Running -Detail 'en cours' -Mdl2Available $false
            $r.AnchorStripe.Visible | Should -BeTrue
            Set-KitModuleRowState -Row $r -State Pending -Detail '' -Mdl2Available $false
            $r.AnchorStripe.Visible | Should -BeTrue
        } finally { $r.Panel.Dispose() }
    }
}

Describe 'Get-KitBackupNetState et affichage' {
    It 'decoche = off, quel que soit le disque' {
        Get-KitBackupNetState -Module01Checked $false -BackupDataChecked $true -Candidates @() | Should -Be 'off'
        $vol = [PSCustomObject]@{ DriveType = 'Removable' }
        Get-KitBackupNetState -Module01Checked $true -BackupDataChecked $false -Candidates @($vol) | Should -Be 'off'
    }
    It 'aucun candidat = none' {
        Get-KitBackupNetState -Module01Checked $true -BackupDataChecked $true -Candidates @() | Should -Be 'none'
    }
    It 'meilleur candidat amovible = external, fixe = internal' {
        $rem = [PSCustomObject]@{ DriveType = 'Removable' }
        $fix = [PSCustomObject]@{ DriveType = 'Fixed' }
        Get-KitBackupNetState -Module01Checked $true -BackupDataChecked $true -Candidates @($rem, $fix) | Should -Be 'external'
        Get-KitBackupNetState -Module01Checked $true -BackupDataChecked $true -Candidates @($fix) | Should -Be 'internal'
    }
    It 'affiche chaque etat avec le bon niveau' {
        $d = Get-KitBackupNetDisplay -State 'external' -Letter 'E' -FreeGB 120.4
        $d.Text | Should -Be 'Filet : disque E: (120 Go libres)'
        $d.Level | Should -Be 'Ok'
        $dInt = Get-KitBackupNetDisplay -State 'internal' -Letter 'D'
        $dInt.Text | Should -Be 'Filet : partition interne D: - vérifier le support'
        $dInt.Level | Should -Be 'Warn'
        (Get-KitBackupNetDisplay -State 'none').Text | Should -Be 'Sans disque externe : fichiers perso non copiés'
        (Get-KitBackupNetDisplay -State 'off').Text | Should -Be 'Aucune sauvegarde des données prévue : aucun filet'
    }
}

Describe 'Get-DebloatPolicyHint' {
    It 'donne une consequence courte par politique' {
        Get-DebloatPolicyHint -PolicyFr 'Conservateur' | Should -Be 'Aucune app douteuse supprimée'
        Get-DebloatPolicyHint -PolicyFr 'Standard'     | Should -Be 'Non utilisée depuis 90 j = retirée sans question'
        Get-DebloatPolicyHint -PolicyFr 'Agressif'     | Should -Be 'Les apps douteuses sont retirées, même utilisées'
    }
    It 'rend une chaine vide pour une politique inconnue' {
        Get-DebloatPolicyHint -PolicyFr 'zzz' | Should -Be ''
        Get-DebloatPolicyHint -PolicyFr ''    | Should -Be ''
    }
}

Describe 'Get-KitPreRunWarnings' {
    It 'ne dit rien en simulation, meme avec tout a signaler' {
        @(Get-KitPreRunWarnings -BackupState 'none' -Module03Checked $true -Policy 'Aggressive' -IsDryRun $true).Count | Should -Be 0
    }
    It 'ne dit rien quand filet externe et debloatage conservateur' {
        @(Get-KitPreRunWarnings -BackupState 'external' -Module03Checked $true -Policy 'Conservative' -IsDryRun $false).Count | Should -Be 0
    }
    It 'signale chaque etat de filet degrade avec le bon texte' {
        # Épinglage par contenu (revue T6) : une inversion des messages entre
        # états passerait un simple comptage au vert.
        $cas = @(
            @{ etat = 'none';     motif = 'Aucun disque externe' }
            @{ etat = 'internal'; motif = 'partition interne' }
            @{ etat = 'off';      motif = 'décochée' }
        )
        foreach ($c in $cas) {
            $w = @(Get-KitPreRunWarnings -BackupState $c.etat -Module03Checked $false -Policy 'Standard' -IsDryRun $false)
            $w.Count | Should -Be 1 -Because $c.etat
            $w[0] | Should -Match $c.motif -Because $c.etat
        }
    }
    It 'signale la suppression silencieuse en Standard et l agressif, pas sans module 03' {
        $w = @(Get-KitPreRunWarnings -BackupState 'external' -Module03Checked $true -Policy 'Standard' -IsDryRun $false)
        $w.Count | Should -Be 1
        $w[0] | Should -Match '90 j'
        $w = @(Get-KitPreRunWarnings -BackupState 'external' -Module03Checked $true -Policy 'Aggressive' -IsDryRun $false)
        $w[0] | Should -Match 'même utilisées'
        @(Get-KitPreRunWarnings -BackupState 'external' -Module03Checked $false -Policy 'Aggressive' -IsDryRun $false).Count | Should -Be 0
    }
    It 'cumule filet et debloatage, dans cet ordre' {
        $w = @(Get-KitPreRunWarnings -BackupState 'none' -Module03Checked $true -Policy 'Standard' -IsDryRun $false)
        $w.Count | Should -Be 2
        $w[0] | Should -Match 'Aucun disque externe'
        $w[1] | Should -Match '90 j'
    }
}
