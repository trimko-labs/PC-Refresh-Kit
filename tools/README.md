# Outils optionnels (enrichissement gracieux)

Ce dossier peut contenir des binaires tiers SIGNÉS MICROSOFT (Sysinternals) qui
enrichissent le diagnostic sans jamais être requis. Le coeur du kit reste 100 %
PowerShell 5.1 natif : si un outil est absent ou non signé, le module bascule
sur son comportement natif.

Le helper `Get-OptionalTool` (lib/Common.ps1) vérifie l'existence ET la
signature Authenticode (Status 'Valid') avant tout usage.

## Outils reconnus

- `autorunsc64.exe` (Sysinternals Autoruns) : inventaire étendu des points de
  démarrage (tâches, services, pilotes, codecs) collecté par le module 00.
  Téléchargement : https://learn.microsoft.com/sysinternals/downloads/autoruns

Les binaires ne sont PAS versionnés (voir .gitignore) : l'opérateur les dépose
sur la clé USB s'il le souhaite.
