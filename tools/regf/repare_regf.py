#!/usr/bin/env python3
"""Répare l'en-tête d'une ruche de registre Windows, SUR UNE COPIE.

Seul défaut traité : un commit d'en-tête interrompu, qui laisse la séquence
secondaire en retard sur la primaire et le checksum faux. Le chargeur refuse
alors la ruche entière pour quelques octets, alors que le corps est intact.
La correction : seq2 := seq1, puis recalcul du checksum.

Règles de sécurité du script, non négociables :
  - la ruche source est ouverte en LECTURE SEULE et jamais réécrite ;
  - une destination identique à la source est REFUSÉE ;
  - une destination existante n'est écrasée qu'avec --ecraser ;
  - les champs d'en-tête que le checksum va SIGNER sont contrôlés avant tout :
    un en-tête incohérent est refusé, jamais béni par un checksum tout neuf ;
  - la copie n'est écrite que si son arbre passe walk_regf sans une erreur ;
  - la copie est relue depuis le disque et re-vérifiée après écriture.

Usage   : py -3 repare_regf.py RUCHE_SOURCE RUCHE_REPAREE
Retours : 0 copie écrite et vérifiée, 1 refus ou échec, 2 erreur d'usage.

Bibliothèque standard uniquement.
"""

import argparse
import os
import struct
import sys
from pathlib import Path

# Les trois scripts de l'atelier forment un tout : le checksum vient de
# l'analyseur (une seule implémentation, donc aucun risque de divergence entre
# le verdict et la correction) et le contrôle d'arbre vient du parcours.
#
# Aucun __pycache__ n'est écrit : l'atelier se copie sur une clé USB ou un
# support de secours parfois en lecture seule, et n'a rien à laisser derrière.
sys.dont_write_bytecode = True
_DOSSIER = Path(__file__).resolve().parent
if str(_DOSSIER) not in sys.path:
    sys.path.insert(0, str(_DOSSIER))
try:
    from analyse_regf import (chaine_hbins, checksum_entete, date_filetime,
                              nombre, sortie_tolerante)
    from walk_regf import parcourir
except ImportError as _erreur:
    # Seul message du script volontairement sans accent : il part sur stderr
    # AVANT que sortie_tolerante() (importee juste au-dessus, donc absente ici)
    # n'ait pu rendre la sortie insensible a la page de code de la console.
    sys.stderr.write(
        "ERREUR : analyse_regf.py et walk_regf.py doivent rester dans le meme "
        "dossier que ce script (%s).\nDetail : %s\n" % (_DOSSIER, _erreur))
    sys.exit(1)

ENTETE = 0x1000        # taille du bloc de base d'une ruche : 4096 octets
CHECKSUM_OFF = 0x1FC   # emplacement du checksum dans le bloc de base
GRAIN_HBIN = 0x1000    # une taille de hbin est un multiple de 4096 octets


def meme_fichier(source, destination):
    """Vrai si les deux chemins désignent le même fichier.

    resolve() + normcase couvre la casse et les chemins détournés ; samefile
    couvre en plus les liens durs, les jonctions et les noms courts 8.3, que la
    seule comparaison de chaînes laisserait passer.
    """
    if os.path.normcase(str(source.resolve())) == os.path.normcase(str(destination.resolve())):
        return True
    if destination.exists():
        try:
            return os.path.samefile(str(source), str(destination))
        except OSError:
            return False
    return False


def fichier_lisible(valeur):
    """Type argparse : le chemin doit exister et être un fichier lisible."""
    chemin = Path(valeur)
    if not chemin.exists():
        raise argparse.ArgumentTypeError('fichier introuvable : %s' % valeur)
    if not chemin.is_file():
        raise argparse.ArgumentTypeError("ce n'est pas un fichier : %s" % valeur)
    try:
        with chemin.open('rb'):
            pass
    except OSError as erreur:
        raise argparse.ArgumentTypeError('fichier illisible : %s (%s)' % (valeur, erreur))
    return chemin


