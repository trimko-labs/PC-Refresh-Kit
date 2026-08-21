# Run-GUI.ps1 - Cockpit graphique du PC-Refresh-Kit (WinForms, zéro dépendance)
# Lancé par Lancer.bat (auto-élévation). Orchestre les mêmes modules que Run.ps1.
# Le mode CLI (Run.ps1) reste le fallback de référence.

param(
    [switch]$WhatIf,
    # -UiPreview : aperçu de l'interface SANS élévation. Aucune action n'est
    # exécutée et rien n'est modifié sur la machine ; le kit crée seulement son
    # dossier de journaux runtime\logs sous son propre répertoire (init de
    # lib/Common.ps1). Sert aux contributeurs, aux démonstrations sans UAC et à
    # la boucle de vérification visuelle (tools/Capture-Fenetre.ps1). LANCER est
    # désactivé.
    [switch]$UiPreview,
    [ValidateSet('Prepare','Running','Done')][string]$PreviewPhase = 'Prepare'   # consommé en Task 9 (données factices des phases)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\Help.ps1"
$script:HelpCatalog = Get-HelpCatalog -Path (Join-Path $PSScriptRoot 'config\help.fr.json')

if (-not $UiPreview -and -not (Test-IsAdmin)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Lancer via Lancer.bat (droits administrateur requis).`r`nPour un simple aperçu de l'interface : Run-GUI.ps1 -UiPreview",
        "PC-Refresh-Kit", 'OK', 'Warning') | Out-Null
    exit 1
}

# --- État partagé (portée script pour être visible dans les handlers) ---
$script:Root        = $PSScriptRoot
$script:Modules     = @(
    [PSCustomObject]@{ Id='00'; Name='Diagnostic'; File='00-Diagnostic.ps1' }
    [PSCustomObject]@{ Id='01'; Name='Backup';     File='01-Backup.ps1' }
    [PSCustomObject]@{ Id='02'; Name='Antivirus';  File='02-Antivirus.ps1' }
    [PSCustomObject]@{ Id='03'; Name='Debloat';    File='03-Debloat.ps1' }
    [PSCustomObject]@{ Id='04'; Name='Privacy';    File='04-Privacy.ps1' }
    [PSCustomObject]@{ Id='05'; Name='Updates';    File='05-Updates.ps1' }
    [PSCustomObject]@{ Id='06'; Name='Software';   File='06-Software.ps1' }
    [PSCustomObject]@{ Id='07'; Name='Cleanup';    File='07-Cleanup.ps1' }
    [PSCustomObject]@{ Id='08'; Name='Accounts';   File='08-Accounts.ps1' }
    [PSCustomObject]@{ Id='09'; Name='Comfort';    File='09-Comfort.ps1' }
    [PSCustomObject]@{ Id='11'; Name='DeepClean';  File='11-DeepClean.ps1' }
    [PSCustomObject]@{ Id='12'; Name='Startup';    File='12-Startup.ps1' }
    [PSCustomObject]@{ Id='13'; Name='BrowserPUP'; File='13-BrowserPUP.ps1' }
    [PSCustomObject]@{ Id='15'; Name='Network';    File='15-Network.ps1' }
    [PSCustomObject]@{ Id='10'; Name='Report';     File='10-Report.ps1' }
)
$script:Queue       = @()      # modules à exécuter (objets {Mod, Args})
$script:QueueIndex  = 0
$script:CurrentProc = $null
$script:LogFile     = $null
$script:LogOffset   = 0
$script:Running     = $false
$script:AdminPwd        = $null
$script:PwdVisible      = $false   # passphrase masquée par défaut (page Clôture)
$script:ReportFile      = $null
$script:StartTime       = $null
$script:LastLogChange   = $null    # horodatage du dernier ajout de ligne réel dans le log
$script:LastHeartbeat   = $null    # horodatage du dernier heartbeat injecté
$script:ModuleStartTime = $null    # horodatage du lancement du module courant
$script:DismLastSize    = [long](-1) # taille du fichier DISM au dernier tick (module 07)
$script:ModuleLogStart  = 0            # offset du log au démarrage du module courant (borne de tranche)
$script:RunLabel        = ''           # préfixe de titre : '[DRY-RUN] ' ou '[RUN RÉEL] ' pendant un run
$script:PrepCardsVisible = $true       # phase de la zone droite : cartes affichées (Préparer) ou masquées (Exécuter/Clôturer)
$script:ProfileStartupKeep = @()       # motifs d'autostarts que le profil appliqué préserve (module 12)
$script:ProfileDescription = ''        # description du profil appliqué, telle qu'écrite dans son JSON
$script:AppliedProfileName = ''        # profil réellement APPLIQUÉ, pas la sélection de la liste déroulante
$script:ProfileDescriptions = @{}      # nom de profil -> Description lue dans son JSON (aide au survol de la liste)
# Nom de machine AFFICHÉ (bandeau et titre de la fenêtre). En aperçu, la machine
# réelle n'a rien à faire dans les captures de documentation : la spec 5.5 fixe
# PC-DEMO. Les CHEMINS (fiche, log, rapport) gardent $env:COMPUTERNAME : eux ne
# sont pas décoratifs, et l'aperçu n'en écrit de toute façon aucun.
$script:MachineLabel = if ($UiPreview) { 'PC-DEMO' } else { $env:COMPUTERNAME }
# Titre de la fenêtre au repos, hors run : toute phase de préparation y revient.
$script:TitleRest = "PC-Refresh-Kit - $($script:MachineLabel)"
if ($UiPreview) { $script:TitleRest = "[APERÇU] $($script:TitleRest)" }

# --- Construction de la fenêtre ---
$script:Palette = Get-KitPalette
$script:Mdl2    = Test-KitMdl2Available

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:TitleRest
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'                       # les tailles suivent le DPI (125/150 %)
$form.Size = New-Object System.Drawing.Size(1200, 720)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 576)   # = 1250x720 physiques à 125 %
$form.BackColor = ConvertTo-KitColor $script:Palette.Ground

# Racine : bandeau (haut) / corps (centre) / barre d'action (bas).
$script:Band = New-KitBand -Machine $script:MachineLabel
$script:Band.Panel.Dock = 'Top'

$script:HostAction = New-Object System.Windows.Forms.Panel
$script:HostAction.Dock = 'Bottom'
$script:HostAction.Height = 56
$script:HostAction.BackColor = ConvertTo-KitColor $script:Palette.Card

$body = New-Object System.Windows.Forms.TableLayoutPanel
$body.Dock = 'Fill'
$body.ColumnCount = 2
$body.RowCount = 1
[void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 300)))
[void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$script:HostLeft = New-Object System.Windows.Forms.Panel
$script:HostLeft.Dock = 'Fill'
$script:HostLeft.BackColor = ConvertTo-KitColor $script:Palette.Card
$script:HostLeft.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)

$script:HostRight = New-Object System.Windows.Forms.Panel
$script:HostRight.Dock = 'Fill'
$script:HostRight.BackColor = ConvertTo-KitColor $script:Palette.Ground
$script:HostRight.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)

$body.Controls.Add($script:HostLeft, 0, 0)
$body.Controls.Add($script:HostRight, 1, 0)

# Ordre d'ajout imposé par le docking WinForms : Fill d'abord, puis Bottom, puis Top.
$form.Controls.Add($body)
$form.Controls.Add($script:HostAction)
$form.Controls.Add($script:Band.Panel)

# Badge de mode initial (le mode dry-run peut encore changer avant LANCER).
if ($UiPreview) { Set-KitBadgeMode -Band $script:Band -Mode Preview }
elseif ($WhatIf) { Set-KitBadgeMode -Band $script:Band -Mode Simulation }
else { Set-KitBadgeMode -Band $script:Band -Mode Real }

# --- Colonne intervention : profil en tête, puis la timeline des modules. ---
# Les contrôles d'options (debloat, compte, sensibles, données, Defender,
# dry-run) survivent tels quels, mêmes variables et mêmes valeurs par défaut :
# ils quittent seulement la colonne pour des positions provisoires en bas de la
# zone droite, jusqu'à ce que la Task 6 les range dans les cartes.
$lblProfileTitle = New-KitEyebrow -Text 'Intervention'
$lblProfileTitle.Location = New-Object System.Drawing.Point(0, 2)
$script:HostLeft.Controls.Add($lblProfileTitle)

$cmbProfile = New-Object System.Windows.Forms.ComboBox
$cmbProfile.DropDownStyle = 'DropDownList'
$cmbProfile.Location = New-Object System.Drawing.Point(0, 20)
$cmbProfile.Size = New-Object System.Drawing.Size(276, 24)
$cmbProfile.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$script:HostLeft.Controls.Add($cmbProfile)

$btnApplyProfile = New-Object System.Windows.Forms.Button
$btnApplyProfile.Text = 'Appliquer'
$btnApplyProfile.Location = New-Object System.Drawing.Point(0, 48)
$btnApplyProfile.Size = New-Object System.Drawing.Size(132, 24)
Set-KitButtonStyle -Button $btnApplyProfile -Kind Mini
$script:HostLeft.Controls.Add($btnApplyProfile)

$btnSaveProfile = New-Object System.Windows.Forms.Button
$btnSaveProfile.Text = 'Enregistrer comme profil'
$btnSaveProfile.Location = New-Object System.Drawing.Point(138, 48)
$btnSaveProfile.Size = New-Object System.Drawing.Size(138, 24)
Set-KitButtonStyle -Button $btnSaveProfile -Kind MiniGhost
$script:HostLeft.Controls.Add($btnSaveProfile)
# Aperçu : dernier contrôle actif qui écrirait sur le disque (config\profiles).
if ($UiPreview) { $btnSaveProfile.Enabled = $false }

$lblModulesEyebrow = New-KitEyebrow -Text 'Modules'
$lblModulesEyebrow.Location = New-Object System.Drawing.Point(0, 84)
$script:HostLeft.Controls.Add($lblModulesEyebrow)

# Timeline : une ligne par module, cochée par défaut, pilotée par Id.
$script:ModuleRows = @{}
# Seule la zone des modules défile quand la fenêtre descend à sa taille mini,
# comme le faisait l'ancienne liste cochable : le bloc profil reste visible en
# tête de colonne et toutes les lignes restent atteignables.
$rowsHost = New-Object System.Windows.Forms.Panel
$rowsHost.Location = New-Object System.Drawing.Point(0, 104)
$rowsHost.Size = New-Object System.Drawing.Size(276, (24 * $script:Modules.Count))
$rowsHost.Anchor = 'Top,Bottom,Left,Right'
$rowsHost.AutoScroll = $true
$y = 0
foreach ($m in $script:Modules) {
    $row = New-KitModuleRow -Id $m.Id -Name $m.Name -Mdl2Available $script:Mdl2
    $row.Panel.Location = New-Object System.Drawing.Point(0, $y)
    $row.Panel.Width = 276
    $row.Panel.Anchor = 'Top,Left,Right'
    $rowsHost.Controls.Add($row.Panel)
    $script:ModuleRows[$m.Id] = $row
    # Le résumé de la barre d'action suit chaque case en direct (phase préparation).
    $row.CheckBox.Add_CheckedChanged({ Update-KitActionSummary })
    $y += 24
}
$script:HostLeft.Controls.Add($rowsHost)

