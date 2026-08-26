# PC-Refresh-Kit v2.1.0

**Date :** 2026-08-14
**Licence :** MIT

---

## Résumé

Version de démonstration. Le kit gagne un point d'entrée dédié aux présentations : le cockpit
peut désormais s'ouvrir directement en mode simulation, sans risque pour la machine hôte.
Aucun changement fonctionnel sur les 16 modules par rapport à la v2.0.0.

---

## Nouveautés

### Lancer-Demo.bat - mode démonstration

Double-clic sur `Lancer-Demo.bat` : auto-élévation UAC, bandeau d'avertissement en console,
puis ouverture du cockpit avec la case "Mode dry-run (-WhatIf)" déjà cochée. Tous les modules
sont simulés, le journal coloré défile normalement, la barre de titre affiche `[DRY-RUN]`, et
rien n'est modifié sur le PC.

Usage : présenter le kit à un prospect, un proche ou un décideur sur sa propre machine, sans
avoir à expliquer où cocher la case ni prendre le risque d'un run réel involontaire.

Pour une intervention réelle, `Lancer.bat` reste le point d'entrée.

---

## Divers

- `Get-KitVersion` retourne `v2.1` (affiché dans l'en-tête des rapports HTML et TXT)
- Version par défaut de `tools/Build-ReleaseZip.ps1` alignée sur 2.1.0
- README : section "Aperçu sans rien modifier" mise à jour

---

## Prérequis

Inchangés : Windows 10 (1903+) ou 11, PowerShell 5.1, session administrateur.

---

## Site du projet

https://kit.trimko.com
