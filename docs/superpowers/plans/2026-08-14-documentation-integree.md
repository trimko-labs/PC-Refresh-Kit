# Documentation intégrée du cockpit - plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Donner au cockpit une aide complète à deux niveaux, et rendre aux profils d'intervention le comportement que leur nom promet.

**Architecture:** Le contenu vit dans un catalogue JSON externe (`config/help.fr.json`), la logique dans `lib/Help.ps1` (quatre fonctions pures), l'affichage dans un `TabControl` à deux onglets qui remplace la zone de journal de `Run-GUI.ps1`. Les profils gagnent deux champs facultatifs, dont un que le module 12 consomme pour préserver certains démarrages automatiques.

**Tech Stack:** PowerShell 5.1 natif, WinForms, Pester 5.7, aucune dépendance externe.

**Spécification de référence:** `docs/superpowers/specs/2026-08-14-documentation-integree-design.md`

## Global Constraints

- **Encodage :** tout fichier `.ps1` créé ou modifié doit être enregistré en **UTF-8 avec BOM**, sinon `tests\Test-KitEncoding.ps1` échoue en CI. Les éditeurs d'agent écrivent souvent sans BOM : après création, exécuter `$c = Get-Content $f -Raw -Encoding UTF8 ; [System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding($true)))`. Les fichiers `.json` restent en **UTF-8 sans BOM** (standard JSON, comme `config/startup-blacklist.json`).
- **Typographie :** aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013) dans aucun fichier. Utiliser ` - `. Contrôlé par la CI.
- **Accents :** tout texte français porte ses accents, y compris dans les chaînes affichées et les commentaires.
- **Anonymat :** aucun nom de personne, aucun chemin `C:\Users\<nom>`, aucune adresse e-mail hors `@trimko.com` dans un fichier suivi par git. Contrôlé par `tests\Test-KitAnonymity.ps1`.
- **Branche et identité :** travailler sur `public-main`. Committer avec `git -c user.name=Trimko -c user.email=contact@trimko.com commit`. Pousser avec `git push public public-main:main`.
- **Avant chaque push :** exécuter les trois contrôles CI localement. Un seul échec bloque le push.
  ```powershell
  .\tests\Test-KitParse.ps1 -CI ; .\tests\Test-KitEncoding.ps1 -CI ; .\tests\Test-KitAnonymity.ps1 -CI
  ```
- **Tests :** `Invoke-Pester .\tests\<fichier>.Tests.ps1 -Output Detailed` sous `pwsh` (Pester 5.7 n'est pas installé pour le PowerShell 5.1 système).
- **Point de départ :** 279 tests verts sur `tests\Common.Tests.ps1`. Aucune tâche ne doit faire baisser ce nombre.

---

### Task 1: Fonctions d'aide (lib/Help.ps1)

**Files:**
- Create: `lib/Help.ps1`
- Create: `tests/Help.Tests.ps1`

**Interfaces:**
- Consumes: rien.
- Produces: `Get-HelpCatalog -Path <string>` renvoie une `hashtable` clé -> `PSCustomObject` ; `Get-HelpEntry -Catalog <hashtable> -Key <string>` renvoie un `PSCustomObject` toujours non nul ; `Format-HelpPanel -Entry <object>` renvoie une `string` multi-lignes ; `Format-HelpTooltip -Entry <object> -Width <int>` renvoie une `string` repliée.

- [ ] **Step 1: Écrire les tests qui échouent**

Créer `tests/Help.Tests.ps1` :

```powershell
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

    It 'charge les entrées du catalogue du kit' {
        $c = Get-HelpCatalog -Path $script:CatalogPath
        $c.Count | Should -BeGreaterThan 0
        $c['module.03'].title | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-HelpEntry' {
    It 'renvoie l entrée demandée' {
        $c = Get-HelpCatalog -Path $script:CatalogPath
        (Get-HelpEntry -Catalog $c -Key 'module.03').title | Should -Match 'Debloat'
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
        $txt | Should -Match 'Ce qu il fait|Ce que fait ce module'
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
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `pwsh -c "Invoke-Pester .\tests\Help.Tests.ps1 -Output Detailed"`
Expected: FAIL, `lib\Help.ps1` introuvable au dot-sourcing.

- [ ] **Step 3: Écrire lib/Help.ps1**

```powershell
# lib/Help.ps1 - Catalogue d'aide du cockpit : chargement, resolution, mise en forme.
# Le CONTENU vit dans config/help.fr.json ; ce fichier ne contient aucun texte
# d'aide, seulement la logique. Fonctions pures, testables sans GUI.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Get-HelpCatalog : charge le catalogue. Ne leve JAMAIS : une aide absente ne
# doit pas empecher le cockpit de demarrer.
# ---------------------------------------------------------------------------
function Get-HelpCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $catalog = @{}
    if (-not (Test-Path $Path)) { return $catalog }
    try {
        $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch { return $catalog }
    if ($null -eq $json -or -not $json.PSObject.Properties['entries']) { return $catalog }

    foreach ($prop in $json.entries.PSObject.Properties) {
        $catalog[$prop.Name] = $prop.Value
    }
    return $catalog
}

# ---------------------------------------------------------------------------
# Get-HelpEntry : entree demandee, ou entree de repli. Ne renvoie jamais $null.
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
        short      = 'Aide indisponible pour cet element.'
        what       = 'Le catalogue config\help.fr.json est absent ou ne contient pas cette rubrique.'
        reversible = 'Sans objet.'
        duration   = 'Sans objet.'
    }
}

