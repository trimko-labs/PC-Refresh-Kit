# Documentation intégrée du cockpit - conception

Date : 2026-08-14
Version du kit visée : 2.2.0

## 1. Problème

Le cockpit expose des choix que rien n'explique sérieusement.

Vingt infobulles existent, d'une à deux phrases, et elles laissent l'essentiel de côté :

- les seize modules n'ont aucune infobulle individuelle, seulement un message global sur la liste entière. Rien n'explique ce que fait `03 Debloat`, `08 Accounts` ou `13 BrowserPUP` ;
- l'infobulle des profils d'intervention dit comment appliquer un profil, jamais ce que chacun contient ;
- les conséquences réelles ne sont nulle part : ce qui est réversible, ce qui ne l'est pas, combien de temps cela prend, dans quel cas il faut décocher.

Un audit du contenu des profils montre que le problème dépasse la rédaction. Les trois profils livrés sont presque identiques :

| Champ | gamer | senior | standard |
|---|---|---|---|
| Debloat | Standard | Conservative | Standard |
| Module 15 Network | non | non | oui |
| Tout le reste | identique | identique | identique |

`gamer` ne se distingue de `standard` que par la réinitialisation réseau désactivée, ce qui n'a aucun rapport avec le jeu. Pire, `config/startup-blacklist.json` désactive les lancements automatiques de Steam et d'Epic Games Launcher, et le profil `gamer` ne l'empêche pas : choisir ce profil produit l'inverse de ce que son nom promet. La protection Game Pass, elle, est codée en dur dans le module 03 et s'applique quel que soit le profil.

Documenter les profils en l'état reviendrait à rédiger la notice d'un bouton qui ne fait pas ce qu'il annonce.

## 2. Objectifs

1. Tout contrôle du cockpit dispose d'une explication accessible, à deux niveaux de profondeur.
2. Les profils d'intervention tiennent la promesse de leur nom.
3. Un contrôle ajouté plus tard sans documentation fait échouer la CI.

## 3. Hors périmètre

- Traduction anglaise. Le nommage des fichiers la prépare, elle n'est pas réalisée.
- Page d'aide HTML distribuable. La structure du catalogue la rendra possible sans réécriture.
- Aide contextuelle dans le mode console (`Run.ps1`).

## 4. Architecture

| Fichier | Responsabilité |
|---|---|
| `config/help.fr.json` | Le contenu de l'aide. Aucune logique. |
| `lib/Help.ps1` | Chargement, validation, mise en forme pour le panneau et pour l'infobulle. |
| `Run-GUI.ps1` | Onglets Aide et Journal, câblage des événements de survol et de sélection. |
| `tests/Help.Tests.ps1` | Couverture, format, cohérence des profils. |

La logique d'aide vit dans `lib/Help.ps1` et non dans `Run-GUI.ps1`, qui approche déjà les 46 Ko. Le cockpit ne fait qu'appeler quatre fonctions.

### 4.1 Format du catalogue

```json
{
  "version": 1,
  "entries": {
    "module.03": {
      "title": "03 Debloat - applications préinstallées",
      "short": "Retire les applications préinstallées inutiles, avec une liste de protection.",
      "what": "Supprime les applications du Microsoft Store et du constructeur qui n'ont jamais servi : jeux de démonstration, applications Bing, suites d'essai, utilitaires de marque.",
      "protects": "Windows Store, Defender, winget, pilotes graphiques et jeux Game Pass ne sont jamais retirés. Les applications utilisées dans les 90 derniers jours sont conservées en politique Standard.",
      "reversible": "Non, mais tout est réinstallable gratuitement depuis le Microsoft Store.",
      "duration": "5 à 15 minutes",
      "whenNot": "Sur un poste d'entreprise où des applications de marque sont imposées par le service informatique."
    }
  }
}
```

Champs obligatoires : `title`, `short`, `what`, `reversible`, `duration`. Champs facultatifs : `protects`, `whenNot`.

Espaces de clés :

