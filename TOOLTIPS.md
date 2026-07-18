# Infos-Bulles (Tooltips) GUI - PC-Refresh-Kit v1.2+

## Ajout UX pour aider les utilisateurs novices

Survol avec la souris sur chaque contrôle affiche une explication contextuelle.

### Modules (CheckedListBox)
**Message global :**
> Cochez les modules à exécuter. Tous sont cochés par défaut.
> Ceux marqués [*] modifient le système.

### Profil Compte (RadioButtons)
- **Standard + passphrase**
  > Recommandé : crée un compte Standard + passphrase sécurisée, désactive l'admin (plus sûr)

- **Garder admin (UAC seul)**
  > Conserve le compte admin visible. UAC seul contrôle les accès (moins sûr)

### Actions Sensibles (CheckBoxes - toutes décochées par défaut)

1. **Vider la corbeille**
   > Vide la corbeille. Libère de l'espace disque. Fichiers supprimés à jamais (récupération difficile).

2. **Supprimer Windows.old**
   > Supprime le dossier ancien Windows après mise à jour. Gain : 5-25 GB. Impossible à récupérer après !

3. **Vider caches navigateurs**
   > Vide les caches navigateur (Chrome, Edge). Supprime cookies, historique, données de login. À redémarrer le navigateur.

4. **Désinstaller OneDrive**
   > Désinstalle OneDrive. Ne synchronise plus tes fichiers cloud Microsoft. Fichiers locaux restent intacts.

5. **Debloat constructeur (OEM)**
   > Supprime les apps inutiles du fabricant (jeux, suites Microsoft pré-installées, etc.)

### Mode Dry-Run
- **Checkbox "Mode dry-run (-WhatIf)"**
  > Simule TOUT sans rien modifier. Idéal pour tester avant de vraiment exécuter. Aucun fichier modifié.

### Boutons
- **LANCER**
  > Démarre l'exécution des modules sélectionnés. Durée : 10-30 min selon le choix.

- **Copier le mot de passe**
  > Copie la passphrase admin dans le presse-papiers (devient actif après le module Comptes).

- **Ouvrir le rapport**
  > Ouvre le rapport final en Notepad++ (récapitulatif des actions et résultats).

## Spécifications techniques

- **Composant :** `System.Windows.Forms.ToolTip`
- **Délai initial :** 500 ms (durée avant apparition au survol)
- **Délai d'affichage :** 5000 ms (5 secondes)
- **Comportement :** Standard WinForms (tooltip disparaît au mouvement de souris)

## Accès utilisateur

Les tooltips s'affichent automatiquement au survol avec la souris :
1. Déplacer la souris sur un contrôle
2. Attendre ~500 ms
3. Tooltip s'affiche avec l'explication

Aucune configuration supplémentaire n'est requise.
