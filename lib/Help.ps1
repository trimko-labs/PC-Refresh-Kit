# lib/Help.ps1 - Catalogue d'aide du cockpit : chargement, résolution, mise en forme.
# Le CONTENU vit dans config/help.fr.json ; ce fichier ne contient aucun texte
# d'aide, seulement la logique. Fonctions pures, testables sans GUI.
# Encodage : UTF-8 avec BOM pour PowerShell 5.1.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Get-HelpCatalog : charge le catalogue. Ne lève JAMAIS : une aide absente ne
# doit pas empêcher le cockpit de démarrer.
# ---------------------------------------------------------------------------
function Get-HelpCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $catalog = @{}
    # Un catalogue absent ou cassé ne bloque pas le cockpit, mais il laisse une
    # trace dans le journal. Write-KitLog n'est pas toujours chargé (tests nus de
    # lib/Help.ps1 seul) : la journalisation elle-même est donc protégée.
    $avertir = {
        try { Write-KitLog -Message "Catalogue d'aide illisible ou vide : $Path" -Level 'WARN' } catch { }
    }

    if (-not (Test-Path $Path)) { & $avertir ; return $catalog }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch { & $avertir ; return $catalog }
    if ($null -eq $json -or -not $json.PSObject.Properties['entries']) { & $avertir ; return $catalog }
    # entries présent mais vide ou d'un autre type : $json.entries.PSObject sur
    # $null lève, et une chaîne n'a pas d'entrées à parcourir.
    if ($null -eq $json.entries -or $json.entries -isnot [PSCustomObject]) { & $avertir ; return $catalog }

    foreach ($prop in $json.entries.PSObject.Properties) {
        $catalog[$prop.Name] = $prop.Value
    }
    return $catalog
}

# ---------------------------------------------------------------------------
# Get-HelpEntry : entrée demandée, ou entrée de repli. Ne renvoie jamais $null.
# ---------------------------------------------------------------------------
function Get-HelpEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$Catalog,
        [Parameter(Mandatory)][string]$Key
    )
    if ($Catalog -and $Catalog.ContainsKey($Key)) { return $Catalog[$Key] }
    return [PSCustomObject]@{
        title      = 'Aide indisponible'
        short      = 'Aide indisponible pour cet élément.'
        what       = 'Le catalogue config\help.fr.json est absent ou ne contient pas cette rubrique.'
        reversible = 'Sans objet.'
        duration   = 'Sans objet.'
    }
}

# ---------------------------------------------------------------------------
# Format-HelpPanel : texte affiché dans l'onglet Aide.
# ---------------------------------------------------------------------------
function Format-HelpPanel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)

    $nl       = [Environment]::NewLine
    $sections = @(
        @{ Field = 'what';       Label = "Ce qu'il fait" }
        @{ Field = 'protects';   Label = 'Ce qui est protégé' }
        @{ Field = 'reversible'; Label = 'Réversible' }
        @{ Field = 'duration';   Label = 'Durée' }
        @{ Field = 'whenNot';    Label = 'À décocher si' }
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine([string]$Entry.title)
    [void]$sb.AppendLine(('-' * [Math]::Min(60, ([string]$Entry.title).Length + 6)))
    [void]$sb.AppendLine('')

    foreach ($s in $sections) {
        if (-not $Entry.PSObject.Properties[$s.Field]) { continue }
        $val = [string]$Entry.($s.Field)
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        [void]$sb.AppendLine(($s.Label + ' :'))
        [void]$sb.AppendLine('  ' + $val)
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd() + $nl
}

# ---------------------------------------------------------------------------
# Format-HelpTooltip : résumé court replié à la largeur voulue. WinForms ne
# coupe pas les lignes tout seul : sans repli, une infobulle longue s'affiche
# sur une seule ligne plus large que l'écran.
# ---------------------------------------------------------------------------
function Format-HelpTooltip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Entry,
        [int]$Width = 90
    )
    $texte = [string]$Entry.short
    if ([string]::IsNullOrWhiteSpace($texte)) { $texte = [string]$Entry.title }

    $lignes  = @()
    $courant = ''
    foreach ($mot in ($texte -split '\s+')) {
        if ($courant -eq '') { $courant = $mot }
        elseif (($courant.Length + 1 + $mot.Length) -le $Width) { $courant = "$courant $mot" }
        else { $lignes += $courant ; $courant = $mot }
    }
    if ($courant -ne '') { $lignes += $courant }
    $lignes += ''
    $lignes += "Détail complet dans l'onglet Aide."
    return ($lignes -join "`n")
}

# ---------------------------------------------------------------------------
# Get-KitHelpDecision : le panneau d'aide doit-il être remplacé ? PURE.
# Épinglé : rien ne remplace (le lecteur a demandé la stabilité).
# Direct (sélection, application de profil) : remplace tout de suite.
# Hover gelé (souris dans le panneau) : ignoré, on ne vole pas la lecture.
# Hover libre : différé (le délai anti-transit filtre les survols de passage).
# ---------------------------------------------------------------------------
function Get-KitHelpDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Hover','Direct')][string]$Source,
        [Parameter(Mandatory)][bool]$Pinned,
        [Parameter(Mandatory)][bool]$Frozen
    )
    if ($Pinned) { return 'Ignore' }
    if ($Source -eq 'Direct') { return 'Show' }
    if ($Frozen) { return 'Ignore' }
    return 'Defer'
}

