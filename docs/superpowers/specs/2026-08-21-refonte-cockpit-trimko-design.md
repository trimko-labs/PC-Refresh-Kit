# Refonte cockpit Trimko + documentation intégrée - conception

Date : 2026-08-21
Version du kit visée : 2.2.0
Design validé par maquettes interactives (brainstorming + grill du 2026-08-21).

Articulation avec `2026-08-14-documentation-integree-design.md` : cette conception ABSORBE la v2.2 documentation intégrée. Ses sections 4 (architecture aide), 6 (infobulles), 7 (refonte des profils), 8 (contenu à rédiger), 9 (tests aide) et 10 (distribution) restent le contrat de référence, inchangées. Sa section 5 (intégration dans le cockpit) est remplacée par le présent document. Les deux documents se lisent ensemble ; en cas de contradiction sur l'interface, celui-ci prime.

## 1. Problème

Le cockpit est fonctionnellement solide (mécanique de run éprouvée, 242 tests Pester, StrictMode) mais visuellement du WinForms gris système intégral : aucune couleur, positions absolues, fenêtre fixe 900x840 qui déborde d'un écran 1366x768 (le laptop typique à remettre à neuf). Pour un produit publié sous la marque Trimko Labs (kit.trimko.com), démontré en rendez-vous prospect (`Lancer-Demo.bat`) et destiné à se vendre comme fiable et recommandable, l'interface est le point faible : elle ressemble à un outil interne de 2005.

Benchmark concurrence (2026-08-21) : WinUtil de Chris Titus a la puissance sans narration d'intervention ni rapport (esthétique contestée au point qu'un fork existe pour ses couleurs) ; CCleaner et les cleaners grand public ont la narration simple mais des scores gadgets et des upsells qui détruisent la confiance ; PC-Doctor a le rapport technicien payant sans élégance ni portabilité. Personne ne combine rigueur d'outil de technicien, lisibilité de produit commercial et zéro dépendance. C'est le créneau de cette refonte.

## 2. Décisions actées (ne pas rediscuter)

| Décision | Choix | Raison |
|---|---|---|
| Périmètre | Cockpit + retouches légères rapport HTML et note ; site kit.trimko.com exclu | Le rapport est déjà charté, le site est un autre repo |
| Séquencement | Fusion avec la v2.2 documentation intégrée en une seule vague | Éviter de construire le layout deux fois |
| Technologie | WinForms modernisé, flat strict | Préserver la mécanique éprouvée et la promesse zéro dépendance ; WPF = tout re-risquer ; WebView2 = dépendance absente des vieux Win10 |
| Structure | Écran zoné par phases (préparer / exécuter / clôturer), un seul écran | Le flux suit le geste de l'opérateur ; validé en maquette |
| Bouton LANCER | Barre d'action globale en pied de fenêtre, pleine largeur | Il engage toute l'intervention, pas une colonne (pattern installeur) |
| Fenêtre | Redimensionnable, défaut 1200x720, MinimumSize 1000x576 | L'actuelle déborde 1366x768 ; 1000x576 logique = 1250x720 physiques à 125 %, le pire cas réel (vieux laptop en accessibilité) |
| Mode aperçu | Paramètre -UiPreview livré et documenté | Aperçu sans admin pour contributeurs, démos sans UAC, et boucle visuelle de développement |
| Version | v2.2.0 unique (refonte + aide intégrée) | La v2.2 n'a jamais été livrée ; une seule release forte |
| Passphrase | Masquée par défaut en clôture (Afficher + Copier) | Cohérent avec la v2.1 qui l'a retirée du rapport TXT |
| Thème | Light seul | Le kit tourne chez des clients, en journée ; YAGNI |
| Marque | « Trimko Labs » affiché dans le bandeau | Le dépôt est publié sous l'identité Trimko (garde-fou d'anonymat : seuls noms de personnes, chemins nominatifs et e-mails personnels sont interdits) |

## 3. Identité visuelle

### 3.1 Palette (tokens du thème, source charte trimko.com)

