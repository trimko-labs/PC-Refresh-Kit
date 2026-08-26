# PC-Refresh-Kit v2.4.1 - durcissement cible

**Date :** 2026-08-26
**Licence :** MIT

## Résumé

Version de durcissement, sans nouvelle fonctionnalité. Elle ferme un risque de
fuite propre au domaine du kit (les ruches de registre), fiabilise le ciblage du
disque système quand Windows n'est pas sur `C:`, étend le contrôle d'encodage aux
documents, et met la chaîne d'intégration continue à jour. Aucune rupture : les
coffres et interventions v2.4.0 restent valides, les rapports affichent `v2.4.1`.

## Anonymat

- Le contrôle d'anonymat (`tests/Test-KitAnonymity.ps1`) refuse désormais toute
  **ruche de registre suivie**, reconnue à son entête `regf` (4 octets), quel que
  soit son nom ou son extension. Une ruche client (`SAM`, `SYSTEM` : empreintes de
  mots de passe, identité machine) copiée dans l'arbre pour analyse ne peut plus
  partir en ligne.
- Lecture **fail-closed** : un fichier suivi présent mais illisible (verrou) ou
  introuvable est signalé et compté, jamais tenu pour propre. Chemins traités en
  littéral : un nom à crochets (`SAM[old]`) n'est plus sauté en silence.
- `.gitignore` couvre le coffre de ruches (`HiveVault/`, `*.hiv`, `*.hive`) en
  complément de `Coffre/` ; le contrôle de contenu reste le vrai filet.

## Cohérence du disque système

- Le module 16 (Filets de secours) cible le disque système via `$env:SystemDrive`
  au lieu de `C:` codé en dur : requête de volume, réserve de clichés VSS
  (`vssadmin`), BitLocker, repli `manage-bde` et choix du volume amovible pour le
  coffre externe. La sentinelle du diagnostic (module 00) applique la même règle à
  ses verdicts (espace libre, réserve VSS, BitLocker), pour que sentinelle et
  module restent cohérents. Aucun changement sur un poste dont Windows est sur
  `C:` ; comportement correct quand il ne l'est pas.

## Qualité

- Le contrôle d'encodage (BOM UTF-8, zéro tiret long) couvre désormais les
  documents `.md` suivis en plus des scripts, sur la liste `git ls-files` (scan
  déterministe, refus d'un résultat vide). BOM ajouté aux `.md` qui en manquaient.
- Intégration continue : `actions/checkout` passe de v4 (Node 20, fin de vie) à v5.
- Suite de tests : 550 tests verts (dont le garde d'anonymat) ; 61 fichiers
  vérifiés à l'encodage, 97 fichiers suivis contrôlés à l'anonymat ; parcours
  SelfTest de l'interface au vert.