# ---------------------------------------------------------------------------
# Format-HelpPanel : texte affiche dans l'onglet Aide.
# ---------------------------------------------------------------------------
function Format-HelpPanel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)

    $nl       = [Environment]::NewLine
    $sections = @(
        @{ Field = 'what';       Label = 'Ce que fait ce module' }
        @{ Field = 'protects';   Label = 'Ce qui est protege' }
        @{ Field = 'reversible'; Label = 'Reversible' }
        @{ Field = 'duration';   Label = 'Duree' }
        @{ Field = 'whenNot';    Label = 'A decocher si' }
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
# Format-HelpTooltip : resume court replie a la largeur voulue. WinForms ne
# coupe pas les lignes tout seul : sans repli, une infobulle longue s'affiche
# sur une seule ligne plus large que l'ecran.
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
    $lignes += 'Detail complet dans l onglet Aide.'
    return ($lignes -join "`n")
}
```

- [ ] **Step 4: Convertir le fichier en UTF-8 avec BOM**

```powershell
$f = 'lib\Help.ps1'
$c = Get-Content $f -Raw -Encoding UTF8
[System.IO.File]::WriteAllText((Resolve-Path $f), $c, (New-Object System.Text.UTF8Encoding($true)))
```

- [ ] **Step 5: Relancer les tests**

Run: `pwsh -c "Invoke-Pester .\tests\Help.Tests.ps1 -Output Detailed"`
Expected: les tests de `Get-HelpCatalog` (fichier absent, JSON invalide), `Get-HelpEntry` (repli), `Format-HelpPanel` et `Format-HelpTooltip` PASSENT. Les deux tests qui lisent `config\help.fr.json` échouent encore : le catalogue n'existe pas, il arrive en Task 2.

- [ ] **Step 6: Commit**

```bash
git add lib/Help.ps1 tests/Help.Tests.ps1
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "feat: fonctions de catalogue d aide (lib/Help.ps1)"
```

---

### Task 2: Catalogue - les seize modules

**Files:**
- Create: `config/help.fr.json`

**Interfaces:**
- Consumes: le format défini en Task 1 (`entries` -> clé -> `title`, `short`, `what`, `protects`, `reversible`, `duration`, `whenNot`).
- Produces: les clés `module.00` à `module.15`.

- [ ] **Step 1: Créer le catalogue avec les entrées de modules**

Créer `config/help.fr.json` (UTF-8 **sans** BOM) :

```json
{
  "version": 1,
  "entries": {
    "module.00": {
      "title": "00 Diagnostic - état des lieux",
      "short": "Lit la configuration de la machine et fige un état avant intervention. Ne modifie rien.",
      "what": "Relève le modèle, le processeur, la mémoire, le type et la santé des disques (SMART), le chiffrement BitLocker, l'antivirus présent, les programmes lancés au démarrage et l'espace libre. Ces valeurs servent de point de comparaison au rapport final.",
      "protects": "Aucune écriture sur la machine : ce module lit uniquement.",
      "reversible": "Sans objet, rien n'est modifié.",
      "duration": "1 à 3 minutes",
      "whenNot": "Jamais. C'est lui qui permet de chiffrer le résultat de l'intervention."
    },
    "module.01": {
      "title": "01 Backup - filet de sécurité",
      "short": "Crée un point de restauration Windows, et copie les dossiers personnels si un disque externe est branché.",
      "what": "Crée un point de restauration système, puis copie Documents, Bureau, Images, Téléchargements, Vidéos et Musique vers le disque externe branché.",
      "protects": "Aucun fichier d'origine n'est déplacé ni supprimé : la copie est une copie.",
      "reversible": "Sans objet. C'est ce module qui rend les autres réversibles.",
      "duration": "10 à 30 minutes selon le volume de données",
      "whenNot": "Jamais sur une machine qui contient des données. Sans disque externe, seul le point de restauration est créé : les fichiers personnels ne sont pas copiés."
    },
    "module.02": {
      "title": "02 Antivirus - retour à Windows Defender",
      "short": "Retire les antivirus tiers redondants et remet Windows Defender en service.",
      "what": "Désinstalle l'antivirus tiers détecté (Avast, Norton, McAfee et équivalents), réactive Windows Defender et lance une analyse complète si l'option est cochée.",
      "protects": "Un seul antivirus doit tourner à la fois : deux moteurs concurrents se ralentissent et se neutralisent.",
      "reversible": "Oui, l'antivirus retiré peut être réinstallé depuis le site de son éditeur.",
      "duration": "5 minutes, plus 20 à 60 minutes si l'analyse complète est cochée",
      "whenNot": "Si un abonnement payant est en cours et que le propriétaire souhaite le garder. Le kit désinstalle le logiciel mais ne résilie jamais l'abonnement : la facturation continue tant que le propriétaire ne l'annule pas."
    },
    "module.03": {
      "title": "03 Debloat - applications préinstallées",
      "short": "Retire les applications préinstallées inutiles, en s'appuyant sur une liste de protection.",
      "what": "Supprime les applications du Microsoft Store et du constructeur qui n'ont jamais servi : jeux de démonstration, applications Bing, suites d'essai, utilitaires de marque. La politique de débloatage choisie décide du sort des applications douteuses.",
      "protects": "Le Microsoft Store, Defender, winget, les pilotes graphiques et les jeux Game Pass ne sont jamais retirés. En politique Standard, une application utilisée dans les 90 derniers jours est conservée.",
      "reversible": "Non, mais toute application retirée se réinstalle gratuitement depuis le Microsoft Store.",
      "duration": "5 à 15 minutes",
      "whenNot": "Sur un poste d'entreprise où des applications de marque sont imposées par le service informatique."
    },
    "module.04": {
      "title": "04 Privacy - collecte de données",
      "short": "Réduit la télémétrie de Windows et installe une protection qui survit aux mises à jour.",
      "what": "Coupe la remontée de données de diagnostic, l'identifiant publicitaire, les suggestions et les fonctions de collecte associées (Copilot, Widgets, Recall). Installe TelemetryGuard, qui réapplique ces réglages après chaque mise à jour de Windows au moyen de deux tâches planifiées.",
      "protects": "SmartScreen, qui bloque les téléchargements dangereux, est conservé : il ne fait pas partie de la télémétrie.",
      "reversible": "Oui, les réglages se remettent dans Paramètres, Confidentialité. Les deux tâches planifiées se désactivent dans le Planificateur de tâches.",
      "duration": "2 à 5 minutes",
      "whenNot": "Sur un poste dont l'entreprise pilote les réglages de confidentialité par stratégie de groupe."
    },
    "module.05": {
      "title": "05 Updates - mises à jour",
      "short": "Installe les mises à jour de Windows et de tous les logiciels connus de winget.",
      "what": "Recherche et installe les mises à jour Windows en attente, puis met à jour l'ensemble des logiciels installés reconnus par winget.",
      "protects": "Si la machine est hors ligne, le module s'arrête proprement sans erreur au lieu de tourner à vide.",
      "reversible": "Une mise à jour Windows se désinstalle depuis l'historique des mises à jour, dans les cas où Microsoft le permet.",
      "duration": "20 minutes à plus d'une heure selon le retard accumulé",
      "whenNot": "Si le temps d'intervention est court : c'est le module le plus long et il demande souvent un redémarrage."
    },
    "module.06": {
      "title": "06 Software - socle logiciel",
      "short": "Installe le socle utile : navigateur, archiveur, lecteur PDF, lecteur multimédia, bureautique.",
      "what": "Installe la liste définie dans config\\apps.json : Firefox, 7-Zip, VLC, Sumatra PDF et LibreOffice par défaut. Les entrées marquées facultatives demandent confirmation une par une.",
      "protects": "Une application déjà présente n'est pas réinstallée.",
      "reversible": "Oui, chaque logiciel se désinstalle normalement depuis Applications installées.",
      "duration": "10 à 20 minutes, connexion internet requise",
      "whenNot": "Si le propriétaire utilise déjà d'autres équivalents et ne veut pas de doublons. Adapter config\\apps.json plutôt que de sauter le module."
    },
    "module.07": {
      "title": "07 Cleanup - nettoyage et réparation",
      "short": "Vide les fichiers temporaires, répare les composants système et optimise le disque.",
      "what": "Supprime les fichiers temporaires et les caches, exécute DISM et SFC pour réparer les composants de Windows, puis optimise le disque : défragmentation sur disque mécanique, TRIM sur disque SSD.",
      "protects": "Le type de disque est détecté avant l'optimisation : aucun SSD n'est jamais défragmenté. DISM est ignoré si moins de 8 Go sont libres, plutôt que d'échouer à mi-parcours.",
      "reversible": "Non, les fichiers temporaires supprimés ne reviennent pas. Aucun fichier personnel n'est concerné.",
      "duration": "30 à 60 minutes, c'est le module le plus long après les mises à jour",
      "whenNot": "Tant qu'un disque externe de sauvegarde est branché : le débrancher d'abord, sinon l'optimisation le traite aussi."
    },
    "module.08": {
      "title": "08 Accounts - comptes et droits",
      "short": "Crée un compte administrateur dédié et bascule le compte quotidien en droits standard.",
      "what": "Crée le compte Admin-Local avec une phrase de passe mémorisable, l'ajoute au groupe Administrateurs, puis rétrograde le compte quotidien en compte standard. La phrase de passe est écrite dans la fiche PC.",
      "protects": "Un contrôle interdit l'opération s'il ne resterait aucun administrateur actif : impossible de se verrouiller hors de la machine.",
      "reversible": "Oui, les droits se remettent dans Paramètres, Comptes, ou en supprimant le compte créé.",
      "duration": "2 minutes",
      "whenNot": "Sur un poste géré par un service informatique, ou si le propriétaire installe des logiciels tous les jours et refuse de saisir un mot de passe à chaque fois. Dans ce cas, choisir Garder admin."
    },
    "module.09": {
      "title": "09 Comfort - confort d'utilisation",
      "short": "Rend Windows plus lisible : extensions de fichiers visibles, suggestions et publicités coupées.",
      "what": "Affiche les extensions de fichiers, coupe les suggestions de l'écran de verrouillage et du menu Démarrer, désactive les publicités intégrées. Désinstalle OneDrive si l'option correspondante est cochée.",
      "protects": "Les fichiers déjà synchronisés avec OneDrive restent sur le disque local.",
      "reversible": "Oui, chaque réglage se remet dans les options de l'Explorateur et les Paramètres.",
      "duration": "1 à 2 minutes",
      "whenNot": "Si le propriétaire utilise activement OneDrive, laisser l'option OneDrive décochée. Le reste du module ne présente aucun risque."
    },
    "module.10": {
      "title": "10 Report - rapport d'intervention",
      "short": "Produit le rapport avant et après, ainsi que la note à remettre à l'utilisateur.",
      "what": "Compare l'état relevé par le module 00 à l'état final et chiffre le résultat : espace disque récupéré, programmes au démarrage, applications retirées ou ajoutées, temps de démarrage. Produit un rapport HTML présentable et un rapport texte, plus une note en langage clair pour l'utilisateur.",
      "protects": "Le mot de passe administrateur n'est jamais recopié dans le rapport : il n'existe que dans la fiche PC.",
      "reversible": "Sans objet, le module écrit uniquement des fichiers dans runtime.",
      "duration": "1 minute",
      "whenNot": "Jamais. C'est le livrable de l'intervention."
    },
    "module.11": {
      "title": "11 DeepClean - résidus de désinstallation",
      "short": "Supprime les raccourcis morts et les dossiers laissés par les applications retirées.",
      "what": "Parcourt le menu Démarrer et supprime les raccourcis dont la cible n'existe plus, puis supprime les dossiers résiduels des applications désinstallées, d'après une liste blanche et le journal du module 03.",
      "protects": "Aucune opération sur le registre. Seuls les sous-dossiers des emplacements d'installation connus peuvent être supprimés, jamais leur racine.",
      "reversible": "Non, mais un raccourci se recrée et un dossier résiduel ne contient plus de programme.",
      "duration": "2 à 5 minutes",
      "whenNot": "Si la machine utilise des lecteurs réseau déconnectés au moment de l'intervention : leurs raccourcis pourraient être vus comme morts."
    },
    "module.12": {
      "title": "12 Startup - programmes au démarrage",
      "short": "Désactive, de façon réversible, les programmes qui se lancent inutilement au démarrage.",
      "what": "Désactive les entrées figurant dans la liste noire config\\startup-blacklist.json : mises à jour Adobe et Java, assistants iTunes et QuickTime, lanceurs de jeux, agents de synchronisation. Trois mécanismes selon le cas : marquage dans l'onglet Démarrage, déplacement du raccourci vers un dossier de sauvegarde, désactivation de la tâche planifiée.",
      "protects": "Rien hors liste noire n'est touché, et rien n'est jamais supprimé. Le profil d'intervention peut préserver certaines entrées, par exemple les lanceurs de jeux avec le profil gamer.",
      "reversible": "Oui, entièrement, par le module 14 ou par le Gestionnaire des tâches, onglet Démarrage.",
      "duration": "1 à 3 minutes",
      "whenNot": "Si le propriétaire tient à ce que ses lanceurs démarrent avec Windows. Préférer alors le profil qui les préserve plutôt que de sauter le module."
    },
    "module.13": {
      "title": "13 BrowserPUP - détournements de navigateur",
      "short": "Retire les moteurs de recherche, pages d'accueil et extensions imposés à Chrome et Edge.",
      "what": "Supprime les stratégies de registre qui forcent un moteur de recherche, une page d'accueil, une page de nouvel onglet ou une extension, quand elles figurent dans la liste des indésirables. Les autres extensions imposées sont seulement signalées dans le journal.",
      "protects": "La clé de registre concernée est exportée en fichier .reg avant toute suppression. Si l'export échoue, la suppression est annulée.",
      "reversible": "Oui, par le module 14 ou par un double-clic sur le fichier .reg de sauvegarde.",
      "duration": "1 à 2 minutes",
      "whenNot": "Sur un poste d'entreprise : les stratégies de navigateur y sont légitimes et posées par le service informatique."
    },
    "module.14": {
      "title": "14 Undo - annulation",
      "short": "Annule les modifications réversibles du dernier passage, dans l'ordre inverse.",
      "what": "Relit le manifeste écrit par les modules 12 et 13 et défait chaque action : réactivation des programmes au démarrage, remise en place des raccourcis, réactivation des tâches planifiées, réimport des clés de registre des navigateurs.",
      "protects": "Ce module ne supprime jamais rien, il restaure. Il accepte le mode simulation pour voir ce qui serait annulé.",
      "reversible": "Sans objet, c'est lui l'annulation.",
      "duration": "1 minute",
      "whenNot": "Ce module ne fait pas partie de la file d'exécution : il se lance à la demande par Lancer-Annuler.bat."
    },
    "module.15": {
      "title": "15 Network - réinitialisation réseau",
      "short": "Remet à zéro la configuration réseau. À réserver aux machines dont la connexion est défectueuse.",
      "what": "Réinitialise la pile TCP/IP, le catalogue Winsock et le cache DNS.",
      "protects": "Aucun mot de passe Wi-Fi n'est effacé.",
      "reversible": "Non sans intervention manuelle. Un redémarrage est nécessaire après le passage.",
      "duration": "1 minute, plus un redémarrage",
      "whenNot": "Sur une machine dont la connexion fonctionne. Ce module ne sert qu'à réparer un réseau cassé, il n'apporte rien sur un poste sain. Il est décoché dans les profils gamer et senior."
    }
  }
}
```

- [ ] **Step 2: Vérifier que le JSON est valide et sans BOM**

```powershell
$p = 'config\help.fr.json'
$c = Get-Content $p -Raw -Encoding UTF8
($c | ConvertFrom-Json).entries.PSObject.Properties.Name.Count   # attendu : 16
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $p))
"BOM present : $($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)"    # attendu : False
```

Si le BOM est présent : `[System.IO.File]::WriteAllText((Resolve-Path $p), $c, (New-Object System.Text.UTF8Encoding($false)))`

- [ ] **Step 3: Relancer les tests de Task 1**

Run: `pwsh -c "Invoke-Pester .\tests\Help.Tests.ps1 -Output Detailed"`
Expected: PASS intégral, y compris les deux tests qui lisent le catalogue du kit.

- [ ] **Step 4: Commit**

```bash
git add config/help.fr.json
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "feat: catalogue d aide, rubriques des seize modules"
```

---

### Task 3: Catalogue - options, politiques, comptes, profils, actions

**Files:**
- Modify: `config/help.fr.json`

**Interfaces:**
- Consumes: le catalogue de Task 2.
- Produces: les clés `option.*`, `debloat.*`, `account.*`, `profile.*`, `action.*`.

- [ ] **Step 1: Ajouter les 24 entrées restantes**

Insérer ces paires dans l'objet `entries`, après `module.15` :

```json
    "option.backupdata": {
      "title": "Sauvegarder les données utilisateur",
      "short": "Copie les dossiers personnels vers le disque externe branché, pendant le module 01.",
      "what": "Copie Documents, Bureau, Images, Téléchargements, Vidéos et Musique vers le disque externe. Sans disque externe branché, l'option est sans effet et seul le point de restauration est créé.",
      "protects": "Les données d'application, comme les messageries locales ou les mots de passe des navigateurs, ne sont pas copiées : elles se sauvegardent à la main si elles comptent.",
      "reversible": "Sans objet, il s'agit d'une copie.",
      "duration": "10 à 30 minutes selon le volume",
      "whenNot": "Si aucun disque externe n'est disponible."
    },
    "option.scandefender": {
      "title": "Scanner avec Defender après bascule",
      "short": "Lance une analyse complète après la remise en service de Windows Defender.",
      "what": "Déclenche une analyse complète du disque à la fin du module 02.",
      "reversible": "Sans objet, une analyse ne modifie rien tant qu'aucune menace n'est trouvée.",
      "duration": "20 à 60 minutes en tâche de fond",
      "whenNot": "Si le temps manque et que la machine ne présente aucun signe d'infection."
    },
    "option.recycle": {
      "title": "Vider la corbeille",
      "short": "Vide définitivement la corbeille de tous les disques.",
      "what": "Supprime le contenu de la corbeille pendant le module 07.",
      "reversible": "Non. Un fichier supprimé de la corbeille ne se récupère plus simplement.",
      "duration": "Quelques secondes",
      "whenNot": "Sans avoir demandé au propriétaire s'il a quelque chose à récupérer dans sa corbeille. Décochée par défaut pour cette raison, et à laisser décochée tant qu'un disque externe de sauvegarde est branché."
    },
    "option.winold": {
      "title": "Supprimer Windows.old",
      "short": "Supprime l'ancienne installation de Windows conservée après une mise à niveau.",
      "what": "Supprime le dossier Windows.old, qui occupe souvent entre 5 et 25 Go.",
      "reversible": "Non. Après suppression, le retour à la version précédente de Windows n'est plus possible.",
      "duration": "2 à 10 minutes",
      "whenNot": "Dans les dix jours suivant une mise à niveau majeure de Windows, tant qu'un retour arrière peut encore être nécessaire."
    },
    "option.cache": {
      "title": "Vider les caches des navigateurs",
      "short": "Vide les fichiers temporaires de Chrome et Edge, tous profils confondus.",
      "what": "Supprime les caches des navigateurs pendant le module 07.",
      "protects": "Les favoris et les mots de passe enregistrés ne sont pas touchés.",
      "reversible": "Non, mais un cache se reconstitue seul à la navigation.",
      "duration": "1 à 3 minutes",
      "whenNot": "Si le propriétaire a des onglets et des sessions ouvertes qu'il ne veut pas perdre. Fermer les navigateurs avant."
    },
    "option.onedrive": {
      "title": "Désinstaller OneDrive",
      "short": "Retire OneDrive, bloque sa réinstallation automatique et coupe ses rappels.",
      "what": "Désinstalle OneDrive pendant le module 09 et empêche son retour lors des mises à jour de Windows.",
      "protects": "Les fichiers déjà présents sur le disque restent en place. Seule la synchronisation cesse.",
      "reversible": "Oui, OneDrive se réinstalle depuis le site de Microsoft.",
      "duration": "2 minutes",
      "whenNot": "Si le propriétaire s'en sert, ou si ses dossiers Documents et Bureau sont redirigés vers OneDrive. Vérifier avant de cocher."
    },
    "option.oem": {
      "title": "Debloat constructeur (OEM)",
      "short": "Retire les utilitaires du fabricant de la machine, au-delà des applications du Store.",
      "what": "Désinstalle les logiciels de marque du constructeur d'après les fiches de config\\oem-bloat, pendant le module 03.",
      "protects": "Les utilitaires nécessaires au matériel, comme la gestion du pavé tactile ou des profils de ventilation, figurent en liste protégée.",
      "reversible": "Oui, ces logiciels se retéléchargent sur le site du constructeur.",
      "duration": "5 à 10 minutes",
      "whenNot": "Sur une machine dont le propriétaire utilise l'outil du fabricant, par exemple pour piloter la batterie ou l'affichage."
    },
    "option.netreset": {
      "title": "Réinitialiser le réseau",
      "short": "Active le module 15. À réserver aux machines dont la connexion est défectueuse.",
      "what": "Réinitialise la pile TCP/IP, Winsock et le cache DNS.",
      "reversible": "Non sans intervention manuelle, et un redémarrage est nécessaire ensuite.",
      "duration": "1 minute, plus un redémarrage",
      "whenNot": "Sur une connexion qui fonctionne. Décochée par défaut."
    },
    "option.dryrun": {
      "title": "Mode dry-run (simulation)",
      "short": "Exécute tout le déroulé sans rien modifier. À utiliser avant tout passage réel.",
      "what": "Chaque module annonce ce qu'il ferait, dans le journal, sans l'exécuter. La barre de titre affiche DRY-RUN pour lever toute ambiguïté.",
      "protects": "Aucune écriture sur la machine, quel que soit le module coché.",
      "reversible": "Sans objet, rien n'est modifié.",
      "duration": "3 à 5 minutes pour le déroulé complet",
      "whenNot": "Jamais avant une première intervention sur une machine inconnue, ni avant une démonstration."
    },
    "debloat.conservative": {
      "title": "Politique de débloatage : Conservatrice",
      "short": "Ne retire que les applications sans usage possible. Toute application douteuse est conservée.",
      "what": "Les applications dites conditionnelles, comme Spotify, Skype, Films et TV ou le Lien avec le téléphone, ne sont jamais supprimées.",
      "reversible": "Sans objet, il s'agit d'un réglage.",
      "duration": "Sans effet sur la durée",
      "whenNot": "Sur une machine très encombrée dont le propriétaire veut repartir de zéro."
    },
    "debloat.standard": {
      "title": "Politique de débloatage : Standard",
      "short": "Retire les applications conditionnelles qui n'ont pas servi depuis 90 jours.",
      "what": "L'usage récent est mesuré sur les fichiers de l'application. Une application utilisée ces trois derniers mois est conservée, les autres sont retirées.",
      "reversible": "Sans objet, il s'agit d'un réglage.",
      "duration": "Sans effet sur la durée",
      "whenNot": "Sur la machine d'une personne qui utilise des applications de façon saisonnière."
    },
    "debloat.aggressive": {
      "title": "Politique de débloatage : Agressive",
      "short": "Retire les applications conditionnelles même si elles ont servi récemment.",
      "what": "Toutes les applications de la liste conditionnelle sont supprimées, sans test d'usage.",
      "protects": "Les jeux Game Pass restent protégés quelle que soit la politique.",
      "reversible": "Sans objet, il s'agit d'un réglage.",
      "duration": "Sans effet sur la durée",
      "whenNot": "Sans avoir montré la liste au propriétaire. C'est le réglage qui surprend le plus après coup."
    },
    "account.standard": {
      "title": "Compte : Standard avec phrase de passe",
      "short": "Le compte quotidien perd les droits d'administrateur, un compte d'administration séparé est créé.",
      "what": "Une installation de logiciel demandera désormais la phrase de passe du compte Admin-Local. C'est la configuration recommandée pour un poste familial.",
      "protects": "Un logiciel malveillant lancé par erreur ne peut plus s'installer en silence.",
      "reversible": "Oui, les droits se remettent dans Paramètres, Comptes.",
      "duration": "2 minutes",
      "whenNot": "Si le propriétaire installe des logiciels quotidiennement, ou n'a personne pour l'aider en cas d'oubli de la phrase de passe."
    },
    "account.keepadmin": {
      "title": "Compte : Garder administrateur",
      "short": "Le compte quotidien reste administrateur, protégé par la confirmation Windows.",
      "what": "Aucun compte n'est créé et aucun mot de passe n'est à retenir. Chaque installation demande une simple confirmation Oui ou Non.",
      "protects": "La confirmation Windows est durcie pour rester affichée sur chaque élévation.",
      "reversible": "Oui, le module 08 peut être relancé plus tard dans l'autre mode.",
      "duration": "Immédiat",
      "whenNot": "Sur la machine d'une personne peu à l'aise, qui cliquerait Oui à toutes les demandes."
    },
    "profile.standard": {
      "title": "Profil standard",
      "short": "Remise en état complète et équilibrée. C'est le profil à utiliser par défaut.",
      "what": "Tous les modules actifs, politique de débloatage Standard, compte quotidien passé en standard, réinitialisation réseau incluse.",
      "reversible": "Sans objet, un profil ne fait que positionner les cases de l'interface.",
      "duration": "Sans effet, il n'exécute rien",
      "whenNot": "Sur une machine de jeu ou pour une personne âgée : les profils dédiés sont mieux adaptés."
    },
    "profile.senior": {
      "title": "Profil senior",
      "short": "Machine la plus simple possible, sans rien retirer de ce qui pourrait encore servir.",
      "what": "Politique de débloatage conservatrice, aucun démarrage automatique préservé pour un démarrage aussi léger que possible, compte quotidien passé en standard, pas de réinitialisation réseau.",
      "protects": "La politique conservatrice évite de faire disparaître une icône connue du propriétaire.",
      "reversible": "Sans objet, un profil ne fait que positionner les cases de l'interface.",
      "duration": "Sans effet, il n'exécute rien",
      "whenNot": "Sur une machine dont le propriétaire veut repartir de zéro."
    },
    "profile.gamer": {
      "title": "Profil gamer",
      "short": "Ne gêne pas une machine de jeu : lanceurs préservés au démarrage et compte administrateur conservé.",
      "what": "Steam, Epic Games Launcher, Discord, GeForce et Battle.net restent lancés au démarrage, la politique de débloatage est conservatrice pour ne pas retirer un outil de jeu saisonnier, le compte reste administrateur pour installer sans friction, et la réinitialisation réseau est écartée.",
      "protects": "Les jeux Game Pass sont de toute façon protégés, quel que soit le profil.",
      "reversible": "Sans objet, un profil ne fait que positionner les cases de l'interface.",
      "duration": "Sans effet, il n'exécute rien",
      "whenNot": "Sur un poste de travail ordinaire : le profil standard sécurise davantage le compte."
    },
    "action.run": {
      "title": "LANCER",
      "short": "Démarre les modules cochés, dans l'ordre, en affichant le journal en direct.",
      "what": "Bascule l'affichage sur l'onglet Journal et enchaîne les modules. Le titre de la fenêtre rappelle en permanence s'il s'agit d'une simulation ou d'un passage réel.",
      "reversible": "L'exécution peut être arrêtée à tout moment par le bouton Annuler.",
      "duration": "1 h 30 à 2 h 30 pour un passage complet",
      "whenNot": "Avant d'avoir vérifié le mode affiché dans la barre de titre."
    },
    "action.cancel": {
      "title": "Annuler",
      "short": "Arrête proprement le module en cours et vide la file des modules restants.",
      "what": "Le module en cours est interrompu et la fenêtre reste ouverte. La machine reste dans l'état atteint.",
      "protects": "Le kit ne supprimant aucun fichier personnel et créant un point de restauration au départ, une interruption ne laisse pas la machine dans un état dégradé.",
      "reversible": "Les actions déjà faites restent faites. Lancer-Annuler.bat défait celles qui sont réversibles.",
      "duration": "Immédiat",
      "whenNot": "Pendant le module 07 si DISM est en cours : le laisser finir évite de relancer une réparation longue."
    },
    "action.report": {
      "title": "Ouvrir le rapport",
      "short": "Ouvre le rapport d'intervention produit par le module 10.",
      "what": "Ouvre la version HTML dans le navigateur, c'est le document présentable à remettre. La version texte s'ouvre dans l'éditeur si le HTML est absent.",
      "protects": "Le rapport ne contient pas le mot de passe administrateur.",
      "reversible": "Sans objet, le bouton n'ouvre qu'un fichier.",
      "duration": "Immédiat",
      "whenNot": "Avant la fin du module 10 : le bouton reste inactif jusque-là."
    },
    "action.delfiche": {
      "title": "Supprimer la fiche PC de la clé",
      "short": "Efface le seul fichier contenant le mot de passe administrateur en clair.",
      "what": "Supprime runtime\\FICHE-PC-<machine>.txt de la clé. À faire avant de repartir d'une intervention, une fois le mot de passe transmis au propriétaire.",
      "protects": "Le mot de passe n'existe que dans ce fichier : le rapport ne le recopie pas.",
      "reversible": "Non. Si le mot de passe n'a pas été noté ailleurs, il est définitivement perdu.",
      "duration": "Immédiat",
      "whenNot": "Avant d'avoir vérifié que le propriétaire a bien noté sa phrase de passe."
    },
    "action.copypassword": {
      "title": "Copier le mot de passe",
      "short": "Copie la phrase de passe du compte Admin-Local dans le presse-papiers.",
      "what": "Devient actif une fois le module 08 passé, quand le compte administrateur existe et que sa phrase de passe est connue.",
      "protects": "Le presse-papiers est volatil : la phrase de passe reste par ailleurs dans la fiche PC, seul endroit où elle est écrite.",
      "reversible": "Sans objet, le bouton ne fait que copier.",
      "duration": "Immédiat",
      "whenNot": "Sur une machine où un gestionnaire de presse-papiers conserve l'historique des copies."
    },
    "action.applyprofile": {
      "title": "Appliquer un profil",
      "short": "Positionne toutes les cases de l'interface selon le profil sélectionné. N'exécute rien.",
      "what": "Charge le fichier de profil et coche ou décoche modules et options en conséquence. Les réglages restent modifiables ensuite.",
      "reversible": "Oui, en appliquant un autre profil ou en modifiant les cases à la main.",
      "duration": "Immédiat",
      "whenNot": "Pendant une exécution : le bouton refuse d'agir pour ne pas modifier une file en cours."
    },
    "action.saveprofile": {
      "title": "Enregistrer comme profil",
      "short": "Enregistre l'état actuel des cases sous un nom réutilisable.",
      "what": "Écrit un fichier dans config\\profiles, immédiatement disponible dans la liste des profils.",
      "reversible": "Oui, le fichier se supprime à la main.",
      "duration": "Immédiat",
      "whenNot": "Sans objet, l'opération est sans risque."
    }