function Get-KitCheckedIds {
    # Ids des modules cochés, dans l'ordre de $script:Modules.
    # Contrat collections (b) : return nu, l'appelant encadre de @().
    [CmdletBinding()]
    param()
    return ($script:Modules | Where-Object { $script:ModuleRows[$_.Id].CheckBox.Checked } |
            ForEach-Object { $_.Id })
}

# --- Zone droite, phase préparation : deux cartes, puis les onglets. ---
# Les options gardent leurs variables, leurs valeurs par défaut et leurs
# handlers : la Task 5 les avait garées en bas de la zone droite, elles
# rejoignent ici les cartes Réglages et Actions sensibles.
$cardSettings = New-KitCard
$cardSettings.Location = New-Object System.Drawing.Point(0, 0)
$cardSettings.Size = New-Object System.Drawing.Size(420, 190)
$cardSettings.Anchor = 'Top,Left'

$eyeSettings = New-KitEyebrow -Text 'Réglages'
$eyeSettings.Location = New-Object System.Drawing.Point(12, 8)
$cardSettings.Controls.Add($eyeSettings)

# Politique debloat (module 03) : conservateur / standard / agressif
$lblDebloat = New-Object System.Windows.Forms.Label
$lblDebloat.Text = "Politique debloat :"
$lblDebloat.AutoSize = $true
$lblDebloat.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$lblDebloat.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$lblDebloat.Location = New-Object System.Drawing.Point(12, 30)
$cardSettings.Controls.Add($lblDebloat)

$cmbDebloat = New-Object System.Windows.Forms.ComboBox
$cmbDebloat.DropDownStyle = 'DropDownList'
[void]$cmbDebloat.Items.AddRange(@('Conservateur', 'Standard', 'Agressif'))
$cmbDebloat.SelectedIndex = 1   # Standard par défaut (décision grill)
$cmbDebloat.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cmbDebloat.Size = New-Object System.Drawing.Size(165, 24)
$cmbDebloat.Location = New-Object System.Drawing.Point(127, 26)
$cardSettings.Controls.Add($cmbDebloat)

# Compte utilisateur : les deux radios partagent le parent carte, leur
# exclusivité mutuelle survit donc à la disparition du GroupBox.
$rbStd = New-Object System.Windows.Forms.RadioButton
$rbStd.Text = "Standard + passphrase"
$rbStd.AutoSize = $true
$rbStd.Checked = $true
$rbStd.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$rbStd.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$rbStd.Location = New-Object System.Drawing.Point(12, 58)
$cardSettings.Controls.Add($rbStd)

$rbKeep = New-Object System.Windows.Forms.RadioButton
$rbKeep.Text = "Garder admin (UAC seul)"
$rbKeep.AutoSize = $true
$rbKeep.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$rbKeep.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$rbKeep.Location = New-Object System.Drawing.Point(12, 80)
$cardSettings.Controls.Add($rbKeep)

# Données utilisateur (action positive, cochée par défaut : non destructrice,
# elle reste hors de la carte des actions sensibles)
$cbBackupData = New-Object System.Windows.Forms.CheckBox
$cbBackupData.Text = "Sauvegarder les données utilisateur"
$cbBackupData.AutoSize = $true
$cbBackupData.Checked = $true
$cbBackupData.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbBackupData.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$cbBackupData.Location = New-Object System.Drawing.Point(12, 106)
$cardSettings.Controls.Add($cbBackupData)

# Option Defender (cochée par défaut - option positive liée au module 02)
$cbScanDefender = New-Object System.Windows.Forms.CheckBox
$cbScanDefender.Text     = 'Scanner avec Defender après bascule'
$cbScanDefender.AutoSize = $true
$cbScanDefender.Checked  = $true
$cbScanDefender.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbScanDefender.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$cbScanDefender.Location = New-Object System.Drawing.Point(12, 128)
$cardSettings.Controls.Add($cbScanDefender)

# Dry-run
$cbDryRun = New-Object System.Windows.Forms.CheckBox
$cbDryRun.Text = "Mode dry-run (-WhatIf)"
$cbDryRun.AutoSize = $true
$cbDryRun.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbDryRun.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$cbDryRun.Location = New-Object System.Drawing.Point(12, 150)
if ($WhatIf) { $cbDryRun.Checked = $true }
$cardSettings.Controls.Add($cbDryRun)

# Actions sensibles (toutes décochées par défaut) : liseré ambre à gauche.
$cardSensitive = New-KitCard -WarnAccent
$cardSensitive.Location = New-Object System.Drawing.Point(430, 0)
$cardSensitive.Size = New-Object System.Drawing.Size(420, 190)
$cardSensitive.Anchor = 'Top,Left'

$eyeSensitive = New-KitEyebrow -Text 'Actions sensibles - décochées = non faites'
$eyeSensitive.Location = New-Object System.Drawing.Point(15, 8)
$cardSensitive.Controls.Add($eyeSensitive)

$cbRecycle  = New-Object System.Windows.Forms.CheckBox; $cbRecycle.Text  = "Vider la corbeille";         $cbRecycle.AutoSize  = $true
$cbWinOld   = New-Object System.Windows.Forms.CheckBox; $cbWinOld.Text   = "Supprimer Windows.old";      $cbWinOld.AutoSize   = $true
$cbCache    = New-Object System.Windows.Forms.CheckBox; $cbCache.Text    = "Vider caches navigateurs";   $cbCache.AutoSize    = $true
$cbOneDrive = New-Object System.Windows.Forms.CheckBox; $cbOneDrive.Text = "Désinstaller OneDrive";      $cbOneDrive.AutoSize = $true
$cbOem      = New-Object System.Windows.Forms.CheckBox; $cbOem.Text      = "Debloat constructeur (OEM)"; $cbOem.AutoSize      = $true
$cbNetReset = New-Object System.Windows.Forms.CheckBox
$cbNetReset.Text     = 'Réinitialiser le réseau (non réversible)'
$cbNetReset.AutoSize = $true
# $cbNetReset.Checked reste $false (décoché par défaut)

$cbRecycle.Font  = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbWinOld.Font   = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbCache.Font    = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbOneDrive.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbOem.Font      = New-Object System.Drawing.Font('Segoe UI', 9.75)
$cbNetReset.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)

$cbRecycle.ForeColor  = ConvertTo-KitColor $script:Palette.Ink
$cbWinOld.ForeColor   = ConvertTo-KitColor $script:Palette.Ink
$cbCache.ForeColor    = ConvertTo-KitColor $script:Palette.Ink
$cbOneDrive.ForeColor = ConvertTo-KitColor $script:Palette.Ink
$cbOem.ForeColor      = ConvertTo-KitColor $script:Palette.Ink
$cbNetReset.ForeColor = ConvertTo-KitColor $script:Palette.Ink

$cbRecycle.Location  = New-Object System.Drawing.Point(15, 30)
$cbWinOld.Location   = New-Object System.Drawing.Point(15, 52)
$cbCache.Location    = New-Object System.Drawing.Point(15, 74)
$cbOneDrive.Location = New-Object System.Drawing.Point(15, 96)
$cbOem.Location      = New-Object System.Drawing.Point(15, 118)
$cbNetReset.Location = New-Object System.Drawing.Point(15, 140)
$cardSensitive.Controls.AddRange(@($cbRecycle, $cbWinOld, $cbCache, $cbOneDrive, $cbOem, $cbNetReset))

$script:HostRight.Controls.Add($cardSettings)
$script:HostRight.Controls.Add($cardSensitive)

# --- Onglets Aide / Journal sous les cartes : ils occupent le reste de la zone
# (taille posée au redimensionnement, voir le handler plus bas). ---
$script:Tabs = New-Object System.Windows.Forms.TabControl
$script:Tabs.Location = New-Object System.Drawing.Point(0, 200)
$script:Tabs.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)

$script:TabHelp = New-Object System.Windows.Forms.TabPage
$script:TabHelp.Text = 'Aide'
$script:TabHelp.BackColor = ConvertTo-KitColor $script:Palette.Card
$script:TabLog = New-Object System.Windows.Forms.TabPage
$script:TabLog.Text = 'Journal'

$txtHelp = New-Object System.Windows.Forms.RichTextBox
$txtHelp.Dock = 'Fill'
$txtHelp.ReadOnly = $true
$txtHelp.BorderStyle = 'None'
$txtHelp.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
$txtHelp.ForeColor = ConvertTo-KitColor $script:Palette.Ink
# Invite d'accueil : gardée en variable, elle est reposée après le peuplement
# initial de la liste des profils (voir l'appel à Update-ProfileComboBox).
$script:HelpPrompt = "Survolez un module ou une option : son explication complète s'affiche ici."
$txtHelp.Text = $script:HelpPrompt
$script:TabHelp.Controls.Add($txtHelp)

# RichTextBox : coloration par niveau. Fond sombre assorti au rapport HTML.
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock = 'Fill'
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = 'None'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = ConvertTo-KitColor $script:Palette.JournalBg
$txtLog.ForeColor = ConvertTo-KitColor $script:Palette.LogInfo
$script:TabLog.Controls.Add($txtLog)

$script:Tabs.TabPages.Add($script:TabHelp)
$script:Tabs.TabPages.Add($script:TabLog)
$script:HostRight.Controls.Add($script:Tabs)

# Taille initiale calée sur la zone droite RÉELLE (le panneau est déjà docké et
# mesuré : le corps a été ajouté au formulaire plus haut), puis ancres quatre
# côtés. C'est ce qui remplace le pilotage manuel Width/Height de la Task 6 : ce
# pilotage n'existait que pour cohabiter avec l'AutoScroll transitoire de la
# Task 4 et son plafond de hauteur 360 aurait figé les onglets sur une fenêtre
# agrandie. Les ancres se calculent sur la taille du parent au moment où elles
# sont posées : l'ordre taille -> ancre est donc obligatoire.
$script:Tabs.Size = New-Object System.Drawing.Size(
    ($script:HostRight.ClientSize.Width - 24),
    ($script:HostRight.ClientSize.Height - 20 - 200))
$script:Tabs.Anchor = 'Top,Bottom,Left,Right'

