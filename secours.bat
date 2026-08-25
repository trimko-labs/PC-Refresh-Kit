@echo off
setlocal EnableDelayedExpansion
REM ================================================================
REM  PC-Refresh-Kit - secours.bat : mode secours WinRE (v2.4)
REM
REM  A lancer depuis la cle USB du kit quand Windows ne demarre plus,
REM  dans l'invite de commandes de l'environnement de recuperation.
REM
REM  Ce fichier est le SEUL du depot ecrit en ASCII pur, donc SANS
REM  AUCUN ACCENT : un WinRE affiche en page de codes OEM et tout
REM  octet au-dela de 0x7F y devient illisible. Exception assumee a
REM  la regle des accents francais, verrouillee par les tests.
REM  Les autres contraintes ont chacune ete payees sur une reparation
REM  reelle de ruche de registre :
REM   - fins de ligne CRLF, cmd.exe est le seul interpreteur present
REM   - zero tube : findstr manque aux WinRE depouilles et son absence
REM     dans un tube tue le script net, sans le moindre message
REM   - binaires limites a reg, xcopy, attrib, chkdsk et fsutil
REM   - aucune lettre de volume en dur : vu depuis WinRE le volume
REM     Windows n'est pas toujours C:, et la cle change de lettre
REM   - erreurs toujours visibles : une redirection vers nul de trop
REM     a deja produit deux faux verdicts pendant une reparation
REM   - aucun bloc if a parentheses autour d'un chemin : le dossier
REM     Program Files x86 en contient et casse le bloc
REM   - chaque binaire externe recoit une entree standard vide, prise
REM     sur nul : PROUVE en local, fsutil, xcopy et attrib heritent de
REM     l'entree standard et la vident. Seul chkdsk la garde, pour que
REM     l'operateur puisse repondre a une eventuelle question, et sa
REM     sortie n'est jamais redirigee : cachee dans le journal, cette
REM     question laisserait une console figee sans explication
REM
REM  Toutes les sorties vont dans le dossier secours de la cle.
REM ================================================================

set "USB=%~d0"
set "KITDIR=%~dp0"
set "SDIR=%~dp0secours"
set "LOG=%SDIR%\secours.txt"
if not defined TEMP set "TEMP=X:\Windows\Temp"
if not exist "%SDIR%" md "%SDIR%"

REM --- Crochets de test, inertes en usage reel. SECOURS_DRYRUN prefixe
REM     toute ecriture systeme par un echo et neutralise les pause.
REM     PIEGE PROUVE en local : pause consomme l'entree standard quand
REM     elle vient d'un fichier et desynchronise les set /p suivants.
set "DO="
if defined SECOURS_DRYRUN set "DO=echo [DRYRUN] "

REM --- Le kit vit-il a la racine de la cle ? Le coffre du module 16
REM     s'ecrit a la RACINE du volume, alors que le script peut avoir
REM     ete copie dans un sous-dossier : les deux racines sont fouillees.
set "SAMERACINE="
if /i "%KITDIR%"=="%USB%\" set "SAMERACINE=1"

REM --- LISEZMOI de navette, genere au premier lancement ---
if not exist "%SDIR%\LISEZMOI.txt" call :lisezmoi

REM --- Crochets de test SECOURS_FORCE_* : ils choisissent le volume ou
REM     l'empreinte machine a la place des garde-fous. Un garde-fou
REM     contourne ne doit jamais passer inapercu : le menu l'annonce.
set "FORCEHOOK="
if defined SECOURS_FORCE_WIN set "FORCEHOOK=1"
if defined SECOURS_FORCE_MID set "FORCEHOOK=1"

REM --- Detection du volume Windows puis du coffre. Refaite a chaque
REM     diagnostic, cf :detecte. X est exclu de toutes les boucles de
REM     lettres : c'est le disque en memoire de WinRE lui-meme.
call :detecte

set "DIAGOK="
set "VIDE=0"

:menu
echo.
echo  ==================================================
echo   PC-REFRESH-KIT - MODE SECOURS, Windows en panne
echo  ==================================================
echo   Volume Windows detecte : [%WINVOL%]
echo   Coffre de ruches       : [%COFFRE%]
if defined SECOURS_DRYRUN echo   MODE TEST DRYRUN ACTIF - aucune ecriture systeme
if defined FORCEHOOK echo   MODE TEST : garde-fou contourne (SECOURS_FORCE_*)
echo.
echo   D - Diagnostic en lecture seule, 10 a 25 min
echo   S - Sauvetage : copier l'etat actuel vers la cle
echo   R - Restauration d'une ruche depuis le coffre
echo   Q - Quitter
echo.
set "CHOIX="
set /p CHOIX="Votre choix D, S, R ou Q puis Entree : "
if not defined CHOIX goto menu_vide
set "VIDE=0"
if /i "!CHOIX!"=="D" goto diag
if /i "!CHOIX!"=="S" goto sauve
if /i "!CHOIX!"=="R" goto restaure
if /i "!CHOIX!"=="Q" goto fin
echo  Choix non reconnu.
goto menu