```

- [ ] **Step 2: Vérifier le compte d'entrées**

```powershell
$c = Get-Content 'config\help.fr.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$c.entries.PSObject.Properties.Name.Count    # attendu : 40
```

- [ ] **Step 3: Commit**

```bash
git add config/help.fr.json
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "feat: catalogue d aide, options, politiques, comptes, profils et actions"
```

---

### Task 4: Test de couverture du catalogue

**Files:**
- Modify: `tests/Help.Tests.ps1`

**Interfaces:**
- Consumes: `Get-HelpCatalog` (Task 1), le catalogue complet (Tasks 2 et 3).
- Produces: le filet qui fait échouer la CI si un contrôle arrive sans documentation.

- [ ] **Step 1: Ajouter les tests de couverture**

Ajouter à la fin de `tests/Help.Tests.ps1` :

```powershell
Describe 'Couverture du catalogue' {
    BeforeAll {
        $script:Catalog = Get-HelpCatalog -Path (Join-Path $PSScriptRoot '..\config\help.fr.json')
        $script:Attendues = @(
            '00','01','02','03','04','05','06','07','08','09','10','11','12','13','14','15' |
                ForEach-Object { "module.$_" }
        ) + @(
            'option.backupdata','option.scandefender','option.recycle','option.winold',
            'option.cache','option.onedrive','option.oem','option.netreset','option.dryrun',
            'debloat.conservative','debloat.standard','debloat.aggressive',
            'account.standard','account.keepadmin',
            'action.run','action.cancel','action.report','action.delfiche',
            'action.copypassword','action.applyprofile','action.saveprofile'
        )
    }

    It 'documente tous les controles attendus' {
        $manquantes = @($script:Attendues | Where-Object { -not $script:Catalog.ContainsKey($_) })
        $manquantes -join ', ' | Should -Be ''
    }

    It 'documente chaque profil livre dans config\profiles' {
        $profils = Get-ChildItem (Join-Path $PSScriptRoot '..\config\profiles') -Filter '*.json'
        foreach ($p in $profils) {
            $script:Catalog.ContainsKey("profile.$($p.BaseName)") | Should -BeTrue -Because "profile.$($p.BaseName) doit exister dans le catalogue"
        }
    }

    It 'remplit les cinq champs obligatoires de chaque entree' {
        foreach ($cle in $script:Catalog.Keys) {
            $e = $script:Catalog[$cle]
            foreach ($champ in @('title','short','what','reversible','duration')) {
                [string]$e.$champ | Should -Not -BeNullOrEmpty -Because "$cle.$champ est obligatoire"
            }
        }
    }

    It 'garde les resumes sous 200 caracteres' {
        foreach ($cle in $script:Catalog.Keys) {
            ([string]$script:Catalog[$cle].short).Length | Should -BeLessOrEqual 200 -Because "$cle a un resume trop long pour une infobulle"
        }
    }

    It 'ne contient aucun tiret cadratin ni demi-cadratin' {
        $brut = Get-Content (Join-Path $PSScriptRoot '..\config\help.fr.json') -Raw -Encoding UTF8
        ($brut -match "[$([char]0x2013)$([char]0x2014)]") | Should -BeFalse
    }
}
```

- [ ] **Step 2: Lancer les tests**

Run: `pwsh -c "Invoke-Pester .\tests\Help.Tests.ps1 -Output Detailed"`
Expected: PASS. Si `documente tous les controles attendus` échoue, le message liste les clés manquantes : les ajouter au catalogue.

- [ ] **Step 3: Brancher le fichier de tests dans la CI**

Aucune modification nécessaire : `.github/workflows/ci.yml` exécute déjà `$cfg.Run.Path = 'tests'`, donc tout fichier `*.Tests.ps1` du dossier est pris.

- [ ] **Step 4: Commit**

```bash
git add tests/Help.Tests.ps1
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "test: couverture du catalogue d aide, un controle non documente casse la CI"
```

---

### Task 5: Onglets Aide et Journal dans le cockpit

**Files:**
- Modify: `Run-GUI.ps1:173-182` (la zone de journal)

**Interfaces:**
- Consumes: rien.
- Produces: `$script:Tabs` (TabControl), `$script:TabHelp` et `$script:TabLog` (TabPage), `$txtHelp` (RichTextBox en lecture seule). `$txtLog` conserve son nom et son type : tout le code de journalisation existant continue de fonctionner sans modification.

- [ ] **Step 1: Remplacer la création du journal par le TabControl**

Dans `Run-GUI.ps1`, remplacer intégralement ce bloc :

```powershell
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
```

par :

```powershell
# Colonne droite : deux onglets a la place du seul journal.
# Onglet Aide au premier plan au demarrage : avant un lancement, cette zone
# etait vide et l'utilisateur n'avait aucune explication sous les yeux.
# Le journal garde son nom de variable et son type : la mecanique de
# journalisation et de coloration n'est pas touchee.
$script:Tabs = New-Object System.Windows.Forms.TabControl
$script:Tabs.Location = New-Object System.Drawing.Point(300, 20)
$script:Tabs.Size = New-Object System.Drawing.Size(580, 400)