# --- Géométrie de la zone droite, pilotée par la phase (spec 4.3). ---
# Préparer : les deux cartes en haut, les onglets dessous (Y = 200).
# Exécuter et Clôturer : les cartes se masquent, les onglets prennent toute la
# hauteur. Ce sont ces 200 px qui manquaient à la page Clôture, dont la checklist
# n'affichait que 7 items sur 9 à la taille de fenêtre par défaut.
# Idempotente : elle repose des valeurs ABSOLUES recalculées sur la taille
# courante de la zone, jamais des deltas cumulés. Elle peut donc être rappelée à
# chaque changement de phase ET à chaque redimensionnement sans dériver.
# Définie ici, avant le handler de redimensionnement qui l'appelle : en PowerShell
# une fonction doit avoir été exécutée pour être appelable (même ordre que
# Update-KitActionBarLayout et la barre d'action).
function Update-KitRightZoneForPhase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$PrepVisible)
    $script:PrepCardsVisible = $PrepVisible
    $cardSettings.Visible  = $PrepVisible
    $cardSensitive.Visible = $PrepVisible
    if ($PrepVisible) {
        # Largeur des deux cartes (moitié-moitié) : seul dimensionnement encore
        # piloté à la main, les cartes gardant une hauteur fixe. Inutile quand
        # elles sont masquées, leur largeur est reposée au retour en Préparer.
        $half = [int](($script:HostRight.ClientSize.Width - 24 - 10) / 2)
        $cardSettings.Width = $half
        $cardSensitive.Location = New-Object System.Drawing.Point(($half + 10), 0)
        $cardSensitive.Width = $half
    }
    # Onglets : sous les cartes ou collés en haut, et dans les deux cas jusqu'au
    # bas de la zone. WinForms rafraîchit les distances d'ancrage à chaque
    # changement de Bounds : les ancres quatre côtés (posées plus haut) repartent
    # donc de ces bornes et suivent les redimensionnements suivants.
    $top = if ($PrepVisible) { 200 } else { 0 }
    $w = [Math]::Max(200, ($script:HostRight.ClientSize.Width - 24))
    $h = [Math]::Max(120, ($script:HostRight.ClientSize.Height - 20 - $top))
    $script:Tabs.SetBounds(0, $top, $w, $h)
}

# Redimensionnement de la zone : même calcul, avec la visibilité de la phase en
# cours. Elle se lit dans $script:PrepCardsVisible et JAMAIS dans
# $cardSettings.Visible : le getter WinForms renvoie la visibilité EFFECTIVE, donc
# $false tant que le formulaire n'est pas affiché ; un redimensionnement reçu
# avant ShowDialog masquerait alors les cartes pour de bon.
$script:HostRight.Add_Resize({ Update-KitRightZoneForPhase -PrepVisible $script:PrepCardsVisible })

# --- Contrôles créés ici, sans parent : leur unique parent définitif est posé
# au reparentage, plus bas. $btnCopy, la checklist et $btnDelFiche rejoignent la
# page Clôture ; $btnRun, $btnCancel et $btnReport la barre d'action (Task 7).
# Plus aucun contrôle n'est garé en position absolue dans la zone droite : c'est
# ce qui permet à l'AutoScroll transitoire de disparaître.
$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Enabled = $false

$btnReport = New-Object System.Windows.Forms.Button
$btnReport.Text = "Ouvrir le rapport"
$btnReport.Enabled = $false

# --- Checklist de fin d'intervention (peuplée en fin de run par Show-KitClosePhase) ---
# Cadre visible + hôte défilant à l'intérieur : un GroupBox n'a pas d'AutoScroll
# (il dérive de Control, pas de ScrollableControl), et les 9 items dépassent la
# hauteur disponible à la taille de fenêtre minimale. Même parti pris que la
# colonne des modules (Task 6).
$script:GbChecklist = New-Object System.Windows.Forms.GroupBox
$script:GbChecklist.Text = ''
$script:GbChecklist.BackColor = ConvertTo-KitColor $script:Palette.Card

$script:ChecklistHost = New-Object System.Windows.Forms.Panel
$script:ChecklistHost.Dock = 'Fill'
$script:ChecklistHost.AutoScroll = $true
$script:ChecklistHost.BackColor = ConvertTo-KitColor $script:Palette.Card
$script:GbChecklist.Controls.Add($script:ChecklistHost)

# Bouton de suppression de la fiche PC (désactivé jusqu'à la fin du run, actif seulement si la fiche existe)
$btnDelFiche = New-Object System.Windows.Forms.Button
$btnDelFiche.Text = 'Supprimer la fiche PC de la clé'
$btnDelFiche.Enabled = $false

# Bouton Lancer
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "LANCER"

# Bouton Annuler (désactivé par défaut, activé en cours de run)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Annuler"
$btnCancel.Enabled = $false

# --- Page Clôture : construite tout de suite, ajoutée au TabControl en fin de
# run seulement (spec 4.3). Journal et Aide restent consultables à côté. La
# taille posée ici est celle d'une TabPage de ce TabControl à la taille de
# fenêtre par défaut : les ancres des enfants s'en déduisent, et restent justes
# quand la page est réellement ajoutée, à n'importe quelle taille de fenêtre. ---
$script:TabClose = New-Object System.Windows.Forms.TabPage
$script:TabClose.Text = 'Clôture'
$script:TabClose.BackColor = ConvertTo-KitColor $script:Palette.Ground
$closePad = 10
$script:TabClose.Padding = New-Object System.Windows.Forms.Padding($closePad)
$script:TabClose.Size = New-Object System.Drawing.Size(
    ($script:Tabs.DisplayRectangle.Width), ($script:Tabs.DisplayRectangle.Height))
$closeW = $script:TabClose.DisplayRectangle.Width    # largeur utile, marges déduites
$closeH = $script:TabClose.DisplayRectangle.Height
# Le Padding d'une TabPage rétrécit bien son DisplayRectangle (d'où $closeW et
# $closeH déjà amputés de 2 x 10 px), mais il ne DÉCALE pas les enfants placés en
# absolu : un enfant en (0,0) collait au bord gauche et haut, et la marge de 10 px
# se retrouvait entièrement à droite et en bas (21 px mesurés). Toutes les
# positions de la page partent donc de $closePad : gouttière égale sur les quatre
# côtés, et les ancres restent justes puisqu'elles se calculent sur ce même
# DisplayRectangle.

$cardPwd = New-KitCard -BorderHex $script:Palette.AccentPale
$cardPwd.Location = New-Object System.Drawing.Point($closePad, $closePad)
$cardPwd.Size = New-Object System.Drawing.Size($closeW, 62)
$cardPwd.Anchor = 'Top,Left,Right'
$cardPwd.BackColor = ConvertTo-KitColor $script:Palette.AccentBgSoft

$eyePwd = New-KitEyebrow -Text 'Compte Admin-Local créé'
$eyePwd.Location = New-Object System.Drawing.Point(12, 8)
$cardPwd.Controls.Add($eyePwd)

$script:LblPwdValue = New-Object System.Windows.Forms.Label
$script:LblPwdValue.Text = '(généré après le module Accounts)'
$script:LblPwdValue.AutoSize = $true
$script:LblPwdValue.Location = New-Object System.Drawing.Point(12, 30)
$script:LblPwdValue.Font = New-Object System.Drawing.Font('Consolas', 11)
$script:LblPwdValue.ForeColor = ConvertTo-KitColor '#134e4a'
$cardPwd.Controls.Add($script:LblPwdValue)

$btnCopy.Text = 'Copier'
$btnCopy.Size = New-Object System.Drawing.Size(80, 26)
$btnCopy.Location = New-Object System.Drawing.Point(($closeW - 92), 26)
$btnCopy.Anchor = 'Top,Right'
Set-KitButtonStyle -Button $btnCopy -Kind Mini
$cardPwd.Controls.Add($btnCopy)          # reparentage : handler Copier conservé

$script:BtnPwdShow = New-KitButton -Text 'Afficher' -Kind Mini
$script:BtnPwdShow.Size = New-Object System.Drawing.Size(80, 26)
$script:BtnPwdShow.Location = New-Object System.Drawing.Point(($closeW - 182), 26)
$script:BtnPwdShow.Anchor = 'Top,Right'
$script:BtnPwdShow.Enabled = $false
$cardPwd.Controls.Add($script:BtnPwdShow)

$script:TabClose.Controls.Add($cardPwd)

# Rangée de section : titre à gauche, actions de la page à droite. Les deux
# boutons ont tenu un temps en pied de page ; ancrés en bas, ils volaient à la
# checklist les 38 px dont elle manque déjà, et venaient la recouvrir dès que la
# fenêtre approchait sa taille minimale (capture du 21/08). Ici ils restent
# visibles à toute taille et le cadre de la checklist prend TOUT le reste.
$eyeCheck = New-KitEyebrow -Text 'Avant de rendre le PC'
$eyeCheck.Location = New-Object System.Drawing.Point(($closePad + 2), ($closePad + 74))
$script:TabClose.Controls.Add($eyeCheck)

$btnDelFiche.Size = New-Object System.Drawing.Size(230, 30)
$btnDelFiche.Location = New-Object System.Drawing.Point(($closePad + $closeW - 230), ($closePad + 68))
$btnDelFiche.Anchor = 'Top,Right'
Set-KitButtonStyle -Button $btnDelFiche -Kind Danger
$script:TabClose.Controls.Add($btnDelFiche)   # reparentage : handler conservé

$btnReportClose = New-KitButton -Text 'Ouvrir le rapport' -Kind Ghost
$btnReportClose.Size = New-Object System.Drawing.Size(150, 30)
$btnReportClose.Location = New-Object System.Drawing.Point(($closePad + $closeW - 390), ($closePad + 68))
$btnReportClose.Anchor = 'Top,Right'
$btnReportClose.Add_Click({ $btnReport.PerformClick() })
$script:TabClose.Controls.Add($btnReportClose)

$script:GbChecklist.Location = New-Object System.Drawing.Point($closePad, ($closePad + 104))
$script:GbChecklist.Size = New-Object System.Drawing.Size($closeW, ($closeH - 104))
$script:GbChecklist.Anchor = 'Top,Bottom,Left,Right'
$script:GbChecklist.Visible = $true      # la page entière est masquée, pas le groupe
$script:TabClose.Controls.Add($script:GbChecklist)

# --- Barre d'action : le fil conducteur des trois phases. ---
$script:ActionSummary = New-Object System.Windows.Forms.Label
$script:ActionSummary.AutoSize = $true
$script:ActionSummary.Location = New-Object System.Drawing.Point(14, 18)
$script:ActionSummary.ForeColor = ConvertTo-KitColor $script:Palette.InkSoft
$script:ActionSummary.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:HostAction.Controls.Add($script:ActionSummary)

# Progression custom (la ProgressBar système ne se colore pas) : piste + remplissage.
$script:ActionProgressTrack = New-Object System.Windows.Forms.Panel
$script:ActionProgressTrack.Height = 8
$script:ActionProgressTrack.BackColor = ConvertTo-KitColor $script:Palette.Line
$script:ActionProgressTrack.Visible = $false
$script:ActionProgressFill = New-Object System.Windows.Forms.Panel
$script:ActionProgressFill.Height = 8
$script:ActionProgressFill.Width = 0
$script:ActionProgressFill.BackColor = ConvertTo-KitColor $script:Palette.Accent
$script:ActionProgressFill.Location = New-Object System.Drawing.Point(0, 0)
$script:ActionProgressTrack.Controls.Add($script:ActionProgressFill)
$script:HostAction.Controls.Add($script:ActionProgressTrack)

# Boutons existants, restylés et migrés dans la barre (handlers conservés).
$btnRun.Text = "▶  LANCER L'INTERVENTION"
$btnRun.Size = New-Object System.Drawing.Size(230, 36)
Set-KitButtonStyle -Button $btnRun -Kind Primary
$script:HostAction.Controls.Add($btnRun)

$btnCancel.Size = New-Object System.Drawing.Size(100, 36)
Set-KitButtonStyle -Button $btnCancel -Kind Ghost
$btnCancel.Visible = $false          # visible uniquement pendant le run
$script:HostAction.Controls.Add($btnCancel)

