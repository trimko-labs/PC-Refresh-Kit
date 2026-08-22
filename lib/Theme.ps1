# lib/Theme.ps1 - Identité visuelle Trimko du cockpit : palette, helpers purs,
# fabriques de contrôles WinForms. Dot-sourcé par lib/Common.ps1 (après Log.ps1
# et Report.ps1 : Get-KitLogLevelColorHex et Get-ModuleTrancheState en dépendent).
# Source des couleurs : charte trimko.com, spec 2026-08-21 section 3.1.
# Encodage : UTF-8 avec BOM pour PowerShell 5.1.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Get-KitPalette : la palette Trimko en chaînes hex. PURE, source unique de
# toute couleur du cockpit : aucune couleur en dur ailleurs.
# ---------------------------------------------------------------------------
function Get-KitPalette {
    [CmdletBinding()]
    param()
    return @{
        Accent       = '#0d9488'   # bandeau, LANCER, onglet actif, cases cochées
        AccentDark   = '#0f766e'   # fond badge SIMULATION, hover primaire
        AccentPale   = '#99f6e4'   # sous-titre bandeau, bordure encadré passphrase
        AccentGhost  = '#ccfbf1'   # texte secondaire sur fond teal
        AccentBgSoft = '#f0fdfa'   # fond encadré passphrase
        Ink          = '#1e293b'   # texte principal
        InkSoft      = '#475569'   # texte secondaire
        InkMuted     = '#64748b'   # eyebrows, durées, heartbeat
        Ground       = '#f8fafc'   # fond fenêtre et zone droite
        Card         = '#ffffff'   # cartes, colonne intervention, barre d'action
        Line         = '#e2e8f0'   # bordures 1px
        Ok           = '#16a34a'
        Warn         = '#d97706'   # avertissement, liseré actions sensibles, badge RÉEL
        Err          = '#dc2626'
        Skip         = '#94a3b8'   # modules ignorés, états en attente
        JournalBg    = '#0f172a'   # fond du journal (identique au pre.log du rapport)
        LogOK        = '#4ade80'   # niveaux du journal : mêmes hex que lib/Report.ps1
        LogWarn      = '#fbbf24'
        LogError     = '#f87171'
        LogWhatIf    = '#22d3ee'
        LogInfo      = '#cbd5e1'
        LogHeartbeat = '#64748b'
        BadgeRealBg     = '#d97706'
        BadgeRealBorder = '#fbbf24'
        BadgeSimBg      = '#0f766e'
        BadgeSimBorder  = '#2dd4bf'
        BadgePreviewBg  = '#475569'
    }
}

# ---------------------------------------------------------------------------
# Get-KitLogLevelColorHex : couleur hex d'une ligne de journal sur fond sombre.
# Get-LogLevelColor (Log.ps1) reste la référence du mode console sur fond
# clair : les deux coexistent, chacune pour son rendu. PURE.
# ---------------------------------------------------------------------------
function Get-KitLogLevelColorHex {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Line)
    $p = Get-KitPalette
    $parts = Get-LogLineParts -Line $Line
    $level = if ($parts) { $parts.Level } else { 'INFO' }
    switch ($level) {
        'OK'     { return $p.LogOK }
        'WARN'   { return $p.LogWarn }
        'ERROR'  { return $p.LogError }
        'WHATIF' { return $p.LogWhatIf }
        default  { return $p.LogInfo }
    }
}

