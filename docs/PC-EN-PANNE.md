# PC en panne : le mode secours du kit (mode navette)

Quand Windows ne démarre plus (écran bleu `0xc000014c`, boucle de réparation
automatique, « préparation de la réparation automatique » sans fin), la clé du
kit reste utile. Elle embarque `secours.bat`, lançable depuis l'invite de
commandes de l'environnement de récupération (WinRE), et le coffre de ruches
registre rempli par l'étape « Filets de secours » lors d'un passage précédent,
quand le PC allait bien.

Le mode s'appelle **navette** parce que rien ne s'analyse sur le PC en panne :
la clé collecte, on la rapporte sur un PC sain, on lit, on décide, puis on
revient poser la réparation. Le PC en panne ne sert qu'à exécuter.

---

## Ce que porte la clé

| Élément | Rôle |
|---------|------|
| `secours.bat` (racine de la clé) | Le script à lancer depuis WinRE. Menu D / S / R. |
| `Coffre\<NOM-DU-PC>\hives-<horodatage>\` | Le coffre externe : les 5 ruches registre sauvegardées par l'étape « Filets de secours », plus un `manifest.txt`. |
| `secours\` | Créé à côté de `secours.bat` au premier lancement : c'est là que partent tous les résultats. |

Le coffre existe aussi en copie locale sur le PC, dans
`C:\ProgramData\PC-Refresh-Kit\HiveVault\`. Cette copie-là meurt avec le disque :
elle dépanne un registre cassé sur un disque sain, pas un disque mort. C'est le
coffre de la clé qui compte.

**Ce que le coffre contient, et comment il est protégé.** Les cinq ruches
incluent `SAM` et `SECURITY` : des secrets de comptes. Le kit verrouille donc
chaque coffre posé sur un support qui gère les droits d'accès - NTFS ou ReFS,
c'est-à-dire la copie locale, mais aussi une seconde partition du PC ou une clé
formatée en NTFS : accès réservé à SYSTEM et aux administrateurs, et aucune
ruche écrite si ce verrou échoue. Une clé en FAT32 ou en exFAT, elle, ne peut
porter aucun verrou : sur ce support-là, et seulement sur celui-là, la
protection est physique et le journal le dit. Une telle clé porte alors les
secrets de comptes du PC sans aucun verrou logiciel : conservez-la comme un
trousseau.

---

## Avant toute intervention (checklist)

Ces quatre points se vérifient **avant** de toucher au PC, pas après. Une
réparation réussie qui débouche sur une session inaccessible n'est pas une
réparation réussie.

1. **Accès au compte Microsoft du propriétaire vérifié** : mot de passe connu
   ET téléphone de confirmation à portée. Après une réparation de registre,
   Windows peut redemander une connexion en ligne (« votre appareil est hors
   connexion », « nous n'avons pas pu vous connecter ») et exiger une
   validation à deux facteurs. Sans le téléphone du propriétaire, la session
   reste fermée alors que le PC démarre parfaitement.
2. **Code PIN de session connu.**
3. **Clé de récupération BitLocker accessible** si le disque est chiffré :
   sur https://aka.ms/myrecoverykey avec le compte Microsoft du propriétaire,
   ou dans le coffre externe (`bitlocker-recovery.txt`) si l'option d'export a
   été cochée lors d'un passage précédent du kit ET que ce coffre vivait sur une
   clé USB amovible - le kit refuse d'écrire les 48 chiffres sur une partition
   interne ou un disque fixe, qui resteraient à demeure à côté du disque qu'ils
   ouvrent. Sans cette clé, WinRE ne verra même pas le volume Windows.
4. **La clé porte un coffre de CE PC** : un dossier
   `Coffre\<NOM-DU-PC>\hives-<horodatage>\` contenant un `manifest.txt`. Sans
   coffre, les menus D et S restent utiles (diagnostic et sauvetage), mais la
   restauration R n'aura rien à poser.

Prévoir aussi du temps : le diagnostic complet dure 10 à 25 minutes, et le
`chkdsk` de la restauration 10 à 40 minutes de plus.

---

## Ouvrir l'invite de commandes du PC en panne

Windows bascule seul dans WinRE après deux ou trois échecs de démarrage. Pour
le forcer : éteindre le PC de force (bouton maintenu) trois fois de suite
pendant l'affichage du logo.

Puis : **Dépannage > Options avancées > Invite de commandes**.

Une fenêtre noire s'ouvre, généralement sur `X:\Windows\System32`. `X:` est le
disque en mémoire de WinRE, pas le disque du PC.

---

## Lancer secours.bat

1. Brancher la clé du kit.
2. Trouver sa lettre : taper `c:` puis `dir`, puis `d:` puis `dir`, puis `e:`,
   `f:`... jusqu'à voir les fichiers du kit. Vu depuis WinRE, le volume Windows
   n'est pas toujours `C:` et la clé change de lettre d'un PC à l'autre : ne
   jamais supposer.
3. Le clavier peut être en QWERTY. Les lettres de A à Z ne bougent pas (sauf
   A/Q, Z/W et M), mais les chiffres et les symboles, si : `:` s'obtient
   parfois avec `Maj` et la touche `.` de l'AZERTY (la touche du `;`).
4. Taper `secours.bat` une fois placé sur la lettre de la clé (ou
   `<lettre>:\secours.bat` depuis n'importe où).

Le menu affiche d'emblée deux informations décisives :

```
  Volume Windows detecte : [D:]
  Coffre de ruches       : [E:\Coffre\PC-BUREAU\hives-20260815-101530]