$btnReport.Text = 'Ouvrir le rapport'
$btnReport.Size = New-Object System.Drawing.Size(160, 36)
Set-KitButtonStyle -Button $btnReport -Kind Primary
$btnReport.Visible = $false          # visible en phase Done
$script:HostAction.Controls.Add($btnReport)

$script:BtnNewRun = New-KitButton -Text 'Préparer une nouvelle intervention' -Kind Ghost
$script:BtnNewRun.Size = New-Object System.Drawing.Size(230, 36)
$script:BtnNewRun.Visible = $false
$script:HostAction.Controls.Add($script:BtnNewRun)

# Placement droit des boutons, piste de progression entre le résumé et eux.
# Fonction plutôt que corps de handler : la barre est dockée et dimensionnée dès
# son ajout au formulaire, bien avant l'existence du handler, donc Resize ne se
# redéclenche pas tout seul (boutons restés hors barre au premier essai). Le
# placement est aussi rejoué à chaque phase et à chaque résumé, car la gauche de
# la piste dépend de la largeur du libellé, qui change avec son texte.
function Update-KitActionBarLayout {
    $w = $script:HostAction.ClientSize.Width
    $btnRun.Location    = New-Object System.Drawing.Point(($w - $btnRun.Width - 14), 10)
    $btnCancel.Location = New-Object System.Drawing.Point(($w - $btnCancel.Width - 14), 10)
    $btnReport.Location = New-Object System.Drawing.Point(($w - $btnReport.Width - 14), 10)
    $script:BtnNewRun.Location = New-Object System.Drawing.Point(($w - $btnReport.Width - 14 - $script:BtnNewRun.Width - 10), 10)
    $left = $script:ActionSummary.Right + 20
    $script:ActionProgressTrack.Location = New-Object System.Drawing.Point($left, 24)
    $script:ActionProgressTrack.Width = [Math]::Max(80, $w - $left - $btnCancel.Width - 40)
}
$script:HostAction.Add_Resize({ Update-KitActionBarLayout })
Update-KitActionBarLayout

# --- Infos-bulles et panneau d'aide, tous deux alimentés par config\help.fr.json ---
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.InitialDelay = 500
$toolTip.AutoPopDelay = 30000   # 5 s ne suffisaient pas à lire une explication complète

# Show-KitHelp : met à jour l'onglet Aide sans jamais le ramener au premier plan
# (pendant une exécution, l'opérateur regarde le journal).
function Show-KitHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    try {
        $entry = Get-HelpEntry -Catalog $script:HelpCatalog -Key $Key
        $txtHelp.Text = Format-HelpPanel -Entry $entry
    }
    catch { }   # l'aide ne doit jamais casser la GUI
}

# Show-KitProfileHelp : aide d'un profil, en trois temps. Un profil enregistré
# depuis le cockpit n'a pas de rubrique de catalogue : sans cette cascade, le
# panneau lui répondait « Aide indisponible - catalogue absent » alors que son
# JSON porte une Description écrite par l'opérateur.
function Show-KitProfileHelp {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ($script:HelpCatalog -and $script:HelpCatalog.ContainsKey("profile.$Name")) {
        Show-KitHelp -Key "profile.$Name"
        return
    }
    $desc = if ($script:ProfileDescriptions.ContainsKey($Name)) { [string]$script:ProfileDescriptions[$Name] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($desc)) {
        # Même mise en forme que les rubriques du catalogue : une seule apparence
        # d'aide, quelle que soit la provenance du texte.
        try { $txtHelp.Text = Format-HelpPanel -Entry ([PSCustomObject]@{ title = "Profil $Name"; what = $desc }) }
        catch { }
        return
    }
    $txtHelp.Text = $script:HelpPrompt
}

# Table de correspondance contrôle -> clé d'aide.
$helpBindings = @(
    @{ Ctrl = $cbBackupData;      Key = 'option.backupdata' }
    @{ Ctrl = $cbScanDefender;    Key = 'option.scandefender' }
    @{ Ctrl = $cbRecycle;         Key = 'option.recycle' }
    @{ Ctrl = $cbWinOld;          Key = 'option.winold' }
    @{ Ctrl = $cbCache;           Key = 'option.cache' }
    @{ Ctrl = $cbOneDrive;        Key = 'option.onedrive' }
    @{ Ctrl = $cbOem;             Key = 'option.oem' }
    @{ Ctrl = $cbNetReset;        Key = 'option.netreset' }
    @{ Ctrl = $cbDryRun;          Key = 'option.dryrun' }
    @{ Ctrl = $rbStd;             Key = 'account.standard' }
    @{ Ctrl = $rbKeep;            Key = 'account.keepadmin' }
    @{ Ctrl = $btnRun;            Key = 'action.run' }
    @{ Ctrl = $btnCancel;         Key = 'action.cancel' }
    @{ Ctrl = $btnReport;         Key = 'action.report' }
    @{ Ctrl = $btnReportClose;    Key = 'action.report' }      # relais de $btnReport sur la page Clôture
    @{ Ctrl = $script:BtnNewRun;  Key = 'action.newrun' }
    @{ Ctrl = $btnCopy;           Key = 'action.copypassword' }
    @{ Ctrl = $script:BtnPwdShow; Key = 'action.pwdshow' }
    @{ Ctrl = $btnDelFiche;       Key = 'action.delfiche' }
    @{ Ctrl = $btnApplyProfile;   Key = 'action.applyprofile' }
    @{ Ctrl = $btnSaveProfile;    Key = 'action.saveprofile' }
)

foreach ($b in $helpBindings) {
    $entry = Get-HelpEntry -Catalog $script:HelpCatalog -Key $b.Key
    $toolTip.SetToolTip($b.Ctrl, (Format-HelpTooltip -Entry $entry -Width 90))
    $cle = $b.Key    # capture par valeur : sans copie locale, tous les handlers verraient la dernière clé
    $b.Ctrl.Add_MouseEnter({ Show-KitHelp -Key $cle }.GetNewClosure())
}

# Politique de débloatage : l'aide dépend de la valeur choisie.
$debloatKeys = @{ 'Conservateur' = 'debloat.conservative'; 'Standard' = 'debloat.standard'; 'Agressif' = 'debloat.aggressive' }
$cmbDebloat.Add_MouseEnter({
    $k = $debloatKeys[[string]$cmbDebloat.SelectedItem]
    if ($k) { Show-KitHelp -Key $k }
})
$cmbDebloat.Add_SelectedIndexChanged({
    $k = $debloatKeys[[string]$cmbDebloat.SelectedItem]
    if ($k) { Show-KitHelp -Key $k }
})

# Profils : l'aide dépend du profil sélectionné (catalogue, puis Description du JSON).
$cmbProfile.Add_MouseEnter({
    Show-KitProfileHelp -Name ([string]$cmbProfile.SelectedItem)
})
$cmbProfile.Add_SelectedIndexChanged({
    Show-KitProfileHelp -Name ([string]$cmbProfile.SelectedItem)
})

# Timeline : aide du module survolé (panel entier + nom, l'un ou l'autre reçoit l'événement).
foreach ($m in $script:Modules) {
    $row = $script:ModuleRows[$m.Id]
    $key = "module.$($m.Id)"
    foreach ($ctrl in @($row.Panel, $row.NameLabel, $row.CheckBox)) {
        $ctrl.Add_MouseEnter({ Show-KitHelp -Key $key }.GetNewClosure())
    }
    $entryRow = Get-HelpEntry -Catalog $script:HelpCatalog -Key $key
    $toolTip.SetToolTip($row.NameLabel, (Format-HelpTooltip -Entry $entryRow -Width 90))
}

# Timer de suivi
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400

# --- Fonctions d'orchestration ---

function Add-LogLines {
    # Lit les nouvelles lignes du log unifié et les ajoute à la zone de texte
    if (-not $script:LogFile -or -not (Test-Path $script:LogFile)) { return }
    try {
        # @() force un tableau : sinon Get-Content d'un log a 0 ou 1 ligne renvoie $null / une chaine,
        # et $all.Count plante sous StrictMode (PropertyNotFoundStrict) -> crash de la GUI.
        $all = @(Get-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop)
    } catch { return }   # fichier verrouillé ce tick, on réessaie au prochain
    if ($all.Count -gt $script:LogOffset) {
        $new = $all[$script:LogOffset..($all.Count - 1)]
        foreach ($line in $new) {
            # Coloration par niveau, DÉFENSIVE : tout échec de coloration ne doit jamais empêcher
            # l'ajout du texte ni casser le tick (la couleur est secondaire, le log est prioritaire).
            try {
                $txtLog.SelectionStart  = $txtLog.TextLength
                $txtLog.SelectionLength = 0
                $txtLog.SelectionColor  = ConvertTo-KitColor (Get-KitLogLevelColorHex -Line $line)
            } catch { }
            $txtLog.AppendText([string]$line + "`r`n")
        }
        try { $txtLog.SelectionColor = $txtLog.ForeColor; $txtLog.ScrollToCaret() } catch { }
        $script:LogOffset   = $all.Count
        $script:LastLogChange = Get-Date   # activité log réelle : réinitialise le compteur de silence
    }
}