# ---------------------------------------------------------------------------
# Get-ModuleStateGlyph : glyphe et couleur d'un état de module de la timeline.
# Glyphes Segoe MDL2 Assets (E73E coche, E768 lecture, E7BA attention, E711
# croix) avec repli Unicode si la police manque (très vieux Windows 10). PURE.
# ---------------------------------------------------------------------------
function Get-ModuleStateGlyph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Pending','Queued','Running','Ok','Warn','Error','Skipped')][string]$State,
        [bool]$Mdl2Available = $true
    )
    $p = Get-KitPalette
    switch ($State) {
        # Pending : son glyphe n'est jamais peint (Set-KitModuleRowState montre la
        # case à la place), d'où un simple cercle Unicode.
        'Pending' { return [PSCustomObject]@{ Glyph = [string][char]0x25CB; ColorHex = $p.Skip } }
        # Queued : module en file pendant un run. Cercle d'attente de la spec 3.2,
        # celui-ci bel et bien peint (la case a disparu au lancement) : il passe
        # donc par EA3A (StatusCircleRing) et non par le ○ Unicode, absent de
        # Segoe MDL2 Assets comme l'était le tiret de Skipped - il s'y afficherait
        # en carré vide. Le ○ reste le repli quand la police manque.
        'Queued'  {
            $g = if ($Mdl2Available) { [string][char]0xEA3A } else { [string][char]0x25CB }
            return [PSCustomObject]@{ Glyph = $g; ColorHex = $p.Skip }
        }
        'Skipped' {
            # E738 (Remove) et non un « - » ASCII : Segoe MDL2 Assets n'a pas de
            # glyphe pour le tiret, la ligne « ignoré » affichait un carré vide.
            $g = if ($Mdl2Available) { [string][char]0xE738 } else { '-' }
            return [PSCustomObject]@{ Glyph = $g; ColorHex = $p.Skip }
        }
        'Running' {
            $g = if ($Mdl2Available) { [string][char]0xE768 } else { [string][char]0x25B6 }
            return [PSCustomObject]@{ Glyph = $g; ColorHex = $p.Accent }
        }
        'Ok' {
            $g = if ($Mdl2Available) { [string][char]0xE73E } else { [string][char]0x2713 }
            return [PSCustomObject]@{ Glyph = $g; ColorHex = $p.Ok }
        }
        'Warn' {
            $g = if ($Mdl2Available) { [string][char]0xE7BA } else { '!' }
            return [PSCustomObject]@{ Glyph = $g; ColorHex = $p.Warn }
        }
        'Error' {
            $g = if ($Mdl2Available) { [string][char]0xE711 } else { 'x' }
            return [PSCustomObject]@{ Glyph = $g; ColorHex = $p.Err }
        }
    }
}

# ---------------------------------------------------------------------------
# Get-RunSummaryText : texte du résumé de la barre d'action en préparation. PURE.
# ---------------------------------------------------------------------------
function Get-RunSummaryText {
    [CmdletBinding()]
    param(
        [int]$ModuleCount,
        [int]$SensitiveCount,
        [AllowEmptyString()][AllowNull()][string]$ProfileName,
        [bool]$IsDryRun
    )
    $mode = if ($IsDryRun) { 'SIMULATION' } else { 'INTERVENTION RÉELLE' }
    # Pluriel grammatical réel plutôt que des « (s) » : ce résumé est lu par le
    # propriétaire du PC autant que par l'opérateur. En français, zéro reste au
    # singulier (« 0 action sensible »).
    # « étape » et non « module » : la colonne de gauche numérote des étapes 1 à 15
    # depuis la v2.3, le résumé emploie le même mot (accord au féminin).
    $sMod = if ($ModuleCount -gt 1) { 's' } else { '' }
    $sAct = if ($SensitiveCount -gt 1) { 's' } else { '' }
    $prof = if ([string]::IsNullOrWhiteSpace($ProfileName)) { '' } else { " - profil $ProfileName" }
    return "$ModuleCount étape$sMod sélectionnée$sMod - $SensitiveCount action$sAct sensible$sAct$prof - $mode"
}

# ---------------------------------------------------------------------------
# Get-RunDoneText : texte du bilan de la barre d'action en clôture. PURE.
# Même accord grammatical que Get-RunSummaryText : le bilan est la dernière
# phrase que lit le propriétaire du PC, elle ne doit pas ressembler à un
# gabarit. « OK » est un sigle, il reste invariable.
# ---------------------------------------------------------------------------
function Get-RunDoneText {
    [CmdletBinding()]
    param(
        [int]$CountOK,
        [int]$CountWarn,
        [int]$CountError,
        [AllowEmptyString()][AllowNull()][string]$Elapsed
    )
    $sWarn = if ($CountWarn -gt 1) { 's' } else { '' }
    $sErr  = if ($CountError -gt 1) { 's' } else { '' }
    $dur   = if ([string]::IsNullOrWhiteSpace($Elapsed)) { '-' } else { $Elapsed }
    return "Terminé : $CountOK OK - $CountWarn avertissement$sWarn - $CountError erreur$sErr - durée $dur"
}

