#!/usr/bin/env python3
"""Autopsie de l'en-tête d'une ruche de registre Windows (format regf).

Ouvre une ou plusieurs ruches en LECTURE SEULE et affiche : signature,
séquences primaire et secondaire, horodatage, version, taille annoncée des
hbins, checksum lu contre checksum recalculé, puis l'état de la chaîne des
hbins. Rend un verdict par ruche.

Usage   : py -3 analyse_regf.py RUCHE [RUCHE ...]
Retours : 0 tout est sain, 1 au moins une anomalie, 2 erreur d'usage.

Bibliothèque standard uniquement. Aucun fichier n'est modifié.
"""

import argparse
import struct
import sys
from datetime import datetime, timedelta
from pathlib import Path

ENTETE = 0x1000        # taille du bloc de base d'une ruche : 4096 octets
CHECKSUM_OFF = 0x1FC   # emplacement du checksum dans le bloc de base
GRAIN_HBIN = 0x1000    # une taille de hbin est un multiple de 4096 octets


def sortie_tolerante():
    """Rend print() insensible à la page de code de la console.

    Une console héritée (cmd en 437, WinPE) ne sait pas encoder tous les
    accents : sans cela, un simple accent ferait lever le script au pire
    moment. On remplace le caractère fautif au lieu d'interrompre.
    """
    for flux in (sys.stdout, sys.stderr):
        try:
            flux.reconfigure(errors='replace')
        except (AttributeError, ValueError):
            pass


def nombre(valeur):
    """Formate un entier avec des espaces comme séparateur de milliers."""
    return format(valeur, ',d').replace(',', ' ')


def date_filetime(valeur):
    """Convertit un FILETIME (unités de 100 ns depuis 1601) en date lisible."""
    if valeur == 0:
        return 'zéro'
    try:
        base = datetime(1601, 1, 1) + timedelta(microseconds=valeur / 10)
        return base.strftime('%Y-%m-%d %H:%M:%S')
    except (OverflowError, ValueError, OSError):
        return 'invalide (0x%016x)' % valeur


def checksum_entete(donnees):
    """Recalcule le checksum du bloc de base.

    XOR des 127 uint32 des offsets 0 à 504 (soit les 508 premiers octets).
    Windows s'interdit les deux valeurs extrêmes : 0 devient 1 et 0xFFFFFFFF
    devient 0xFFFFFFFE.
    """
    somme = 0
    for offset in range(0, CHECKSUM_OFF, 4):
        somme ^= struct.unpack_from('<I', donnees, offset)[0]
    if somme == 0:
        return 1
    if somme == 0xFFFFFFFF:
        return 0xFFFFFFFE
    return somme


def chaine_hbins(donnees, taille_annoncee):
    """Suit la chaîne des hbins depuis l'offset 4096.

    Chaque hbin porte sa signature (offset relatif 0), son propre offset dans
    la zone des hbins (4) et sa taille (8). La chaîne doit couvrir AU MOINS la
    taille annoncée dans l'en-tête : une rupture avant cette borne est un dégât
    du corps de la ruche, alors qu'une fin de chaîne après cette borne est
    normale (réserve de fin allouée d'avance, ou hbins ajoutés avant que
    l'en-tête n'ait été remis à jour).

    Retourne un dictionnaire : hbins valides, offset de fin de chaîne, hbins
    trouvés au-delà de la taille annoncée, taille et nature de la queue, et
    l'anomalie éventuelle.
    """
    fin_annoncee = ENTETE + taille_annoncee
    offset = ENTETE
    valides = 0
    au_dela = 0
    rupture = None
    # 12 octets : la signature (4) plus l'offset interne et la taille (8) lus
    # juste après. Une borne à 8 laisserait struct.unpack_from lever sur un
    # fichier qui s'arrête au milieu de l'en-tête d'un hbin, et une ruche
    # tronquée doit rendre un verdict, pas une trace Python.
    while offset + 12 <= len(donnees):
        if donnees[offset:offset + 4] != b'hbin':
            rupture = ('signature hbin absente', offset,
                       donnees[offset:offset + 4].hex(' '))
            break
        relatif, taille = struct.unpack_from('<II', donnees, offset + 4)
        if taille == 0 or taille % GRAIN_HBIN != 0 or offset + taille > len(donnees):
            rupture = ('taille de hbin aberrante', offset, '0x%x' % taille)
            break
        if relatif != offset - ENTETE:
            rupture = ('offset interne de hbin incohérent', offset, '0x%x' % relatif)
            break
        valides += 1
        if offset >= fin_annoncee:
            au_dela += 1
        offset += taille
    if rupture is None and offset + 12 > len(donnees) and offset < fin_annoncee:
        rupture = ('fichier tronqué au milieu de la chaîne', offset,
                   '%s octets manquants' % nombre(fin_annoncee - offset))
    queue = donnees[offset:]
    return {
        'valides': valides,
        'fin': offset,
        'au_dela': au_dela,
        'queue': len(queue),
        'queue_nulle': queue.count(0) == len(queue),
        # Une rupture au-delà de la borne annoncée ne condamne pas la ruche :
        # le chargeur ne lit que la zone annoncée.
        'anomalie': rupture if (rupture is not None and offset < fin_annoncee) else None,
        'note': rupture if (rupture is not None and offset >= fin_annoncee) else None,
    }