REM Reponse vide en boucle : soit une touche Entree repetee, soit une
REM entree standard epuisee. Sans ce compteur le menu tournerait sans fin.
:menu_vide
set /a VIDE+=1
if !VIDE! geq 3 goto menu_fin_vide
echo  Reponse vide. Tapez D, S, R ou Q.
goto menu

:menu_fin_vide
echo.
echo  Trois reponses vides de suite : fermeture du mode secours.
goto fin

REM ================================================================
REM  ROUTINES DE DETECTION
REM ================================================================
REM Detection complete, rejouable : volume Windows, empreinte, coffre.
REM Le diagnostic la relance a chaque passage. Sans cela, un volume
REM BitLocker deverrouille A LA MAIN pendant la session resterait invisible
REM jusqu'a un nouveau lancement du script, le menu afficherait toujours des
REM crochets vides et la restauration refuserait sans rien expliquer.
:detecte
set "WINVOL="
set "NBWIN=0"
set "MIDVOL="
set "COFFRE="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :sonde_win %%D
if defined SECOURS_FORCE_WIN set "WINVOL=%SECOURS_FORCE_WIN%"
call :cherche_coffre
goto :eof

REM Le repere est le DOSSIER config, pas la ruche SAM qui s'y trouve : sous
REM WinRE le script tourne en SYSTEM et voit les deux, mais l'ACL de SAM
REM masque le fichier a tout autre compte et le volume passerait inapercu.
:sonde_win
if not exist "%1:\Windows\System32\config\" goto :eof
set /a NBWIN+=1
if not defined WINVOL set "WINVOL=%1:"
goto :eof

REM Empreinte machine posee par le module Filets de secours cote Windows.
REM Seul ce fichier fait foi : en WinRE le nom de machine vaut MININT-xxx
REM et le registre, justement, peut etre illisible.
:lire_mid
set "MIDVOL="
if not exist "%~1\ProgramData\PC-Refresh-Kit\machine-id.txt" goto lire_mid_force
set /p MIDVOL=<"%~1\ProgramData\PC-Refresh-Kit\machine-id.txt"
REM SECOURS_FORCE_MID est un crochet de TEST, jamais un reglage : il fait
REM concorder n'importe quel coffre avec n'importe quel volume. En usage reel
REM il rouvrirait la porte que :r_autre_pc ferme, celle de la ruche SYSTEM
REM d'une AUTRE machine posee sur ce PC. Il ne vit donc que sous
REM SECOURS_DRYRUN, comme SECOURS_FORCE_WIN qui choisit la lettre du volume.
:lire_mid_force
if not defined SECOURS_DRYRUN goto :eof
if defined SECOURS_FORCE_MID set "MIDVOL=%SECOURS_FORCE_MID%"
goto :eof

REM Le coffre n'est JAMAIS reconstruit depuis le nom de machine : ce nom est
REM assaini en ASCII cote Windows et ne concorde plus avec un nom accentue.
REM On enumere les coffres et on apparie par empreinte machine.
:cherche_coffre
if not defined WINVOL goto :eof
call :lire_mid "%WINVOL%"
call :trouve_coffre "%WINVOL%"
if defined COFFRE goto :eof
if defined SECOURS_FORCE_WIN goto :eof
if %NBWIN% leq 1 goto :eof
REM Plusieurs volumes portent un Windows : celui dont l'empreinte designe
REM un coffre est le bon. Sinon on garde le premier trouve.
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :essai_vol %%D
if defined COFFRE goto :eof
call :lire_mid "%WINVOL%"
goto :eof

:essai_vol
if defined COFFRE goto :eof
if not exist "%1:\Windows\System32\config\" goto :eof
call :lire_mid "%1:"
call :trouve_coffre "%1:"
if not defined COFFRE goto :eof
set "WINVOL=%1:"
goto :eof

REM Ordre de fouille : le coffre de la cle d'abord, celui du disque en
REM panne en dernier recours. Argument 1 = volume Windows candidat.
:trouve_coffre
set "COFFRE="
set "MEILLEUR="
if not defined MIDVOL goto :eof
call :scan_racine "%KITDIR%Coffre"
if defined SAMERACINE goto trouve_coffre_local
call :scan_racine "%USB%\Coffre"
:trouve_coffre_local
if defined COFFRE goto :eof
if "%~1"=="" goto :eof
call :scan_pc "%~1\ProgramData\PC-Refresh-Kit\HiveVault"
goto :eof

:scan_racine
if not exist "%~1\" goto :eof
for /d %%C in ("%~1\*") do call :scan_pc "%%~fC"
goto :eof