# ---------------------------------------------------------------------------
# Get-ModuleTrancheState : état final d'un module depuis son code de sortie et
# SA tranche du log unifié (bornée par l'offset au démarrage du module).
# Réutilise Get-ReportSummary (Report.ps1) : aucun double comptage. PURE.
# ---------------------------------------------------------------------------
function Get-ModuleTrancheState {
    [CmdletBinding()]
    param(
        [int]$ExitCode,
        [AllowNull()][string[]]$TrancheLines
    )
    if ($ExitCode -ne 0) { return 'Error' }
    $sum = Get-ReportSummary -Lines $TrancheLines
    if ($sum.CountError -gt 0) { return 'Error' }
    if ($sum.CountWarn -gt 0)  { return 'Warn' }
    return 'Ok'
}

# ===========================================================================
# Fabriques de contrôles WinForms. Testables sans affichage : instancier,
# vérifier les propriétés, Dispose. Aucun ShowDialog ici sauf Show-KitInputDialog.
# ===========================================================================

function ConvertTo-KitColor {
    # Hex '#rrggbb' -> System.Drawing.Color.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Test-KitMdl2Available {
    # $true si la police Segoe MDL2 Assets est installée (Windows 10+ standard).
    [CmdletBinding()]
    param()
    try {
        $ff = New-Object System.Drawing.FontFamily 'Segoe MDL2 Assets'
        $ff.Dispose()
        return $true
    } catch { return $false }
}

function Set-KitButtonStyle {
    # Style Trimko appliqué à un bouton EXISTANT (handlers conservés).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory)][ValidateSet('Primary','Ghost','Mini','MiniGhost','Danger')][string]$Kind
    )
    $p = Get-KitPalette
    $Button.FlatStyle = 'Flat'
    $Button.UseVisualStyleBackColor = $false
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    switch ($Kind) {
        'Primary' {
            $Button.FlatAppearance.BorderSize = 0
            $Button.BackColor = ConvertTo-KitColor $p.Accent
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
            $Button.FlatAppearance.MouseOverBackColor = ConvertTo-KitColor $p.AccentDark
        }
        'Ghost' {
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = ConvertTo-KitColor $p.Line
            $Button.BackColor = ConvertTo-KitColor $p.Card
            $Button.ForeColor = ConvertTo-KitColor $p.InkSoft
            $Button.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
        }
        'Mini' {
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = ConvertTo-KitColor $p.Accent
            $Button.BackColor = ConvertTo-KitColor $p.Card
            $Button.ForeColor = ConvertTo-KitColor $p.Accent
            $Button.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
        }
        'MiniGhost' {
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = ConvertTo-KitColor $p.Line
            $Button.BackColor = ConvertTo-KitColor $p.Card
            $Button.ForeColor = ConvertTo-KitColor $p.InkMuted
            $Button.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
        }
        'Danger' {
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = ConvertTo-KitColor '#fca5a5'
            $Button.BackColor = ConvertTo-KitColor $p.Card
            $Button.ForeColor = ConvertTo-KitColor $p.Err
            $Button.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
        }
    }
    # Rendu désactivé. WinForms grise un bouton système, mais un bouton FlatStyle
    # à fond imposé garde son fond : LANCER désactivé restait teal et se lisait
    # comme cliquable. Les couleurs actives sont capturées ici et repeintes à
    # chaque bascule d'état. La BORDURE en fait partie : sans elle, un Danger
    # désactivé gardait son liseré rouge et un Mini son liseré teal, seuls
    # éléments encore vifs d'un bouton par ailleurs grisé. Un bouton déjà
    # désactivé au moment du style est grisé tout de suite : le style peut être
    # posé avant ou après Enabled.
    # Les couleurs vivent dans le Tag, pas dans une closure : un second appel sur
    # le même bouton les remplace au lieu d'empiler un handler aux couleurs
    # périmées, qui se disputerait la repeinte avec le premier.
    $wired = ($Button.Tag -is [hashtable]) -and $Button.Tag.ContainsKey('KitDisabledStyle')
    if (-not $wired) { $Button.Tag = @{} }
    $Button.Tag['KitDisabledStyle'] = @{
        Back           = $Button.BackColor
        Fore           = $Button.ForeColor
        Border         = $Button.FlatAppearance.BorderColor
        DisabledBack   = ConvertTo-KitColor $p.Line
        DisabledFore   = ConvertTo-KitColor $p.InkMuted
        DisabledBorder = ConvertTo-KitColor $p.Line
    }
    if (-not $wired) {
        $Button.Add_EnabledChanged({
            param($sender, $e)
            $s = $sender.Tag['KitDisabledStyle']
            if ($sender.Enabled) {
                $sender.BackColor = $s.Back ; $sender.ForeColor = $s.Fore
                $sender.FlatAppearance.BorderColor = $s.Border
            } else {
                $sender.BackColor = $s.DisabledBack ; $sender.ForeColor = $s.DisabledFore
                $sender.FlatAppearance.BorderColor = $s.DisabledBorder
            }
        })
    }
    if (-not $Button.Enabled) {
        $st = $Button.Tag['KitDisabledStyle']
        $Button.BackColor = $st.DisabledBack
        $Button.ForeColor = $st.DisabledFore
        $Button.FlatAppearance.BorderColor = $st.DisabledBorder
    }
}

