# Run-GUI.ps1 - Cockpit graphique du PC-Refresh-Kit (WinForms, zéro dépendance)
# Lancé par Lancer.bat (auto-élévation). Orchestre les mêmes modules que Run.ps1.
# Le mode CLI (Run.ps1) reste le fallback de référence.

param([switch]$WhatIf)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

. "$PSScriptRoot\lib\Common.ps1"

if (-not (Test-IsAdmin)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Lancer via Lancer.bat (droits administrateur requis).",
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
$script:ReportFile      = $null
$script:StartTime       = $null
$script:LastLogChange   = $null    # horodatage du dernier ajout de ligne réel dans le log
$script:LastHeartbeat   = $null    # horodatage du dernier heartbeat injecté
$script:ModuleStartTime = $null    # horodatage du lancement du module courant
$script:DismLastSize    = [long](-1) # taille du fichier DISM au dernier tick (module 07)
$script:RunLabel        = ''           # préfixe de titre : '[DRY-RUN] ' ou '[RUN RÉEL] ' pendant un run

# --- Construction de la fenetre ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "PC-Refresh-Kit - $env:COMPUTERNAME"
$form.Size = New-Object System.Drawing.Size(900, 840)
$form.StartPosition = 'CenterScreen'

# Colonne gauche : modules + options
$panelLeft = New-Object System.Windows.Forms.Panel
$panelLeft.Location = New-Object System.Drawing.Point(10, 10)
$panelLeft.Size = New-Object System.Drawing.Size(280, 675)
$form.Controls.Add($panelLeft)

$lblModules = New-Object System.Windows.Forms.Label
$lblModules.Text = "Modules :"
$lblModules.Location = New-Object System.Drawing.Point(0, 0)
$lblModules.AutoSize = $true
$panelLeft.Controls.Add($lblModules)

$clbModules = New-Object System.Windows.Forms.CheckedListBox
$clbModules.Location = New-Object System.Drawing.Point(0, 20)
$clbModules.Size = New-Object System.Drawing.Size(280, 190)
foreach ($m in $script:Modules) {
    [void]$clbModules.Items.Add(("{0} {1}" -f $m.Id, $m.Name), $true)  # tous cochés par défaut
}
$panelLeft.Controls.Add($clbModules)

# Politique debloat (module 03) : conservateur / standard / agressif
$lblDebloat = New-Object System.Windows.Forms.Label
$lblDebloat.Text = "Politique debloat :"
$lblDebloat.Location = New-Object System.Drawing.Point(0, 218)
$lblDebloat.AutoSize = $true
$panelLeft.Controls.Add($lblDebloat)

$cmbDebloat = New-Object System.Windows.Forms.ComboBox
$cmbDebloat.DropDownStyle = 'DropDownList'
[void]$cmbDebloat.Items.AddRange(@('Conservateur', 'Standard', 'Agressif'))
$cmbDebloat.SelectedIndex = 1   # Standard par défaut (décision grill)
$cmbDebloat.Location = New-Object System.Drawing.Point(115, 214)
$cmbDebloat.Size = New-Object System.Drawing.Size(165, 24)
$panelLeft.Controls.Add($cmbDebloat)

# Profil compte
$gbProfile = New-Object System.Windows.Forms.GroupBox
$gbProfile.Text = "Compte utilisateur"
$gbProfile.Location = New-Object System.Drawing.Point(0, 245)
$gbProfile.Size = New-Object System.Drawing.Size(280, 70)
$rbStd = New-Object System.Windows.Forms.RadioButton
$rbStd.Text = "Standard + passphrase"
$rbStd.Location = New-Object System.Drawing.Point(10, 18)
$rbStd.AutoSize = $true
$rbStd.Checked = $true
$rbKeep = New-Object System.Windows.Forms.RadioButton
$rbKeep.Text = "Garder admin (UAC seul)"
$rbKeep.Location = New-Object System.Drawing.Point(10, 42)
$rbKeep.AutoSize = $true
$gbProfile.Controls.AddRange(@($rbStd, $rbKeep))
$panelLeft.Controls.Add($gbProfile)

# Options sensibles (toutes décochées par défaut)
$gbSensitive = New-Object System.Windows.Forms.GroupBox
$gbSensitive.Text = "Actions sensibles (décochées = non faites)"
$gbSensitive.Location = New-Object System.Drawing.Point(0, 320)
$gbSensitive.Size = New-Object System.Drawing.Size(280, 162)
$cbRecycle  = New-Object System.Windows.Forms.CheckBox; $cbRecycle.Text  = "Vider la corbeille";         $cbRecycle.Location  = New-Object System.Drawing.Point(10,18);  $cbRecycle.AutoSize = $true
$cbWinOld   = New-Object System.Windows.Forms.CheckBox; $cbWinOld.Text   = "Supprimer Windows.old";      $cbWinOld.Location   = New-Object System.Drawing.Point(10,40);  $cbWinOld.AutoSize = $true
$cbCache    = New-Object System.Windows.Forms.CheckBox; $cbCache.Text    = "Vider caches navigateurs";   $cbCache.Location    = New-Object System.Drawing.Point(10,62);  $cbCache.AutoSize = $true
$cbOneDrive = New-Object System.Windows.Forms.CheckBox; $cbOneDrive.Text = "Désinstaller OneDrive";      $cbOneDrive.Location = New-Object System.Drawing.Point(10,84);  $cbOneDrive.AutoSize = $true
$cbOem      = New-Object System.Windows.Forms.CheckBox; $cbOem.Text      = "Debloat constructeur (OEM)"; $cbOem.Location      = New-Object System.Drawing.Point(10,106); $cbOem.AutoSize = $true
$cbBackupData = New-Object System.Windows.Forms.CheckBox; $cbBackupData.Text = "Sauvegarder les données utilisateur"; $cbBackupData.Location = New-Object System.Drawing.Point(10, 20); $cbBackupData.AutoSize = $true; $cbBackupData.Checked = $true
$cbNetReset   = New-Object System.Windows.Forms.CheckBox
$cbNetReset.Text     = 'Réinitialiser le réseau (non réversible)'
$cbNetReset.AutoSize = $true
$cbNetReset.Location = New-Object System.Drawing.Point(10, 128)
# $cbNetReset.Checked reste $false (décoché par défaut)
$gbSensitive.Controls.AddRange(@($cbRecycle, $cbWinOld, $cbCache, $cbOneDrive, $cbOem, $cbNetReset))
$panelLeft.Controls.Add($gbSensitive)

# Données utilisateur (action positive, cochée par défaut ; séparée des actions sensibles car non destructrice)
$gbUserData = New-Object System.Windows.Forms.GroupBox
$gbUserData.Text = "Données utilisateur"
$gbUserData.Location = New-Object System.Drawing.Point(0, 486)
$gbUserData.Size = New-Object System.Drawing.Size(280, 62)
$gbUserData.Controls.Add($cbBackupData)
$panelLeft.Controls.Add($gbUserData)

# Option Defender (cochée par défaut - option positive liée au module 02)
$cbScanDefender = New-Object System.Windows.Forms.CheckBox
$cbScanDefender.Text     = 'Scanner avec Defender après bascule'
$cbScanDefender.AutoSize = $true
$cbScanDefender.Checked  = $true
$cbScanDefender.Location = New-Object System.Drawing.Point(0, 552)
$panelLeft.Controls.Add($cbScanDefender)

# Dry-run
$cbDryRun = New-Object System.Windows.Forms.CheckBox
$cbDryRun.Text = "Mode dry-run (-WhatIf)"
$cbDryRun.Location = New-Object System.Drawing.Point(0, 568)
$cbDryRun.AutoSize = $true
if ($WhatIf) { $cbDryRun.Checked = $true }
$panelLeft.Controls.Add($cbDryRun)

# Bouton Lancer
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "LANCER"
$btnRun.Location = New-Object System.Drawing.Point(0, 595)
$btnRun.Size = New-Object System.Drawing.Size(280, 40)
$panelLeft.Controls.Add($btnRun)

# Bouton Annuler (désactivé par défaut, activé en cours de run)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Annuler"
$btnCancel.Location = New-Object System.Drawing.Point(0, 640)
$btnCancel.Size = New-Object System.Drawing.Size(280, 30)
$btnCancel.Enabled = $false
$panelLeft.Controls.Add($btnCancel)

# Colonne droite : log + progression + mot de passe
# RichTextBox (au lieu de TextBox) : permet la coloration par niveau (OK vert, WARN orange, ERROR rouge).
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(300, 20)
$txtLog.Size = New-Object System.Drawing.Size(580, 400)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($txtLog)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(300, 425)
$progress.Size = New-Object System.Drawing.Size(580, 20)
$form.Controls.Add($progress)

$lblPwd = New-Object System.Windows.Forms.Label
$lblPwd.Text = "Mot de passe Admin-Local : (généré après le module Accounts)"
$lblPwd.Location = New-Object System.Drawing.Point(300, 455)
$lblPwd.Size = New-Object System.Drawing.Size(580, 20)
$form.Controls.Add($lblPwd)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Copier le mot de passe"
$btnCopy.Location = New-Object System.Drawing.Point(300, 480)
$btnCopy.Size = New-Object System.Drawing.Size(180, 30)
$btnCopy.Enabled = $false
$form.Controls.Add($btnCopy)

$btnReport = New-Object System.Windows.Forms.Button
$btnReport.Text = "Ouvrir le rapport"
$btnReport.Location = New-Object System.Drawing.Point(490, 480)
$btnReport.Size = New-Object System.Drawing.Size(180, 30)
$btnReport.Enabled = $false
$form.Controls.Add($btnReport)

# --- Checklist de fin d'intervention (créée maintenant, invisible ; peuplée et affichée en fin de run) ---
$script:GbChecklist = New-Object System.Windows.Forms.GroupBox
$script:GbChecklist.Text = "Avant de rendre le PC"
$script:GbChecklist.Location = New-Object System.Drawing.Point(300, 520)
$script:GbChecklist.Size = New-Object System.Drawing.Size(580, 220)
$script:GbChecklist.Visible = $false
$form.Controls.Add($script:GbChecklist)

# Bouton de suppression de la fiche PC (désactivé jusqu'à la fin du run, actif seulement si la fiche existe)
# Positionné en dessous du groupe checklist (Y=520+220=740, marge de 8px => Y=748)
$btnDelFiche = New-Object System.Windows.Forms.Button
$btnDelFiche.Text = "Supprimer la fiche PC de la clé"
$btnDelFiche.Location = New-Object System.Drawing.Point(300, 748)
$btnDelFiche.Size = New-Object System.Drawing.Size(580, 34)
$btnDelFiche.Enabled = $false
$form.Controls.Add($btnDelFiche)

# --- Infos-bulles (tooltips pour aider l'utilisateur novice) ---
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.InitialDelay = 500
$toolTip.AutoPopDelay = 5000

# Descriptions des modules
$moduleDescriptions = @{
    '00' = "Analyse le système : espace disque, RAM utilisée, services actifs"
    '01' = "Crée une sauvegarde complète du système sur clé USB (important !)"
    '02' = "Configure l'antivirus Windows Defender"
    '03' = "Supprime les apps inutiles du fabricant et les bloatwares"
    '04' = "Désactive la collecte de données (télémétrie, pub ciblée)"
    '05' = "Applique les mises à jour Windows en attente"
    '06' = "Installe les logiciels courants (VLC, 7-Zip, etc.)"
    '07' = "Nettoie les fichiers temporaires et libère de l'espace"
    '08' = "Configure les comptes utilisateur et la sécurité"
    '09' = "Améliore le confort d'utilisation (écran verrouillage, police, etc.)"
    '10' = "Génère un rapport final avec les actions effectuées"
    '11' = "Nettoyage léger : supprime les raccourcis morts du menu Démarrer et les dossiers résiduels d'apps désinstallées (liste blanche). Ne touche pas au registre."
    '12' = "Gestionnaire de démarrage : désactive (réversible) les programmes au démarrage indésirables (liste noire). Réactivable via le Gestionnaire des tâches."
    '13' = "Nettoyage navigateurs : retire les détournements de recherche/page d'accueil et extensions forcées (Chrome/Edge), avec sauvegarde. Conservateur."
    '15' = "Réinitialisation réseau : remet à zéro les paramètres TCP/IP, Winsock et le cache DNS. Non réversible sans intervention manuelle."
}

$toolTip.SetToolTip($clbModules, "Cochez les modules à exécuter. Tous sont cochés par défaut.`nCeux marqués [*] modifient le système.")

# Profil compte
$toolTip.SetToolTip($rbStd, "Recommandé : crée un compte Standard + passphrase sécurisée, désactive l'admin (plus sûr)")
$toolTip.SetToolTip($rbKeep, "Le compte reste administrateur, protégé par l'UAC durci (prompt Oui/Non à chaque élévation, sans mot de passe). Aucun compte ni mot de passe à gérer.")

# Actions sensibles
$toolTip.SetToolTip($cbRecycle, "Vide la corbeille. Libère de l'espace disque. Fichiers supprimés à jamais (récupération difficile).")
$toolTip.SetToolTip($cbWinOld, "Supprime le dossier ancien Windows après mise à jour. Gain : 5-25 GB. Impossible à récupérer après !")
$toolTip.SetToolTip($cbCache, "Vide les caches navigateur (Chrome, Edge). Supprime cookies, historique, données de login. À redémarrer le navigateur.")
$toolTip.SetToolTip($cbOneDrive, "Coché : désinstalle OneDrive, bloque son retour (résiste aux mises à jour) et coupe ses rappels/notifications. Décoché : le kit ne touche PAS à OneDrive. Fichiers locaux conservés.")
$toolTip.SetToolTip($cbOem, "Supprime les apps inutiles du fabricant (jeux, suites Microsoft pré-installées, etc.)")
$toolTip.SetToolTip($cbNetReset, "Réinitialise TCP/IP, Winsock et le cache DNS (netsh int ip reset, netsh winsock reset). Non réversible sans intervention manuelle. Utile uniquement si la connexion réseau est défectueuse.")
$toolTip.SetToolTip($cbScanDefender, "Lance un scan complet Windows Defender après la configuration antivirus (module 02). Coché par défaut - décocher pour gagner du temps si le PC est sain.")
$toolTip.SetToolTip($cmbDebloat, "Apps conditionnelles (Spotify, Skype...) : Conservateur = jamais supprimées. Standard = supprimées si non utilisées depuis 90 jours. Agressif = supprimées même si utilisées (les jeux Game Pass restent toujours protégés).")

# Mode dry-run
$toolTip.SetToolTip($cbDryRun, "Simule TOUT sans rien modifier. Idéal pour tester avant de vraiment exécuter. Aucun fichier modifié.")

# Boutons
$toolTip.SetToolTip($btnRun, "Démarre l'exécution des modules sélectionnés. Durée : 10-30 min selon le choix.")
$toolTip.SetToolTip($btnCancel, "Arrête proprement le module en cours et stoppe la file. Le système reste dans l'état atteint (le kit est non-destructif).")
$toolTip.SetToolTip($btnCopy, "Copie la passphrase admin dans le presse-papiers (devient actif après le module Comptes).")
$toolTip.SetToolTip($btnReport, "Ouvre le rapport final : HTML dans le navigateur (livrable présentable) ou TXT dans Notepad++. Récapitulatif des actions et résultats.")
$toolTip.SetToolTip($btnDelFiche, "Supprime le fichier FICHE-PC qui contient le mot de passe en clair. À faire avant de rendre la clé USB à quelqu'un d'autre. Vérifiez que le mot de passe a bien été noté ailleurs !")

# --- Profils d'intervention (colonne gauche, sous $panelLeft, directement sur le formulaire) ---
# Positionnement : X=10-290, Y=692-764 - la colonne gauche est libre en-dessous de $panelLeft (fin à Y=685).
# La colonne droite ($script:GbChecklist X=300, $btnDelFiche X=300) ne chevauche pas.
$lblProfileTitle = New-Object System.Windows.Forms.Label
$lblProfileTitle.Text = "Profil d'intervention :"
$lblProfileTitle.Location = New-Object System.Drawing.Point(10, 692)
$lblProfileTitle.AutoSize = $true
$form.Controls.Add($lblProfileTitle)

$cmbProfile = New-Object System.Windows.Forms.ComboBox
$cmbProfile.DropDownStyle = 'DropDownList'
$cmbProfile.Location = New-Object System.Drawing.Point(10, 710)
$cmbProfile.Size = New-Object System.Drawing.Size(280, 24)
$form.Controls.Add($cmbProfile)

$btnApplyProfile = New-Object System.Windows.Forms.Button
$btnApplyProfile.Text = "Appliquer"
$btnApplyProfile.Location = New-Object System.Drawing.Point(10, 738)
$btnApplyProfile.Size = New-Object System.Drawing.Size(132, 26)
$form.Controls.Add($btnApplyProfile)

$btnSaveProfile = New-Object System.Windows.Forms.Button
$btnSaveProfile.Text = "Enregistrer comme profil"
$btnSaveProfile.Location = New-Object System.Drawing.Point(148, 738)
$btnSaveProfile.Size = New-Object System.Drawing.Size(142, 26)
$form.Controls.Add($btnSaveProfile)

$toolTip.SetToolTip($cmbProfile, "Sélectionnez un profil enregistré (config\profiles\*.json) puis cliquez sur Appliquer.")
$toolTip.SetToolTip($btnApplyProfile, "Charge les paramètres du profil sélectionné dans les contrôles de la GUI. N'exécute rien.")
$toolTip.SetToolTip($btnSaveProfile, "Enregistre l'état actuel des contrôles comme nouveau profil JSON réutilisable.")

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
                $txtLog.SelectionColor  = [System.Drawing.Color]::FromName((Get-LogLevelColor -Line $line))
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
        $btnRun.Enabled = $true
        $btnCancel.Enabled = $false
        $progress.Value = $progress.Maximum
        $txtLog.AppendText("`r`n=== Terminé ===`r`n")
        # Bilan final : compteurs du run + durée, lus depuis le log unifié.
        try {
            $sumLines   = @(Get-Content $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            $sum        = Get-ReportSummary -Lines $sumLines
            $elapsedStr = if ($script:StartTime) { Format-Elapsed ([int]((Get-Date) - $script:StartTime).TotalSeconds) } else { '-' }
            $txtLog.AppendText("Bilan : OK $($sum.CountOK) / Avertissements $($sum.CountWarn) / Erreurs $($sum.CountError) - durée $elapsedStr`r`n")
            $form.Text = "$($script:RunLabel)PC-Refresh-Kit - $env:COMPUTERNAME - terminé en $elapsedStr"
        } catch { }
        # Mot de passe depuis la fiche
        $fiche = Join-Path $script:Root "runtime\FICHE-PC-$env:COMPUTERNAME.txt"
        if (Test-Path $fiche) {
            $line = (Get-Content $fiche -Encoding UTF8 | Where-Object { $_ -match 'Mot de passe' } | Select-Object -First 1)
            if ($line -match ':\s*(.+)$') {
                $script:AdminPwd = $Matches[1].Trim()
                $lblPwd.Text = "Mot de passe Admin-Local : $($script:AdminPwd)"
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
        # Checklist de fin d'intervention : peupler le GroupBox et l'afficher
        try {
            $rebootReq = Test-Path (Join-Path $script:Root 'runtime\reboot-required.flag')
            $script:GbChecklist.Controls.Clear()
            $yItem = 22
            foreach ($item in @(Get-EndChecklistItems -RebootRequired $rebootReq)) {
                $cb = New-Object System.Windows.Forms.CheckBox
                $cb.Text     = [string]$item
                $cb.AutoSize = $true
                $cb.Checked  = $false
                $cb.Location = New-Object System.Drawing.Point(8, $yItem)
                # Mettre en rouge l'item de redémarrage requis (déjà préfixé "REBOOT REQUIS" par le helper)
                if ($rebootReq -and ([string]$item -match 'REBOOT REQUIS')) {
                    $cb.ForeColor = [System.Drawing.Color]::Red
                }
                $script:GbChecklist.Controls.Add($cb)
                $yItem += 20
            }
            $script:GbChecklist.Visible = $true
        } catch { }   # la checklist est informative : toute erreur ne doit pas bloquer la fin de run
        return
    }

    $item = $script:Queue[$script:QueueIndex]
    $mod  = $item.Mod
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
    }

    for ($i = 0; $i -lt $clbModules.Items.Count; $i++) {
        if (-not $clbModules.GetItemChecked($i)) { continue }
        $mod = $script:Modules[$i]
        $fileArgs = @('-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $script:Root "modules\$($mod.File)")))
        $modArgs  = Build-ModuleArgList -Id $mod.Id -DryRun:$dry -Options $options
        $script:Queue += [PSCustomObject]@{ Mod = $mod; Args = (($fileArgs + $modArgs) -join ' ') }
    }
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

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Vérifie que le backup est bien présent sur le disque externe, puis clique OK pour continuer.`r`n`r`nSans action, l'intervention reprend seule dans 5 minutes."
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(420, 80)
    $lbl.AutoSize = $false

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK, continuer'
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
    # Repeuple la combobox depuis config\profiles\*.json (BaseName uniquement).
    $cmbProfile.Items.Clear()
    $profilesDir = Join-Path $script:Root 'config\profiles'
    if (Test-Path $profilesDir) {
        $files = @(Get-ChildItem -Path $profilesDir -Filter '*.json' -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            [void]$cmbProfile.Items.Add($f.BaseName)
        }
    }
    if ($cmbProfile.Items.Count -gt 0) { $cmbProfile.SelectedIndex = 0 }
}

function Set-GuiFromProfile {
    # Applique un objet Read-KitProfile aux contrôles de la GUI.
    # Le mapping module passe par $script:Modules[$i].Id (jamais une position en dur)
    # car $clbModules est peuplé dans le même ordre que $script:Modules.
    param($Prof)
    for ($i = 0; $i -lt $script:Modules.Count; $i++) {
        $id  = $script:Modules[$i].Id
        $val = $true
        if ($Prof.Modules.ContainsKey($id)) { $val = [bool]$Prof.Modules[$id] }
        $clbModules.SetItemChecked($i, $val)
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
}

function Get-GuiProfileObject {
    # Capture l'état courant des contrôles GUI dans un objet sérialisable.
    # Les modules sont capturés par Id (pas par position) pour cohérence avec Set-GuiFromProfile.
    $mods = @{}
    for ($i = 0; $i -lt $script:Modules.Count; $i++) {
        $mods[$script:Modules[$i].Id] = [bool]$clbModules.GetItemChecked($i)
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
        Modules      = $mods
    }
}

# Initialisation : peupler la combobox au démarrage
Update-ProfileComboBox

# --- Handlers ---

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
    if ($script:Queue.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Aucun module sélectionné.", "PC-Refresh-Kit") | Out-Null
        return
    }
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
    $progress.Minimum = 0
    $progress.Maximum = $script:Queue.Count
    $progress.Value = 0
    $btnRun.Enabled = $false
    $btnCancel.Enabled = $true
    $btnCopy.Enabled = $false
    $btnReport.Enabled = $false
    $btnDelFiche.Enabled = $false
    $script:GbChecklist.Visible = $false   # masquer la checklist d'un run précédent éventuel
    $form.Text = "$($script:RunLabel)PC-Refresh-Kit - $env:COMPUTERNAME"
    Start-NextModule
    $timer.Start()
})

$timer.Add_Tick({
    Add-LogLines
    if ($script:Running -and $script:StartTime) {
        try { $form.Text = "$($script:RunLabel)PC-Refresh-Kit - $env:COMPUTERNAME - écoulé $(Format-Elapsed ([int]((Get-Date) - $script:StartTime).TotalSeconds))" } catch { }
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
                    $txtLog.SelectionColor  = [System.Drawing.Color]::Gray
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
        $progress.Value = [Math]::Min($script:QueueIndex, $progress.Maximum)
        $script:CurrentProc = $null
        Start-NextModule
    }
})

$btnCopy.Add_Click({
    if ($script:AdminPwd) { [System.Windows.Forms.Clipboard]::SetText($script:AdminPwd) }
})

$btnCancel.Add_Click({
    $timer.Stop()
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        try { $script:CurrentProc.Kill() } catch { }
    }
    $script:Running = $false
    $btnCancel.Enabled = $false
    $btnRun.Enabled = $true
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
                $txtLog.SelectionColor  = [System.Drawing.Color]::Green
            } catch { }
            $txtLog.AppendText("$logLine`r`n")
            try { $txtLog.SelectionColor = $txtLog.ForeColor; $txtLog.ScrollToCaret() } catch { }
            # Désactiver le bouton et effacer l'affichage du mot de passe
            $btnDelFiche.Enabled = $false
            $lblPwd.Text = "Mot de passe Admin-Local : (fiche supprimée de la clé)"
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
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Erreur lors de l'application du profil : $_",
            "PC-Refresh-Kit", 'OK', 'Error') | Out-Null
    }
})

$btnSaveProfile.Add_Click({
    # Demander le nom via InputBox (Microsoft.VisualBasic, sans dépendance supplémentaire).
    $nom = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Entrez le nom du profil à enregistrer :", "Enregistrer comme profil", "")
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
        [System.Windows.Forms.MessageBox]::Show(
            "Profil `"$nom`" enregistré.", "PC-Refresh-Kit", 'OK', 'Information') | Out-Null
    } catch {
        if (Test-Path $tmpPath) { Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.MessageBox]::Show(
            "Erreur lors de l'enregistrement du profil : $_",
            "PC-Refresh-Kit", 'OK', 'Error') | Out-Null
    }
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

[void]$form.ShowDialog()