| Préfixe | Exemple | Portée |
|---|---|---|
| `module.NN` | `module.08` | Les seize modules |
| `option.<nom>` | `option.winold` | Cases à cocher et données utilisateur |
| `debloat.<politique>` | `debloat.aggressive` | Les trois politiques |
| `account.<choix>` | `account.standard` | Les deux modes de compte |
| `profile.<nom>` | `profile.gamer` | Les profils livrés |
| `action.<nom>` | `action.run` | Boutons LANCER, Annuler, rapport, fiche, profils |

### 4.2 Fonctions de `lib/Help.ps1`

| Fonction | Contrat |
|---|---|
| `Get-HelpCatalog -Path` | Charge et valide le fichier. Renvoie une hashtable de clés vers entrées. En cas d'absence ou d'erreur, journalise un WARN et renvoie une hashtable vide, jamais une exception. |
| `Get-HelpEntry -Catalog -Key` | Renvoie l'entrée demandée, ou une entrée de repli portant le libellé « Aide indisponible pour cet élément ». |
| `Format-HelpPanel -Entry` | Texte multi-lignes pour le panneau : titre, puis les sections présentes, chacune précédée de son intitulé. |
| `Format-HelpTooltip -Entry -Width 90` | Résumé court, replié à la largeur demandée, terminé par « Détail complet dans l'onglet Aide ». |

Ces quatre fonctions sont pures au sens du projet : elles ne lisent aucun contrôle et sont testables directement par Pester, comme `Build-ModuleArgList`.

## 5. Intégration dans le cockpit

Le champ de journal `$txtLog` (580 x 400) est déplacé dans un `TabControl` de mêmes dimensions, à la même position, comportant deux onglets :

- **Aide**, sélectionné au démarrage, contenant un champ en lecture seule ;
- **Journal**, contenant le champ de journal actuel, inchangé.

Comportements :

1. Survol d'un contrôle documenté : l'onglet Aide affiche l'entrée correspondante. Le survol ne change jamais l'onglet actif, il ne fait que mettre à jour le contenu.
2. Changement de sélection dans la liste des modules : l'onglet Aide affiche l'entrée du module sélectionné.
3. Clic sur LANCER : bascule automatique sur l'onglet Journal.
4. Pendant une exécution, le survol continue de mettre à jour le contenu de l'onglet Aide sans jamais le ramener au premier plan.

Le journal écrit toujours dans son champ, que l'onglet soit visible ou non. Aucune modification de la mécanique d'exécution.

## 6. Infobulles

Deux réglages actuels rendent les textes longs inutilisables : le délai d'affichage est de 5 secondes et WinForms ne coupe pas les lignes.

- `AutoPopDelay` porté à 30000 ms, `InitialDelay` conservé à 500 ms.
- Repli des lignes à 90 caractères par `Format-HelpTooltip`, sur les espaces, sans couper les mots.
- Chaque infobulle est générée depuis le catalogue. Plus aucun texte d'infobulle codé en dur dans `Run-GUI.ps1`.

## 7. Refonte des profils

### 7.1 Format étendu

Deux champs s'ajoutent au format de profil, tous deux facultatifs pour rester compatible avec les profils déjà enregistrés par les utilisateurs :

| Champ | Type | Rôle |
|---|---|---|
| `Description` | chaîne | Phrase affichée dans le panneau d'aide au survol de la liste des profils. |
| `StartupKeep` | tableau de chaînes | Motifs de la liste noire de démarrage que ce profil préserve. |

### 7.2 Contenu des trois profils livrés

| Profil | Intention | Debloat | StartupKeep | Module 15 | Compte |
|---|---|---|---|---|---|
| gamer | Ne pas gêner une machine de jeu | Conservative | Steam, EpicGamesLauncher, Discord, GeForce, Battle.net | non | Garder admin |
| senior | Machine la plus simple et la plus légère possible | Conservative | aucun | non | Standard avec passphrase |
| standard | Remise en état complète et équilibrée | Standard | aucun | oui | Standard avec passphrase |

`gamer` passe en politique Conservative parce que la politique Standard retire les applications non utilisées depuis 90 jours, ce qui frappe les lanceurs et outils de jeu saisonniers. Le profil garde le compte administrateur : un joueur installe et met à jour souvent, une élévation par mot de passe à chaque opération serait rejetée.

