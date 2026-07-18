# Procedure operateur - PC-Refresh-Kit

Checklist a suivre le jour de l'intervention, sur le PC d'un proche. A lire en entier avant le premier vrai PC. Le README documente les commandes ; ce fichier documente le deroule humain (quoi demander, verifier, remettre).

Regle d'or : **lancer le kit depuis la session du proprietaire du PC** (son compte Windows, qui doit etre administrateur au depart). C'est ce compte que le module 01 sauvegarde et que le module 08 retrograde en standard. Lancer depuis un autre compte = backup du mauvais profil + mauvais compte retrograde.

---

## Avant l'intervention - 5 questions au proprietaire

- [ ] **Antivirus payant ?** (Avast, Norton, McAfee avec abonnement) - le module 02 desinstalle l'AV tiers et reactive Defender. A valider s'il y a un abonnement en cours.
- [ ] **Apps utilisees ?** Xbox / Game Pass, Spotify, Skype, Films & TV, Lien avec le telephone. Les garde-fous v1.1 protegent Game Pass et detectent l'usage recent, mais en mode `-All` la suppression est automatique pour le "non utilise". En cas de doute, lancer le module 03 en interactif.
- [ ] **Compte standard accepte ?** Le module 08 passe le compte quotidien en standard (mot de passe admin demande a chaque install). Plus sur, mais contraignant. Si non souhaite : sauter le module 08.
- [ ] **Donnees a sauvegarder ?** Si oui, brancher un disque externe (voir ci-dessous).
- [ ] **Mot de passe de session connu ?** Pour pouvoir rouvrir la session apres redemarrage.

## Avant l'intervention - preparation technique