function New-KitButton {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('Primary','Ghost','Mini','MiniGhost','Danger')][string]$Kind
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    Set-KitButtonStyle -Button $b -Kind $Kind
    return $b
}

function New-KitCard {
    # Panel blanc, bordure 1px dessinée au Paint, padding intérieur.
    # -WarnAccent ajoute un liseré gauche 3px Warn (actions sensibles).
    # -BorderHex remplace la bordure Line par défaut : l'encadré passphrase de la
    # page Clôture la veut AccentPale, assortie à son fond AccentBgSoft (spec 4.3).
    [CmdletBinding()]
    param(
        [switch]$WarnAccent,
        [AllowEmptyString()][AllowNull()][string]$BorderHex
    )
    $p = Get-KitPalette
    $card = New-Object System.Windows.Forms.Panel
    $card.BackColor = ConvertTo-KitColor $p.Card
    $card.Padding = if ($WarnAccent) { New-Object System.Windows.Forms.Padding(15, 10, 12, 10) }
                    else             { New-Object System.Windows.Forms.Padding(12, 10, 12, 10) }
    $borderHexEff = if ([string]::IsNullOrWhiteSpace($BorderHex)) { $p.Line } else { $BorderHex }
    $lineColor = ConvertTo-KitColor $borderHexEff
    $warnColor = ConvertTo-KitColor $p.Warn
    $hasWarn   = [bool]$WarnAccent
    $card.Add_Paint({
        param($sender, $e)
        $rect = $sender.ClientRectangle
        $pen = New-Object System.Drawing.Pen $lineColor
        try { $e.Graphics.DrawRectangle($pen, 0, 0, $rect.Width - 1, $rect.Height - 1) }
        finally { $pen.Dispose() }
        if ($hasWarn) {
            $brush = New-Object System.Drawing.SolidBrush $warnColor
            try { $e.Graphics.FillRectangle($brush, 0, 0, 3, $rect.Height) }
            finally { $brush.Dispose() }
        }
    }.GetNewClosure())
    return $card
}

function New-KitEyebrow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $p = Get-KitPalette
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text.ToUpperInvariant()
    $l.AutoSize = $true
    $l.ForeColor = ConvertTo-KitColor $p.InkMuted
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 8.25, [System.Drawing.FontStyle]::Bold)
    return $l
}

