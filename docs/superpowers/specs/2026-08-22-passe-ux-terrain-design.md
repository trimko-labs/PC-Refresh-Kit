# Passe UX terrain v2.3 - spec design

Date : 2026-08-22. Statut : validée (design présenté par sections, quatre choix actés,
y compris le défaut « standard appliqué au démarrage »).

## 1. Origine

Premier test terrain de la v2.2 : six griefs UX remontés par l'opérateur, tous vérifiés
fondés dans le code. La vague v2.2 avait validé le rendu (captures figées, panneau d'aide pré-rempli de
force pour la photo) mais jamais l'expérience (aucun parcours utilisateur joué, spec
d'apparence et pas d'interaction). La v2.3 corrige les six griefs ET ajoute le garde-fou
qui manquait.

Les six griefs et leur cause vérifiée :

| # | Grief | Cause dans le code |
|---|-------|--------------------|
| G1 | Journal vide, on ne comprend pas à quoi il sert | Onglet Journal présent dès l'ouverture, rien n'y écrit avant le run (Run-GUI.ps1:338, :365-366) |
| G2 | Les cases ne bougent pas quand on choisit un profil | SelectedIndexChanged n'affiche que l'aide (:698) ; seules Appliquer (:1420) bouge les cases ; rien ne le signale |
| G3 | « Rapport numéro 10 » en fin de liste, numérotation illisible | IDs de fichiers internes affichés dans l'ordre d'exécution : 00..09, 11, 12, 13, 15, 10 - saut du 14, 10 en dernier (:36-52, Theme New-KitModuleRow :450) |
| G4 | « Intervention réelle » incompréhensible | Quatre vocabulaires pour un concept : « Mode dry-run (-WhatIf) » (case :276), « SIMULATION / INTERVENTION RÉELLE » (badge Theme :404-409, résumé :128), « [DRY-RUN] / [RUN RÉEL] » (titre :1140) |
| G5 | Aide au survol impraticable (écrasée en route, scroll impossible) | MouseEnter remplace le panneau instantanément, partout (:680, :685, :695, :707) ; zéro délai, zéro gel, zéro épinglage ; le panneau est SOUS les cartes, tout trajet le traverse |
| G6 | Pas fluide, pas cohérent, pas logique | Somme des cinq + noms de modules en anglais + textes d'aide en jargon interne (« ne fait que positionner les cases », help.fr.json:272) |

## 2. Décisions actées

1. **Profils : application immédiate** à la sélection, entrée « (personnalisé) », suppression
   du bouton Appliquer. Au démarrage, le profil standard est appliqué d'office (changement de
   défaut assumé : avant, tout coché sans nom).