```

Des crochets vides à la première ligne signifient qu'aucun volume Windows n'a
été trouvé (disque mort, ou BitLocker non déverrouillé). Des crochets vides à
la seconde signifient qu'aucun coffre de ce PC n'a été reconnu.

---

## Le menu : D, puis S, puis (peut-être) R

### D - Diagnostic, lecture seule, 10 à 25 minutes

**Toujours en premier.** Il ne modifie rien sur le PC en panne. Il relance la
détection du volume et du coffre, puis écrit sur la clé :

- l'état du dossier `config` (les 5 ruches et leurs journaux de transaction) ;
- l'espace libre du volume Windows ;
- un sondage des clichés VSS 1 à 30, avec le nombre de clichés exploitables ;
- les inventaires complets des dossiers (`dump-*.txt`), la partie la plus longue ;
- la liste des outils réellement présents dans ce WinRE.

Le diagnostic est aussi le **laissez-passer de la restauration** : le menu R
refuse de travailler tant que D n'a pas tourné dans la session courante.
Relancer D coûte quelques minutes et garantit qu'on répare sur un état frais,
pas sur un souvenir.

### S - Sauvetage : copier l'état cassé sur la clé

À faire **avant toute réparation**, y compris avant une réparation tentée par
un autre outil. Le sauvetage copie dans `secours\etat-casse\` les 5 ruches
(`SYSTEM`, `SOFTWARE`, `SAM`, `SECURITY`, `DEFAULT`), les journaux `.LOG1` et
`.LOG2` de `SYSTEM` et `SOFTWARE`, et le dossier `TxR` en entier.

C'est le filet de la dernière chance : tant que ces fichiers existent sur la
clé, une réparation ratée reste rattrapable, et une analyse fine du registre
cassé reste possible sur un PC sain.

### R - Restauration d'une ruche depuis le coffre

**Seulement après analyse sur un PC sain**, et seulement si le diagnostic
pointe une ruche cassée alors qu'un coffre de CE PC existe. Voir la section
« Les garde-fous de la restauration » plus bas.

Après une restauration réussie, le script demande, dans cet ordre :

1. appuyer sur une touche pour revenir à l'invite de commandes (le script se
   termine, la fenêtre reste ouverte) ;
2. **retirer la clé USB** (sinon le PC risque de redémarrer dessus) ;
3. taper `wpeutil reboot`.

---

## Lire les fichiers de la navette sur un PC sain

Rapporter la clé et ouvrir le dossier `secours\` :

| Fichier | Contenu |
|---------|---------|
| `secours.txt` | Le journal de toutes les sessions, ajouté à chaque passage (jamais remis à zéro). Refus, tailles, codes de retour. |
| `diagfait.txt` | Date et heure du dernier diagnostic complet, et sur quel volume. |
| `dump-*.txt` | Inventaires des dossiers du volume Windows : racine, Users, Windows, Program Files, ProgramData, System Volume Information. |
| `outils-winre.txt` | Les exécutables présents dans ce WinRE précis (ils varient d'une machine à l'autre). |
| `etat-casse\` | Les ruches et journaux copiés par le menu S. |
| `LISEZMOI.txt` | Le rappel de la marche à suivre, généré sur la clé. |

**Encodage : ces fichiers sortent d'une console Windows, donc en page de codes
OEM 850, pas en UTF-8.** Ouverts tels quels dans un éditeur moderne, les
accents et les caractères de cadre apparaissent en charabia. Dans PowerShell :

```powershell
Get-Content .\secours\secours.txt -Encoding Oem
# Variante explicite, si la page de codes OEM du PC de lecture n'est pas 850 :
[IO.File]::ReadAllText("$PWD\secours\secours.txt", [Text.Encoding]::GetEncoding(850))
```

Ce qu'on cherche dans `secours.txt`, dans l'ordre :

- **La taille des ruches** dans la section `[1/5] ETAT DES RUCHES` : une ruche
  de 0 octet, ou beaucoup plus petite que les autres relevés, désigne la
  coupable. `SYSTEM` fait typiquement plusieurs dizaines de Mo.
- **L'espace libre** : un volume à zéro octet libre explique à lui seul un
  registre cassé, et il faut faire de la place avant toute autre tentative.
- **Le nombre de clichés VSS exploitables** : s'il y en a, une restauration
  système classique depuis WinRE est une option moins lourde que la pose d'une
  ruche.
- **Les lignes de refus** des sessions précédentes, s'il y en a eu.

---

## Les garde-fous de la restauration

Le menu R oppose six refus bloquants avant d'écrire quoi que ce soit. Chacun
laisse le PC exactement dans l'état trouvé.

1. **Volume Windows détecté.** Sans lui, il n'y a nulle part où poser.
2. **Diagnostic D lancé dans la session courante.** Pas de réparation à
   l'aveugle.
3. **Coffre de CE PC trouvé.** L'appariement se fait sur l'empreinte machine
   (`ProgramData\PC-Refresh-Kit\machine-id.txt` sur le volume Windows), jamais
   sur le nom de la machine : en WinRE le nom vaut `MININT-xxx`, et le registre
   qui le porte est justement celui qu'on répare.
4. **Ruche choisie présente dans le jeu retenu.**
5. **Taille du fichier égale à celle annoncée par le `manifest.txt`.** Un
   octet d'écart et la pose est refusée.
6. **Confirmation `OUI` tapée en toutes lettres.** Ni `O`, ni `oui`, ni Entrée.

Une fois ces six points passés, la pose elle-même reste sous surveillance :

- `chkdsk /f` tourne d'abord sur le volume (10 à 40 minutes, ne pas éteindre).
  Sa sortie reste affichée à l'écran : s'il demande à planifier la
  vérification au prochain démarrage, répondre dans la fenêtre. Un code de
  retour supérieur ou égal à 3 arrête tout : le disque se traite avant le
  registre.
- La ruche en place est mise de côté sous `<RUCHE>.casseN` (N = premier numéro
  libre de 1 à 9), et cette copie est **remesurée** : si sa taille ne
  correspond pas à l'original, rien n'est posé. Une sauvegarde tronquée qui
  servirait de retour arrière ferait perdre les deux exemplaires.
- La ruche posée est remesurée elle aussi. En cas d'écart, le retour arrière
  est immédiat, puis vérifié à son tour.
- Les journaux `.LOG1` et `.LOG2` de l'ancienne ruche sont renommés en
  `.casseN`, pour qu'ils ne soient pas rejoués sur la ruche fraîche au
  démarrage suivant.

Le choix de ruche par défaut est `SYSTEM` : c'est le cas classique de l'erreur
`0xc000014c` au démarrage. Restaurer `SOFTWARE`, `SAM`, `SECURITY` ou `DEFAULT`
peut désynchroniser des applications ou des comptes, et ne se fait que si
l'analyse menée sur le PC sain l'a explicitement demandé.

---

## Quand secours.bat refuse ou alerte

### Jeu incomplet

> `REFUS : la ruche <RUCHE> est absente du coffre retenu.`

Le jeu retenu est le **plus récent** de ce PC, pas le seul. Le kit n'écrit le
`manifest.txt` d'un jeu que lorsque ses 5 ruches sont là : un jeu à la fois
manifesté et amputé a donc perdu un fichier après coup, par une copie partielle
du coffre, une suppression manuelle ou un défaut du support.

Marche à suivre :

1. Noter le chemin du jeu retenu, affiché par le message.
2. Sur un PC sain, ouvrir le dossier `Coffre\<NOM-DU-PC>\` de la clé et lister
   les autres jeux `hives-<horodatage>`. Sur une clé formatée en NTFS, ce
   dossier est verrouillé pour les administrateurs : ouvrir l'Explorateur ou
   l'invite de commandes en tant qu'administrateur pour y accéder (une clé
   FAT32 ou exFAT s'ouvre sans droits particuliers).
3. Repérer un jeu plus ancien qui contient à la fois la ruche voulue et un
   `manifest.txt`.
4. Pour le forcer, **sortir les jeux plus récents du dossier `Coffre`** : les
   déplacer dans un dossier créé à côté, par exemple `Coffre-ecarte\`, jamais à
   l'intérieur de `Coffre\`. Le script retient toujours le jeu le plus récent
   qui reste. Ne jamais renommer ni bricoler un jeu : le déplacer suffit.
5. Relancer `secours.bat`, refaire D, puis R.

Sans aucun jeu complet : le coffre local du PC
(`ProgramData\PC-Refresh-Kit\HiveVault\`) est fouillé en dernier recours et
peut en contenir un, à condition que le disque soit encore lisible. Sinon, la
piste des clichés VSS relevés par le diagnostic reste ouverte.

### Jeu corrompu

> `REFUS : <RUCHE> du coffre fait N octets au lieu de M annoncés par le
> manifeste. Jeu corrompu, rien n'a ete fait.`

