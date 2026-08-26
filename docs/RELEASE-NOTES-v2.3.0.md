# PC-Refresh-Kit v2.3.0 - passe UX terrain

**Date :** 2026-08-22
**Licence :** MIT

## Résumé

Corrections issues du premier retour terrain de la v2.2 : l'interface se comporte désormais comme
elle se lit. Aucun module ne change de comportement, aucune action nouvelle n'est exécutée sur la
machine : cette version ne touche qu'au cockpit, à son vocabulaire et à son aide.

## Profils

- Sélectionner un profil applique immédiatement ses cases (plus de bouton Appliquer).
- Au démarrage, le profil standard est appliqué d'office, aide comprise.
- L'entrée (personnalisé) apparaît dès qu'une case est modifiée à la main ; Enregistrer comme
  profil la conserve sous un nom.

## Lisibilité

- La colonne d'intervention affiche les étapes 1 à 15, en français, dans l'ordre réel d'exécution
  (le Rapport clôt l'intervention en étape 15). Les identifiants 00 à 15 restent les noms de
  fichiers, visibles dans les logs et le rapport.
- Un seul vocabulaire de mode : Simulation / Intervention réelle - sur la case, le badge, le titre
  de fenêtre et le bouton principal (LANCER LA SIMULATION / LANCER L'INTERVENTION). Le mot
  « dry-run » a quitté l'interface.
- Le résumé de la barre d'action compte des étapes, comme la colonne juste au-dessus.
- L'onglet Journal n'apparaît qu'au lancement, quand il a quelque chose à dire.

## Aide intégrée

- Le survol ne remplace le panneau qu'après un court délai : traverser l'écran ne fait plus
  disparaître ce que vous lisiez.
- Entrer dans le panneau fige son contenu : lecture et défilement tranquilles.
- Une épingle en tête du panneau fige la rubrique affichée (Échap la libère).

## Qualité

- Nouveau parcours utilisateur scripté (`Run-GUI.ps1 -SelfTest`, 19 assertions) exécuté en CI :
  profils, étapes, mode et journal sont vérifiés à chaque commit.
- Captures du README refaites sur la version livrée, phase par phase.

## Site du projet

https://kit.trimko.com