$script:TabHelp = New-Object System.Windows.Forms.TabPage
$script:TabHelp.Text = 'Aide'
$script:TabLog  = New-Object System.Windows.Forms.TabPage
$script:TabLog.Text = 'Journal'

$txtHelp = New-Object System.Windows.Forms.RichTextBox
$txtHelp.Dock = 'Fill'
$txtHelp.ReadOnly = $true
$txtHelp.BorderStyle = 'None'
$txtHelp.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$txtHelp.Text = "Survolez un module ou une option : son explication complete s'affiche ici."
$script:TabHelp.Controls.Add($txtHelp)

# RichTextBox (au lieu de TextBox) : permet la coloration par niveau (OK vert, WARN orange, ERROR rouge).
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock = 'Fill'
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:TabLog.Controls.Add($txtLog)

$script:Tabs.TabPages.Add($script:TabHelp)
$script:Tabs.TabPages.Add($script:TabLog)
$form.Controls.Add($script:Tabs)
```

- [ ] **Step 2: Vérifier que le fichier parse toujours**

Run: `.\tests\Test-KitParse.ps1 -CI`
Expected: `[PARSE] 31 fichier(s), 0 en erreur`

- [ ] **Step 3: Vérifier visuellement**

Run: `.\Lancer-Demo.bat`
Expected: le cockpit s'ouvre en dry-run, deux onglets Aide et Journal occupent la zone de droite, l'onglet Aide est au premier plan et affiche la phrase d'invite. Fermer la fenêtre.

- [ ] **Step 4: Commit**

```bash
git add Run-GUI.ps1
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "feat: onglets Aide et Journal dans le cockpit"
```

---

### Task 6: Câblage de l'aide sur les contrôles

**Files:**
- Modify: `Run-GUI.ps1` (dot-sourcing en tête, bloc `$moduleDescriptions` lignes 231-248, bloc des `SetToolTip` lignes 226-305, handler de lancement)

**Interfaces:**
- Consumes: `Get-HelpCatalog`, `Get-HelpEntry`, `Format-HelpPanel`, `Format-HelpTooltip` (Task 1), le catalogue (Tasks 2 et 3), `$script:Tabs` et `$txtHelp` (Task 5).
- Produces: `Show-KitHelp -Key <string>` qui met à jour l'onglet Aide.

- [ ] **Step 1: Charger la bibliothèque et le catalogue**

Après la ligne `. "$PSScriptRoot\lib\Common.ps1"`, ajouter :

```powershell
. "$PSScriptRoot\lib\Help.ps1"
$script:HelpCatalog = Get-HelpCatalog -Path (Join-Path $PSScriptRoot 'config\help.fr.json')
```

- [ ] **Step 2: Supprimer le hashtable de descriptions mort**

Supprimer intégralement le bloc `$moduleDescriptions = @{ ... }` (lignes 231-248). Ce hashtable n'est référencé nulle part ailleurs dans le fichier : les descriptions qu'il contenait n'ont jamais été affichées. Son contenu est repris et complété par le catalogue.

Vérifier après suppression :

```powershell
Select-String -Path .\Run-GUI.ps1 -Pattern 'moduleDescriptions'   # attendu : aucune sortie
```

- [ ] **Step 3: Remplacer les vingt SetToolTip par un câblage sur le catalogue**

Remplacer tout le bloc allant de `$toolTip = New-Object System.Windows.Forms.ToolTip` jusqu'à la dernière ligne `$toolTip.SetToolTip($cbDryRun, ...)`, ainsi que les trois `SetToolTip` des profils (lignes 303-305), par :

```powershell
# --- Infos-bulles et panneau d'aide, tous deux alimentes par config\help.fr.json ---
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.InitialDelay = 500
$toolTip.AutoPopDelay = 30000   # 5 s ne suffisaient pas a lire une explication complete