2. **Liste : étapes 1 à 15 + noms français**, IDs techniques réservés aux logs et au rapport.
3. **Aide : délai + gel + épinglage au clic** (l'option la plus complète a été choisie).
4. **Livraison : vague complète** (spec, plan, subagents, revues, captures, release v2.3.0)
   avec le nouveau garde-fou de parcours scripté.

Tranchés sans question (pas deux bonnes réponses) : journal ajouté au lancement du run ;
vocabulaire unique « Simulation / Intervention réelle » partout.

## 3. Chantier A - profils à application immédiate

### Comportement

- Sélectionner un profil dans `$cmbProfile` applique immédiatement : `Read-KitProfile` ->
  `Set-GuiFromProfile` -> `$script:AppliedProfileName = <nom>` -> `Update-KitActionSummary`,
  puis affiche son aide (`Show-KitProfileHelp`, comportement conservé).
- Une entrée sentinelle « (personnalisé) » vit en DERNIÈRE position de la liste, toujours
  présente. La sélectionner à la main ne change AUCUNE case : elle représente l'état courant.
- Dès qu'un contrôle piloté par le profil change alors qu'un profil nommé est sélectionné,
  la ComboBox bascule sur « (personnalisé) » (les cases ne bougent pas). Contrôles pilotés =
  exactement le périmètre de `Set-GuiFromProfile` (:1032) : les 15 cases modules,
  `$cmbDebloat`, `$rbKeep`/`$rbStd`, `$cbRecycle`, `$cbWinOld`, `$cbCache`, `$cbOneDrive`,
  `$cbOem`, `$cbNetReset`, `$cbBackupData`, `$cbScanDefender`. `$cbDryRun` n'est PAS dans le
  profil : il ne déclenche pas la bascule.
- Garde anti-réentrance `$script:ApplyingProfile` : pendant `Set-GuiFromProfile`, les
  CheckedChanged/SelectedIndexChanged déclenchés par l'application ne basculent pas sur
  « (personnalisé) » ; et la bascule programmatique vers « (personnalisé) » ne repasse pas
  par l'application de profil.
- Résumé de barre : quand « (personnalisé) » est actif, `Get-RunSummaryText` reçoit
  `personnalisé` (affiche « - profil personnalisé »). `$script:AppliedProfileName` garde sa
  sémantique : nom du dernier profil dont l'état est fidèle, ou « personnalisé ».
- `Build-Queue` et l'enregistrement de profil lisent l'état des contrôles (inchangé) ;
  `$script:ProfileStartupKeep`/`$script:ProfileDescription` suivent le profil appliqué et
  survivent à la bascule « (personnalisé) » (les motifs préservés restent actifs : ils font
  partie de l'état courant, `Get-GuiProfileObject` les capture déjà).
- `$btnApplyProfile` disparaît : création (:150-155), helpBindings (:672), verrou
  Set-KitPrepareEnabled (:1093), handler (:1420-1447), rubrique `action.applyprofile` du
  catalogue. `$btnSaveProfile` reprend la largeur libérée (pleine largeur 276, même Y).
- « Enregistrer comme profil » : après enregistrement réussi, le nouveau profil devient la
  sélection courante de la ComboBox (comportement actuel de repeuplement conservé, mais la
  sélection ne doit PAS réappliquer ce qu'on vient de capturer - garde réentrance).
- Démarrage : `Update-ProfileComboBox` sélectionne « standard » (fallback : premier profil
  si standard.json absent ; « (personnalisé) » si aucun profil) et l'APPLIQUE. Le panneau
  d'aide montre alors la rubrique du profil appliqué (le commentaire :1102-1106 et la repose
  de l'invite deviennent obsolètes). En -UiPreview : rien à forcer, standard est déjà la
  sélection naturelle.
- Pendant un run : `$cmbProfile` reste verrouillée (Set-KitPrepareEnabled, inchangé).

### Textes

Les trois rubriques `profile.standard|senior|gamer` de config/help.fr.json sont réécrites :
- `what` commence par « Sélectionner ce profil coche immédiatement... » (le comportement
  redevient celui que le texte décrit) ;
- `reversible` : « Oui : choisir un autre profil ou modifier une case reprend la main.
  Aucun réglage n'est écrit sur le disque. » (remplace « Sans objet, un profil ne fait que
  positionner les cases de l'interface. ») ;
- une rubrique `profile.custom` est ajoutée pour l'entrée « (personnalisé) » : « Votre
  sélection actuelle. Cette entrée apparaît dès que vous modifiez une case après avoir
  choisi un profil. Utilisez Enregistrer comme profil pour la conserver. »

## 4. Chantier B - étapes 1 à 15, noms français

- `$script:Modules` (:36-52) gagne un champ `Label` (français). Correspondance fixe :

| Étape | Id | Label français | Étape | Id | Label français |
|-------|----|----------------|-------|----|----------------|
| 1 | 00 | Diagnostic | 9  | 08 | Comptes |
| 2 | 01 | Sauvegarde | 10 | 09 | Confort |
| 3 | 02 | Antivirus | 11 | 11 | Nettoyage profond |
| 4 | 03 | Désencombrement | 12 | 12 | Démarrage |
| 5 | 04 | Confidentialité | 13 | 13 | Navigateurs |
| 6 | 05 | Mises à jour | 14 | 15 | Réseau |
| 7 | 06 | Logiciels | 15 | 10 | Rapport |

- `New-KitModuleRow` reçoit le numéro d'étape (1..15, position dans `$script:Modules`) pour
  `$idLbl` et le `Label` français pour `$nameLbl`. Le paramètre garde des noms neutres
  (`-Index`, `-Name`) ; l'Id technique ne s'affiche plus nulle part dans la fenêtre.
- Les titres des 15 rubriques `module.NN` de help.fr.json deviennent
  « Étape N - <Label français> - <complément actuel> » (ex. « Étape 15 - Rapport
  d'intervention »). Le corps des rubriques est relu : toute mention « module NN » devient
  « étape N » ou le nom français (grep `module [0-9]{2}` sur help.fr.json).
- Ne changent PAS : noms de fichiers modules/NN-*.ps1, logs (`[10-Report]`...), rapport
  HTML, tableau des modules du README (il documente les fichiers ; on y ajoute une phrase :
  « L'interface numérote les étapes 1 à 15 dans l'ordre d'exécution. »).
- Largeurs vérifiées : « Désencombrement » et « Nettoyage profond » tiennent dans la ligne
  (nameLbl x=44, panel 276, détail droit ~60 px) ; à contrôler sur capture à la taille
  minimale 1000x576.

## 5. Chantier C - aide praticable (délai + gel + épinglage)

### Mécanique

Trois états, par priorité décroissante :
1. **Épinglé** (`$script:HelpPinned`) : rien ne remplace le panneau, ni survol ni sélection,
   sauf dés-épinglage (re-clic sur l'épingle, ou Échap) ou clic explicite sur l'épingle.
2. **Gelé** (`$script:HelpFrozen`) : souris à l'intérieur de l'onglet Aide (MouseEnter de
   `$script:TabHelp`/`$txtHelp` -> gelé ; MouseLeave du TabControl -> dégelé). Les
   remplacements par survol sont ignorés ; lecture et scroll tranquilles.
3. **Délai anti-transit** : un survol ne remplace le panneau qu'après 350 ms de survol
   stable. Un `System.Windows.Forms.Timer` unique (`$script:HelpHoverTimer`, Interval 350)
   plus `$script:PendingHelpKey` : chaque MouseEnter écrase la clé en attente et relance le
   timer ; le Tick affiche puis s'arrête. Traverser des cartes en route vers le panneau
   n'écrase plus la lecture.

### Décision pure et testable

Fonction pure dans lib/Help.ps1 (avec Get-HelpEntry/Format-HelpPanel) :
`Get-KitHelpDecision -Source Hover|Direct -Pinned <bool> -Frozen <bool>` -> `Defer` (Hover,
ni épinglé ni gelé : passer par le timer), `Show` (Direct non épinglé : remplacer tout de
suite), `Ignore` (épinglé, ou Hover gelé). `Direct` = demandes non-survol : sélection d'un
profil, changement de politique de débloatage au clavier, invite initiale. Couverte par
Pester (table de vérité complète, 8 cas).

Les handlers appellent une unique `Request-KitHelp -Key <k> -Source Hover|Direct` qui
applique la décision (timer, Show-KitHelp direct, ou rien). Show-KitHelp (:618) reste
l'écrivain final unique du panneau.

### Épingle

- Petit bouton dans l'en-tête de l'onglet Aide, aligné à droite AU-DESSUS du RichTextBox
  (bandeau de 22 px dans la TabPage, pas dans le flux du texte) : glyphe Segoe MDL2 E718
  (Pin) / E77A (Unpin) si `$script:Mdl2`, repli texte « Épingler » / « Épinglé ». La
  disponibilité RÉELLE des deux glyphes dans segmdl2.ttf est vérifiée par GlyphTypeface
  AVANT usage (leçon v2.2 : U+25CB absent, EA3A choisi sur preuve).
- État épinglé : fond AccentDark, texte blanc (badge actif) ; tooltip explicite.
- Échap dés-épingle : `$form.KeyPreview = $true` + handler KeyDown Escape. Vérifié : le
  formulaire n'a pas de CancelButton, Échap est libre.
- L'épinglage survit aux changements de phase ; un nouveau run ne dés-épingle pas (le
  panneau d'aide reste consultable pendant le run, comportement v2.2 conservé).

## 6. Chantier D - journal au bon moment

- Au démarrage, `$script:Tabs` ne contient QUE `$script:TabHelp` (« Aide »). La ligne
  `$script:Tabs.TabPages.Add($script:TabLog)` (:366) quitte l'initialisation.
- Petite fonction `Show-KitJournalTab` : ajoute `$script:TabLog` s'il est absent puis
  `SelectedTab = $script:TabLog`. Appelée au lancement du run (à l'endroit qui sélectionne
  déjà le Journal, :1177). Idempotente (garde `TabPages.Contains`, même pattern que
  TabClose :948-951).
- Le Journal reste ensuite présent : clôture, « Préparer une nouvelle intervention »
  (l'historique du run précédent reste consultable, comportement v2.2 conservé).
- L'invite du panneau d'aide reste la seule zone texte visible en préparation.

## 7. Chantier E - un seul vocabulaire de mode

Couple unique : « Simulation / Intervention réelle ». Les quatre surfaces :

1. Case (:276) : « Simulation : montrer ce qui serait fait, sans rien modifier » (remplace
   « Mode dry-run (-WhatIf) »). AutoSize déjà posé, largeur de carte à vérifier sur capture.
2. Badge bandeau (Theme :404-409) : « SIMULATION » / « INTERVENTION RÉELLE » - inchangés,
   ils deviennent compréhensibles par la case qui les définit.
3. Titre de fenêtre (:68, :1140) : préfixes « [SIMULATION] » / « [INTERVENTION RÉELLE] »
   (remplacent « [DRY-RUN] » / « [RUN RÉEL] »). README section correspondante mise à jour.
4. Bouton principal (:571) : « ▶  LANCER LA SIMULATION » quand `$cbDryRun.Checked`, sinon
   « ▶  LANCER L'INTERVENTION ». Rafraîchi par CheckedChanged de la case ET à l'entrée en
   phase Prepare. La barre d'action recalcule son layout (largeur du texte change :
   Update-KitActionBarLayout).

Câblage à compléter (bug latent v2.2 découvert en conception) : `$cbDryRun` et les six
cases sensibles doivent rafraîchir le résumé en direct (Add_CheckedChanged ->
Update-KitActionSummary) si ce n'est pas déjà le cas - à inventorier en implémentation ;
le résumé lit déjà leurs valeurs (:861-867) mais le déclenchement doit exister pour
chacune.

L'aide `option.dryrun` est réécrite pour définir les deux termes (« En simulation, chaque
étape décrit ce qu'elle ferait sans rien modifier. En intervention réelle, les actions
sont appliquées. »). `Lancer-Demo.bat` (déjà « intervention reelle ») et le README suivent.

## 8. Chantier F - garde-fou : parcours utilisateur scripté

### Mode SelfTest

`Run-GUI.ps1 -SelfTest` : construit toute la GUI (aucun ShowDialog, aucune élévation,
aucune écriture disque hors sortie console), déroule le parcours, imprime `[SELFTEST]`
par assertion, exit 0/1. Les assertions lisent les états LOGIQUES (Checked, SelectedItem,
Items, TabPages.Contains, .Text) - jamais `Visible` (getter = visibilité effective, faux
sans affichage : piège documenté v2.2).

Parcours minimal (ordre imposé) :
1. Démarrage : sélection = « standard », cases conformes à config/profiles/standard.json,
   résumé contient « profil standard », `TabPages` ne contient pas le Journal, dernière
   entrée de la ComboBox = « (personnalisé) ».
2. Sélection « senior » : cases conformes à senior.json, résumé « profil senior ».
3. Toggle d'une case module : ComboBox = « (personnalisé) », résumé « profil personnalisé »,
   cases inchangées par la bascule.
4. Re-sélection « standard » : cases reviennent conformes.
5. Divergence par option sensible (cbRecycle) : « (personnalisé) » à nouveau.
6. Étapes : ligne 1 affiche « 1 » + « Diagnostic », dernière ligne « 15 » + « Rapport ».
7. Mode : cocher `$cbDryRun` -> bouton contient « SIMULATION » ; décocher -> « INTERVENTION ».
8. Journal : `Show-KitJournalTab` -> l'onglet est présent et sélectionné.
9. Aide pure : la table de vérité de `Get-KitHelpDecision` est du ressort de Pester
   (Theme.Tests), pas du SelfTest.

### Intégration

- CI locale : nouvelle étape après Test-KitParse (Windows PowerShell 5.1 :
  `powershell -File Run-GUI.ps1 -SelfTest`).
- CI GitHub : même étape dans le workflow (windows-latest, session desktop : WinForms sans
  ShowDialog y fonctionne ; en cas d'impossibilité d'environnement, l'étape échoue
  EXPLICITEMENT - jamais de faux vert silencieux).
- Pester : table de vérité Get-KitHelpDecision ; tests existants adaptés (libellés, retrait
  d'Appliquer, résumé « personnalisé »).

## 9. Non-buts

- Pas de refonte de layout (positions des cartes, colonne, onglets inchangées hors retrait
  du bouton Appliquer et bandeau épingle).
- Rapport HTML et logs : libellés techniques inchangés (réévalué plus tard si besoin).
- Pas de nouvelle rubrique d'aide au-delà de profile.custom et des réécritures listées.
- Pas de changement des modules eux-mêmes (aucun .ps1 de modules/ touché).
- vendor/TelemetryGuard intouchable.

## 10. Contraintes globales (héritées, inchangées)

- PowerShell 5.1, WinForms, `Set-StrictMode -Version Latest` ; contrats collections par
  fonction (return nu + appelant @() vs return ,@()) respectés à l'identique.
- BOM UTF-8 + newline finale + zéro U+2014/U+2013 sur tous les fichiers suivis (CI
  Encoding) ; accents français corrects dans tout texte visible.
- Messages de commit ASCII sans accents ni apostrophes (hook).
- Anonymat dépôt public (Test-KitAnonymity -CI, et -History avant toute publication).
- JAMAIS exécuter le kit en réel sur ce PC ; jamais élever ; jamais cliquer LANCER hors
  -UiPreview ; validation visuelle par -UiPreview + tools/Capture-Fenetre.ps1 (powershell
  5.1, curseur écarté en (4,4)).
- Glyphes Segoe MDL2 : présence vérifiée par GlyphTypeface avant tout nouvel usage.
- 365 tests Pester existants : tous verts en fin de chaque tâche (adaptés si le
  comportement spécifié ici les contredit).

## 11. Critères d'acceptation (un par grief)

- G1 : à l'ouverture, un seul onglet « Aide » ; le Journal apparaît sélectionné au clic
  LANCER (SelfTest 1 et 8).
- G2 : sélectionner « senior » change les cases à l'écran sans autre action (SelfTest 2) ;
  plus aucun bouton Appliquer dans la fenêtre.
- G3 : la colonne affiche 1..15 dans l'ordre, Rapport = étape 15, zéro saut (SelfTest 6 +
  capture).
- G4 : le mot « dry-run » n'apparaît plus dans la fenêtre ; la case définit la simulation
  en français ; titre, badge, bouton et résumé utilisent le même couple de termes (grep sur
  Run-GUI.ps1 + capture).
- G5 : traverser la fenêtre ne change pas le panneau (délai) ; lire et scroller dans le
  panneau ne le change jamais (gel) ; une rubrique épinglée reste affichée pendant qu'on
  coche ailleurs (Pester sur la décision + validation visuelle).
- G6 : zéro nom anglais et zéro jargon dans la fenêtre (relecture des textes sur captures,
  aide affichée écran par écran) ; vocabulaire unique vérifié par grep.