function New-KitBand {
    # Bandeau d'identité : nom produit + Trimko Labs, machine, badge de mode.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Machine)
    $p = Get-KitPalette
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = ConvertTo-KitColor $p.Accent
    $panel.Height = 46

    $name = New-Object System.Windows.Forms.Label
    $name.Text = 'PC-Refresh-Kit'
    $name.ForeColor = [System.Drawing.Color]::White
    $name.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $name.AutoSize = $true
    $name.Location = New-Object System.Drawing.Point(16, 5)

    $by = New-Object System.Windows.Forms.Label
    $by.Text = 'Trimko Labs'
    $by.ForeColor = ConvertTo-KitColor $p.AccentPale
    $by.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $by.AutoSize = $true
    $by.Location = New-Object System.Drawing.Point(18, 28)

    $machineLbl = New-Object System.Windows.Forms.Label
    $machineLbl.Text = "Machine : $Machine"
    $machineLbl.ForeColor = ConvertTo-KitColor $p.AccentGhost
    $machineLbl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $machineLbl.AutoSize = $true
    $machineLbl.Anchor = 'Top,Right'

    $badge = New-Object System.Windows.Forms.Label
    $badge.AutoSize = $false
    $badge.Size = New-Object System.Drawing.Size(170, 24)
    $badge.TextAlign = 'MiddleCenter'
    $badge.Font = New-Object System.Drawing.Font('Segoe UI', 8.25, [System.Drawing.FontStyle]::Bold)
    $badge.Anchor = 'Top,Right'

    $panel.Controls.AddRange(@($name, $by, $machineLbl, $badge))
    # Positionnement droit recalculé au redimensionnement du bandeau.
    $panel.Add_Resize({
        param($sender, $e)
        $badge.Location     = New-Object System.Drawing.Point(($sender.Width - $badge.Width - 16), 11)
        $machineLbl.Location = New-Object System.Drawing.Point(($sender.Width - $badge.Width - 16 - $machineLbl.Width - 18), 15)
    }.GetNewClosure())

    return [PSCustomObject]@{ Panel = $panel; BadgeLabel = $badge }
}

function Set-KitBadgeMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Band,
        [Parameter(Mandatory)][ValidateSet('Simulation','Real','Preview')][string]$Mode
    )
    $p = Get-KitPalette
    switch ($Mode) {
        'Simulation' {
            $Band.BadgeLabel.Text = 'SIMULATION'
            $Band.BadgeLabel.BackColor = ConvertTo-KitColor $p.BadgeSimBg
            $Band.BadgeLabel.ForeColor = ConvertTo-KitColor $p.AccentGhost
        }
        'Real' {
            $Band.BadgeLabel.Text = 'INTERVENTION RÉELLE'
            $Band.BadgeLabel.BackColor = ConvertTo-KitColor $p.BadgeRealBg
            $Band.BadgeLabel.ForeColor = [System.Drawing.Color]::White
        }
        'Preview' {
            $Band.BadgeLabel.Text = 'APERÇU'
            $Band.BadgeLabel.BackColor = ConvertTo-KitColor $p.BadgePreviewBg
            $Band.BadgeLabel.ForeColor = ConvertTo-KitColor $p.Line
        }
    }
}

function New-KitModuleRow {
    # Ligne de la timeline d'intervention : case (préparation) OU glyphe d'état
    # (run/clôture), numéro d'étape grisé, nom français, détail droit
    # (durée/état).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Index,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Mdl2Available = $true
    )
    $p = Get-KitPalette
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Height = 24
    $panel.BackColor = ConvertTo-KitColor $p.Card

    $cbx = New-Object System.Windows.Forms.CheckBox
    $cbx.Checked = $true
    $cbx.AutoSize = $false
    $cbx.Size = New-Object System.Drawing.Size(16, 16)
    $cbx.Location = New-Object System.Drawing.Point(2, 4)

    $glyph = New-Object System.Windows.Forms.Label
    $glyph.Visible = $false
    $glyph.AutoSize = $false
    $glyph.Size = New-Object System.Drawing.Size(18, 18)
    $glyph.TextAlign = 'MiddleCenter'
    $glyph.Location = New-Object System.Drawing.Point(0, 3)
    $glyph.Font = if ($Mdl2Available) { New-Object System.Drawing.Font('Segoe MDL2 Assets', 9) }
                  else                { New-Object System.Drawing.Font('Segoe UI', 9) }

    $idLbl = New-Object System.Windows.Forms.Label
    $idLbl.Text = $Index
    $idLbl.AutoSize = $false
    $idLbl.Size = New-Object System.Drawing.Size(20, 18)
    $idLbl.Location = New-Object System.Drawing.Point(22, 4)
    $idLbl.ForeColor = ConvertTo-KitColor $p.Skip
    $idLbl.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $idLbl.TextAlign = 'MiddleLeft'

    $nameLbl = New-Object System.Windows.Forms.Label
    $nameLbl.Text = $Name
    $nameLbl.AutoSize = $true
    $nameLbl.Location = New-Object System.Drawing.Point(44, 4)
    $nameLbl.ForeColor = ConvertTo-KitColor $p.Ink
    $nameLbl.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)

    $detail = New-Object System.Windows.Forms.Label
    $detail.Text = ''
    $detail.AutoSize = $true
    $detail.ForeColor = ConvertTo-KitColor $p.InkMuted
    $detail.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
    $detail.Anchor = 'Top,Right'
    $panel.Add_Resize({
        param($sender, $e)
        $detail.Location = New-Object System.Drawing.Point(($sender.Width - $detail.Width - 4), 6)
    }.GetNewClosure())

    $panel.Controls.AddRange(@($cbx, $glyph, $idLbl, $nameLbl, $detail))
    # Index (et non Id) : la colonne montre le numéro d'étape 1..15, plus jamais
    # l'identifiant technique du fichier module.
    return [PSCustomObject]@{
        Panel = $panel; CheckBox = $cbx; GlyphLabel = $glyph; IdLabel = $idLbl
        NameLabel = $nameLbl; DetailLabel = $detail; Index = $Index
    }
}