function Start-NextModule {
    if ($script:QueueIndex -ge $script:Queue.Count) {
        # Terminé
        $timer.Stop()
        Add-LogLines   # dernière lecture : capturer les ultimes lignes du dernier module
        $script:Running = $false
        $btnRun.Enabled = -not $UiPreview   # même garde qu'ailleurs : l'aperçu ne rouvre jamais LANCER
        $btnCancel.Enabled = $false
        Set-KitActionProgress -Current 1 -Total 1
        $txtLog.AppendText("`r`n=== Terminé ===`r`n")
        # Bilan final : compteurs du run + durée, lus depuis le log unifié.
        try {
            $sumLines   = @(Get-Content $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            $sum        = Get-ReportSummary -Lines $sumLines
            $elapsedStr = if ($script:StartTime) { Format-Elapsed ([int]((Get-Date) - $script:StartTime).TotalSeconds) } else { '-' }
            $txtLog.AppendText("Bilan : OK $($sum.CountOK) / Avertissements $($sum.CountWarn) / Erreurs $($sum.CountError) - durée $elapsedStr`r`n")
            $form.Text = "$($script:RunLabel)PC-Refresh-Kit - $($script:MachineLabel) - terminé en $elapsedStr"
            Set-KitActionPhase -Phase Done -Data @{
                Bilan = Get-RunDoneText -CountOK $sum.CountOK -CountWarn $sum.CountWarn `
                                        -CountError $sum.CountError -Elapsed $elapsedStr
            }
        } catch {
            # Le bilan est informatif : même s'il échoue, la barre doit quitter la
            # phase Running (sinon Annuler resterait seul visible après la fin) et
            # le résumé doit dire pourquoi il est vide. Le repli est lui-même
            # protégé : le chemin terminal ne doit jamais lever.
            try { Set-KitActionPhase -Phase Done -Data @{ Bilan = 'Terminé - bilan indisponible' } } catch { }
        }
        # Mot de passe depuis la fiche
        $fiche = Join-Path $script:Root "runtime\FICHE-PC-$env:COMPUTERNAME.txt"
        if (Test-Path $fiche) {
            $line = (Get-Content $fiche -Encoding UTF8 | Where-Object { $_ -match 'Mot de passe' } | Select-Object -First 1)
            if ($line -match ':\s*(.+)$') {
                $script:AdminPwd = $Matches[1].Trim()
                $script:PwdVisible = $false
                $script:LblPwdValue.Text = ('•' * 12)     # masquée par défaut (spec, décision grill)
                $script:BtnPwdShow.Text = 'Afficher'
                $script:BtnPwdShow.Enabled = $true
                $btnCopy.Enabled = $true
            }
        }
        # Rapport : on privilégie le HTML (livrable présentable), sinon le TXT.
        $repHtml = Get-ChildItem (Join-Path $script:Root 'runtime') -Filter "RAPPORT-$env:COMPUTERNAME-*.html" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $repTxt  = Get-ChildItem (Join-Path $script:Root 'runtime') -Filter "RAPPORT-$env:COMPUTERNAME-*.txt" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($repHtml)    { $script:ReportFile = $repHtml.FullName; $btnReport.Enabled = $true }
        elseif ($repTxt) { $script:ReportFile = $repTxt.FullName;  $btnReport.Enabled = $true }
        # Bouton de suppression de fiche : activer seulement si la fiche est encore présente
        # ($fiche est calculé plus haut dans ce même bloc terminal)
        if (Test-Path $fiche) { $btnDelFiche.Enabled = $true }
        # Bascule en phase clôture : checklist peuplée, onglet Clôture ajouté et sélectionné
        try {
            $rebootReq = Test-Path (Join-Path $script:Root 'runtime\reboot-required.flag')
            Show-KitClosePhase -RebootRequired $rebootReq
        } catch { }   # la clôture est informative : toute erreur ne bloque pas la fin de run
        return
    }

    $item = $script:Queue[$script:QueueIndex]
    $mod  = $item.Mod
    # Borne de tranche depuis le fichier RÉEL, pas depuis l'offset d'affichage :
    # le WARN du timeout de pause backup (écrit timer arrêté) n'appartient à aucun module.
    $script:ModuleLogStart = @(Get-Content $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue).Count
    Set-KitModuleRowState -Row $script:ModuleRows[$mod.Id] -State Running -Detail 'en cours' -Mdl2Available $script:Mdl2
    $txtLog.AppendText("`r`n--- Module $($mod.Id) $($mod.Name) ---`r`n")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = $item.Args
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:Root

    $script:CurrentProc = [System.Diagnostics.Process]::Start($psi)
    # Fermer le stdin : tout Read-Host résiduel reçoit EOF et retourne vide (anti-blocage)
    $script:CurrentProc.StandardInput.Close()
    # Initialiser les compteurs heartbeat pour ce module
    $script:LastLogChange   = Get-Date
    $script:LastHeartbeat   = Get-Date
    $script:ModuleStartTime = Get-Date
    $script:DismLastSize    = [long](-1)  # réinitialisé à chaque démarrage de module
}

function Build-Queue {
    $script:Queue = @()
    $dry = $cbDryRun.Checked
    $policyMap = @{ 'Conservateur' = 'Conservative'; 'Standard' = 'Standard'; 'Agressif' = 'Aggressive' }
    $options = @{
        BackupData    = $cbBackupData.Checked
        ScanDefender  = $cbScanDefender.Checked
        Oem           = $cbOem.Checked
        DebloatPolicy = $policyMap[[string]$cmbDebloat.SelectedItem]
        Recycle       = $cbRecycle.Checked
        WinOld        = $cbWinOld.Checked
        Cache         = $cbCache.Checked
        KeepAdmin     = $rbKeep.Checked
        OneDrive      = $cbOneDrive.Checked
        NetReset      = $cbNetReset.Checked
        StartupKeep   = $script:ProfileStartupKeep
    }

    foreach ($mod in $script:Modules) {
        if (-not $script:ModuleRows[$mod.Id].CheckBox.Checked) { continue }
        $fileArgs = @('-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $script:Root "modules\$($mod.File)")))
        $modArgs  = Build-ModuleArgList -Id $mod.Id -DryRun:$dry -Options $options
        $script:Queue += [PSCustomObject]@{ Mod = $mod; Args = (($fileArgs + $modArgs) -join ' ') }
    }
}

function Update-KitActionSummary {
    # Résumé live de la phase préparation. Appelé à chaque changement de case.
    # NOTE pipeline : le tableau DOIT être construit avant le Where-Object,
    # sinon le pipe ne s'applique qu'au dernier élément de la liste.
    $checked = @(Get-KitCheckedIds)
    $sensitives = @(@($cbRecycle, $cbWinOld, $cbCache, $cbOneDrive, $cbOem, $cbNetReset) |
                    Where-Object { $_.Checked })
    # Le profil AFFICHÉ est celui réellement appliqué : sélectionner une entrée de la
    # liste déroulante sans cliquer Appliquer ne doit rien changer au résumé.
    $profName = $script:AppliedProfileName
    $script:ActionSummary.Text = Get-RunSummaryText -ModuleCount $checked.Count `
        -SensitiveCount $sensitives.Count -ProfileName $profName -IsDryRun $cbDryRun.Checked
    Update-KitActionBarLayout   # le libellé a changé de largeur : la piste se recale
}

function Set-KitActionPhase {
    # Bascule la barre d'action (et les boutons) dans une phase.
    # Data : Prepare -> rien ; Running -> rien (le Tick alimente) ;
    # Done -> @{ Bilan = <string> }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Prepare','Running','Done')][string]$Phase,
        [hashtable]$Data = @{}
    )
    switch ($Phase) {
        'Prepare' {
            $btnRun.Visible = $true
            $btnCancel.Visible = $false
            $btnReport.Visible = $false
            $script:BtnNewRun.Visible = $false
            $script:ActionProgressTrack.Visible = $false
            $script:ActionSummary.ForeColor = ConvertTo-KitColor $script:Palette.InkSoft
            Update-KitActionSummary
        }
        'Running' {
            $btnRun.Visible = $false
            $btnCancel.Visible = $true
            $btnReport.Visible = $false
            $script:BtnNewRun.Visible = $false
            $script:ActionProgressTrack.Visible = $true
            $script:ActionProgressFill.Width = 0
        }
        'Done' {
            $btnRun.Visible = $false
            $btnCancel.Visible = $false
            $btnReport.Visible = $true
            $script:BtnNewRun.Visible = $true
            $script:ActionProgressTrack.Visible = $false
            if ($Data.ContainsKey('Bilan')) { $script:ActionSummary.Text = [string]$Data.Bilan }
        }
    }
    # Zone droite : cartes visibles en Préparer seulement, les onglets récupèrent
    # leurs 200 px en Exécuter et en Clôturer (spec 4.3). Calculé depuis $Phase
    # plutôt que branche par branche : impossible de désynchroniser les deux.
    Update-KitRightZoneForPhase -PrepVisible ($Phase -eq 'Prepare')
    Update-KitActionBarLayout
    $script:HostAction.PerformLayout()
}

function Set-KitActionProgress {
    # Progression : Current modules terminés sur Total.
    [CmdletBinding()]
    param([int]$Current, [int]$Total)
    if ($Total -le 0) { return }
    $ratio = [Math]::Min(1.0, $Current / [double]$Total)
    $script:ActionProgressFill.Width = [int]($script:ActionProgressTrack.ClientSize.Width * $ratio)
}

function Show-KitClosePhase {
    # Peuple la checklist, ajoute l'onglet Clôture au TabControl et le sélectionne.
    # Les items viennent de Get-EndChecklistItems (lib/Report.ps1) : une seule
    # source pour la GUI, le rapport et la note utilisateur.
    [CmdletBinding()]
    param([bool]$RebootRequired)
    $script:ChecklistHost.Controls.Clear()
    $yItem = 6
    foreach ($item in @(Get-EndChecklistItems -RebootRequired $RebootRequired)) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = [string]$item
        $cb.AutoSize = $true
        $cb.Checked = $false
        $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
        $cb.Location = New-Object System.Drawing.Point(8, $yItem)
        if ($RebootRequired -and ([string]$item -match 'REBOOT REQUIS|REDÉMARRER')) {
            $cb.ForeColor = ConvertTo-KitColor $script:Palette.Err
            $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
        } else {
            $cb.ForeColor = ConvertTo-KitColor $script:Palette.Ink
        }
        $script:ChecklistHost.Controls.Add($cb)
        $yItem += 24
    }
    if (-not $script:Tabs.TabPages.Contains($script:TabClose)) {
        $script:Tabs.TabPages.Add($script:TabClose)
    }
    $script:Tabs.SelectedTab = $script:TabClose
}

# ---------------------------------------------------------------------------
# Show-BackupPause : modale de vérification backup après le module 01.
# Retourne 'ok' (opérateur a cliqué) ou 'timeout' (5 min écoulées sans action).
# La file est suspendue pendant ShowDialog (message loop bloqué), ce qui est
# voulu : le timer principal reprend automatiquement à la fermeture.
# ---------------------------------------------------------------------------
function Show-BackupPause {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Vérification du backup'
    $dlg.Size = New-Object System.Drawing.Size(460, 180)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.ControlBox = $false
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = ConvertTo-KitColor $script:Palette.Card

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Vérifie que le backup est bien présent sur le disque externe, puis clique OK pour continuer.`r`n`r`nSans action, l'intervention reprend seule dans 5 minutes."
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(420, 80)
    $lbl.AutoSize = $false
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
    $lbl.ForeColor = ConvertTo-KitColor $script:Palette.Ink

    $ok = New-KitButton -Text 'OK, continuer' -Kind Primary
    $ok.Location = New-Object System.Drawing.Point(170, 105)
    $ok.Size = New-Object System.Drawing.Size(120, 30)
    $ok.Add_Click({ $dlg.Tag = 'ok'; $dlg.Close() })

    # Timer à usage unique : ferme automatiquement la modale après 5 minutes.
    $to = New-Object System.Windows.Forms.Timer
    $to.Interval = 300000
    $to.Add_Tick({ $to.Stop(); $dlg.Tag = 'timeout'; $dlg.Close() })

    $dlg.Controls.Add($lbl)
    $dlg.Controls.Add($ok)
    $to.Start()
    [void]$dlg.ShowDialog($form)
    $to.Stop()
    $to.Dispose()
    # Capturer Tag avant Dispose (Dispose peut effacer les propriétés du formulaire).
    $result = [string]$dlg.Tag
    $dlg.Dispose()
    return $result
}

# ---------------------------------------------------------------------------
# Profils d'intervention - fonctions GUI (Task 7)
# ---------------------------------------------------------------------------

function Update-ProfileComboBox {
    # Repeuple la combobox depuis config\profiles\*.json (BaseName uniquement) et
    # relit au passage la Description de chaque profil : l'aide au survol la lit
    # en mémoire, jamais sur le disque. La table est remplie AVANT la sélection
    # initiale, qui déclenche SelectedIndexChanged donc l'aide.
    $cmbProfile.Items.Clear()
    $script:ProfileDescriptions = @{}
    $profilesDir = Join-Path $script:Root 'config\profiles'
    if (Test-Path $profilesDir) {
        $files = @(Get-ChildItem -Path $profilesDir -Filter '*.json' -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            [void]$cmbProfile.Items.Add($f.BaseName)
            # Un JSON illisible ne doit pas amputer la liste : le profil reste
            # sélectionnable, il n'aura simplement pas de description.
            try { $script:ProfileDescriptions[$f.BaseName] = [string](Read-KitProfile -Path $f.FullName).Description }
            catch { }
        }
    }
    if ($cmbProfile.Items.Count -gt 0) {
        # Aperçu : la capture de documentation montre la politique Standard, pas
        # le premier profil de l'ordre alphabétique (gamer).
        $idx = if ($UiPreview) { $cmbProfile.Items.IndexOf('standard') } else { -1 }
        if ($idx -lt 0) { $idx = 0 }
        $cmbProfile.SelectedIndex = $idx
    }
}

function Set-GuiFromProfile {
    # Applique un objet Read-KitProfile aux contrôles de la GUI.
    # Le mapping module passe par l'Id (jamais une position en dur) : les lignes
    # de timeline sont indexées par Id dans $script:ModuleRows.
    param($Prof)
    foreach ($m in $script:Modules) {
        $val = $true
        if ($Prof.Modules.ContainsKey($m.Id)) { $val = [bool]$Prof.Modules[$m.Id] }
        $script:ModuleRows[$m.Id].CheckBox.Checked = $val
    }
    # La combobox GUI est en français ; les valeurs JSON sont en anglais.
    $idx = @('Conservative', 'Standard', 'Aggressive').IndexOf([string]$Prof.Debloat)
    if ($idx -lt 0) { $idx = 1 }
    $cmbDebloat.SelectedIndex = $idx
    $rbKeep.Checked         = [bool]$Prof.KeepAdmin
    $rbStd.Checked          = -not [bool]$Prof.KeepAdmin
    $cbRecycle.Checked      = [bool]$Prof.Recycle
    $cbWinOld.Checked       = [bool]$Prof.WinOld
    $cbCache.Checked        = [bool]$Prof.Cache
    $cbOneDrive.Checked     = [bool]$Prof.OneDrive
    $cbOem.Checked          = [bool]$Prof.Oem
    $cbNetReset.Checked     = [bool]$Prof.NetReset
    $cbBackupData.Checked   = [bool]$Prof.BackupData
    $cbScanDefender.Checked = [bool]$Prof.ScanDefender
    # Ces deux champs n'ont pas de contrôle GUI : ils vivent dans l'état du script,
    # jusqu'à la queue (module 12) et jusqu'au réenregistrement du profil.
    $script:ProfileStartupKeep = @($Prof.StartupKeep)
    $script:ProfileDescription = [string]$Prof.Description
}

function Get-GuiProfileObject {
    # Capture l'état courant des contrôles GUI dans un objet sérialisable.
    # Les modules sont capturés par Id (pas par position) pour cohérence avec Set-GuiFromProfile.
    $mods = @{}
    foreach ($m in $script:Modules) {
        $mods[$m.Id] = [bool]$script:ModuleRows[$m.Id].CheckBox.Checked
    }
    return [PSCustomObject]@{
        Debloat      = @('Conservative', 'Standard', 'Aggressive')[[Math]::Max(0, $cmbDebloat.SelectedIndex)]
        KeepAdmin    = [bool]$rbKeep.Checked
        Recycle      = [bool]$cbRecycle.Checked
        WinOld       = [bool]$cbWinOld.Checked
        Cache        = [bool]$cbCache.Checked
        OneDrive     = [bool]$cbOneDrive.Checked
        Oem          = [bool]$cbOem.Checked
        NetReset     = [bool]$cbNetReset.Checked
        BackupData   = [bool]$cbBackupData.Checked
        ScanDefender = [bool]$cbScanDefender.Checked
        Description  = $script:ProfileDescription
        StartupKeep  = $script:ProfileStartupKeep
        Modules      = $mods
    }
}

function Set-KitPrepareEnabled {
    # Verrouille/déverrouille tout ce qui paramètre l'intervention pendant un run.
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)
    foreach ($m in $script:Modules) { $script:ModuleRows[$m.Id].CheckBox.Enabled = $Enabled }
    foreach ($c in @($cmbDebloat, $rbStd, $rbKeep, $cbBackupData, $cbScanDefender, $cbDryRun,
                     $cbRecycle, $cbWinOld, $cbCache, $cbOneDrive, $cbOem, $cbNetReset,
                     $cmbProfile, $btnApplyProfile, $btnSaveProfile)) {
        $c.Enabled = $Enabled
    }
    # Aperçu : Enregistrer comme profil reste le seul contrôle écrivain, jamais réactivé.
    if ($Enabled -and $UiPreview) { $btnSaveProfile.Enabled = $false }
}

# Initialisation : peupler la combobox au démarrage
Update-ProfileComboBox
# Sélectionner la première entrée déclenche SelectedIndexChanged, donc l'aide de ce
# profil. Au démarrage aucun profil n'est APPLIQUÉ : le panneau décrirait un profil
# qui n'est pas en vigueur, exactement ce que le résumé de la barre d'action se
# garde d'annoncer. L'invite reprend donc sa place.
$txtHelp.Text = $script:HelpPrompt

# --- Handlers ---

# Résumé live de la barre d'action : chaque option de la zone droite le rafraîchit,
# comme les cases de la timeline. Ce câblage vit ici (et non près des cartes) parce
# qu'il appelle Set-KitActionPhase, définie plus haut mais après la construction :
# en PowerShell, une fonction doit être exécutée avant d'être appelable.
foreach ($c in @($cbRecycle, $cbWinOld, $cbCache, $cbOneDrive, $cbOem, $cbNetReset, $cbDryRun)) {
    $c.Add_CheckedChanged({ Update-KitActionSummary })
}
$cbDryRun.Add_CheckedChanged({
    if (-not $UiPreview) {
        if ($cbDryRun.Checked) { Set-KitBadgeMode -Band $script:Band -Mode Simulation }
        else { Set-KitBadgeMode -Band $script:Band -Mode Real }
    }
})
Set-KitActionPhase -Phase Prepare

$btnRun.Add_Click({
    if ($script:Running) { return }
    # Fiche d'un AUTRE PC restée sur la clé (intervention précédente) :
    # avertir avant de lancer, le mot de passe d'un tiers ne doit pas voyager.
    $ficheNames = @(Get-ChildItem (Join-Path $script:Root 'runtime') -Filter 'FICHE-PC-*.txt' -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name)
    $foreign = @(Get-ForeignFicheNames -FileNames $ficheNames -ComputerName $env:COMPUTERNAME)
    if ($foreign.Count -gt 0) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Fiche(s) d'une intervention précédente présente(s) sur la clé :`r`n`r`n$($foreign -join "`r`n")`r`n`r`nCes fichiers contiennent des mots de passe en clair. Continuer quand même ?`r`n(Les supprimer manuellement depuis runtime\ après avoir vérifié qu'ils sont notés ailleurs.)",
            "PC-Refresh-Kit - fiche étrangère détectée", 'YesNo', 'Warning')
        if ($r -eq 'No') { return }
    }
    Build-Queue
    # Calculer le préfixe de titre APRÈS Build-Queue (l'état cbDryRun est figé à ce moment)
    $script:RunLabel = if ($cbDryRun.Checked) { '[DRY-RUN] ' } else { '[RUN RÉEL] ' }
    if ($cbDryRun.Checked) { Set-KitBadgeMode -Band $script:Band -Mode Simulation }
    else { Set-KitBadgeMode -Band $script:Band -Mode Real }
    if ($script:Queue.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Aucun module sélectionné.", "PC-Refresh-Kit") | Out-Null
        return
    }
    # Timeline : tous les états posés d'un coup au lancement.
    $lblModulesEyebrow.Text = 'DÉROULÉ'
    $queuedIds = @($script:Queue | ForEach-Object { $_.Mod.Id })
    foreach ($m in $script:Modules) {
        if ($queuedIds -contains $m.Id) {
            Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Queued -Detail 'en attente' -Mdl2Available $script:Mdl2
        } else {
            Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Skipped -Detail 'ignoré' -Mdl2Available $script:Mdl2
        }
    }
    Set-KitPrepareEnabled -Enabled $false
    # Log unifié : un fichier par run, exporté en variable d'environnement
    $logsDir = Join-Path $script:Root 'runtime\logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Force -Path $logsDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $logsDir "gui-$env:COMPUTERNAME-$stamp.log"
    New-Item -ItemType File -Path $script:LogFile -Force | Out-Null
    $env:KIT_LOG_FILE = $script:LogFile
    $script:LogOffset = 0
    $script:QueueIndex = 0
    $script:Running = $true
    $script:StartTime = Get-Date
    $txtLog.Clear()
    Set-KitActionPhase -Phase Running
    $btnRun.Enabled = $false
    $btnCancel.Enabled = $true
    $btnCopy.Enabled = $false
    $btnReport.Enabled = $false
    $btnDelFiche.Enabled = $false
    # Retirer la page Clôture d'un run précédent éventuel (elle sera réajoutée en
    # fin de run), puis afficher le Journal : c'est lui qui vit pendant le run
    # (spec 4.3), et retirer l'onglet sélectionné laisserait sinon WinForms
    # choisir seul celui qui prend sa place.
    if ($script:Tabs.TabPages.Contains($script:TabClose)) {
        $script:Tabs.TabPages.Remove($script:TabClose)
    }
    $script:Tabs.SelectedTab = $script:TabLog
    $form.Text = "$($script:RunLabel)PC-Refresh-Kit - $($script:MachineLabel)"
    Start-NextModule
    $timer.Start()
})

