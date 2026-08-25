# PC-Refresh-Kit v2.4.0 - filets de secours

**Date :** 2026-08-22
**Licence :** MIT

## Résumé

Les versions précédentes remettaient un PC à neuf. Celle-ci prépare sa panne
pendant qu'il va bien, et outille l'intervention quand il ne démarre plus.

Trois briques : une sentinelle qui mesure l'état des filets de récupération de
Windows, une étape qui les réarme et sauvegarde le registre dans un coffre daté,
et un mode secours lançable depuis l'environnement de récupération (WinRE) pour
poser une ruche saine sur un PC qui refuse de démarrer.

L'intervention fondatrice a été menée sur une erreur `0xc000014c` : un disque
saturé avait interrompu l'écriture de la ruche `SYSTEM`. Tout ce qui suit vient
de ce chantier, garde-fous compris.

## Filets de secours

- **Sentinelle de résilience (étape 1, Diagnostic, lecture seule)** : espace
  libre de C: contre les seuils du kit, fraîcheur des écritures du registre,
  état et nombre de points de restauration système, réserve de clichés VSS,
  environnement de récupération (WinRE), auto-réparation au démarrage
  (`recoveryenabled`), chiffrement BitLocker. Chaque sonde est défensive : un
  état non mesurable donne un verdict neutre, jamais une conclusion inventée.
  Le résultat est repris dans le rapport TXT et HTML.
- **Nouvelle étape 3, « Filets de secours »** (`modules/16-Resilience.ps1`),
  placée juste après la sauvegarde. Elle réarme WinRE, l'auto-réparation au
  démarrage et la réserve de clichés, **jamais dans le sens de la réduction** :
  agrandir la réserve VSS est sans risque, la réduire purgerait les points de
  restauration existants. Rien n'est réarmé qui n'ait d'abord été mesuré désarmé.
- **Coffre de ruches** : les 5 ruches (`SYSTEM`, `SOFTWARE`, `SAM`, `SECURITY`,
  `DEFAULT`) sont sauvegardées par `reg save` dans un jeu daté
  `hives-<horodatage>`, accompagné d'un `manifest.txt` (empreinte machine,
  nom de PC assaini en ASCII, build, taille exacte de chaque ruche). Deux
  destinations : le support depuis lequel le kit tourne (coffre externe, le seul
  qui survive à la mort du disque) et `ProgramData` (coffre local). Rotation à
  3 jeux complets par destination ; un jeu sans manifeste est un jeu inutilisable
  et n'évince jamais un jeu posable.
- **Le coffre local est verrouillé avant la première écriture.** Il contient SAM
  et SECURITY : posé sans rien faire sous `ProgramData`, il livrerait les
  empreintes de mots de passe locaux et les secrets LSA en lecture à n'importe
  quel compte standard de la machine, c'est-à-dire l'élévation de privilèges de
  la famille HiveNightmare, créée par le kit lui-même et laissée en place. Le
  dossier est donc refermé sur SYSTEM et Administrateurs (héritage coupé,
  identités désignées par SID pour tenir sur les Windows de toutes langues), sa
  **propriété est reprise** (un propriétaire détient WRITE_DAC et rouvrirait la
  DACL après coup), l'ACL est **relue et vérifiée**, et un dossier qui serait un
  point d'analyse (jonction posée avant le kit) est refusé sans être touché. Si
  ce verrou échoue, aucune ruche n'est écrite. Le coffre externe suit la même
  règle dès que son support gère les droits d'accès (NTFS ou ReFS : une seconde
  partition ou une clé formatée en NTFS sont verrouillées comme la copie
  locale). Seule une clé en FAT32 ou exFAT ne peut porter aucun verrou : là, et
  là seulement, la protection est physique et le journal le dit - garder la clé
  comme un trousseau.
- **Empreinte machine** (`ProgramData\PC-Refresh-Kit\machine-id.txt`, ASCII
  pur) : c'est elle qui permettra, depuis WinRE, de prouver qu'un coffre vient
  bien de CE PC. En WinRE le nom de machine vaut `MININT-xxx` et le registre qui
  le porte est justement celui qu'on répare.
- **Export de la clé de récupération BitLocker** : nouvelle case du cockpit,
  **décochée par défaut**, choix par intervention et jamais enregistré dans un
  profil (un secret ne se coche pas durablement dans un JSON). L'écriture ne va
  que dans le coffre externe, jamais sur le disque chiffré que la clé est censée
  ouvrir, et le mot de passe n'est jamais journalisé.