:scan_pc
if not exist "%~1\" goto :eof
for /d %%J in ("%~1\hives-*") do call :scan_jeu "%%~fJ"
goto :eof

REM Un jeu sans manifeste est un jeu incomplet : inutilisable, il est ignore.
REM Entre deux jeux du bon PC, le nom horodate hives-aaaammjj-hhmmss tranche.
:scan_jeu
if not exist "%~1\manifest.txt" goto :eof
set "MFID="
for /f "usebackq tokens=1,2 delims==" %%A in ("%~1\manifest.txt") do call :lit_mid_ligne "%%A" "%%B"
if not defined MFID goto :eof
if /i not "!MFID!"=="!MIDVOL!" goto :eof
set "JEU=%~nx1"
if not defined MEILLEUR goto scan_jeu_prend
if /i not "!JEU!" gtr "!MEILLEUR!" goto :eof
:scan_jeu_prend
set "MEILLEUR=%~nx1"
set "COFFRE=%~1"
goto :eof

:lit_mid_ligne
if /i not "%~1"=="machineid" goto :eof
set "MFID=%~2"
goto :eof

:lit_manifeste
if /i "%~1"=="machineid" set "MFID=%~2"
if /i "%~1"=="%TCLE%" set "MFTAILLE=%~2"
goto :eof

REM ================================================================
REM  D - DIAGNOSTIC, LECTURE SEULE SUR LE VOLUME WINDOWS
REM ================================================================
REM Le diagnostic redetecte avant tout : c'est le seul point de passage
REM obligatoire avant la restauration, et le volume a pu apparaitre entre
REM deux passages, par exemple apres un deverrouillage BitLocker manuel.
REM Le journal est TOUJOURS ajoute, jamais remis a zero : cette cle est une
REM navette, elle porte l'inventaire, les refus et les traces de reparation
REM des sessions precedentes. Un seul > ici les effacerait tous, alors que
REM la restauration R impose justement un nouveau diagnostic.
:diag
call :detecte
>>"%LOG%" echo.
>>"%LOG%" echo ==== SECOURS DIAG - lecture seule ====
>>"%LOG%" echo Date: %DATE% %TIME%
>>"%LOG%" echo Script: %~f0
>>"%LOG%" ver
>>"%LOG%" echo Volume Windows : [%WINVOL%]  Candidats : %NBWIN%
>>"%LOG%" echo Empreinte du volume : [%MIDVOL%]
>>"%LOG%" echo Coffre         : [%COFFRE%]
echo.
if not defined WINVOL goto diag_sans_windows
echo  [1/5] Etat des ruches et des journaux...
call :d_etat >>"%LOG%" 2>&1
echo  [2/5] Espace disque...
>>"%LOG%" echo.
>>"%LOG%" echo ==== [2/5] ESPACE ====
>>"%LOG%" fsutil volume diskfree %WINVOL% <nul
echo  [3/5] Sondage des cliches VSS 1 a 30...
set /a NBCS=0
call :d_vss >>"%LOG%" 2>&1
echo  [4/5] Dumps des dossiers vers la cle, le plus long...
call :d_dumps >>"%LOG%" 2>&1
echo  [5/5] Inventaire des outils de ce WinRE...
dir /b "%SystemRoot%\System32\*.exe" > "%SDIR%\outils-winre.txt" 2>&1
dir /b "%SystemRoot%\System32\*.com" >> "%SDIR%\outils-winre.txt" 2>&1
>>"%LOG%" echo ==== FIN DIAG ====
> "%SDIR%\diagfait.txt" echo %DATE% %TIME% - diag complet sur %WINVOL%
set "DIAGOK=1"
echo.
echo  TERMINE. Cliches VSS exploitables : !NBCS!
echo  Resultats sur la cle : secours\secours.txt et secours\dump-*.txt
echo  Rapportez la cle sur un PC sain pour analyse.
if not defined SECOURS_DRYRUN pause
goto menu

:diag_sans_windows
echo  ERREUR : aucun volume Windows trouve.
echo  Si le disque est chiffre par BitLocker, il faut le deverrouiller
echo  avec la cle de recuperation du proprietaire, soit sur son compte
echo  Microsoft aka.ms/myrecoverykey, soit sur la fiche du coffre.
call :aide_bitlocker
echo  Une fois le volume deverrouille, relancez D depuis le menu : la
echo  detection du volume et du coffre est refaite a chaque diagnostic.
echo  Le detail des lecteurs visibles part dans le log.
call :dumpletters >>"%LOG%" 2>&1
if not defined SECOURS_DRYRUN pause
goto menu

:aide_bitlocker
if not exist "%SystemRoot%\System32\manage-bde.exe" goto :eof
echo  Ce WinRE possede manage-bde. Commande a taper vous-meme :
echo    manage-bde -unlock LETTRE: -RecoveryPassword VOTRE-CLE-48-CHIFFRES
goto :eof