- [ ] Kit copie sur cle USB, dossier `runtime/` vide (pas de fiche d'un PC precedent qui traine).
- [ ] **Session ouverte sur le compte du proprietaire**, et ce compte est administrateur. Verifier via Parametres > Comptes > "Vos informations" (mention "Administrateur" sous le nom). Si le compte n'a PAS de mot de passe de session : aucun probleme, l'UAC demande juste "Oui" (pas de mot de passe puisque deja admin), et le kit ne met jamais de mot de passe sur le compte du proprietaire. Si le compte n'est PAS admin (rare) : il faut un autre compte admin existant pour lancer.
- [ ] PC branche sur secteur (DISM, updates et defrag sont longs).
- [ ] Connexion internet active (modules 05 Updates et 06 Software).
- [ ] Disque externe branche si backup data voulu. Le module 01 copie Documents, Desktop, Pictures, Downloads (+ Videos, Music si presents) vers `PCRefresh-Backup-<PC>-<date>` sur le disque externe. **Ce qui n'est PAS copie** : AppData (mails Thunderbird/Outlook locaux, mots de passe et favoris navigateur, donnees d'applis), les autres disques (D:), les autres profils. Si le proprietaire a des mails en local ou des donnees ailleurs, les sauver a la main avant. Sans disque externe : seul le point de restauration systeme est cree (les fichiers perso ne sont pas copies, mais rien n'est supprime non plus).

## Etape 1 - Dry-run (aucune modification)

**Plus simple avec la GUI :** double-clic sur `Lancer.bat`, cocher "Mode dry-run (-WhatIf)" en bas a gauche, puis LANCER. Meme effet que `Run.ps1 -WhatIf`, avec le log en direct dans la fenetre.

En ligne de commande (fallback si la GUI ne s'ouvre pas) :

```powershell
Set-Location E:\PC-Refresh-Kit   # adapter la lettre de la cle
powershell -ExecutionPolicy Bypass -File .\Run.ps1 -WhatIf
```

Taper `A` pour voir l'enchainement complet sans rien modifier. Lire surtout ce que veulent faire le module 03 (Debloat) et le module 08 (Accounts).

## Etape 2 - Run reel, module par module (recommande pour un premier PC)

Relancer sans `-WhatIf`, puis choisir les modules un par un dans le menu. Points de vigilance :

| Module | Vigilance |
|--------|-----------|
| 00 Diagnostic | Lecture seule. Note l'inventaire (modele, disque, AV present). |
| 01 Backup | Point de restauration + copie data si disque externe. **Apres ce module, ouvrir le dossier `PCRefresh-Backup-...` sur le disque externe et verifier visuellement que les fichiers y sont AVANT de continuer** (robocopy logue un code mais ne verifie pas octet par octet). Si le point de restauration echoue, decider si on continue. |
| 02 Antivirus | Avast -> Defender. Confirmer d'abord si AV payant. |
| 03 Debloat | Le lancer **sans `-Force`** pour valider les apps au cas par cas. |
| 04 Privacy | Telemetrie + TelemetryGuard. SmartScreen est **garde** par defaut (ne pas passer `-DisableSmartScreen` pour un non-technicien). |
| 05 Updates | Long, besoin internet. Skip propre si hors-ligne. |
| 06 Software | Pack de base (Firefox, 7-Zip, VLC, Sumatra, LibreOffice). Besoin internet. |
| 07 Cleanup | DISM / SFC / defrag. Long. Besoin de 8 Go libres sur C: pour DISM. **Debrancher le disque externe de backup avant ce module** : il optimise/defragmente tous les disques fixes (le disque externe s'il est vu comme fixe = long et inutile), et "vider la corbeille" si coche vide aussi celle du disque externe. |
| 08 Accounts | **MODULE CRITIQUE. Noter le mot de passe admin affiche en console (encadre jaune/vert).** |
| 09 Comfort | OneDrive off, extensions visibles, suggestions off. |
| 10 Report | Genere le rapport + la note utilisateur dans `runtime/`. |

Alternative rapide pour un PC deja connu : `powershell -ExecutionPolicy Bypass -File .\Run.ps1 -All`. Attention : `-All` passe `-Force` partout, donc debloat automatique sans confirmation.

## Etape 3 - Verifications avant de rendre le PC

- [ ] Recuperer le mot de passe admin dans `runtime\FICHE-PC-<PC>.txt`.
- [ ] **Se connecter une fois au compte `Admin-Local`** avec ce mot de passe pour verifier qu'il fonctionne. Tant que ce n'est pas valide, ne pas rendre le PC (tu es encore admin pour corriger).
- [ ] Verifier que la session du proprietaire s'ouvre toujours (elle est maintenant en standard).
- [ ] Si la banniere **REDEMARRAGE REQUIS** s'est affichee (ou fichier `runtime\reboot-required.flag` present) : redemarrer le PC avant de le rendre.
- [ ] Lire `runtime\RAPPORT-<PC>-<date>.txt` et verifier le nombre d'ERROR.

## Etape 4 - Rendre le PC

- [ ] Remettre la note utilisateur (`runtime\NOTE-UTILISATEUR-<PC>.md`), imprimee ou transmise.
- [ ] **Communiquer le mot de passe admin** au proprietaire, a stocker dans un gestionnaire (Bitwarden gratuit) ou sur papier en lieu sur. Le mot de passe n'est volontairement pas dans la note utilisateur.
- [ ] **Antivirus** : expliquer que l'Avast payant est remplace par Windows Defender (gratuit, integre a Windows, suffisant pour un usage normal). **Lui dire de resilier son abonnement Avast cote facturation** - le kit desinstalle le logiciel mais ne resilie pas l'abonnement ; sans resiliation, le proprietaire paie dans le vide.
- [ ] **Compte et mot de passe** : expliquer que le compte quotidien est en standard pour la securite ; quand un logiciel demande un mot de passe administrateur lors d'une installation, c'est normal, c'est le compte `Admin-Local` + ce mot de passe. **Ce mot de passe n'a RIEN a voir avec l'antivirus** - ne pas confondre les deux sujets en parlant au proprietaire.
- [ ] **Nettoyer la cle USB** : supprimer `runtime\FICHE-PC-*.txt` de la cle (ne pas repartir avec le mot de passe en clair sur la cle). Le conserver cote operateur uniquement dans un gestionnaire de mots de passe si besoin de suivi.

---

## Pieges connus (les eviter)

- **Mot de passe admin non note** = le proprietaire ne peut plus rien installer sur son propre PC. Le piege numero un.
- **Kit lance depuis un autre compte que celui du proprietaire** = backup du mauvais profil, mauvais compte retrograde en standard.
- **Rendre sans redemarrer** alors qu'un reboot est requis = mises a jour et reparations non finalisees.
- **AV payant desinstalle sans prevenir** = abonnement perdu, proprietaire mecontent.
- **Pas de disque externe** = pas de copie des fichiers perso (seul le point de restauration systeme protege, et uniquement le systeme).
- **Compte standard impose alors qu'il le gene** : si le proprietaire installe souvent des logiciels et que ca le frustre, c'etait une erreur de le retrograder. Le remettre administrateur (via `Admin-Local`) ou sauter le module 08 des le depart.
- **Compte du proprietaire non administrateur au depart** = impossible de lancer le kit, et le module 08 echoue. Verifier avant.
- **Confondre antivirus et mot de passe admin** en rendant le PC = proprietaire desinforme. L'antivirus, c'est Windows Defender (gratuit) ; le mot de passe, c'est pour installer des logiciels. Deux sujets distincts.
- **Abonnement Avast non resilie** = le proprietaire continue de payer un logiciel desinstalle. Lui rappeler de resilier cote facturation.
- **Disque externe laisse branche pendant le module 07** = defrag inutile du disque (long) et corbeille du disque externe videe si l'option est cochee. Le debrancher apres le module 01.
- **AppData non sauvegarde** : le backup ne couvre pas les mails locaux, favoris et mots de passe navigateur. Si le proprietaire y tient, les exporter a la main avant l'intervention.
