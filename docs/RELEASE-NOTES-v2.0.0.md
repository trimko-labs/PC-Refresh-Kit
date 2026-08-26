# PC-Refresh-Kit v2.0.0

**Date :** 2026-07-18
**Licence :** MIT

---

## Résumé

PC-Refresh-Kit v2.0.0 est la première version open-source du kit. Elle consolide 16 modules
de remise en état, une interface GUI cockpit, la réversibilité complète des actions et un
niveau de fiabilité terrain validé par CI verte (288 tests passants).

---

## Nouveautés et améliorations depuis v1.x

### 16 modules couvrant l'intégralité d'une remise à neuf

| N  | Module           | Rôle                                               |
|----|-----------------|----------------------------------------------------|
| 00 | Diagnostic      | Inventaire complet - SMART, BitLocker, pilotes, avant/après |
| 01 | Backup          | Point de restauration + copie des données utilisateur |
| 02 | Antivirus       | Suppression Avast/AV tiers, activation Defender, scan |
| 03 | Debloat         | Bloatware Store et OEM (ASUS, Dell, HP...) avec politique |
| 04 | Privacy         | Télémétrie, Copilot, Widgets, Recall, TelemetryGuard |
| 05 | Updates         | Windows Update + winget upgrade --all               |
| 06 | Software        | Firefox, 7-Zip, VLC, Sumatra PDF, LibreOffice       |
| 07 | Cleanup         | Temp/cache, DISM, SFC, défrag/TRIM adapté au disque |
| 08 | Accounts        | Compte admin séparé + compte standard               |
| 09 | Comfort         | OneDrive, extensions visibles, suggestions off      |
| 10 | Report          | Rapport HTML + TXT, avant/après chiffré             |
| 11 | DeepClean       | Raccourcis morts, dossiers résiduels post-débloatage |
| 12 | Startup         | Désactivation réversible des autostarts             |
| 13 | BrowserPUP      | Nettoyage policy navigateur Chrome/Edge             |
| 14 | Undo            | Annulation complète (LIFO) des actions réversibles  |
| 15 | Network         | Reset réseau Winsock/IP/DNS (déscoché par défaut)   |

### GUI cockpit

- Sélection des modules par cases à cocher, profils d'intervention (standard/senior/gamer)
- Journal coloré en direct (OK vert, avertissement orange, erreur rouge)
- Pause de vérification backup après module 01
- Heartbeat pendant les silences longs (DISM, SFC)
- Checklist de fin d'intervention, bouton suppression fiche PC
- Mode DRY-RUN vs RUN RÉEL affiché dans la barre de titre

### Réversibilité et sécurité

- Module 14-Undo : manifeste JSON, annulation LIFO de toutes les actions réversibles
- Dry-run (`-WhatIf`) sur tous les modules
- Aucune donnée personnelle supprimée ou déplacée
- Garde-fou "au moins 2 admins" anti-verrouillage
- Génération de mot de passe via CSPRNG (rejection sampling + Fisher-Yates)

### CI verte - 288/288 tests Pester

Suite complète sur `lib/Common.ps1` + smoke-tests sur tous les modules.

---

## Prérequis

- Windows 10 (1903+) ou Windows 11
- PowerShell 5.1 (inclus dans Windows, aucune installation requise)
- Session administrateur
- Connexion internet (pour modules 05/06 uniquement)

---

## Installation

1. Télécharger `PC-Refresh-Kit-v2.0.0.zip`
2. Extraire sur une clé USB
3. Double-cliquer `Lancer.bat` sur le PC cible

---

## Site du projet

https://kit.trimko.com

---

## Licence

Distribué sous licence [MIT](../LICENSE). Fourni « tel quel », sans garantie.