# Show-KitHelp : met a jour l'onglet Aide sans jamais le ramener au premier plan
# (pendant une execution, l'operateur regarde le journal).
function Show-KitHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    try {
        $entry = Get-HelpEntry -Catalog $script:HelpCatalog -Key $Key
        $txtHelp.Text = Format-HelpPanel -Entry $entry
    }
    catch { }   # l'aide ne doit jamais casser la GUI
}

# Table de correspondance controle -> cle d'aide.
$helpBindings = @(
    @{ Ctrl = $cbBackupData;     Key = 'option.backupdata' }
    @{ Ctrl = $cbScanDefender;   Key = 'option.scandefender' }
    @{ Ctrl = $cbRecycle;        Key = 'option.recycle' }
    @{ Ctrl = $cbWinOld;         Key = 'option.winold' }
    @{ Ctrl = $cbCache;          Key = 'option.cache' }
    @{ Ctrl = $cbOneDrive;       Key = 'option.onedrive' }
    @{ Ctrl = $cbOem;            Key = 'option.oem' }
    @{ Ctrl = $cbNetReset;       Key = 'option.netreset' }
    @{ Ctrl = $cbDryRun;         Key = 'option.dryrun' }
    @{ Ctrl = $rbStd;            Key = 'account.standard' }
    @{ Ctrl = $rbKeep;           Key = 'account.keepadmin' }
    @{ Ctrl = $btnRun;           Key = 'action.run' }
    @{ Ctrl = $btnCancel;        Key = 'action.cancel' }
    @{ Ctrl = $btnReport;        Key = 'action.report' }
    @{ Ctrl = $btnCopy;          Key = 'action.copypassword' }
    @{ Ctrl = $btnDelFiche;      Key = 'action.delfiche' }
    @{ Ctrl = $btnApplyProfile;  Key = 'action.applyprofile' }
    @{ Ctrl = $btnSaveProfile;   Key = 'action.saveprofile' }
)