Le fichier du coffre ne correspond plus à ce que le manifeste annonce : copie
interrompue, clé retirée pendant une écriture, ou support en fin de vie. Poser
une ruche tronquée rendrait le PC indémarrable avec le message d'origine, en
pire.

Marche à suivre : identique à celle du jeu incomplet, en écartant le jeu
corrompu du dossier `Coffre` pour laisser le script retenir le jeu sain
précédent. Et si toute une clé donne des tailles fausses, la traiter comme
suspecte : recopier ce qui reste lisible ailleurs avant de continuer.

Variante : `REFUS : le manifeste du coffre n'annonce aucune taille pour <RUCHE>.`
Le `manifest.txt` du jeu a été tronqué (clé retirée pendant son écriture) : même
remède, écarter ce jeu et retenir le précédent.

### La ruche actuelle n'a pas pu être mise de côté

> `REFUS : la ruche actuelle n'a pas pu etre mise de cote INTACTE.`

Rien n'a été posé, et c'est voulu : sans copie de secours entière, un échec de
pose serait sans retour. La cause est presque toujours un volume plein ou en
lecture seule. Lire l'espace libre dans `secours.txt`, faire de la place depuis
WinRE (les `dump-*.txt` du diagnostic montrent où est le volume), puis
relancer D et R.