:d_etat
echo.
echo ==== [1/5] ETAT DES RUCHES ====
dir /a "%WINVOL%\Windows\System32\config" 2>&1
echo --- Journaux de transactions TxR ---
dir /a "%WINVOL%\Windows\System32\config\TxR" 2>&1
echo --- Empreinte machine et coffre local ---
dir /a "%WINVOL%\ProgramData\PC-Refresh-Kit" 2>&1
goto :eof

:d_vss
echo.
echo ==== [3/5] CLICHES VSS HarddiskVolumeShadowCopy 1 a 30 ====
if not defined SECOURS_DRYRUN goto d_vss_go
echo [DRYRUN] sondage saute : mklink ecrirait un lien hors du dossier secours
goto :eof
:d_vss_go
for /L %%N in (1,1,30) do call :d_sonde_vss %%N
echo Cliches exploitables : !NBCS!
goto :eof

REM Le lien symbolique vit sur le disque en memoire de WinRE, jamais sur le
REM volume a secourir. PIEGE PAYE : if exist ne resout pas un lien GLOBALROOT,
REM la presence du cliche et celle de la ruche se prouvent par une ligne de dir.
:d_sonde_vss
set "LNK=%TEMP%\prk_cs%1"
rmdir "%LNK%" 2>nul
mklink /d "%LNK%" "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy%1\" >nul 2>&1
set "ALIVE="
for /f "delims=" %%X in ('dir /b /a "%LNK%\" 2^>nul') do if not defined ALIVE set "ALIVE=1"
if defined ALIVE goto d_vss_vivant
echo [CS%1] rien
goto d_vss_fin
:d_vss_vivant
echo [CS%1] CLICHE VIVANT - contenu de config :
dir /a "%LNK%\Windows\System32\config" 2>&1
set "HASSYS="
for /f "delims=" %%X in ('dir /b /a "%LNK%\Windows\System32\config\SYSTEM" 2^>nul') do if not defined HASSYS set "HASSYS=1"
if defined HASSYS set /a NBCS+=1
:d_vss_fin
rmdir "%LNK%" 2>nul
goto :eof

:d_dumps
echo.
echo ==== [4/5] DUMPS VERS LA CLE ====
if not defined SECOURS_DRYRUN goto d_dumps_go
echo [DRYRUN] dumps dir /s sautes
goto :eof
:d_dumps_go
>con echo         racine...
dir /a "%WINVOL%\" > "%SDIR%\dump-racine.txt" 2>&1
>con echo         System Volume Information...
dir /s /a "%WINVOL%\System Volume Information" > "%SDIR%\dump-svi.txt" 2>&1
>con echo         Users, plusieurs minutes...
dir /s /a "%WINVOL%\Users" > "%SDIR%\dump-users.txt" 2>&1
>con echo         Windows, le plus long...
dir /s /a "%WINVOL%\Windows" > "%SDIR%\dump-windows.txt" 2>&1
>con echo         Program Files...
dir /s /a "%WINVOL%\Program Files" > "%SDIR%\dump-progfiles.txt" 2>&1
dir /s /a "%WINVOL%\Program Files (x86)" > "%SDIR%\dump-progfiles86.txt" 2>&1
>con echo         ProgramData...
dir /s /a "%WINVOL%\ProgramData" > "%SDIR%\dump-progdata.txt" 2>&1
dir "%SDIR%\dump-*.txt" 2>&1
goto :eof

:dumpletters
echo.
echo ==== LECTEURS VISIBLES ====
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :dumproot %%D
goto :eof

:dumproot
if not exist "%1:\" goto :eof
echo --- Racine %1: ---
dir /a "%1:\" 2>&1
goto :eof

REM ================================================================
REM  S - SAUVETAGE DE L'ETAT ACTUEL VERS LA CLE
REM ================================================================
:sauve
if not defined WINVOL goto sauve_sans_windows
>>"%LOG%" echo.
>>"%LOG%" echo ==== SAUVETAGE vers la cle ====
echo.
echo  Copie de l'etat actuel, ruches et journaux, vers la cle...
md "%SDIR%\etat-casse" 2>nul
md "%SDIR%\etat-casse\TxR" 2>nul
call :s_copie >>"%LOG%" 2>&1
echo  TERMINE. Verifiez les tailles copiees dans secours\secours.txt.
dir "%SDIR%\etat-casse"
if not defined SECOURS_DRYRUN pause
goto menu

:sauve_sans_windows
echo  ERREUR : aucun volume Windows trouve. Lancez D d'abord.
if not defined SECOURS_DRYRUN pause
goto menu