| Token | Hex | Usage |
|---|---|---|
| Accent | #0d9488 | Bandeau, bouton LANCER, onglet actif, cases cochées, fill progression |
| AccentDark | #0f766e | Hover boutons primaires, labels chips aide |
| AccentPale | #99f6e4 | Sous-titre bandeau, bordure encadré passphrase |
| AccentGhost | #ccfbf1 | Texte secondaire sur fond teal, fond encadré passphrase #f0fdfa |
| Ink | #1e293b | Texte principal |
| InkSoft | #475569 | Texte secondaire |
| InkMuted | #64748b | Eyebrows, durées, texte d'état |
| Ground | #f8fafc | Fond de la zone droite et de la fenêtre |
| Card | #ffffff | Cartes, colonne intervention, barre d'action |
| Line | #e2e8f0 | Bordures 1px |
| Ok | #16a34a | État module OK |
| Warn | #d97706 | État avertissement, liseré actions sensibles, badge RÉEL |
| Err | #dc2626 | État erreur, item REBOOT, bouton suppression fiche |
| Skip | #94a3b8 | Modules ignorés, cases décochées |
| JournalBg | #0f172a | Fond du journal |

Note d'écart acté (M14) : onglets et cases à cocher restent au rendu système WinForms. Les colorer exigerait un owner-draw disproportionné au regard du gain visuel ; écart accepté.

Couleurs des niveaux du journal : reprendre EXACTEMENT celles du rapport HTML (`lib/Report.ps1`) pour la cohérence cockpit/rapport : OK #4ade80, WARN #fbbf24, ERROR #f87171, WHATIF #22d3ee, INFO #cbd5e1, heartbeat #64748b. `Get-LogLevelColor` évolue en conséquence (renvoie ces couleurs pour la GUI).

### 3.2 Typographie et glyphes

- Contrôles : Segoe UI 9.75pt ; eyebrows : Segoe UI Semibold 8.25pt majuscules ; titre bandeau : Segoe UI Semibold 12pt ; bouton LANCER : Segoe UI Semibold 10.5pt ; journal : Consolas 9pt.
- Glyphes d'état : Segoe MDL2 Assets (police native Windows 10/11, zéro fichier) : CheckMark E73E (Ok), Play E768 (Running), StatusCircleRing EA3A (cercle d'attente d'un module en file), Warning E7BA (Warn), Cancel E711 (Error), Remove E738 (Skipped). Si un glyphe manque (rendu carré), repli caractères Unicode ✓ ▶ ○ ! x -. Attention : Segoe MDL2 Assets ne contient NI le ○ (U+25CB) NI le tiret ASCII, d'où le passage par un point de code MDL2 pour ces deux états.
- Interdits absolus dans tout texte visible : em-dash U+2014, en-dash U+2013 (contrôle CI existant).

### 3.3 Anti-patterns formels

Jamais de score de santé chiffré gadget, jamais d'upsell visuel, jamais d'animation décorative, jamais de coin arrondi ni d'ombre simulée. La sobriété est le positionnement : rigueur d'outil de technicien, lisibilité de produit commercial.

## 4. Structure de l'écran

```
+----------------------------------------------------------------------+
| BANDEAU teal 46px : PC-Refresh-Kit / Trimko Labs   Machine    BADGE  |
+---------------------------+------------------------------------------+
| COLONNE INTERVENTION 290px| ZONE DROITE (par phase)                  |
|  Profil (combo+2 boutons) |  Préparer : cartes Réglages + Actions    |
|  Modules : case+id+nom    |    sensibles, puis onglets Aide/Journal  |
|  (cases -> états au run,  |  Exécuter : onglets seuls, Journal actif |
|   durée par module)       |  Clôturer : onglet Clôture ajouté et     |
|                           |    sélectionné (Journal/Aide restent)    |
+---------------------------+------------------------------------------+
| BARRE D'ACTION pleine largeur : résumé | progression | bilan + CTA   |
+----------------------------------------------------------------------+
```

### 4.1 Bandeau