### DANGER : ruche tronquée sur le volume

> `DANGER : ... ce volume porte une ruche <RUCHE> TRONQUEE. NE REDEMARREZ PAS
> dessus.`

Cas rare : la pose a échoué **et** le retour arrière aussi, ou il n'y avait pas
de ruche d'origine à remettre. Le message nomme les exemplaires complets encore
récupérables (la copie `.casseN` sur le volume, et la ruche du coffre).

**Ne pas redémarrer.** Marche à suivre :

1. Ne rien tenter d'autre tant que la cause n'est pas levée : c'est presque
   toujours un volume plein, et la même cause tronquera la tentative suivante.
2. Libérer de l'espace sur le volume Windows depuis WinRE.
3. Relancer `secours.bat`, refaire D (il remesure l'espace), puis R. Le script
   choisira un nouveau suffixe `.casseN` et ne touchera pas aux précédents.
4. Si l'espace n'est pas en cause, rapporter la clé : `secours.txt` porte les
   tailles exactes de chaque étape et permet de comprendre laquelle a menti.

### Un journal .LOG1 ou .LOG2 n'a pas pu être renommé

> `AVERTISSEMENT : <RUCHE>.LOG1 n'a pas pu etre renomme, il est toujours en
> place et peut etre rejoue sur la ruche fraiche au demarrage.`

Ce n'est pas bloquant, la ruche est posée. Mais un ancien journal laissé en
place peut être rejoué au démarrage **par-dessus** la ruche fraîche et rendre
la réparation inopérante. Avant de redémarrer, renommer le fichier à la main
depuis la même invite de commandes :

```
attrib -s -h D:\Windows\System32\config\SYSTEM.LOG1
ren D:\Windows\System32\config\SYSTEM.LOG1 SYSTEM.LOG1.ecarte
```

(adapter la lettre du volume Windows, celle affichée dans le menu). Si le
renommage échoue encore, redémarrer quand même : si le PC repart, tant mieux ;
s'il retombe en panne avec la même erreur, le journal rejoué est la cause et le
diagnostic le montrera.

### Aucun volume Windows trouvé

Le disque est mort, ou il est chiffré par BitLocker et non déverrouillé. Le
script écrit alors dans le journal la liste de tous les lecteurs visibles.

Déverrouiller avec la clé de récupération à 48 chiffres du propriétaire, si ce
WinRE embarque `manage-bde` :

```
manage-bde -unlock D: -RecoveryPassword 123456-123456-123456-123456-123456-123456-123456-123456
```

Puis relancer D depuis le menu : la détection du volume et du coffre est refaite
à chaque diagnostic, sans avoir à relancer le script.

---

## Après le redémarrage réussi (checklist de restitution)

1. **Ouvrir la session** (PIN). Si Windows affiche « votre appareil est hors
   connexion » ou refuse le PIN : connecter le Wi-Fi depuis l'écran de
   connexion (icône réseau en bas à droite), puis valider avec le mot de passe
   du compte Microsoft et le téléphone du propriétaire. C'est le moment où la
   checklist d'avant intervention se paie.
2. **Relancer le kit complet côté Windows**, ou au minimum les étapes
   Diagnostic, Filets de secours et Rapport : le PC repart avec un coffre neuf
   et sain, et les filets sont réarmés.
3. **Vérifier dans le rapport** : l'étape « Filets de secours » en OK, l'espace
   libre de C: au vert, WinRE `Enabled`, la restauration système active et un
   point de restauration présent.
4. **Tester le compte Microsoft en ligne** (ouvrir les Paramètres > Comptes, ou
   simplement le Microsoft Store) : si une reconnexion est demandée, la faire
   pendant qu'on est encore devant le PC avec le propriétaire.
5. **Ne rien nettoyer tout de suite** : garder les fichiers `<RUCHE>.casseN` du
   dossier `config`, le dossier `secours\etat-casse\` de la clé et l'ancien
   coffre pendant quelques semaines. Une panne qui revient au bout de trois
   jours a besoin de ces pièces.

---

## Ce que le mode secours ne fait pas

- Il ne réinstalle pas Windows et ne touche à aucun fichier personnel.
- Il ne restaure pas de cliché VSS : il les **détecte et les compte**, la
  restauration système reste à lancer depuis les options avancées de WinRE.
- Il ne répare pas une ruche cassée : il en **pose une saine** venue du coffre.
  Quand il n'existe ni coffre ni cliché, et que la ruche cassée est le seul
  exemplaire, l'atelier `tools/regf` (hors zip de distribution, réservé à un
  usage expert) permet une analyse et une réparation d'en-tête sur copie.
- Il ne déverrouille pas BitLocker à votre place : il affiche la commande, la
  clé de récupération reste à fournir.