`senior` conserve la politique Conservative pour une raison inverse : sur ce poste, la disparition d'une icône connue coûte plus cher que l'espace disque gagné.

### 7.3 Transmission jusqu'au module 12

`Build-ModuleArgList` gagne un cas :

```powershell
'12' {
    $keep = @($Options['StartupKeep'])
    if ($keep.Count -gt 0) { $a += @('-KeepPatterns', ($keep -join ',')) }
}
```

`12-Startup.ps1` gagne le paramètre `[string]$KeepPatterns`. Toute entrée de la liste noire dont le champ `match` ou le champ `label` contient l'un des motifs préservés est ignorée et journalisée en INFO, avec la mention du profil. Le comportement par défaut, sans profil et sans motif, reste identique à aujourd'hui.

## 8. Contenu à rédiger

Trente-neuf entrées :

| Catégorie | Nombre | Clés |
|---|---|---|
| Modules | 16 | `module.00` à `module.15` |
| Options et données | 9 | corbeille, Windows.old, caches navigateurs, OneDrive, débloatage constructeur, réinitialisation réseau, sauvegarde des données, analyse Defender, mode simulation |
| Politiques de débloatage | 3 | conservatrice, standard, agressive |
| Modes de compte | 2 | standard avec passphrase, conservation de l'administrateur |
| Profils | 3 | gamer, senior, standard |
| Actions | 6 | lancer, annuler, ouvrir le rapport, supprimer la fiche PC, appliquer un profil, enregistrer un profil |

Règles de rédaction : le champ `short` tient en moins de 200 caractères et dit ce que l'utilisateur doit décider, pas comment le kit fonctionne. Le champ `what` décrit l'effet concret sur la machine. Aucun tiret cadratin ni demi-cadratin, conformément au contrôle d'encodage déjà en place.

## 9. Tests

`tests/Help.Tests.ps1` couvre :

1. **Couverture** : la liste des clés attendues, dérivée des identifiants de modules et des noms de contrôles, est entièrement présente dans le catalogue. Une clé manquante fait échouer le test, ce qui protège des ajouts non documentés.
2. **Format** : chaque entrée possède les cinq champs obligatoires, non vides, et `short` reste sous 200 caractères.
3. **Typographie** : aucune entrée ne contient de tiret cadratin ou demi-cadratin.
4. **Profils** : chaque fichier de `config/profiles` possède une entrée `profile.<nom>` et un champ `Description`.
5. **Fonctions** : `Format-HelpTooltip` replie bien à la largeur demandée sans couper de mot, `Get-HelpEntry` renvoie l'entrée de repli sur une clé inconnue, `Get-HelpCatalog` renvoie une hashtable vide sur fichier absent au lieu de lever une exception.
6. **Arguments** : `Build-ModuleArgList` produit `-KeepPatterns` pour le module 12 quand le profil en définit, et rien sinon.

## 10. Distribution

`tools/Build-ReleaseZip.ps1` exclut déjà `docs/plans`. L'exclusion est étendue à `docs/superpowers`, qui contient les documents de conception internes. `config/help.fr.json` est inclus dans la distribution, sans quoi l'aide serait vide sur la clé USB.

## 11. Risques et limites

- **Catalogue absent ou corrompu.** Le cockpit démarre quand même, les infobulles retombent sur un texte de repli et le panneau affiche « Aide indisponible ». Aucun blocage.
- **Profils utilisateur existants.** Les deux nouveaux champs étant facultatifs, un profil enregistré avant cette version continue de fonctionner, sans description et sans préservation de démarrage.
- **Volume de rédaction.** Trente-sept entrées d'une centaine de mots représentent le gros du travail. Le contenu existe déjà en partie dans le README et dans `docs/PROCEDURE-OPERATEUR.md`, il s'agit surtout de le reformuler pour un lecteur qui n'est pas technicien.
- **Fenêtre en 1366 x 768.** Le panneau ne change aucune dimension, le cockpit reste affichable comme aujourd'hui.

## 12. Conséquence documentaire

`TOOLTIPS.md` décrit un état devenu faux. Il est remplacé par une section du README renvoyant au catalogue, seule source de vérité.