$timer.Add_Tick({
    Add-LogLines
    if ($script:Running -and $script:StartTime) {
        try {
            $elapsed = Format-Elapsed ([int]((Get-Date) - $script:StartTime).TotalSeconds)
            $form.Text = "$($script:RunLabel)PC-Refresh-Kit - $($script:MachineLabel) - écoulé $elapsed"
            $cur = $script:Queue[$script:QueueIndex]
            $lbl = if ($cur) { "$($cur.Mod.Id) $($cur.Mod.Name)" } else { '' }
            $script:ActionSummary.Text = "Module $([Math]::Min($script:QueueIndex + 1, $script:Queue.Count))/$($script:Queue.Count) - $lbl - écoulé $elapsed"
            if ($cur -and $script:ModuleStartTime) {
                $curSec = [int]((Get-Date) - $script:ModuleStartTime).TotalSeconds
                Set-KitModuleRowState -Row $script:ModuleRows[$cur.Mod.Id] -State Running -Detail "en cours - $(Format-Elapsed $curSec)" -Mdl2Available $script:Mdl2
            }
        } catch { }
    }
    # --- Heartbeat : signe de vie pendant les silences de log ---
    # Injecté dans l'affichage UNIQUEMENT (AppendText), JAMAIS écrit dans $script:LogFile.
    # Objectif : informer l'opérateur qu'un module long est toujours actif sans polluer
    # le rapport ni fausser les compteurs de lignes.
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited -and
        $script:LastLogChange -and $script:LastHeartbeat -and $script:ModuleStartTime) {
        try {
            $hbItem = $script:Queue[$script:QueueIndex]

            # Signe de vie DISM (module 07) : Invoke-DismToFile crée un fichier temporaire
            # $env:TEMP\dism-<GUID>.log pendant l'exécution de DISM (supprimé dans le finally).
            # Si ce fichier a grossi depuis le dernier tick, c'est une activité réelle :
            # on réinitialise $script:LastLogChange pour éviter un faux heartbeat "figé"
            # pendant un StartComponentCleanup ou RestoreHealth légitime.
            if ($hbItem -and [string]$hbItem.Mod.Id -eq '07') {
                try {
                    $dismFiles = @(Get-ChildItem -Path $env:TEMP -Filter 'dism-*.log' -ErrorAction SilentlyContinue |
                                   Sort-Object LastWriteTime -Descending)
                    if ($dismFiles.Count -gt 0) {
                        $dismSize = [long]$dismFiles[0].Length
                        if ($script:DismLastSize -ge 0 -and $dismSize -gt $script:DismLastSize) {
                            # Croissance confirmée : DISM écrit activement dans son fichier de redirection
                            $script:LastLogChange = Get-Date
                        }
                        $script:DismLastSize = $dismSize
                    }
                } catch { }  # ne jamais laisser une erreur de stat fichier casser le tick
            }

            # Déclencher un heartbeat si silence > 60 s et dernier heartbeat émis il y a >= 30 s
            $silenceSec = ((Get-Date) - $script:LastLogChange).TotalSeconds
            $hbSinceSec = ((Get-Date) - $script:LastHeartbeat).TotalSeconds
            if ($silenceSec -gt 60 -and $hbSinceSec -ge 30) {
                $hbElapsed = [int]((Get-Date) - $script:ModuleStartTime).TotalSeconds
                $hbLabel   = if ($hbItem) { "$($hbItem.Mod.Id) $($hbItem.Mod.Name)" } else { '??' }
                $hbMsg     = Get-HeartbeatMessage -ModuleLabel $hbLabel -ElapsedSeconds $hbElapsed
                # Colorier en gris : indique clairement que ce n'est pas une ligne du log réel
                try {
                    $txtLog.SelectionStart  = $txtLog.TextLength
                    $txtLog.SelectionLength = 0
                    $txtLog.SelectionColor  = ConvertTo-KitColor $script:Palette.LogHeartbeat
                } catch { }
                $txtLog.AppendText("[heartbeat] $hbMsg`r`n")
                try { $txtLog.SelectionColor = $txtLog.ForeColor; $txtLog.ScrollToCaret() } catch { }
                # Mettre à jour UNIQUEMENT $script:LastHeartbeat, jamais $script:LastLogChange
                # (sinon le heartbeat se réinitialiserait lui-même et ne se redéclencherait plus)
                $script:LastHeartbeat = Get-Date
            }
        } catch { }  # un échec du heartbeat ne doit jamais casser le tick principal
    }

    if ($script:CurrentProc -and $script:CurrentProc.HasExited) {
        # Surfacer un module qui sort en erreur : sinon un échec avant son 1er
        # log serait invisible, la queue avancerait sans rien afficher.
        $exitCode = $script:CurrentProc.ExitCode
        $finished = $script:Queue[$script:QueueIndex]
        # Verdict du module : code de sortie + tranche de son log (Add-LogLines a
        # déjà poussé $script:LogOffset au bout : la tranche est [start, offset)).
        if ($finished) {
            try {
                $all = @(Get-Content $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
                $tranche = @()
                if ($all.Count -gt $script:ModuleLogStart) {
                    $tranche = $all[$script:ModuleLogStart..($all.Count - 1)]
                }
                $state = Get-ModuleTrancheState -ExitCode $exitCode -TrancheLines $tranche
                $durSec = [int]((Get-Date) - $script:ModuleStartTime).TotalSeconds
                $detail = switch ($state) {
                    'Ok'    { Format-Elapsed $durSec }
                    'Warn'  { "$(Format-Elapsed $durSec) - avertissement(s)" }
                    'Error' { "$(Format-Elapsed $durSec) - erreur" }
                }
                Set-KitModuleRowState -Row $script:ModuleRows[$finished.Mod.Id] -State $state -Detail $detail -Mdl2Available $script:Mdl2
            } catch { }   # un échec d'affichage d'état ne casse jamais le tick
        }
        if ($exitCode -ne 0 -and $finished) {
            $txtLog.AppendText("`r`n[!] Module $($finished.Mod.Id) $($finished.Mod.Name) : code de sortie $exitCode (voir le log).`r`n")
        }
        # Pause de vérification backup après le module 01 (si backup réellement effectué hors WhatIf)
        # Le timer est stoppé avant ShowDialog pour éviter la réentrance WM_TIMER : sans Stop(),
        # le message loop imbriqué de ShowDialog déclencherait à nouveau le tick toutes les 400 ms,
        # chaque tick verrait HasExited=$true et empiérait une nouvelle modale -> corruption de la file.
        if ($finished -and [string]$finished.Mod.Id -eq '01') {
            $timer.Stop()
            try {
                $pauseLines = @(Get-Content $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
                if (Test-BackupPauseNeeded -LogLines $pauseLines -IsWhatIf $cbDryRun.Checked) {
                    $pauseResult = Show-BackupPause
                    if ($pauseResult -eq 'timeout') {
                        # Écriture directe dans le log du run courant ($script:LogFile = $env:KIT_LOG_FILE),
                        # au format exact de Write-KitLog : "[$ts] [$Level] $Message".
                        # Write-KitLog écrit dans $script:KitLogFile (figé au démarrage), pas dans ce log.
                        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        Add-Content -Path $script:LogFile -Value "[$ts] [WARN] Vérification backup non confirmée (timeout 5 min), poursuite automatique." -Encoding UTF8
                    }
                }
            }
            finally { $timer.Start() }
        }
        $script:QueueIndex++
        Set-KitActionProgress -Current $script:QueueIndex -Total $script:Queue.Count
        $script:CurrentProc = $null
        Start-NextModule
    }
})

$btnCopy.Add_Click({
    if ($script:AdminPwd) { [System.Windows.Forms.Clipboard]::SetText($script:AdminPwd) }
})

$script:BtnPwdShow.Add_Click({
    # La passphrase reste masquée par défaut : l'opérateur la dévoile quand il
    # est seul devant l'écran, jamais devant le propriétaire du PC.
    if (-not $script:AdminPwd) { return }
    $script:PwdVisible = -not $script:PwdVisible
    if ($script:PwdVisible) {
        $script:LblPwdValue.Text = $script:AdminPwd
        $script:BtnPwdShow.Text = 'Masquer'
    } else {
        $script:LblPwdValue.Text = ('•' * 12)
        $script:BtnPwdShow.Text = 'Afficher'
    }
})

$btnCancel.Add_Click({
    $timer.Stop()
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        try { $script:CurrentProc.Kill() } catch { }
    }
    $script:Running = $false
    $btnCancel.Enabled = $false
    # En aperçu, Annuler est délibérément actif (la capture doit montrer
    # l'échappatoire) : réactiver LANCER sans garde rendrait un VRAI run
    # atteignable en deux clics depuis -PreviewPhase Running.
    $btnRun.Enabled = -not $UiPreview
    Set-KitActionPhase -Phase Prepare
    Set-KitPrepareEnabled -Enabled $true
    foreach ($m in $script:Modules) {
        Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Pending -Detail '' -Mdl2Available $script:Mdl2
    }
    $lblModulesEyebrow.Text = 'MODULES'
    # Même retour au repos que BtnNewRun : l'annulation ramène en préparation,
    # le titre ne doit pas rester figé sur le dernier « écoulé » du run avorté.
    $script:RunLabel = ''
    $form.Text = $script:TitleRest
    # Write-KitLog écrit dans $script:KitLogFile (log de démarrage GUI), pas dans le log de run.
    # On écrit directement dans $script:LogFile pour que la WARN figure dans le rapport.
    if ($script:LogFile -and (Test-Path $script:LogFile)) {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $script:LogFile -Value "[$ts] [WARN] Annulation demandée par l'opérateur." -Encoding UTF8
    }
    [System.Windows.Forms.MessageBox]::Show(
        "Exécution annulée. Le système est resté dans l'état atteint.",
        "PC-Refresh-Kit", 'OK', 'Warning') | Out-Null
})