- **Garde d'espace** : sur un disque système déjà saturé - la cause même du
  sinistre qui a motivé ce module - le coffre local est sauté plutôt qu'écrit,
  et le journal explique quoi faire (brancher une clé, ou nettoyer d'abord).

## Mode secours WinRE

- **`secours.bat`**, à la racine de la clé, se lance depuis l'invite de
  commandes de l'environnement de récupération d'un PC qui ne démarre plus.
  Trois menus : **D** diagnostic en lecture seule, **S** sauvetage de l'état
  cassé vers la clé, **R** restauration guidée d'une ruche depuis le coffre.
- **Mode navette** : rien ne s'analyse sur le PC en panne. La clé collecte
  (`secours\secours.txt`, `dump-*.txt`, inventaire des outils du WinRE, ruches
  cassées), on la rapporte sur un PC sain, on lit, on décide, on revient poser.
- **Le coffre est apparié par empreinte machine, jamais par nom de PC** : un nom
  accentué ne se relit pas pareil en page de codes OEM. Entre plusieurs jeux du
  bon PC, le plus récent gagne ; à défaut de coffre sur la clé, celui du disque
  est fouillé en dernier recours.
- **Six garde-fous bloquants** avant la moindre écriture : volume Windows
  détecté, diagnostic D exécuté dans la session courante, coffre de CE PC
  trouvé, ruche demandée présente dans le jeu, taille du fichier égale à celle
  du manifeste, confirmation `OUI` tapée en toutes lettres. Chaque refus laisse
  le PC dans l'état trouvé et nomme le chemin retenu, pour que l'opérateur ne
  reste pas en cul-de-sac.
- **La pose reste sous surveillance** : `chkdsk /f` d'abord (un code de retour
  grave arrête tout), la ruche en place est mise de côté en `<RUCHE>.casseN` et
  cette copie est **remesurée** avant d'autoriser la pose (une sauvegarde
  tronquée qui servirait de retour arrière ferait perdre les deux exemplaires),
  la ruche posée est remesurée, et le retour arrière lui-même est vérifié avant
  d'être annoncé. Les journaux `.LOG1` et `.LOG2` sont écartés avec le même
  numéro que la ruche, pour ne pas être rejoués sur la ruche fraîche.
- **Contraintes payées sur le terrain** : ASCII strict (un WinRE affiche en page
  de codes OEM), CRLF, aucun tube (`findstr` manque aux WinRE dépouillés et son
  absence dans un tube tue le script sans le moindre message), binaires limités
  à `reg`, `xcopy`, `attrib`, `chkdsk` et `fsutil`, aucune lettre de volume codée
  en dur, aucune redirection vers `nul` qui masquerait une erreur.
- **`docs/PC-EN-PANNE.md`** : la marche à suivre complète pour l'opérateur.
  Checklist AVANT intervention (accès au compte Microsoft du propriétaire
  vérifié - mot de passe et téléphone -, code PIN, clé BitLocker accessible,
  coffre à jour sur la clé), lecture des fichiers de la navette en page de codes
  OEM 850, conduite à tenir devant chaque refus, et checklist de restitution.
  La leçon la plus chère de l'intervention fondatrice y est en tête : après une
  réparation réussie, le compte Microsoft peut réclamer une validation à deux
  facteurs, et un PC qui redémarre parfaitement sur une session inaccessible
  n'est pas un PC réparé.

## Rapport et cockpit

- L'intervention compte désormais **16 étapes**, « Filets de secours » en
  position 3 (juste après la sauvegarde) et le Rapport toujours en dernier.
- Le rapport porte une carte **Filets de sécurité** issue de la sentinelle, avec
  ses verdicts colorés ; un diagnostic antérieur à v2.4 fait simplement omettre
  la carte, jamais échouer le rapport.
- La **checklist de clôture** gagne un item : « Coffre de ruches à jour (module
  Filets de secours en OK) ».
- L'aide intégrée couvre les nouveaux contrôles : **44 rubriques** dans
  `config/help.fr.json`, seule source de vérité, et un contrôle ajouté à
  l'interface sans rubrique correspondante fait toujours échouer la CI.

## Qualité

- **Tests statiques sur `secours.bat`** : aucun octet au-delà de 0x7F, fins de
  ligne CRLF, aucun tube, aucun binaire hors liste blanche, aucune lettre de
  volume codée en dur, aucun `!` dans les textes affichés (expansion différée).
  Ces règles ne sont pas des préférences de style : chacune a été payée sur une
  réparation réelle, et un test les empêche de se perdre.
- **Passe à blanc du menu en CI** : `secours.bat` est déroulé via ses crochets
  de test (`SECOURS_DRYRUN`, `SECOURS_FORCE_*`), qui préfixent toute écriture
  système et rendent le parcours vérifiable sans toucher à quoi que ce soit. Un
  garde-fou contourné par un crochet est annoncé dans le menu, jamais silencieux.
- **Parcours utilisateur scripté** (`Run-GUI.ps1 -SelfTest`) : **27 assertions**,
  exécuté à chaque commit en CI.
- **Suite Pester** : plus de 470 tests unitaires, dont la couverture des
  fonctions pures du coffre (règles d'ACL, verdict de sécurité relu, rotation
  des jeux, manifeste, assainissement ASCII des noms).
- Contrôles habituels inchangés : AST, encodage (BOM UTF-8, zéro em-dash),
  anonymat du dépôt public, smoke-tests des modules en `-WhatIf`.
- **`tools/regf`** (atelier expert d'analyse et de réparation d'en-tête de
  ruche, en Python) reste **hors du zip de distribution** : la construction du
  zip vérifie désormais son absence et échoue si elle constate le contraire.
  Une promesse de distribution jamais vérifiée finit par mentir.

## Mise à jour depuis la v2.3

Rien à migrer : extraire le nouveau zip sur la clé par-dessus l'ancien contenu.
Le coffre n'existera qu'après le premier passage de l'étape « Filets de
secours » sur chaque PC - c'est ce passage-là qui rend le mode secours utile,
et il est coché par défaut.

## Site du projet

https://kit.trimko.com