def analyser_ruche(chemin):
    """Analyse une ruche et l'affiche.

    Retourne le couple (liste des anomalies, séquence primaire ou None), la
    séquence servant ensuite à juger si un journal voisin est rejouable.
    """
    donnees = chemin.read_bytes()
    anomalies = []
    reparables = []
    print('')
    print('==== %s : %s octets ====' % (chemin.name, nombre(len(donnees))))

    if len(donnees) < ENTETE:
        print('  FICHIER TRONQUÉ : moins de %d octets, pas de bloc de base' % ENTETE)
        return ['fichier tronqué'], None
    if donnees[0:4] != b'regf':
        print('  SIGNATURE INVALIDE : %r (une ruche commence par regf)'
              % donnees[0:4])
        return ['signature invalide'], None

    seq1, seq2 = struct.unpack_from('<II', donnees, 0x04)
    horodatage = struct.unpack_from('<Q', donnees, 0x0C)[0]
    majeure, mineure = struct.unpack_from('<II', donnees, 0x14)
    type_fichier, format_fichier = struct.unpack_from('<II', donnees, 0x1C)
    racine, taille_hbins, grappe = struct.unpack_from('<III', donnees, 0x24)
    checksum_lu = struct.unpack_from('<I', donnees, CHECKSUM_OFF)[0]
    checksum_calcule = checksum_entete(donnees)

    print('  signature       : regf')
    # Le SENS de l'écart décide du verdict : la primaire en avance est le seul
    # modèle de panne de l'atelier (commit interrompu, réparable). La
    # secondaire en avance ne s'explique pas par ce modèle, et y appliquer
    # seq2 := seq1 ferait RÉGRESSER la séquence : hors périmètre.
    if seq1 == seq2:
        etat_seq = "ACCORDÉES (dernier commit d'en-tête terminé)"
    elif seq1 > seq2:
        etat_seq = ("DÉSACCORDÉES, primaire en avance de %d : commit d'en-tête "
                    'interrompu' % (seq1 - seq2))
        reparables.append('séquences désaccordées (primaire en avance)')
    else:
        etat_seq = ("DÉSACCORDÉES, SECONDAIRE en avance de %d : hors du modèle "
                    "de panne de l'atelier" % (seq2 - seq1))
        anomalies.append('séquence secondaire en avance sur la primaire')
    print('  séquences       : primaire=%d  secondaire=%d  -> %s'
          % (seq1, seq2, etat_seq))
    print('  horodatage      : %s' % date_filetime(horodatage))
    print('  version         : %d.%d   type=%d (0 = ruche primaire)   format=%d'
          % (majeure, mineure, type_fichier, format_fichier))
    print('  cellule racine  : 0x%x   grappe : %d' % (racine, grappe))

    attendue = ENTETE + taille_hbins
    reserve = len(donnees) - attendue
    if reserve >= 0:
        print('  taille          : %s octets = %s (en-tête) + %s (hbins annoncés) '
              '+ %s (réserve de fin)'
              % (nombre(len(donnees)), nombre(ENTETE), nombre(taille_hbins),
                 nombre(reserve)))
    else:
        print('  taille          : %s octets, FICHIER TRONQUÉ : %s octets manquants '
              'sur les %s annoncés'
              % (nombre(len(donnees)), nombre(-reserve), nombre(attendue)))
        anomalies.append('fichier plus court que la taille annoncée')

    if checksum_lu == checksum_calcule:
        etat_checksum = 'OK'
    else:
        etat_checksum = 'FAUX : en-tête incohérent'
        reparables.append('checksum faux')
    print('  checksum        : lu=0x%08x  calculé=0x%08x -> %s'
          % (checksum_lu, checksum_calcule, etat_checksum))

    chaine = chaine_hbins(donnees, taille_hbins)
    couverture = 100.0 * (chaine['fin'] - ENTETE) / taille_hbins if taille_hbins else 0.0
    print("  chaîne de hbins : %s hbin(s) valides jusqu'à 0x%x, soit %.1f%% de la "
          'zone annoncée' % (nombre(chaine['valides']), chaine['fin'], couverture))
    if chaine['au_dela']:
        print('                    dont %s hbin(s) VALIDES au-delà de la taille '
              'annoncée (en-tête en retard sur le corps)' % nombre(chaine['au_dela']))
    if chaine['queue']:
        print('  après la chaîne : %s octet(s) %s'
              % (nombre(chaine['queue']),
                 'nuls (réserve normale)' if chaine['queue_nulle']
                 else "NON NULS, sans signature hbin (résidu d'une écriture interrompue)"))
        if chaine['note'] is not None and not chaine['queue_nulle']:
            raison, position, detail = chaine['note']
            print("                    la chaîne s'arrête là sur : %s (détail : %s)"
                  % (raison, detail))
    if chaine['anomalie'] is not None:
        raison, position, detail = chaine['anomalie']
        print("  RUPTURE DE CHAÎNE : %s à l'offset 0x%x (détail : %s)"
              % (raison, position, detail))
        print('  contexte hex     : %s' % donnees[position:position + 32].hex(' '))
        anomalies.append('chaîne de hbins rompue')

    if anomalies:
        print('  VERDICT         : ANOMALIE HORS PÉRIMÈTRE DE RÉPARATION (%s)'
              % ', '.join(anomalies))
        print('                    la seule voie sûre est de restaurer une copie '
              '(coffre, cliché VSS, sauvegarde).')
    elif reparables:
        print('  VERDICT         : ANOMALIE RÉPARABLE (%s)' % ', '.join(reparables))
        print("                    vérifier l'arbre avec walk_regf.py, puis produire "
              'une copie avec repare_regf.py.')
    else:
        print('  VERDICT         : SAINE')
    return anomalies + reparables, seq1