function Set-KitModuleRowState {
    # Bascule une ligne de timeline dans un état. Pending = retour préparation
    # (case visible) ; tous les autres états, Queued compris, masquent la case au
    # profit du glyphe : pendant un run, plus une seule case ne subsiste.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][ValidateSet('Pending','Queued','Running','Ok','Warn','Error','Skipped')][string]$State,
        [AllowEmptyString()][string]$Detail = '',
        [bool]$Mdl2Available = $true
    )
    $p = Get-KitPalette
    $Row.DetailLabel.Text = $Detail
    # Un Label AutoSize ancré à droite garde son X quand son texte s'allonge :
    # le détail sortirait du panneau (donc invisible, il est rogné par le parent).
    # Recalage explicite à chaque changement de texte, comme au redimensionnement.
    $Row.DetailLabel.Location = New-Object System.Drawing.Point(($Row.Panel.Width - $Row.DetailLabel.Width - 4), 6)
    if ($State -eq 'Pending') {
        $Row.CheckBox.Visible = $true
        $Row.GlyphLabel.Visible = $false
        $Row.NameLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
        $Row.NameLabel.ForeColor = ConvertTo-KitColor $p.Ink
        return
    }
    $g = Get-ModuleStateGlyph -State $State -Mdl2Available $Mdl2Available
    $Row.CheckBox.Visible = $false
    $Row.GlyphLabel.Visible = $true
    $Row.GlyphLabel.Text = $g.Glyph
    $Row.GlyphLabel.ForeColor = ConvertTo-KitColor $g.ColorHex
    $bold = if ($State -eq 'Running') { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $Row.NameLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.75, $bold)
    $Row.NameLabel.ForeColor = if ($State -eq 'Skipped') { ConvertTo-KitColor $p.Skip } else { ConvertTo-KitColor $p.Ink }
}

function Show-KitInputDialog {
    # Remplace l'InputBox de l'assembly tiers historique : dialogue charte, zéro
    # dépendance hors System.Windows.Forms / System.Drawing. Renvoie la saisie
    # ou $null si Annuler/fermeture. Seule fonction du thème à faire ShowDialog :
    # exclue des tests unitaires.
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Owner,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Prompt
    )
    $p = Get-KitPalette
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(400, 160)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false ; $dlg.MinimizeBox = $false
    $dlg.BackColor = ConvertTo-KitColor $p.Card

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size = New-Object System.Drawing.Size(355, 34)
    $lbl.ForeColor = ConvertTo-KitColor $p.Ink
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(15, 50)
    $txt.Size = New-Object System.Drawing.Size(355, 24)
    $txt.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)

    $ok = New-KitButton -Text 'Enregistrer' -Kind Primary
    $ok.Size = New-Object System.Drawing.Size(120, 30)
    $ok.Location = New-Object System.Drawing.Point(250, 85)
    $ok.DialogResult = 'OK'
    $cancel = New-KitButton -Text 'Annuler' -Kind Ghost
    $cancel.Size = New-Object System.Drawing.Size(90, 30)
    $cancel.Location = New-Object System.Drawing.Point(152, 85)
    $cancel.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))
    $dlg.AcceptButton = $ok ; $dlg.CancelButton = $cancel
    $result = if ($Owner) { $dlg.ShowDialog($Owner) } else { $dlg.ShowDialog() }
    $value = if ($result -eq 'OK') { $txt.Text } else { $null }
    $dlg.Dispose()
    return $value
}