foreach ($b in $helpBindings) {
    $entry = Get-HelpEntry -Catalog $script:HelpCatalog -Key $b.Key
    $toolTip.SetToolTip($b.Ctrl, (Format-HelpTooltip -Entry $entry -Width 90))
    $cle = $b.Key    # capture par valeur : sans copie locale, tous les handlers verraient la derniere cle
    $b.Ctrl.Add_MouseEnter({ Show-KitHelp -Key $cle }.GetNewClosure())
}

# Politique de debloatage : l'aide depend de la valeur choisie.
$debloatKeys = @{ 'Conservateur' = 'debloat.conservative'; 'Standard' = 'debloat.standard'; 'Agressif' = 'debloat.aggressive' }
$cmbDebloat.Add_MouseEnter({
    $k = $debloatKeys[[string]$cmbDebloat.SelectedItem]
    if ($k) { Show-KitHelp -Key $k }
})
$cmbDebloat.Add_SelectedIndexChanged({
    $k = $debloatKeys[[string]$cmbDebloat.SelectedItem]
    if ($k) { Show-KitHelp -Key $k }
})

# Profils : l'aide depend du profil selectionne.
$cmbProfile.Add_MouseEnter({
    $sel = [string]$cmbProfile.SelectedItem
    if ($sel) { Show-KitHelp -Key "profile.$sel" }
})
$cmbProfile.Add_SelectedIndexChanged({
    $sel = [string]$cmbProfile.SelectedItem
    if ($sel) { Show-KitHelp -Key "profile.$sel" }
})

# Liste des modules : aide du module survole, puis du module selectionne.
$clbModules.Add_MouseMove({
    param($sender, $e)
    $idx = $clbModules.IndexFromPoint($e.Location)
    if ($idx -ge 0 -and $idx -lt $script:Modules.Count) {
        Show-KitHelp -Key ("module." + $script:Modules[$idx].Id)
    }
})
$clbModules.Add_SelectedIndexChanged({
    $idx = $clbModules.SelectedIndex
    if ($idx -ge 0 -and $idx -lt $script:Modules.Count) {
        Show-KitHelp -Key ("module." + $script:Modules[$idx].Id)
    }
})
```

- [ ] **Step 4: Basculer sur le journal au lancement**

Dans le handler du bouton LANCER, juste après l'appel à `Build-Queue`, ajouter :

```powershell
    $script:Tabs.SelectedTab = $script:TabLog   # l'operateur suit le deroule, pas l'aide