Nom produit + « Trimko Labs » en sous-titre AccentPale, nom machine à droite, badge de mode : SIMULATION (fond #0f766e, bordure #2dd4bf, texte #ccfbf1), INTERVENTION RÉELLE (fond #d97706, bordure #fbbf24, texte blanc), APERÇU (fond #475569, texte #e2e8f0). Le titre de la fenêtre Windows conserve sa logique actuelle ([DRY-RUN]/[RUN RÉEL], écoulé, terminé en X).

### 4.2 Colonne intervention

Eyebrow INTERVENTION : combo profil + boutons Appliquer / Enregistrer (comportement actuel conservé, y compris interdiction pendant un run). Eyebrow MODULES (devient DÉROULÉ pendant le run) : 15 lignes custom, chacune : CheckBox (phase préparation) OU glyphe d'état (phases run/clôture), id grisé, nom, zone droite durée ou état. Modules décochés au lancement : ligne grisée, glyphe -, mention « ignoré ». Module en cours : nom en gras, durée qui vit (« en cours - 3 min 12 »).

### 4.3 Zone droite

- Préparer : carte Réglages (politique debloat, compte utilisateur, sauvegarde données, scan Defender, mode simulation) ; carte Actions sensibles (liseré gauche 3px Warn, libellé « décochées = non faites », 6 cases dont Réinitialiser le réseau avec tag rouge « non réversible ») ; en dessous, TabControl Aide / Journal, Aide sélectionné.
- Exécuter : les deux cartes se masquent, le TabControl s'étire (Dock Fill), Journal sélectionné automatiquement au LANCER. Le journal garde sa mécanique actuelle (RichTextBox, couleurs par niveau, heartbeat gris, AppendText).
- Clôturer : une TabPage Clôture est ajoutée et sélectionnée ; Journal et Aide restent consultables. Contenu Clôture : encadré passphrase (fond #f0fdfa, bordure AccentPale) avec valeur MASQUÉE (points) + boutons Afficher et Copier ; carte « Avant de rendre le PC » avec les items réels de `Get-EndChecklistItems` (dont REBOOT REQUIS en rouge si flag) ; boutons Ouvrir le rapport et Supprimer la fiche PC de la clé (rouge, comportement actuel conservé : confirmation, log, purge mémoire du mot de passe).

### 4.4 Barre d'action (pied de fenêtre, 3 états)

- Préparer : résumé recalculé à chaque changement de case ou d'option (« 14 modules sélectionnés - 0 action sensible - profil standard - SIMULATION ») + bouton LANCER L'INTERVENTION (primary). Pas de bouton Annuler affiché hors run.
- Exécuter : « Module 3/14 - 02 Antivirus » + barre de progression (fill Accent) + « écoulé 12 min 40 » + bouton Annuler (comportement actuel : kill du process, WARN au log).
- Clôturer : bilan chiffré coloré (« Terminé : 12 OK - 2 avertissements - 0 erreur - durée 43 min ») + bouton Ouvrir le rapport (primary) + bouton ghost « Préparer une nouvelle intervention » qui réaffiche les cartes de préparation et remet la barre en état Préparer (la timeline conserve les états du run précédent jusqu'au prochain LANCER).

### 4.5 Aide intégrée (contrat v2.2 sections 4 à 6, transposé)

Survol d'un contrôle documenté : met à jour le CONTENU de la TabPage Aide sans jamais changer l'onglet sélectionné. Sélection d'un module dans la colonne : affiche son entrée. Clic LANCER : sélectionne Journal. Infobulles générées du catalogue (`Format-HelpTooltip`, repli 90 colonnes, AutoPopDelay 30 s), plus aucun texte d'infobulle en dur. Panneau d'aide : titre, sections, puis chips Réversible / Durée / Protégés / Quand décocher.

## 5. Architecture du code

### 5.1 Nouveaux fichiers

| Fichier | Responsabilité |
|---|---|
| `lib/Theme.ps1` | Tokens (couleurs, polices) + fabriques de contrôles + helpers d'état purs. Aucune logique métier. |
| `lib/Help.ps1` | Contrat v2.2 section 4.2 inchangé (Get-HelpCatalog, Get-HelpEntry, Format-HelpPanel, Format-HelpTooltip). |
| `config/help.fr.json` | Catalogue v2.2 section 4.1 inchangé (39 entrées). |
| `tests/Theme.Tests.ps1` | Conformité palette/typo, propriétés des fabriques, transitions d'état, helpers purs. |
| `tests/Help.Tests.ps1` | Contrat v2.2 section 9 inchangé. |

### 5.2 Fonctions de `lib/Theme.ps1`

| Fonction | Contrat |
|---|---|
| `Get-KitTheme` | Hashtable des tokens (Color et Font instanciés). Pure, source unique des couleurs. |
| `New-KitButton -Text -Kind Primary/Ghost/Mini/MiniGhost/Danger` | Button FlatStyle Flat configuré (couleurs, police, padding). |
| `New-KitCard` | Panel fond Card, bordure 1px Line (événement Paint), padding standard. |
| `New-KitEyebrow -Text` | Label majuscules Semibold InkMuted. |
| `New-KitModuleRow -Id -Name` | Objet { Panel, CheckBox, GlyphLabel, NameLabel, DetailLabel }. |
| `Set-KitModuleRowState -Row -State Pending/Running/Ok/Warn/Error/Skipped -Detail` | Bascule case/glyphe, applique couleur et texte détail. |
| `New-KitBand`, `Set-KitBadgeMode -Mode Simulation/Real/Preview` | Bandeau et badge. |
| `New-KitActionBar`, `Set-KitActionBarPhase -Bar -Phase Prepare/Running/Done -Data` | Barre à 3 états. |
| `Show-KitInputDialog -Owner -Title -Prompt` | Dialog charté qui remplace l'InputBox VisualBasic (Enregistrer un profil). Retourne la saisie ou $null. |
| `Get-RunSummaryText -ModuleCount -SensitiveCount -ProfileName -IsDryRun` | Texte du résumé de la barre. Pure. |
| `Get-ModuleStateGlyph -State` | Glyphe MDL2 + repli Unicode. Pure. |

Contrainte : les fabriques retournent des contrôles instanciés SANS affichage, donc testables par Pester en CI (instancier, vérifier propriétés, Dispose). Aucun ShowDialog dans les tests.

### 5.3 `Run-GUI.ps1` : ce qui change, ce qui ne change pas

CHANGE : la construction de l'interface (TableLayoutPanel racine 3 rangées : bandeau / corps en 2 colonnes (290 fixe, remplissage) / barre d'action ; anchors ; AutoScaleMode Dpi) ; la liste CheckedListBox remplacée par les lignes `New-KitModuleRow` ; l'affichage passphrase (masqué + Afficher/Copier) ; le dialog profil ; la modale backup rhabillée via Theme (même mécanique).

NE CHANGE PAS (liste de non-régression) : le timer 400 ms et son Tick ; Start-NextModule, Build-Queue, la queue de process enfants et la fermeture stdin ; le heartbeat (seuils 60 s / 30 s, signe de vie DISM) ; la modale backup : timeout 5 min, timer principal stoppé avant ShowDialog et relancé en finally (fix réentrance v1.9, à préserver mot pour mot) ; la détection de fiche étrangère ; la suppression de fiche (confirmation, log, purge) ; le bilan Get-ReportSummary ; les profils (Read-KitProfile, mapping par Id) ; les MessageBox système (fiable, pas de rhabillage) ; l'écriture des WARN d'annulation et de timeout backup dans le log de run ; StrictMode et les gardes @() existantes.

### 5.4 État par module (nouvelle télémétrie, mécanique existante)

Au démarrage d'un module, mémoriser l'offset du log (`$script:LogOffset`) comme borne de tranche. À sa sortie : exit code non nul => Error ; sinon `Get-ReportSummary` (fonction existante, réutilisée) sur la tranche du module => CountError > 0 => Error, CountWarn > 0 => Warn, sinon Ok. Durée : `ModuleStartTime` existant, formatée par `Format-Elapsed` existant. Modules décochés : Skipped dès Build-Queue.

### 5.5 Mode aperçu `-UiPreview`

Paramètre switch de `Run-GUI.ps1` : saute le contrôle admin, badge APERÇU, LANCER désactivé (infobulle explicative). Aucune action n'est exécutée et rien n'est modifié sur la machine ; le kit crée seulement son dossier de journaux `runtime\logs` sous son propre répertoire (init de `lib/Common.ps1`, commun à tous les points d'entrée). Paramètre associé `-PreviewPhase Prepare/Running/Done` : peuple l'interface avec des données factices en dur (machine PC-DEMO, états et durées exemples, passphrase factice, checklist) pour visualiser et capturer les trois phases sans rien exécuter. Sert : à la boucle visuelle de développement (avec `tools/Capture-Fenetre.ps1`), aux captures du README, aux contributeurs et aux démonstrations sans UAC. Documenté dans le README (section développement).

## 6. Rapport HTML et note utilisateur (retouches légères)

- En-tête du rapport : mention « PC-Refresh-Kit - Trimko Labs » discrète ; pied de page : lien kit.trimko.com.
- Alignement des couleurs sur les tokens de la section 3.1 là où elles divergent. Aucun changement structurel, aucun changement du contenu.

## 7. Tests

- Les 242 tests Pester existants restent verts (aucune fonction pure existante modifiée hors `Get-LogLevelColor`, dont les tests sont mis à jour avec lui).
- `Theme.Tests.ps1` : Get-KitTheme conforme aux hex de la section 3.1 (test table exacte) ; chaque fabrique : FlatStyle, couleurs, police, texte ; Set-KitModuleRowState : les 6 états (glyphe, couleur, visibilité case) ; Get-RunSummaryText et Get-ModuleStateGlyph : cas nominaux et bords.
- `Help.Tests.ps1` : contrat v2.2 section 9 intégral (couverture 39 clés, format, typographie, profils, repli, arguments module 12).
- Parse étendu aux nouveaux .ps1, encodage BOM/em-dash, anonymat, smoke : inchangés, verts.
- Pièges PS 5.1 à respecter dans tout le nouveau code : contrat de retour des collections (return ,@() vs @() appelant), gardes StrictMode sur les propriétés.
- Validation manuelle : -UiPreview aux trois phases en 100/125/150 % DPI et aux tailles 1024x640 / 1200x720 / plein écran ; un run -WhatIf complet en console admin par le mainteneur avant release (habitude des vagues précédentes).

## 8. Distribution et livraison

- `tools/Build-ReleaseZip.ps1` : inchangé (docs/superpowers déjà exclu, `config/help.fr.json` inclus car sous config/).
- README : nouvelles captures des trois phases (via -UiPreview -PreviewPhase + Capture-Fenetre), section -UiPreview, tableau modules inchangé.
- `TOOLTIPS.md` supprimé, remplacé par le renvoi au catalogue (v2.2 section 12). `docs/PROCEDURE-OPERATEUR.md` mis à jour (nouvelles zones, barre d'action, clôture).
- Release notes `docs/RELEASE-NOTES-v2.2.0.md` : refonte cockpit + aide intégrée + profils corrigés.
- Branche `feat/v2.2-cockpit-trimko` depuis public-main, revue finale complète avant merge (le pattern des vagues précédentes ; la revue v1.9 avait rattrapé un CRITICAL invisible aux revues par tâche).

## 9. Hors périmètre

Run.ps1 et le mode console (fallback intact), lanceurs .bat secondaires, dark mode, traduction anglaise, site kit.trimko.com, tout changement de comportement des modules 00 à 15.

## 10. Risques et limites

- **Régression de mécanique de run** : le risque principal. Mitigé par la liste de non-régression 5.3, la conservation des handlers, et la revue finale de branche.
- **DPI 125/150 %** : traité structurellement (TableLayoutPanel, AutoSize, AutoScaleMode Dpi), vérifié manuellement en -UiPreview. Le piège gbUserData h=50 de la v1.9 disparaît avec les positions absolues.
- **Glyphes MDL2 absents** (Windows 10 très anciens) : repli Unicode prévu dans Get-ModuleStateGlyph.
- **Redimensionnement** : bornes garanties par MinimumSize 1000x576 ; textes français longs et colonne intervention (environ 445 unités utiles nécessaires) vérifiés à la borne basse.
- **Flicker WinForms** au basculement de phase : SuspendLayout/ResumeLayout autour des bascules.
- **Volume de rédaction du catalogue** : inchangé vs plan v2.2 (39 entrées), le contenu source existe (README, PROCEDURE-OPERATEUR, tooltips actuels).

## 11. Critères d'acceptation

1. Le cockpit s'affiche intégralement : 1366x768 à 100 % (taille par défaut, avec marge) ; 1366x768 à 125 % (taille minimale 1000x576 logique = 1250x720 physiques, barre des tâches comprise) ; 1920x1080 à 150 % (taille par défaut, surface logique 1280x720). Aucun chevauchement de contrôles à ces trois bornes.
2. `-UiPreview -PreviewPhase Prepare|Running|Done` ouvre les trois phases sans élévation et sans écriture disque.
3. Un run -WhatIf complet en GUI se déroule à l'identique de la v2.1 (queue, heartbeat, modale backup, bilan, checklist, fiche) avec la nouvelle interface, états par module corrects.
4. Aide : 39 entrées, survol sans vol d'onglet, bascule Journal au LANCER, infobulles générées, plus aucun texte d'aide en dur.
5. Profils conformes v2.2 section 7.2 (gamer Conservative + StartupKeep, transmission -KeepPatterns au module 12).
6. Passphrase masquée par défaut, Afficher/Copier fonctionnels, suppression de fiche purge l'affichage.
7. CI verte : parse, Pester (242 existants + nouveaux), encodage, anonymat, smoke.
8. Captures README régénérées, PROCEDURE-OPERATEUR et release notes à jour, TOOLTIPS.md remplacé.