REM Les ruches et leurs journaux sont des binaires : xcopy uniquement, jamais
REM une copie de texte qui les tronquerait au premier octet de fin de fichier.
:s_copie
echo --- ruches ---
for %%H in (SYSTEM SOFTWARE SAM SECURITY DEFAULT) do call :s_un "%WINVOL%\Windows\System32\config\%%H"
echo --- journaux ---
for %%H in (SYSTEM.LOG1 SYSTEM.LOG2 SOFTWARE.LOG1 SOFTWARE.LOG2) do call :s_un "%WINVOL%\Windows\System32\config\%%H"
echo --- dossier TxR ---
xcopy /h /k /y "%WINVOL%\Windows\System32\config\TxR\*" "%SDIR%\etat-casse\TxR\" <nul 2>&1
echo --- verification ---
dir /a "%SDIR%\etat-casse" 2>&1
goto :eof

:s_un
xcopy /h /k /y "%~1" "%SDIR%\etat-casse\" <nul 2>&1
goto :eof

REM ================================================================
REM  R - RESTAURATION D'UNE RUCHE DEPUIS LE COFFRE
REM  Chaque garde-fou est bloquant et laisse le PC dans l'etat trouve.
REM ================================================================
:restaure
echo.
if not defined WINVOL goto r_sans_windows
if not defined DIAGOK goto r_sans_diag
if not defined COFFRE goto r_sans_coffre
echo  Coffre retenu : %COFFRE%
echo.
echo  Quelle ruche restaurer ?
echo   S - SYSTEM, le cas classique : erreur 0xc000014c au demarrage
echo   W - SOFTWARE   A - SAM   E - SECURITY   D - DEFAULT
echo   Q - retour au menu
set "HCHOIX="
set /p HCHOIX="Votre choix puis Entree, S par defaut : "
if not defined HCHOIX set "HCHOIX=S"
set "HIVE="
if /i "!HCHOIX!"=="S" set "HIVE=SYSTEM"
if /i "!HCHOIX!"=="W" set "HIVE=SOFTWARE"
if /i "!HCHOIX!"=="A" set "HIVE=SAM"
if /i "!HCHOIX!"=="E" set "HIVE=SECURITY"
if /i "!HCHOIX!"=="D" set "HIVE=DEFAULT"
if /i "!HCHOIX!"=="Q" goto menu
if not defined HIVE goto r_choix_ko
if /i not "!HIVE!"=="SYSTEM" call :r_avertit

set "SRC=%COFFRE%\%HIVE%"
if not exist "%SRC%" goto r_hive_absente
set "MFID="
set "MFTAILLE="
set "TCLE=taille_%HIVE%"
for /f "usebackq tokens=1,2 delims==" %%A in ("%COFFRE%\manifest.txt") do call :lit_manifeste "%%A" "%%B"
if not defined MIDVOL goto r_sans_mid
if /i not "!MFID!"=="!MIDVOL!" goto r_autre_pc
if not defined MFTAILLE goto r_sans_taille
set "SZ="
for %%F in ("%SRC%") do set "SZ=%%~zF"
if not "!SZ!"=="!MFTAILLE!" goto r_taille_ko

echo.
echo  PRET A POSER : %HIVE% de !MFTAILLE! octets, depuis le coffre
echo  vers %WINVOL%\Windows\System32\config\%HIVE%
echo  L'ancienne ruche est conservee sous %HIVE%.casseN, retour possible.
echo.
set "CONF="
set /p CONF="Tapez OUI en toutes lettres pour continuer : "
if not "!CONF!"=="OUI" goto r_abandon

set "CFG=%WINVOL%\Windows\System32\config"
>>"%LOG%" echo.
>>"%LOG%" echo ==== RESTAURATION %HIVE% depuis %COFFRE% ====
>>"%LOG%" dir /a "%CFG%\%HIVE%*" 2>&1

echo  [1/4] Verification du disque par chkdsk /f, 10 a 40 min. NE PAS ETEINDRE.
echo        Sa sortie reste a l'ecran : s'il ne peut pas demonter le volume
echo        il pose une question, tapez la reponse dans cette fenetre.
if not defined SECOURS_DRYRUN goto r_chkdsk
>>"%LOG%" echo [DRYRUN] chkdsk saute
goto r_apres_chkdsk
REM Aucune redirection sur chkdsk. Envoyer sa sortie dans le journal y
REM enverrait aussi sa question de demontage, planifier au prochain
REM demarrage O/N : la console resterait figee sans dire si l'outil
REM travaille ou s'il attend une reponse qui n'arrivera jamais. Seul le
REM code retour est journalise. Pas de <nul non plus, chkdsk garde son
REM entree standard pour que l'operateur puisse repondre.
:r_chkdsk
chkdsk %WINVOL% /f
set "CKRC=!errorlevel!"
>>"%LOG%" echo chkdsk code retour : !CKRC!
if !CKRC! geq 3 goto r_chkdsk_ko
:r_apres_chkdsk

