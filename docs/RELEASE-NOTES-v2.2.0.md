# PC-Refresh-Kit v2.2.0

**Date :** 2026-08-21
**Licence :** MIT

## Résumé

Refonte complète du cockpit aux couleurs Trimko Labs et aide intégrée. L'écran suit le geste de
l'opérateur : préparer (profil, modules, réglages, actions sensibles), exécuter (timeline d'états
par module, journal en direct), clôturer (passphrase masquée, checklist de restitution, rapport).
Chaque module et chaque option disposent d'une aide complète, et les profils d'intervention
tiennent la promesse de leur nom.

## Cockpit Trimko

- Bandeau d'identité avec badge de mode : SIMULATION, INTERVENTION RÉELLE ou APERÇU
- Timeline d'intervention : chaque module passe d'une case à cocher à un état visuel
  (en attente, en cours, OK, avertissement, erreur, ignoré) avec sa durée
- Barre d'action en pied de fenêtre : résumé de ce qui sera fait, progression pendant le run,
  bilan chiffré à la fin
- Fenêtre redimensionnable (minimum 1000x576) qui tient sur un écran 1366x768
- Journal sombre aux couleurs du rapport HTML
- Passphrase masquée par défaut en clôture, boutons Afficher et Copier
- Mode aperçu sans élévation : `Run-GUI.ps1 -UiPreview [-PreviewPhase Prepare|Running|Done]`

## Aide intégrée

- Onglet **Aide** à côté du journal, au premier plan au démarrage
- 42 rubriques : les 16 modules, les 9 options, les 3 politiques de débloatage, les 2 modes de
  compte, les 3 profils et les 9 actions
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

- Le rapport HTML porte la marque Trimko Labs et le lien kit.trimko.com
- `TOOLTIPS.md` supprimé, remplacé par le catalogue
- Suppression d'un hashtable de descriptions de modules jamais affiché

## Site du projet

https://kit.trimko.com
