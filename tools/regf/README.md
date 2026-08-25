# tools/regf - atelier de réparation de ruche registre (expert, hors release)

Outillage de DERNIER recours quand : le coffre du kit est vide, les clichés VSS
sont morts, et la ruche cassée est le seul exemplaire. Situation type : un poste
qui refuse de démarrer sur l'erreur 0xc000014c après une saturation du disque.

## Modèle de panne couvert

Un disque saturé interrompt le commit de l'en-tête de la ruche : `seq1 != seq2`,
journaux dépareillés (LOG1 vide ou en retard de séquence), hbins INTACTS.
Le chargeur refuse la ruche entière pour 4 octets. La réparation : `seq2 := seq1`
+ checksum recalculé, appliquée SUR COPIE, jamais en place.

## Les trois scripts

| Commande | Rôle | Codes de retour |
| --- | --- | --- |
| `py -3 analyse_regf.py RUCHE [RUCHE ...]` | autopsie de l'en-tête : signatures, séquences, checksum lu contre checksum recalculé, chaîne des hbins, journaux `.LOG1` / `.LOG2` voisins | 0 saine, 1 anomalie, 2 usage |
| `py -3 walk_regf.py RUCHE` | parcours intégral de l'arbre (nk, vk, lf, lh, li, ri, db, sk), chaque référence bornée à la chaîne des hbins | 0 aucune erreur, 1 erreurs, 2 usage |
| `py -3 repare_regf.py RUCHE RUCHE_REPAREE` | produit une COPIE corrigée et vérifiée | 0 copie écrite et vérifiée, 1 refus ou échec, 2 usage |

Python 3 et sa bibliothèque standard suffisent, sans rien à installer (`py -3`
sous Windows). Les trois fichiers restent dans le même dossier : `repare_regf.py`
réutilise le calcul de checksum de l'analyseur et le contrôle d'arbre du
parcours, pour qu'un verdict et une correction ne puissent jamais diverger.

## Méthode (dans cet ordre, sans sauter d'étape)

1. `py -3 analyse_regf.py RUCHE` : confirmer seq1/seq2 et le checksum.
2. `py -3 walk_regf.py RUCHE` : le parcours complet doit sortir ZÉRO erreur de
   structure. Des hbins endommagés = HORS périmètre de cet outil (la copie du
   coffre ou du cliché est alors la seule voie).
3. `py -3 repare_regf.py RUCHE RUCHE_REPAREE` : produit la copie réparée.
4. Validation sur un PC sain, en admin : `reg load HKLM\TestHive RUCHE_REPAREE`
   puis vérifier `Select` (Current/Default), `ControlSet001\Services` (pilotes de
   stockage Start=0 : stornvme, storahci, disk, partmgr, volmgr), `MountedDevices`,
   et pour SYSTEM la bootkey (`ControlSet001\Control\Lsa` : JD, Skew1, GBG, Data
   présents). `reg unload HKLM\TestHive` ensuite. reg load PEUT rejouer des
   journaux et modifier le fichier : toujours travailler sur une copie de plus.
5. La pose sur le PC en panne passe par le menu R de secours.bat quand un coffre
   existe ; sinon procédure manuelle WinRE (chkdsk /f, copie .casseN de
   l'ancienne, pose, contrôle de taille, renommage des .LOG en .casse).

## Garde-fous du réparateur

- la ruche source est ouverte en lecture seule ; sa taille et sa date de
  modification sont recomparées après coup et affichées ;
- une destination qui désigne la source est refusée, y compris par un chemin
  détourné, une différence de casse ou un lien ;
- une destination existante n'est écrasée qu'avec `--ecraser` ;
- rien n'est écrit tant que l'arbre de la copie corrigée n'a pas été parcouru
  sans une seule erreur de structure ;
- la copie est relue depuis le disque et re-vérifiée après écriture. Une
  vérification qui échoue rend un code non nul et un refus explicite : la copie
  ne doit pas être posée.

## Ce que dit l'analyse

- `séquences DESACCORDEES` : le commit d'en-tête a été interrompu. C'est le seul
  défaut que cet atelier répare.
- `checksum FAUX` : l'en-tête a été modifié après son dernier calcul. Réparable
  avec le point précédent.
- `RUPTURE DE CHAINE` : la chaîne des hbins s'arrête avant la taille annoncée.
  Le corps est touché, la réparation d'en-tête ne servirait à rien.
- `réserve de fin` : des octets nuls après la zone annoncée sont NORMAUX (place
  allouée d'avance). Des hbins valides au-delà de la taille annoncée signalent
  au contraire un en-tête en retard sur le corps.
- Un journal n'est rejouable que si sa plus haute séquence atteint celle de la
  ruche. Un journal vide ou en retard n'aide à rien.

## Limites assumées

- Ne répare QUE le cas seq1/seq2 + checksum. Tout le reste (hbins corrompus,
  cellules déchirées) = restaurer une copie, pas réparer.
- Jamais exécuté par le produit : absent du zip de release, jamais appelé par
  les modules ni par secours.bat.
- Une ruche réparée n'est pas une ruche validée : l'étape 4 de la méthode
  (chargement de contrôle sur un PC sain) n'est pas facultative.