echo  [2/4] Mise de cote de la ruche actuelle...
set "CASSE="
set "CASSEN="
set "SZORIG="
set "SZBACK="
for %%N in (1 2 3 4 5 6 7 8 9) do call :r_libre %%N
if not defined CASSE set "CASSE=%HIVE%.casse9"
if not defined CASSEN set "CASSEN=9"
REM Ruche deja disparue : il n'y a rien a mettre de cote, et le retour
REM arriere n'aura pas de source. La pose reste legitime.
if exist "%CFG%\%HIVE%" goto r_copie_avant
>>"%LOG%" echo Aucune ruche %HIVE% en place, rien a mettre de cote.
set "CASSE="
goto r_pose
REM Taille de l'original mesuree AVANT la copie : c'est la seule reference
REM qui prouvera que la sauvegarde vaut quelque chose, puis, en cas de pepin,
REM que le retour arriere a bien rendu une ruche entiere.
:r_copie_avant
if defined SECOURS_DRYRUN goto r_copie_go
for %%F in ("%CFG%\%HIVE%") do set "SZORIG=%%~zF"
>>"%LOG%" echo Ruche %HIVE% en place avant travaux : !SZORIG! octets
:r_copie_go
%DO%copy /b /y "%CFG%\%HIVE%" "%CFG%\!CASSE!" >>"%LOG%" 2>&1
REM Sans copie de secours PROUVEE, poser serait un aller simple : on refuse.
REM L'existence du fichier ne prouve rien du tout. Sur un volume plein, copy
REM ecrit ce qui tient puis s'arrete : le fichier existe et il est tronque.
REM Ecraser l'original par-dessus une sauvegarde pareille detruirait les DEUX
REM exemplaires de la ruche. Seule l'egalite des tailles fait foi.
if defined SECOURS_DRYRUN goto r_pose
if not exist "%CFG%\!CASSE!" goto r_backup_ko
set "SZBACK="
for %%F in ("%CFG%\!CASSE!") do set "SZBACK=%%~zF"
>>"%LOG%" echo Sauvegarde !CASSE! : !SZBACK! octets pour !SZORIG! attendus
if not defined SZORIG goto r_backup_ko
if not defined SZBACK goto r_backup_ko
if not "!SZBACK!"=="!SZORIG!" goto r_backup_ko

:r_pose
echo  [3/4] Pose de la ruche du coffre...
%DO%copy /b /y "%SRC%" "%CFG%\%HIVE%" >>"%LOG%" 2>&1
set "RESTAURE_KO="
set "RETOUR_OK="
if not defined SECOURS_DRYRUN call :r_verifie
if defined RESTAURE_KO goto r_pose_ko

echo  [4/4] Neutralisation des anciens journaux de %HIVE%...
call :r_journal LOG1
call :r_journal LOG2

>>"%LOG%" echo ==== ETAT APRES ====
>>"%LOG%" dir /a "%CFG%\%HIVE%*" 2>&1
>>"%LOG%" echo ==== FIN RESTAURATION ====
echo.
echo  TERMINE. Dans l'ordre :
echo   1. Fermez cette fenetre en appuyant sur une touche
echo   2. RETIREZ LA CLE USB, sinon le PC redemarre dessus
echo   3. Tapez :  wpeutil reboot
echo   4. Apres un redemarrage reussi, relancez le kit cote Windows :
echo      le rapport, puis un nouveau passage de l'etape Filets de secours
if not defined SECOURS_DRYRUN pause
goto fin

REM Premier suffixe casseN libre : une restauration ratee ne doit jamais
REM ecraser la ruche mise de cote par la tentative precedente.
:r_libre
if defined CASSE goto :eof
if exist "%CFG%\%HIVE%.casse%1" goto :eof
set "CASSE=%HIVE%.casse%1"
set "CASSEN=%1"
goto :eof

REM Les journaux portent le meme numero que la ruche mise de cote : un jeu
REM casseN reste coherent. Un suffixe fixe ferait echouer le renommage a la
REM deuxieme tentative, l'ancien journal resterait en place et serait rejoue
REM sur la ruche fraiche : exactement la panne que cette etape doit ecarter.
REM Le renommage se VERIFIE ensuite. Il peut echouer, cible casseN deja prise
REM ou fichier verrouille, et le seul message partirait dans un journal que
REM personne ne lit avant de redemarrer. Ce n'est pas bloquant, la ruche est
REM deja posee, mais l'operateur doit le savoir AVANT le reboot.
:r_journal
if not exist "%CFG%\%HIVE%.%1" goto :eof
%DO%attrib -s -h "%CFG%\%HIVE%.%1" <nul >>"%LOG%" 2>&1
%DO%ren "%CFG%\%HIVE%.%1" "%HIVE%.%1.casse!CASSEN!" >>"%LOG%" 2>&1
if defined SECOURS_DRYRUN goto :eof
if not exist "%CFG%\%HIVE%.%1" goto :eof
echo  AVERTISSEMENT : %HIVE%.%1 n'a pas pu etre renomme, il est toujours
echo  en place et peut etre rejoue sur la ruche fraiche au demarrage.
echo  Voir secours\secours.txt et docs\PC-EN-PANNE.md avant de redemarrer.
>>"%LOG%" echo AVERTISSEMENT : renommage de %HIVE%.%1 en echec, journal toujours en place
goto :eof

