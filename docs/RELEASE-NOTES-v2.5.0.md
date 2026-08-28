# PC-Refresh-Kit v2.5.0 - confiance visuelle

**Date :** 2026-08-28
**Licence :** MIT

## Résumé

Version de confiance : l'interface justifie d'un coup d'oeil ce que chaque étape
fait, ce qu'elle risque et ce qui protège les données. Aide enrichie de badges et
d'une ancre visuelle, filet de sauvegarde affiché en permanence, vérité annoncée
avant tout lancement réel, et correction de deux messages fantômes des rapports.
Aucune rupture : les coffres et interventions v2.4 restent valides, les rapports
affichent `v2.5.0`.

## Aide visuelle

- **En-tête contextuel** du panneau d'aide : type de l'élément survolé (ÉTAPE,
  PROFIL, RÉGLAGE, ACTION), fil d'Ariane, et badges normalisés **RÉVERSIBLE**,
  **DONNÉES PERSO** et **DURÉE**, colorés selon l'enjeu. Les 28 rubriques
  concernées du catalogue portent leurs badges, dérivés fidèlement des textes
  existants ; une rubrique sans badge s'affiche comme avant.
- **Liseré d'ancrage** : la ligne de la timeline dont l'aide est affichée reste
  marquée d'un liseré, y compris pendant le gel et l'épinglage du panneau - on
  sait toujours à quoi correspond ce qu'on lit.

## Filet de sauvegarde visible

- Un **indicateur permanent** dans la barre d'action annonce l'état du filet :
  disque externe détecté (vert, avec la lettre et l'espace libre) ou filet
  absent/dégradé (orange). La détection est partagée avec le module Sauvegarde :
  le cockpit ne peut pas nommer un autre disque que celui où la copie partira.
  Le disque système n'est plus supposé être `C:`.
- L'aide du module Sauvegarde répond désormais au **pourquoi** : le point de
  restauration Windows ne protège pas les fichiers personnels, et une copie sur
  le même disque disparaîtrait avec lui - seul un disque externe survit.

## Vérité avant le lancement

- En intervention réelle, une **confirmation unique** n'apparaît que s'il y a
  quelque chose à dire : filet absent ou dégradé, applications douteuses
  supprimées sans question (politique Standard depuis le cockpit) ou supprimées
  même utilisées (Agressive). Rien à signaler = aucune friction ; jamais de
  confirmation en simulation.
- La **conséquence de la politique de débloatage** est toujours visible sous la
  liste : le mot « Agressif » ne porte plus seul.
- Micro-copie de confiance : la sauvegarde dit « une copie - jamais un
  déplacement », le désencombrement « liste fermée - jamais vos logiciels
  installés ».

## Corrections

- Le rapport final ne réclame plus un **redémarrage à chaque intervention** :
  les marqueurs de redémarrage étaient comptés à tort même absents.
- L'avertissement « **antivirus tiers actif ()** » ne part plus sur les machines
  qui n'en ont pas.
- Un contrôle statique interdit désormais le motif d'appel fautif à l'origine de
  ces deux défauts, sur les neuf fonctions concernées du dépôt.

## Qualité

- 585 tests verts ; parcours SelfTest de l'interface porté de 27 à 49 assertions
  (plancher verrouillé : aucune assertion ne peut être sautée en silence).
- Contrôles d'encodage et d'anonymat au vert, historique des commits compris.
- Les captures d'aperçu (`-UiPreview`) affichent un état de démonstration figé :
  aucune donnée du poste de capture ne peut fuiter.