def analyser_journal(chemin, seq_ruche=None):
    """Affiche l'état d'un journal .LOG1 / .LOG2 voisin d'une ruche.

    Un journal utilisable porte un bloc de base regf puis des entrées HvLE.
    Sa séquence doit être supérieure ou égale à celle de l'en-tête de la ruche
    pour être rejouable : un journal vide ou en retard n'aide à rien.
    """
    donnees = chemin.read_bytes()
    print('')
    print('---- %s : %s octets ----' % (chemin.name, nombre(len(donnees))))
    if len(donnees) == 0:
        print('  journal VIDE : rien à rejouer')
        return
    if len(donnees) >= 0x20 and donnees[0:4] == b'regf':
        seq1, seq2 = struct.unpack_from('<II', donnees, 0x04)
        horodatage = struct.unpack_from('<Q', donnees, 0x0C)[0]
        type_fichier = struct.unpack_from('<I', donnees, 0x1C)[0]
        print('  bloc de base    : seq1=%d seq2=%d type=%d (1 = journal) horodatage %s'
              % (seq1, seq2, type_fichier, date_filetime(horodatage)))
    else:
        print('  premiers octets : %s (pas un bloc de base regf)'
              % donnees[0:8].hex(' '))

    offset = 0x200
    sequences = []
    while offset + 40 <= len(donnees):
        if donnees[offset:offset + 4] != b'HvLE':
            break
        taille, _drapeaux, sequence, _hbins = struct.unpack_from('<IIII', donnees, offset + 4)
        if taille == 0 or offset + taille > len(donnees):
            print('  entrée HvLE tronquée à 0x%x (taille 0x%x)' % (offset, taille))
            break
        sequences.append(sequence)
        offset += taille
    if sequences:
        print('  entrées HvLE    : %d valides, séquences %d à %d'
              % (len(sequences), sequences[0], sequences[-1]))
        if seq_ruche is not None:
            if max(sequences) >= seq_ruche:
                print('  rejouable       : PLAUSIBLE, la plus haute séquence du journal '
                      '(%d) atteint celle de la ruche (%d)' % (max(sequences), seq_ruche))
            else:
                print("  rejouable       : NON, le journal s'arrête à la séquence %d "
                      'alors que la ruche en est à %d' % (max(sequences), seq_ruche))
    else:
        print('  entrées HvLE    : aucune à partir de 0x200 : journal inutilisable')


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
        description="Autopsie de l'en-tête d'une ruche de registre Windows "
                    "(format regf). Lecture seule.",
        epilog="Codes de retour : 0 tout est sain, 1 au moins une anomalie, "
               "2 erreur d'usage.")
    analyseur.add_argument('ruches', metavar='RUCHE', nargs='+', type=fichier_lisible,
                           help='ruche à analyser (SYSTEM, SOFTWARE, une copie...)')
    analyseur.add_argument('--sans-journaux', action='store_true',
                           help='ne pas analyser les journaux .LOG1 et .LOG2 voisins')
    return analyseur


def main(arguments=None):
    sortie_tolerante()
    options = construire_analyseur().parse_args(arguments)
    anomalies = 0
    for ruche in options.ruches:
        try:
            trouvees, seq_ruche = analyser_ruche(ruche)
        except OSError as erreur:
            print('')
            print('==== %s : LECTURE IMPOSSIBLE (%s) ====' % (ruche.name, erreur))
            trouvees, seq_ruche = ['lecture impossible'], None
        if trouvees:
            anomalies += 1
        if not options.sans_journaux:
            for suffixe in ('.LOG1', '.LOG2'):
                journal = ruche.with_name(ruche.name + suffixe)
                if journal.is_file():
                    try:
                        analyser_journal(journal, seq_ruche)
                    except OSError as erreur:
                        print('  journal illisible : %s' % erreur)
    print('')
    print('%d ruche(s) analysée(s), %d avec anomalie.' % (len(options.ruches), anomalies))
    return 1 if anomalies else 0


if __name__ == '__main__':
    sys.exit(main())