REM Verification par taille exacte apres la pose, retour arriere immediat si
REM la copie a ete tronquee : une ruche a moitie ecrite ne demarre jamais.
REM Le retour arriere se MESURE lui aussi avant d'etre annonce : la cause la
REM plus probable d'une pose tronquee est un volume plein, et cette meme
REM cause tronque la copie de retour. Annoncer une remise en place sans la
REM verifier enverrait l'operateur redemarrer sur une ruche morte.
:r_verifie
set "SZ2="
for %%F in ("%CFG%\%HIVE%") do set "SZ2=%%~zF"
if "!SZ2!"=="!MFTAILLE!" goto :eof
set "RESTAURE_KO=1"
>>"%LOG%" echo POSE EN ECHEC : taille !SZ2! au lieu de !MFTAILLE!
if not defined CASSE goto r_verifie_sans_retour
copy /b /y "%CFG%\!CASSE!" "%CFG%\%HIVE%" >>"%LOG%" 2>&1
set "SZ3="
for %%F in ("%CFG%\%HIVE%") do set "SZ3=%%~zF"
if not "!SZ3!"=="!SZORIG!" goto r_verifie_tronque
set "RETOUR_OK=1"
>>"%LOG%" echo Retour arriere effectue depuis !CASSE! : !SZ3! octets rendus
goto :eof
:r_verifie_tronque
>>"%LOG%" echo RETOUR ARRIERE EN ECHEC : ruche en place !SZ3! octets au lieu de !SZORIG!
>>"%LOG%" echo Ruche TRONQUEE sur le volume, ne pas redemarrer dessus.
>>"%LOG%" echo Exemplaires restants : %CFG%\!CASSE! et %SRC%
goto :eof
:r_verifie_sans_retour
>>"%LOG%" echo Aucune ruche d'origine a remettre : la place etait deja vide.
goto :eof

:r_avertit
echo.
echo  ATTENTION : restaurer une autre ruche que SYSTEM peut desynchroniser
echo  des applications ou des comptes. A ne faire que si l'analyse menee
echo  sur le PC sain l'a demande.
goto :eof

:r_sans_windows
echo  REFUS : aucun volume Windows detecte. Lancez D d'abord.
if not defined SECOURS_DRYRUN pause
goto menu

:r_sans_diag
echo  REFUS : lancez d'abord le diagnostic D dans cette session.
echo  Il prend quelques minutes et evite de reparer a l'aveugle.
if not defined SECOURS_DRYRUN pause
goto menu

:r_sans_coffre
echo  REFUS : aucun coffre de CE PC n'a ete trouve.
echo  Le coffre se remplit quand le kit passe sur un PC en bonne sante.
if not defined MIDVOL echo  Note : l'empreinte machine-id.txt du volume Windows est introuvable.
if not defined SECOURS_DRYRUN pause
goto menu

:r_choix_ko
echo  Choix non reconnu.
goto restaure

REM Le coffre retenu est le jeu le PLUS RECENT de ce PC, pas le seul. Un refus
REM muet laisserait l'operateur en cul-de-sac devant une cle qui porte peut-etre
REM un jeu plus ancien et complet. Le chemin retenu se nomme, la suite se lit.
:r_hive_absente
echo  REFUS : la ruche %HIVE% est absente du coffre retenu.
echo  Jeu retenu : %COFFRE%
echo  C'est le jeu le plus recent de CE PC. La cle ou le disque peuvent en
echo  porter d'autres, plus anciens et complets, non essayes ici.
echo  Marche a suivre : docs\PC-EN-PANNE.md, section jeu incomplet.
if not defined SECOURS_DRYRUN pause
goto menu

:r_sans_mid
echo  REFUS : empreinte machine-id.txt introuvable sur %WINVOL%.
echo  Impossible de garantir que ce coffre vient de CE PC.
if not defined SECOURS_DRYRUN pause
goto menu

:r_autre_pc
echo  REFUS : ce coffre vient d'un AUTRE PC, les empreintes different.
echo  Poser la ruche d'une autre machine rendrait ce PC indemarrable.
if not defined SECOURS_DRYRUN pause
goto menu

:r_sans_taille
echo  REFUS : le manifeste du coffre n'annonce aucune taille pour %HIVE%.
echo  Sans taille de reference, l'integrite ne peut pas etre verifiee.
if not defined SECOURS_DRYRUN pause
goto menu