# ---------------------------------------------------------------------------
# Get-HelpHeaderInfo : type et fil d'Ariane d'une rubrique, dérivés de sa clé.
# PURE. Aucune donnée de catalogue : la clé suffit, toute clé inconnue tombe
# sur le repli générique (jamais d'erreur).
# ---------------------------------------------------------------------------
function Get-HelpHeaderInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    $map = @(
        @{ Prefix = 'module.';  Kind = 'module';  KindText = 'ÉTAPE';   Breadcrumb = 'Intervention > Étapes' }
        @{ Prefix = 'profile.'; Kind = 'profile'; KindText = 'PROFIL';  Breadcrumb = 'Intervention > Profil' }
        @{ Prefix = 'debloat.'; Kind = 'setting'; KindText = 'RÉGLAGE'; Breadcrumb = 'Réglages > Débloatage' }
        @{ Prefix = 'account.'; Kind = 'setting'; KindText = 'RÉGLAGE'; Breadcrumb = 'Réglages > Comptes' }
        @{ Prefix = 'option.';  Kind = 'setting'; KindText = 'RÉGLAGE'; Breadcrumb = 'Réglages' }
        @{ Prefix = 'status.';  Kind = 'status';  KindText = 'ÉTAT';    Breadcrumb = "Barre d'action" }
        @{ Prefix = 'action.';  Kind = 'action';  KindText = 'ACTION';  Breadcrumb = 'Actions' }
    )
    foreach ($m in $map) {
        if ($Key.StartsWith($m.Prefix)) {
            return [PSCustomObject]@{ Kind = $m.Kind; KindText = $m.KindText; Breadcrumb = $m.Breadcrumb }
        }
    }
    return [PSCustomObject]@{ Kind = 'general'; KindText = 'AIDE'; Breadcrumb = 'Général' }
}

# ---------------------------------------------------------------------------
# Get-HelpBadges : badges normalisés d'une rubrique, depuis son champ optionnel
# badges { reversible, data, duration }. PURE, fail-safe : champ absent,
# valeur inconnue ou vide = badge omis, jamais d'erreur (même contrat que le
# reste du catalogue). Ordre fixe : réversibilité, données, durée.
#
# CONTRAT D'APPEL : envelopper l'appel, `@(Get-HelpBadges -Entry $e)`. Pas de
# virgule unaire au retour ici, contrairement à Get-UndoPlan et consorts : les
# deux conventions s'excluent. Avec `return ,$badges`, le tableau sort comme un
# objet unique et `@(...)` l'imbrique au lieu de le dérouler (Count toujours 1,
# même vide) - c'est le « contrat (a) » décrit dans 02-Antivirus.ps1, que le kit
# s'est déjà fait piéger à écrire. Ici tous les appelants enveloppent, donc le
# retour est déroulé ; un appel nu sur une entrée sans badge rendrait $null.
# ---------------------------------------------------------------------------
function Get-HelpBadges {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)
    $badges = @()
    if (-not $Entry.PSObject.Properties['badges'] -or $null -eq $Entry.badges) { return $badges }
    $b = $Entry.badges
    $revMap = @{
        'yes'      = @{ Text = 'RÉVERSIBLE';               Level = 'Ok' }
        'store'    = @{ Text = 'RÉVERSIBLE VIA STORE';     Level = 'Accent' }
        'partial'  = @{ Text = 'PARTIELLEMENT RÉVERSIBLE'; Level = 'Warn' }
        'no'       = @{ Text = 'IRRÉVERSIBLE';             Level = 'Err' }
        'readonly' = @{ Text = 'LECTURE SEULE';            Level = 'Ok' }
    }
    $dataMap = @{
        'untouched' = @{ Text = 'DONNÉES PERSO : INTACTES';      Level = 'Ok' }
        'copyonly'  = @{ Text = 'DONNÉES PERSO : COPIE SEULE';   Level = 'Accent' }
        'optin'     = @{ Text = 'DONNÉES : SELON CASES COCHÉES'; Level = 'Warn' }
    }
    if ($b.PSObject.Properties['reversible']) {
        $v = [string]$b.reversible
        if ($revMap.ContainsKey($v)) {
            $badges += [PSCustomObject]@{ Text = $revMap[$v].Text; Level = $revMap[$v].Level }
        }
    }
    if ($b.PSObject.Properties['data']) {
        $v = [string]$b.data
        if ($dataMap.ContainsKey($v)) {
            $badges += [PSCustomObject]@{ Text = $dataMap[$v].Text; Level = $dataMap[$v].Level }
        }
    }
    if ($b.PSObject.Properties['duration']) {
        $v = [string]$b.duration
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            $badges += [PSCustomObject]@{ Text = "DURÉE : $v"; Level = 'Neutral' }
        }
    }
    return $badges
}