def construire_analyseur():
    analyseur = argparse.ArgumentParser(
        description="Produit une COPIE réparée d'une ruche de registre dont "
                    "l'en-tête porte un commit interrompu (seq2 := seq1 et "
                    "checksum recalculé). La source n'est jamais modifiée.",
        epilog="Codes de retour : 0 copie écrite et vérifiée, 1 refus ou échec, "
               "2 erreur d'usage.")
    analyseur.add_argument('source', metavar='RUCHE_SOURCE', type=fichier_lisible,
                           help='ruche à lire (jamais modifiée)')
    analyseur.add_argument('destination', metavar='RUCHE_REPAREE',
                           help='fichier de sortie, obligatoirement différent de la source')
    analyseur.add_argument('--ecraser', action='store_true',
                           help="autoriser l'écrasement d'une destination existante")
    analyseur.add_argument('--profondeur-max', type=int, default=512,
                           help="profondeur maximale du contrôle d'arbre (défaut : 512)")
    return analyseur


def refus(message):
    """Affiche un refus motivé et rend le code d'échec."""
    print('REFUS : %s' % message)
    return 1


def main(arguments=None):
    sortie_tolerante()
    options = construire_analyseur().parse_args(arguments)
    source = options.source
    destination = Path(options.destination)

    # --- Garde-fous de chemins, avant toute lecture sérieuse ---------------
    if meme_fichier(source, destination):
        return refus('la destination désigne la source. Cet outil ne travaille '
                     'JAMAIS en place : donner un nom de fichier différent.')
    if destination.exists():
        if not destination.is_file():
            return refus("la destination existe et n'est pas un fichier : %s" % destination)
        if not options.ecraser:
            return refus('la destination existe déjà : %s (ajouter --ecraser pour '
                         'la remplacer)' % destination)
    if not destination.parent.is_dir():
        return refus("le dossier de destination n'existe pas : %s" % destination.parent)

    # Empreinte de la source AVANT lecture : elle sera recomparée à la fin, pour
    # prouver que ce script n'a rien touché. Le contrôle argparse a seulement
    # prouvé que le fichier s'OUVRAIT : sur un disque mourant, c'est la LECTURE
    # qui échoue. Refus net, jamais une trace Python.
    try:
        etat_avant = source.stat()
        donnees = bytearray(source.read_bytes())
    except OSError as erreur:
        return refus('lecture de la source impossible : %s. Aucune copie écrite. '
                     "Travailler sur une image du disque, ou restaurer une "
                     'sauvegarde.' % erreur)
    if len(donnees) < ENTETE:
        return refus('fichier plus court que le bloc de base (%s octets) : ce '
                     "n'est pas une ruche" % nombre(len(donnees)))
    if donnees[0:4] != b'regf':
        return refus("signature regf absente (%r) : ce fichier n'est pas une ruche"
                     % bytes(donnees[0:4]))

    seq1, seq2 = struct.unpack_from('<II', donnees, 0x04)
    horodatage = struct.unpack_from('<Q', donnees, 0x0C)[0]
    checksum_avant = struct.unpack_from('<I', donnees, CHECKSUM_OFF)[0]
    print('source          : %s (%s octets)' % (source.name, nombre(len(donnees))))
    print('horodatage      : %s' % date_filetime(horodatage))
    print('avant           : seq1=%d seq2=%d checksum=0x%08x'
          % (seq1, seq2, checksum_avant))

    # --- Les champs d'en-tête doivent tenir AVANT d'être signés --------------
    # Recalculer le checksum revient à SIGNER les 508 premiers octets. Si l'un
    # d'eux est corrompu - typiquement la taille annoncée des hbins en 0x28 - la
    # copie ressort cohérente AVEC sa propre corruption : le checksum ne la
    # dénonce plus, et aucune analyse ultérieure ne peut la voir. Un outil de
    # dernier recours ne doit pas dépendre de la discipline de l'opérateur pour
    # s'interdire de fabriquer un mensonge : ce que ce script s'apprête à signer,
    # il le contrôle lui-même.
    taille_hbins = struct.unpack_from('<I', donnees, 0x28)[0]
    consigne = ("Lancer d'abord analyse_regf.py sur la source pour le "
                "diagnostic complet. Aucune copie n'est écrite.")
    if taille_hbins == 0 or taille_hbins % GRAIN_HBIN != 0:
        return refus("l'en-tête annonce une taille de hbins aberrante "
                     '(0x%x : elle doit être un multiple non nul de 0x%x). '
                     'Recalculer le checksum par-dessus figerait cette '
                     'corruption dans la copie. %s'
                     % (taille_hbins, GRAIN_HBIN, consigne))
    if ENTETE + taille_hbins > len(donnees):
        return refus("l'en-tête annonce %s octets de hbins, soit %s octets avec "
                     'le bloc de base, alors que le fichier en compte %s : ruche '
                     'TRONQUÉE ou taille annoncée corrompue. Recalculer le '
                     'checksum par-dessus figerait cette corruption dans la '
                     'copie. %s'
                     % (nombre(taille_hbins), nombre(ENTETE + taille_hbins),
                        nombre(len(donnees)), consigne))
    chaine = chaine_hbins(bytes(donnees), taille_hbins)
    if chaine['anomalie'] is not None:
        raison, position, detail = chaine['anomalie']
        return refus("la chaîne des hbins est rompue à l'offset 0x%x : %s "
                     '(détail : %s). Le corps de la ruche est touché : réparer '
                     "l'en-tête ne servirait à rien, et le checksum recalculé "
                     'rendrait le dégât invisible. %s'
                     % (position, raison, detail, consigne))
    print('hbins           : %s octets annoncés, %s hbin(s) valides jusqu\'à 0x%x'
          % (nombre(taille_hbins), nombre(chaine['valides']), chaine['fin']))

    # Le SENS de l'écart de séquences décide de tout. Le modèle de panne traité
    # est « primaire en avance » : le commit d'en-tête s'est arrêté entre les
    # deux écritures, seq2 est en retard, la remettre au niveau de seq1 fait
    # AVANCER la ruche jusqu'à l'état déjà écrit dans son corps. La situation
    # inverse ne s'explique pas par ce modèle : y appliquer la même correction
    # ferait RECULER la séquence, ce qui n'est pas une réparation.
    if seq2 > seq1:
        return refus('la séquence SECONDAIRE (%d) est EN AVANCE sur la PRIMAIRE '
                     '(%d) de %d. Cet atelier ne traite que le cas inverse '
                     "(primaire en avance, commit d'en-tête interrompu) : "
                     'appliquer seq2 := seq1 ferait RÉGRESSER la séquence de la '
                     "ruche, ce n'est pas une réparation. Aucune copie n'est "
                     'écrite. Analyser les journaux .LOG1 / .LOG2 avec '
                     'analyse_regf.py, ou restaurer une sauvegarde.'
                     % (seq2, seq1, seq2 - seq1))

    corrections = []
    if seq1 != seq2:
        corrections.append('seq2 := seq1 (%d -> %d, secondaire en retard de %d)'
                           % (seq2, seq1, seq1 - seq2))
    struct.pack_into('<I', donnees, 0x08, seq1)
    checksum_apres = checksum_entete(donnees)
    if checksum_apres != checksum_avant:
        corrections.append('checksum := 0x%08x' % checksum_apres)
    struct.pack_into('<I', donnees, CHECKSUM_OFF, checksum_apres)
    print('après           : seq1=%d seq2=%d checksum=0x%08x'
          % (seq1, seq1, checksum_apres))
    if corrections:
        print('corrections     : %s' % ' ; '.join(corrections))
    else:
        print("corrections     : aucune, l'en-tête était déjà cohérent "
              '(la copie sera identique à la source)')

    # --- Contrôle d'arbre AVANT d'écrire quoi que ce soit -------------------
    rapport = parcourir(bytes(donnees), profondeur_max=options.profondeur_max)
    print("contrôle d'arbre : %s clé(s), %s valeur(s), %s erreur(s) de structure"
          % (nombre(rapport['cles']), nombre(rapport['valeurs']),
             nombre(rapport['total_erreurs'])))
    if rapport['total_erreurs'] > 0:
        for message in rapport['erreurs'][:5]:
            print('  - %s' % message)
        return refus('le corps de la ruche porte des erreurs de structure : '
                     "réparer l'en-tête ne servirait à rien. Restaurer une copie "
                     '(coffre, cliché VSS, sauvegarde).')

    # --- Écriture puis relecture depuis le disque ---------------------------
    # Écriture dans un fichier temporaire voisin, puis bascule par os.replace :
    # write_bytes VIDE sa cible avant d'écrire, donc une panne en cours de route
    # (disque plein, support mourant : le modèle de panne de cet outil)
    # laisserait une ruche à moitié écrite là où l'utilisateur attend un fichier
    # posable. Avec le temporaire, la destination reste soit absente, soit
    # intacte, soit complète : jamais tronquée.
    temporaire = destination.with_name(destination.name + '.tmp')
    if temporaire.exists():
        return refus("un fichier de travail traîne déjà : %s. Le supprimer (il "
                     "vient d'une exécution interrompue) ou choisir un autre nom "
                     'de destination.' % temporaire)
    try:
        temporaire.write_bytes(bytes(donnees))
        os.replace(str(temporaire), str(destination))
    except OSError as erreur:
        try:
            temporaire.unlink()
        except OSError:
            pass
        return refus('écriture impossible : %s. Destination NON écrite : %s reste '
                     "%s, aucun fichier tronqué n'a été laissé derrière."
                     % (erreur, destination,
                        'inchangée' if destination.exists() else 'absente'))

    try:
        relu = destination.read_bytes()
    except OSError as erreur:
        print('copie écrite    : %s' % destination)
        return refus("la copie ne peut pas être relue (%s) : elle n'est donc pas "
                     'vérifiée, NE PAS LA POSER.' % erreur)

    echecs = []
    if relu != bytes(donnees):
        echecs.append('le fichier relu diffère de ce qui a été écrit')
    if relu[0:4] != b'regf':
        echecs.append('signature regf absente après écriture')
    elif len(relu) < ENTETE:
        echecs.append('copie relue tronquée : %s octets, moins que le bloc de base'
                      % nombre(len(relu)))
    else:
        relu_seq1, relu_seq2 = struct.unpack_from('<II', relu, 0x04)
        if relu_seq1 != relu_seq2:
            echecs.append('séquences toujours désaccordées (%d / %d)'
                          % (relu_seq1, relu_seq2))
        relu_checksum = struct.unpack_from('<I', relu, CHECKSUM_OFF)[0]
        if relu_checksum != checksum_entete(relu):
            echecs.append('checksum faux après écriture')
        controle = parcourir(relu, profondeur_max=options.profondeur_max)
        if controle['total_erreurs'] > 0:
            echecs.append('%s erreur(s) de structure dans la copie relue'
                          % nombre(controle['total_erreurs']))

    # Une source qui a bougé pendant le traitement est le signal le plus grave
    # que cet outil sache produire : la promesse « la source n'est jamais
    # touchée » vient de tomber. Il compte donc comme un ÉCHEC, pas comme une
    # ligne d'information au milieu d'une sortie de succès.
    try:
        etat_apres = source.stat()
    except OSError as erreur:
        etat_apres = None
        print('source          : %s (état NON VÉRIFIABLE : %s)'
              % (source.name, erreur))
        echecs.append("l'état de la source n'a pas pu être relu après écriture : "
                      "impossible de prouver qu'elle est intacte")
    if etat_apres is not None:
        source_intacte = (etat_avant.st_size == etat_apres.st_size
                          and etat_avant.st_mtime == etat_apres.st_mtime)
        print('source          : %s (taille et date de modification %s)'
              % (source.name, 'inchangées' if source_intacte else 'MODIFIÉES'))
        if not source_intacte:
            echecs.append('la SOURCE a changé de taille ou de date pendant le '
                          "traitement (%s -> %s octets) : un autre programme y "
                          'écrit, ou le support est instable'
                          % (nombre(etat_avant.st_size), nombre(etat_apres.st_size)))

    if echecs:
        print('copie écrite    : %s' % destination)
        for message in echecs:
            print('  - %s' % message)
        return refus("la vérification finale a échoué. NE PAS POSER LA COPIE : "
                     'la conserver pour examen et restaurer une sauvegarde.')

    print('copie vérifiée  : %s (%s octets)' % (destination, nombre(len(relu))))
    print('')
    print('Étape suivante, sur un PC SAIN et en administrateur :')
    print('  reg load HKLM\\TestHive "%s"' % destination)
    print('  puis contrôler les clés attendues, enfin reg unload HKLM\\TestHive.')
    print('reg load peut rejouer des journaux et MODIFIER le fichier : travailler '
          'sur une copie de plus.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