$btnReport.Add_Click({
    if ($script:ReportFile -and (Test-Path $script:ReportFile)) {
        if ($script:ReportFile -like '*.html') {
            # Rapport HTML : ouverture dans le navigateur par défaut.
            Start-Process $script:ReportFile
        }
        else {
            $npp = 'C:\Program Files\Notepad++\notepad++.exe'
            if (Test-Path $npp) { Start-Process $npp -ArgumentList "`"$($script:ReportFile)`"" }
            else { Start-Process notepad.exe -ArgumentList "`"$($script:ReportFile)`"" }
        }
    }
})

$btnDelFiche.Add_Click({
    $fichePath = Join-Path $script:Root "runtime\FICHE-PC-$env:COMPUTERNAME.txt"
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Supprimer définitivement la fiche PC de la clé ?`r`n`r`n$fichePath`r`n`r`nAssurez-vous que le mot de passe a bien été noté ailleurs avant de confirmer.",
        "PC-Refresh-Kit - supprimer la fiche", 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    if (Test-Path $fichePath) {
        try {
            Remove-Item -Path $fichePath -Force -ErrorAction Stop
            $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $logLine = "[$ts] [OK] Fiche PC supprimée de la clé."
            # Écrire dans le log de run courant (même format que Write-KitLog)
            if ($script:LogFile -and (Test-Path $script:LogFile)) {
                Add-Content -Path $script:LogFile -Value $logLine -Encoding UTF8
            }
            # Afficher dans la zone de log (vert = OK)
            try {
                $txtLog.SelectionStart  = $txtLog.TextLength
                $txtLog.SelectionLength = 0
                $txtLog.SelectionColor  = ConvertTo-KitColor $script:Palette.LogOK
            } catch { }
            $txtLog.AppendText("$logLine`r`n")
            try { $txtLog.SelectionColor = $txtLog.ForeColor; $txtLog.ScrollToCaret() } catch { }
            # Désactiver le bouton et effacer l'affichage du mot de passe
            $btnDelFiche.Enabled = $false
            $script:LblPwdValue.Text = '(fiche supprimée de la clé)'
            $script:PwdVisible = $false
            $script:BtnPwdShow.Text = 'Afficher'
            $script:BtnPwdShow.Enabled = $false
            # Effacer le mot de passe en mémoire et désactiver la copie : une fois la fiche
            # détruite, l'opérateur ne doit plus pouvoir exfiltrer le mot de passe via le bouton.
            $script:AdminPwd = $null
            $btnCopy.Enabled = $false
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Erreur lors de la suppression : $_",
                "PC-Refresh-Kit", 'OK', 'Error') | Out-Null
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "La fiche PC est introuvable (déjà supprimée ?).",
            "PC-Refresh-Kit", 'OK', 'Information') | Out-Null
        $btnDelFiche.Enabled = $false
    }
})