:r_taille_ko
echo  REFUS : %HIVE% du coffre fait !SZ! octets au lieu de !MFTAILLE!
echo  annonces par le manifeste. Jeu corrompu, rien n'a ete fait.
echo  Jeu retenu : %COFFRE%
echo  C'est le jeu le plus recent de CE PC. La cle ou le disque peuvent en
echo  porter d'autres, plus anciens et sains, non essayes ici.
echo  Marche a suivre : docs\PC-EN-PANNE.md, section jeu corrompu.
if not defined SECOURS_DRYRUN pause
goto menu

:r_abandon
echo  Abandon : confirmation non recue. Rien n'a ete fait.
if not defined SECOURS_DRYRUN pause
goto menu

:r_chkdsk_ko
echo  ERREUR GRAVE chkdsk, code retour !CKRC!.
echo  Le detail est reste affiche ci-dessus, seul ce code part dans le log.
echo  La ruche N'A PAS ete posee, le disque doit etre traite d'abord.
if not defined SECOURS_DRYRUN pause
goto menu

REM Trois issues bien distinctes apres une pose ratee, et une seule autorise
REM le mot rassurant : celle ou le retour arriere a ete remesure.
:r_pose_ko
echo  ERREUR : la taille posee ne correspond pas au manifeste.
if defined RETOUR_OK goto r_pose_ko_rendu
if not defined CASSE goto r_pose_ko_vide
echo.
echo  DANGER : le retour arriere a echoue lui aussi, ce volume porte une
echo  ruche %HIVE% TRONQUEE. NE REDEMARREZ PAS dessus.
echo  Exemplaires complets encore recuperables :
echo    %CFG%\!CASSE!
echo    %SRC%
echo  Cause la plus frequente : volume plein. Voir secours\secours.txt et
echo  la marche a suivre docs\PC-EN-PANNE.md avant toute autre tentative.
if not defined SECOURS_DRYRUN pause
goto menu

:r_pose_ko_vide
echo.
echo  DANGER : aucune ruche d'origine n'existait, la place etait vide et
echo  elle porte maintenant une ruche %HIVE% TRONQUEE.
echo  NE REDEMARREZ PAS dessus. Exemplaire complet : %SRC%
echo  Voir secours\secours.txt et docs\PC-EN-PANNE.md.
if not defined SECOURS_DRYRUN pause
goto menu

:r_pose_ko_rendu
echo  La ruche d'origine a ete remise en place, et sa taille reverifiee sur
echo  le volume. Le PC est revenu a l'etat trouve, voir secours\secours.txt.
if not defined SECOURS_DRYRUN pause
goto menu

:r_backup_ko
echo  REFUS : la ruche actuelle n'a pas pu etre mise de cote INTACTE.
if not defined SZBACK echo  La copie !CASSE! n'a meme pas ete creee.
if defined SZBACK echo  Copie !CASSE! de !SZBACK! octets pour !SZORIG! attendus.
echo  Rien n'a ete pose : sans copie de secours entiere, un echec serait
echo  sans retour et le PC perdrait ses deux exemplaires de la ruche.
echo  Voir secours\secours.txt, souvent un disque plein ou en lecture seule.
echo  Marche a suivre : docs\PC-EN-PANNE.md.
if not defined SECOURS_DRYRUN pause
goto menu

REM ================================================================
:lisezmoi
> "%SDIR%\LISEZMOI.txt" echo PC-REFRESH-KIT - MODE SECOURS, mode navette
>>"%SDIR%\LISEZMOI.txt" echo.
>>"%SDIR%\LISEZMOI.txt" echo Ce dossier recoit les resultats de secours.bat, lance depuis
>>"%SDIR%\LISEZMOI.txt" echo l'invite de commandes de l'environnement de recuperation
>>"%SDIR%\LISEZMOI.txt" echo d'un PC qui ne demarre plus.
>>"%SDIR%\LISEZMOI.txt" echo.
>>"%SDIR%\LISEZMOI.txt" echo 1. Sur le PC en panne, brancher la cle, reperer sa lettre en
>>"%SDIR%\LISEZMOI.txt" echo    essayant c: puis d: puis e: suivis de dir, puis taper la
>>"%SDIR%\LISEZMOI.txt" echo    lettre de la cle suivie de \secours.bat
>>"%SDIR%\LISEZMOI.txt" echo 2. Choisir D pour le diagnostic, puis S pour le sauvetage
>>"%SDIR%\LISEZMOI.txt" echo 3. Rapporter la cle sur un PC sain et lire ce dossier :
>>"%SDIR%\LISEZMOI.txt" echo    secours.txt et les fichiers dump-*.txt, encodage console OEM
>>"%SDIR%\LISEZMOI.txt" echo 4. La restauration R ne s'utilise qu'apres analyse, et seulement
>>"%SDIR%\LISEZMOI.txt" echo    avec le coffre de CE PC, rempli par le kit quand il allait bien
goto :eof

:fin
endlocal
exit /b 0