```

- [ ] **Step 5: Vérifier parse et encodage**

Run: `.\tests\Test-KitParse.ps1 -CI ; .\tests\Test-KitEncoding.ps1 -CI`
Expected: 0 erreur, 0 violation.

- [ ] **Step 6: Vérifier le comportement à l'écran**

Run: `.\Lancer-Demo.bat`
Expected, dans l'ordre :
1. survoler `03 Debloat` dans la liste : l'onglet Aide affiche le titre, ce que fait le module, ce qui est protégé, la réversibilité, la durée et le cas où le décocher ;
2. laisser la souris immobile sur la case `Supprimer Windows.old` : l'infobulle apparaît, tient sur plusieurs lignes et se termine par le renvoi vers l'onglet Aide ;
3. changer la politique de débloatage : l'onglet Aide suit la valeur choisie ;
4. cliquer LANCER : l'affichage bascule sur Journal et le déroulé simulé s'affiche.

Fermer la fenêtre.

- [ ] **Step 7: Commit**

```bash
git add Run-GUI.ps1
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "feat: infobulles et panneau d aide alimentes par le catalogue"
```

---

### Task 7: Des profils qui tiennent leur promesse

**Files:**
- Modify: `lib/Common.ps1` (`Read-KitProfile` vers la ligne 441, `Build-ModuleArgList` vers la ligne 512, nouvelle fonction `Remove-KeptEntries`)
- Modify: `modules/12-Startup.ps1:12-17` et la boucle de désactivation
- Modify: `Run-GUI.ps1` (`Build-Queue`, `Set-GuiFromProfile`, `Get-GuiProfileObject`)
- Modify: `config/profiles/gamer.json`, `config/profiles/senior.json`, `config/profiles/standard.json`
- Test: `tests/Common.Tests.ps1`

**Interfaces:**
- Consumes: `Get-StartupMatch` (déjà présent dans `lib/Common.ps1` ligne 700).
- Produces: `Remove-KeptEntries -Blacklist <object[]> -KeepPatterns <string[]>` renvoie un tableau d'entrées filtré ; `Build-ModuleArgList` produit `-KeepPatterns "a,b,c"` pour le module 12 ; `12-Startup.ps1` accepte `[string]$KeepPatterns`.

- [ ] **Step 1: Écrire les tests qui échouent**

Ajouter à `tests/Common.Tests.ps1` :

```powershell
Describe 'Remove-KeptEntries' {
    BeforeAll {
        $script:Bl = @(
            [PSCustomObject]@{ match = 'Steam';             label = 'Steam autostart (optionnel)' }
            [PSCustomObject]@{ match = 'EpicGamesLauncher'; label = 'Epic Games Launcher' }
            [PSCustomObject]@{ match = 'AdobeARM';          label = 'Adobe Reader/Acrobat Updater' }
        )
    }

    It 'retire les entrees preservees par le profil' {
        $r = Remove-KeptEntries -Blacklist $script:Bl -KeepPatterns @('Steam', 'EpicGamesLauncher')
        @($r).Count | Should -Be 1
        $r[0].match | Should -Be 'AdobeARM'
    }

    It 'compare sans tenir compte de la casse' {
        $r = Remove-KeptEntries -Blacklist $script:Bl -KeepPatterns @('steam')
        @($r).match | Should -Not -Contain 'Steam'
    }

    It 'renvoie la liste entiere si aucun motif' {
        @(Remove-KeptEntries -Blacklist $script:Bl -KeepPatterns @()).Count   | Should -Be 3
        @(Remove-KeptEntries -Blacklist $script:Bl -KeepPatterns $null).Count | Should -Be 3
    }

    It 'ignore les motifs vides sans tout supprimer' {
        @(Remove-KeptEntries -Blacklist $script:Bl -KeepPatterns @('', '  ')).Count | Should -Be 3
    }
}

Describe 'Build-ModuleArgList module 12' {
    It 'transmet les motifs preserves' {
        $a = Build-ModuleArgList -Id '12' -Options @{ StartupKeep = @('Steam', 'Discord') }
        ($a -join ' ') | Should -Match '-KeepPatterns Steam,Discord'
    }

    It 'ne transmet rien sans motif' {
        (Build-ModuleArgList -Id '12' -Options @{}) -join ' ' | Should -Not -Match 'KeepPatterns'
    }
}

Describe 'Read-KitProfile champs de profil etendus' {
    It 'lit Description et StartupKeep' {
        $tmp = Join-Path $env:TEMP "profil-$(New-Guid).json"
        '{ "Description": "Profil de test", "StartupKeep": ["Steam"], "Debloat": "Conservative" }' |
            Set-Content -Path $tmp -Encoding UTF8
        $p = Read-KitProfile -Path $tmp
        $p.Description | Should -Be 'Profil de test'
        @($p.StartupKeep) | Should -Contain 'Steam'
        Remove-Item $tmp -Force
    }

    It 'applique des valeurs par defaut vides pour un profil ancien' {
        $tmp = Join-Path $env:TEMP "profil-$(New-Guid).json"
        '{ "Debloat": "Standard" }' | Set-Content -Path $tmp -Encoding UTF8
        $p = Read-KitProfile -Path $tmp
        $p.Description | Should -Be ''
        @($p.StartupKeep).Count | Should -Be 0
        Remove-Item $tmp -Force
    }
}
```

- [ ] **Step 2: Lancer pour vérifier l'échec**

Run: `pwsh -c "Invoke-Pester .\tests\Common.Tests.ps1 -Output Detailed"`
Expected: FAIL, `Remove-KeptEntries` n'est pas reconnue.

- [ ] **Step 3: Ajouter Remove-KeptEntries à lib/Common.ps1**

Juste après `Get-StartupMatch` (vers la ligne 715) :

```powershell
# ---------------------------------------------------------------------------
# Remove-KeptEntries : retire de la liste noire les entrees qu'un profil
# preserve. Le profil gamer desactivait le demarrage automatique de Steam et
# d'Epic alors que son nom promet l'inverse. Pur.
# ---------------------------------------------------------------------------
function Remove-KeptEntries {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Blacklist,
        [AllowNull()][string[]]$KeepPatterns
    )
    if ($null -eq $Blacklist) { return @() }
    $motifs = @($KeepPatterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($motifs.Count -eq 0) { return $Blacklist }

    return @($Blacklist | Where-Object {
        $entry = $_
        $garde = $false
        foreach ($m in $motifs) {
            $rx = [regex]::Escape($m)
            if (($entry.match -and $entry.match -match "(?i)$rx") -or
                ($entry.label -and $entry.label -match "(?i)$rx")) { $garde = $true ; break }
        }
        -not $garde
    })
}
```

- [ ] **Step 4: Étendre Read-KitProfile**

Dans `lib/Common.ps1`, dans `Read-KitProfile`, ajouter les deux clés au bloc `$defaults` :

```powershell
        BackupData  = $true
        ScanDefender = $true
        Description = ''
        StartupKeep = @()