$btnApplyProfile.Add_Click({
    # Interdit pendant un run : les contrôles piloteraient la queue en cours.
    if ($script:Running) {
        [System.Windows.Forms.MessageBox]::Show(
            "Impossible d'appliquer un profil pendant l'exécution.",
            "PC-Refresh-Kit", 'OK', 'Warning') | Out-Null
        return
    }
    $sel = [string]$cmbProfile.SelectedItem
    if ($sel -eq '') {
        [System.Windows.Forms.MessageBox]::Show(
            "Aucun profil sélectionné.", "PC-Refresh-Kit", 'OK', 'Information') | Out-Null
        return
    }
    $profPath = Join-Path $script:Root "config\profiles\$sel.json"
    if (-not (Test-Path $profPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Fichier de profil introuvable : $profPath", "PC-Refresh-Kit", 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $prof = Read-KitProfile -Path $profPath
        Set-GuiFromProfile $prof
        $script:AppliedProfileName = $sel
        Update-KitActionSummary
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Erreur lors de l'application du profil : $_",
            "PC-Refresh-Kit", 'OK', 'Error') | Out-Null
    }
})

$btnSaveProfile.Add_Click({
    # Demander le nom via le dialogue maison (charte Trimko, plus aucune dépendance tierce).
    $nom = Show-KitInputDialog -Owner $form -Title 'Enregistrer comme profil' -Prompt 'Nom du profil à enregistrer :'
    if ($null -eq $nom) { return }
    $nom = $nom.Trim()
    if ($nom -eq '') { return }
    # Sanitiser : retirer les caractères invalides pour un nom de fichier Windows.
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($c in $invalidChars) { $nom = $nom.Replace([string]$c, [string]::Empty) }
    $nom = $nom.Trim()
    if ($nom -eq '') {
        [System.Windows.Forms.MessageBox]::Show(
            "Le nom de profil est invalide (caractères non autorisés).",
            "PC-Refresh-Kit", 'OK', 'Warning') | Out-Null
        return
    }
    $profilesDir = Join-Path $script:Root 'config\profiles'
    if (-not (Test-Path $profilesDir)) {
        New-Item -ItemType Directory -Force -Path $profilesDir | Out-Null
    }
    $destPath = Join-Path $profilesDir "$nom.json"
    $tmpPath  = "$destPath.tmp"
    try {
        $json = Get-GuiProfileObject | ConvertTo-Json -Depth 4
        # Écriture atomique : fichier temporaire puis renommage (Move-Item -Force).
        # UTF-8 sans BOM (standard JSON).
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
        Move-Item -Path $tmpPath -Destination $destPath -Force
        # Rafraîchir la combobox et sélectionner le nouveau profil.
        Update-ProfileComboBox
        $idx = $cmbProfile.Items.IndexOf($nom)
        if ($idx -ge 0) { $cmbProfile.SelectedIndex = $idx }
        # L'état enregistré sous ce nom EST l'état courant de la GUI : le résumé doit
        # l'annoncer, au lieu de rester sur le profil appliqué précédemment.
        $script:AppliedProfileName = $nom
        Update-KitActionSummary
        [System.Windows.Forms.MessageBox]::Show(
            "Profil `"$nom`" enregistré.", "PC-Refresh-Kit", 'OK', 'Information') | Out-Null
    } catch {
        if (Test-Path $tmpPath) { Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.MessageBox]::Show(
            "Erreur lors de l'enregistrement du profil : $_",
            "PC-Refresh-Kit", 'OK', 'Error') | Out-Null
    }
})

$script:BtnNewRun.Add_Click({
    # Retour en phase préparation : les états du run précédent, affichés sur la
    # timeline pendant toute la phase Done, cèdent ici la place aux cases, qui
    # redeviennent éditables (choix de la spec 4.4 : c'est ce bouton, et lui
    # seul, qui déverrouille la préparation).
    if ($script:Tabs.TabPages.Contains($script:TabClose)) {
        $script:Tabs.TabPages.Remove($script:TabClose)
    }
    $script:Tabs.SelectedTab = $script:TabHelp
    # L'onglet revient au premier plan : il doit repartir de l'invite, pas de la
    # dernière rubrique survolée pendant le run précédent.
    $txtHelp.Text = $script:HelpPrompt
    foreach ($m in $script:Modules) {
        Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Pending -Detail '' -Mdl2Available $script:Mdl2
    }
    $lblModulesEyebrow.Text = 'MODULES'
    # Le titre repart de sa forme de repos : sans cela la fenêtre reste
    # indéfiniment sur le « - terminé en 43:07 » du run précédent.
    $script:RunLabel = ''
    $form.Text = $script:TitleRest
    Set-KitPrepareEnabled -Enabled $true
    Set-KitActionPhase -Phase Prepare
})

$form.Add_FormClosing({
    if ($script:Running) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Un traitement est en cours. Quitter quand même ?", "PC-Refresh-Kit", 'YesNo', 'Warning')
        if ($r -eq 'No') { $_.Cancel = $true; return }
        # L'opérateur confirme la fermeture : stopper le timer et tuer le module
        # en cours, sinon le process enfant (ex : DISM) continue en orphelin.
        $timer.Stop()
        if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
            try { $script:CurrentProc.Kill() } catch { }
        }
        $script:Running = $false
    }
})

# Mode aperçu : rien ne doit pouvoir être lancé. Le titre porte déjà [APERÇU]
# depuis le démarrage ($script:TitleRest), inutile de le réécrire ici.
# Placé juste avant ShowDialog : $btnRun y existe quel que soit le layout en cours.
# Le dry-run est coché d'office : un aperçu ne doit JAMAIS afficher un résumé
# « INTERVENTION RÉELLE » (ni dans les captures du README, ni sur un poste réel).
if ($UiPreview) {
    $btnRun.Enabled = $false
    $cbDryRun.Checked = $true      # avant les données de phase : le résumé dit SIMULATION
}

# --- Aperçu des phases (-UiPreview -PreviewPhase Running|Done) : données
# factices pour les captures du README et la vérification visuelle. Aucune
# écriture disque, aucun process lancé. Le badge reste APERÇU en toutes phases :
# c'est le mode réel du processus, la phase simulée ne le change pas. ---
function Get-KitPreviewData {
    [CmdletBinding()]
    param()
    return @{
        Running = @(
            @{ Id='00'; State='Ok';      Detail='00:45' }
            @{ Id='01'; State='Ok';      Detail='08:05' }
            @{ Id='02'; State='Running'; Detail='en cours - 03:12' }
        )
        DoneWarn = '05'
        DoneSkip = '15'
        # Le module en avertissement garde sa durée : le run réel écrit
        # "<durée> - avertissement(s)" (Tick, branche 'Warn'), l'aperçu reproduit
        # ce format exact plutôt qu'une forme à lui.
        DoneDurations = @{
            '00'='00:45'; '01'='08:05'; '02'='11:30'; '03'='06:12'; '04'='01:08'
            '05'='21:35 - avertissement(s)'; '06'='04:55'; '07'='07:40'; '08'='00:38'
            '09'='00:22'; '11'='00:51'; '12'='00:14'; '13'='00:29'; '10'='00:18'
        }
    }
}

if ($UiPreview -and $PreviewPhase -ne 'Prepare') {
    $pv = Get-KitPreviewData
    $lblModulesEyebrow.Text = 'DÉROULÉ'
    Set-KitPrepareEnabled -Enabled $false
    if ($PreviewPhase -eq 'Running') {
        foreach ($m in $script:Modules) {
            $preset = @($pv.Running | Where-Object { $_.Id -eq $m.Id })
            if ($preset.Count -gt 0) {
                Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State $preset[0].State -Detail $preset[0].Detail -Mdl2Available $script:Mdl2
            } elseif ($m.Id -eq '15') {
                Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Skipped -Detail 'ignoré' -Mdl2Available $script:Mdl2
            } else {
                Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Queued -Detail 'en attente' -Mdl2Available $script:Mdl2
            }
        }
        Set-KitActionPhase -Phase Running
        # Annuler est actif pendant un vrai run (Start-KitRun) : l'aperçu doit le
        # montrer tel quel, sinon la capture du README annonce une échappatoire
        # grisée. Le handler ne fait rien ici, aucun run n'est en cours.
        $btnCancel.Enabled = $true
        $script:ActionSummary.Text = 'Module 3/14 - 02 Antivirus - écoulé 12:40'
        Set-KitActionProgress -Current 2 -Total 14
        $script:Tabs.SelectedTab = $script:TabLog
        foreach ($demo in @(
            '[14:11:58] [INFO] Module 02 Antivirus : démarrage',
            '[14:12:03] [OK] Avast désinstallé proprement',
            '[14:12:19] [OK] Windows Defender activé (protection temps réel)',
            '[14:13:05] [WARN] Exclusion Defender héritée détectée : C:\Games (conservée)',
            '[14:13:22] [INFO] Scan complet Defender démarré...')) {
            try {
                $txtLog.SelectionStart = $txtLog.TextLength ; $txtLog.SelectionLength = 0
                $txtLog.SelectionColor = ConvertTo-KitColor (Get-KitLogLevelColorHex -Line $demo)
            } catch { }
            $txtLog.AppendText("$demo`r`n")
        }
    }
    if ($PreviewPhase -eq 'Done') {
        foreach ($m in $script:Modules) {
            $detail = [string]$pv.DoneDurations[$m.Id]
            if ($m.Id -eq $pv.DoneSkip)      { Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Skipped -Detail 'ignoré' -Mdl2Available $script:Mdl2 }
            elseif ($m.Id -eq $pv.DoneWarn)  { Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Warn -Detail $detail -Mdl2Available $script:Mdl2 }
            else                             { Set-KitModuleRowState -Row $script:ModuleRows[$m.Id] -State Ok -Detail $detail -Mdl2Available $script:Mdl2 }
        }
        $script:AdminPwd = 'tortue-camion-soleil-42'   # passphrase FACTICE d'aperçu
        $script:LblPwdValue.Text = ('•' * 12)
        $script:BtnPwdShow.Enabled = $true
        $btnCopy.Enabled = $true
        # Ouvrir le rapport : actif pour que le CTA primaire de la barre s'affiche
        # comme tel. Sans rapport sur le disque, le handler ne fait rien (il teste
        # le fichier). Supprimer la fiche PC reste DÉSACTIVÉ : c'est la seule
        # action destructrice de la page, un aperçu ne doit jamais l'ouvrir.
        $btnReport.Enabled = $true
        Show-KitClosePhase -RebootRequired $true
        # Bilan calé sur la timeline juste au-dessus : 15 modules, un seul en
        # avertissement (05), un seul ignoré (15), donc 13 OK. La durée totale
        # dépasse la somme des durées affichées (1:04:42) du temps de lancement
        # des processus.
        Set-KitActionPhase -Phase Done -Data @{
            Bilan = Get-RunDoneText -CountOK 13 -CountWarn 1 -CountError 0 -Elapsed '1:05:12'
        }
    }
}

# Phase Prepare demandée EXPLICITEMENT (capture de la doc) : le panneau montre
# une vraie rubrique du catalogue au lieu de l'invite, l'aide intégrée étant ce
# que la capture doit donner à voir. -UiPreview seul et le démarrage normal
# gardent l'invite : rien n'a encore été survolé.
if ($UiPreview -and $PreviewPhase -eq 'Prepare' -and $PSBoundParameters.ContainsKey('PreviewPhase')) {
    Show-KitHelp -Key 'module.02'
}

[void]$form.ShowDialog()