```

- [ ] **Step 5: Étendre Build-ModuleArgList**

Dans le `switch ($Id)`, ajouter ce cas après `'09'` :

```powershell
        '12' {
            $keep = @($Options['StartupKeep'] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($keep.Count -gt 0) { $a += @('-KeepPatterns', ($keep -join ',')) }
        }
```

- [ ] **Step 6: Relancer les tests**

Run: `pwsh -c "Invoke-Pester .\tests\Common.Tests.ps1 -Output Detailed"`
Expected: PASS, au moins 288 tests.

- [ ] **Step 7: Consommer le paramètre dans le module 12**

Dans `modules/12-Startup.ps1`, étendre le bloc `param` :

```powershell
param(
    [switch]$WhatIf,
    [string]$Profile = 'Standard',
    [switch]$Force,
    [switch]$Unattended,
    [string]$KeepPatterns = ''
)
```

Puis, juste après le bloc qui charge `$blacklist` et avant le test `if ($blacklist.Count -eq 0)` :

```powershell
if (-not [string]::IsNullOrWhiteSpace($KeepPatterns)) {
    $motifs  = @($KeepPatterns -split ',' | ForEach-Object { $_.Trim() })
    $avant   = @($blacklist).Count
    $blacklist = @(Remove-KeptEntries -Blacklist $blacklist -KeepPatterns $motifs)
    $preserves = $avant - @($blacklist).Count
    Write-KitLog -Message "Profil : $preserves entree(s) de la liste noire preservee(s) ($($motifs -join ', '))." -Level 'INFO'
}
```

- [ ] **Step 8: Transmettre le profil depuis la GUI**

Dans `Run-GUI.ps1`, déclarer l'état à côté des autres variables `$script:` :

```powershell
$script:ProfileStartupKeep = @()
$script:ProfileDescription = ''
```

Dans `Set-GuiFromProfile`, mémoriser les deux valeurs lues :

```powershell
    $script:ProfileStartupKeep = @($Profile.StartupKeep)
    $script:ProfileDescription = [string]$Profile.Description
```

Dans `Get-GuiProfileObject`, conserver les deux champs à l'enregistrement, sans quoi un profil réenregistré depuis la GUI perdrait sa description et ses démarrages préservés :

```powershell
        Description = $script:ProfileDescription
        StartupKeep = $script:ProfileStartupKeep
```

Dans `Build-Queue`, ajouter la clé au hashtable `$options` :

```powershell
        StartupKeep   = $script:ProfileStartupKeep
```

- [ ] **Step 9: Réécrire les trois profils livrés**

`config/profiles/gamer.json` :

```json
{
  "Description": "Machine de jeu : lanceurs conserves au demarrage, compte administrateur garde, debloatage prudent.",
  "StartupKeep": ["Steam", "EpicGamesLauncher", "Discord", "GeForce", "Battle.net"],
  "Debloat": "Conservative",
  "KeepAdmin": true,
  "Recycle": false,
  "WinOld": false,
  "Cache": false,
  "OneDrive": false,
  "Oem": false,
  "NetReset": false,
  "BackupData": true,
  "ScanDefender": true,
  "Modules": {
    "00": true, "01": true, "02": true, "03": true, "04": true,
    "05": true, "06": true, "07": true, "08": true, "09": true,
    "11": true, "12": true, "13": true, "15": false, "10": true
  }
}
```

`config/profiles/senior.json` :

```json
{
  "Description": "Poste le plus simple possible : demarrage allege au maximum, rien de connu n'est retire.",
  "StartupKeep": [],
  "Debloat": "Conservative",
  "KeepAdmin": false,
  "Recycle": false,
  "WinOld": false,
  "Cache": false,
  "OneDrive": false,
  "Oem": false,
  "NetReset": false,
  "BackupData": true,
  "ScanDefender": true,
  "Modules": {
    "00": true, "01": true, "02": true, "03": true, "04": true,
    "05": true, "06": true, "07": true, "08": true, "09": true,
    "11": true, "12": true, "13": true, "15": false, "10": true
  }
}
```

`config/profiles/standard.json` :

```json
{
  "Description": "Remise en etat complete et equilibree. Profil a utiliser par defaut.",
  "StartupKeep": [],
  "Debloat": "Standard",
  "KeepAdmin": false,
  "Recycle": false,
  "WinOld": false,
  "Cache": false,
  "OneDrive": false,
  "Oem": false,
  "NetReset": false,
  "BackupData": true,
  "ScanDefender": true,
  "Modules": {
    "00": true, "01": true, "02": true, "03": true, "04": true,
    "05": true, "06": true, "07": true, "08": true, "09": true,
    "11": true, "12": true, "13": true, "15": true, "10": true
  }
}
```

- [ ] **Step 10: Vérifier le comportement de bout en bout**

```powershell
powershell -ExecutionPolicy Bypass -File .\modules\12-Startup.ps1 -WhatIf -KeepPatterns "Steam,EpicGamesLauncher"
```

Expected: le journal affiche `Profil : 2 entree(s) de la liste noire preservee(s)`, et aucune ligne `WHATIF: desactiverait` ne mentionne Steam ou Epic.

- [ ] **Step 11: Contrôles CI et commit**

```powershell
.\tests\Test-KitParse.ps1 -CI ; .\tests\Test-KitEncoding.ps1 -CI ; .\tests\Test-KitAnonymity.ps1 -CI
```

```bash
git add lib/Common.ps1 modules/12-Startup.ps1 Run-GUI.ps1 config/profiles tests/Common.Tests.ps1
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "feat: les profils d intervention preservent les demarrages qu ils annoncent"
```

---

### Task 8: Documentation, version et distribution

**Files:**
- Delete: `TOOLTIPS.md`
- Modify: `README.md` (section Captures, et nouvelle section Aide intégrée)
- Modify: `lib/Report.ps1` (`Get-KitVersion`), `tests/Common.Tests.ps1` (test de version)
- Create: `docs/RELEASE-NOTES-v2.2.0.md`
- Modify: `tools/Build-ReleaseZip.ps1` si nécessaire

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: le zip de distribution v2.2.0.

- [ ] **Step 1: Supprimer TOOLTIPS.md et le retirer de la distribution**

`TOOLTIPS.md` décrit l'état des infobulles de la v1.2, devenu faux. Le catalogue est désormais la seule source.

```powershell
git rm TOOLTIPS.md
```

Dans `tools/Build-ReleaseZip.ps1`, retirer `"TOOLTIPS.md"` de la liste `$include`.

- [ ] **Step 2: Documenter l'aide intégrée dans le README**

Ajouter après la section `## Captures` :

```markdown
## Aide intégrée

Le cockpit affiche deux onglets à droite : **Aide** et **Journal**. Survoler un module ou une
option affiche dans l'onglet Aide ce qu'elle fait, ce qui est protégé, si l'action est réversible,
combien de temps elle prend et dans quel cas la décocher. L'infobulle donne le résumé, l'onglet
donne le détail.

Le contenu vit dans `config/help.fr.json`, seule source de vérité. Un contrôle ajouté à
l'interface sans entrée correspondante fait échouer la CI (`tests/Help.Tests.ps1`).
```

- [ ] **Step 3: Passer la version à v2.2**

Dans `lib/Report.ps1` : `function Get-KitVersion { return 'v2.2' }`
Dans `tests/Common.Tests.ps1` : `Get-KitVersion | Should -Be 'v2.2'`
Dans `tools/Build-ReleaseZip.ps1` : `[string]$Version = "2.2.0"`

- [ ] **Step 4: Écrire les notes de version**

Créer `docs/RELEASE-NOTES-v2.2.0.md` :

```markdown
# PC-Refresh-Kit v2.2.0

**Date :** 2026-08-14
**Licence :** MIT

## Résumé

Le cockpit explique enfin ce qu'il fait. Chaque module et chaque option disposent d'une aide
complète, consultable sans quitter la fenêtre, et les profils d'intervention tiennent la promesse
de leur nom.

## Aide intégrée

- Onglet **Aide** à côté du journal, au premier plan au démarrage
- 40 rubriques : les 16 modules, les 9 options, les 3 politiques de débloatage, les 2 modes de
  compte, les 3 profils et les 7 actions
- Chaque rubrique dit ce que fait l'élément, ce qui est protégé, si l'action est réversible,
  combien de temps elle prend et quand la décocher
- Infobulles régénérées depuis la même source, affichées 30 secondes au lieu de 5
- Contenu isolé dans `config/help.fr.json`, modifiable sans toucher au code

## Profils d'intervention

Les trois profils livrés étaient presque identiques : `gamer` ne se distinguait de `standard` que
par la réinitialisation réseau désactivée, et laissait la liste noire couper le démarrage
automatique de Steam et d'Epic Games Launcher.

- Nouveau champ `StartupKeep` : le profil déclare les démarrages automatiques à préserver
- Nouveau champ `Description` : affiché dans l'onglet Aide
- `gamer` conserve Steam, Epic, Discord, GeForce et Battle.net, garde le compte administrateur et
  passe en débloatage prudent
- `senior` allège le démarrage au maximum en politique prudente
- `standard` reste le profil complet et équilibré
- Les profils enregistrés avec une version antérieure continuent de fonctionner

## Divers

- `TOOLTIPS.md` supprimé, remplacé par le catalogue
- Suppression d'un hashtable de descriptions de modules jamais affiché

## Site du projet

https://kit.trimko.com
```

- [ ] **Step 5: Construire et vérifier le zip**

```powershell
.\tools\Build-ReleaseZip.ps1
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path .\dist\PC-Refresh-Kit-v2.2.0.zip))
$n = $z.Entries.FullName ; $z.Dispose()
"help.fr.json present : $($n -contains 'config/help.fr.json')"     # attendu : True
"Help.ps1 present     : $($n -contains 'lib/Help.ps1')"            # attendu : True
"specs exclues        : $(($n | Where-Object { $_ -like '*superpowers*' }).Count)"  # attendu : 0
"TOOLTIPS absent      : $(-not ($n -contains 'TOOLTIPS.md'))"      # attendu : True
```

- [ ] **Step 6: Validation complète**

```powershell
pwsh -c "Invoke-Pester .\tests -Output Detailed"
.\tests\Test-KitParse.ps1 -CI ; .\tests\Test-KitEncoding.ps1 -CI ; .\tests\Test-KitAnonymity.ps1 -CI
```

Expected: tous les tests passent, 0 erreur de parse, 0 violation d'encodage, 0 violation d'anonymat.

- [ ] **Step 7: Commit et push**

```bash
git add -A
git -c user.name=Trimko -c user.email=contact@trimko.com commit -m "docs: notes de version v2.2.0 et documentation de l aide integree"
git push public public-main:main
```

- [ ] **Step 8: Vérifier la CI distante**

```powershell
gh run list --repo trimko-labs/PC-Refresh-Kit --limit 1
```

Expected: `completed success`. En cas d'échec, lire le journal du run avant toute autre action.

---

## Après le plan

Une fois les huit tâches livrées, deux décisions restent ouvertes, hors périmètre de ce plan :

1. **Publier la release GitHub v2.2.0** avec le zip produit en Task 8. Le site kit.trimko.com pointe sur `releases/latest` et affichera automatiquement la nouvelle version.
2. **Porter les correctifs sur la branche privée `master`**, dont l'historique est disjoint de `public-main`. Concerne le correctif du rapport TXT, celui du script de distribution, et ce chantier.

