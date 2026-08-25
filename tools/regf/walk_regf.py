#!/usr/bin/env python3
"""Parcours intégral de l'arbre d'une ruche de registre Windows (format regf).

Suit la cellule racine, puis toutes les listes de sous-clés (lf, lh, li, ri),
toutes les valeurs (vk) et toutes les cellules de données, en vérifiant que
CHAQUE référence tombe dans la chaîne des hbins et que chaque cellule a une
taille plausible. Compte les clés, les valeurs et les erreurs de structure.

Le but n'est pas d'exporter le registre : c'est de prouver que le corps de la
ruche est intact avant de toucher à son en-tête. Zéro erreur = le défaut est
dans les 4096 premiers octets, donc réparable. Une seule erreur = le corps est
touché, la réparation d'en-tête ne servirait à rien.

Usage   : py -3 walk_regf.py RUCHE
Retours : 0 aucune erreur de structure, 1 erreurs détectées, 2 erreur d'usage.

Bibliothèque standard uniquement. Aucun fichier n'est modifié.
"""

import argparse
import struct
import sys
from pathlib import Path

ENTETE = 0x1000          # taille du bloc de base d'une ruche : 4096 octets
GRAIN_HBIN = 0x1000      # une taille de hbin est un multiple de 4096 octets
REF_VIDE = 0xFFFFFFFF    # référence nulle dans une ruche
INLINE = 0x80000000      # bit de poids fort de la taille d'une valeur vk
PLAFOND_ERREURS = 10000  # au-delà, on compte sans stocker


def sortie_tolerante():
    """Rend print() insensible à la page de code de la console (cf. WinPE)."""
    for flux in (sys.stdout, sys.stderr):
        try:
            flux.reconfigure(errors='replace')
        except (AttributeError, ValueError):
            pass


def nombre(valeur):
    """Formate un entier avec des espaces comme séparateur de milliers."""
    return format(valeur, ',d').replace(',', ' ')


def fin_chaine_hbins(donnees):
    """Retourne l'offset RELATIF de fin de la chaîne des hbins valides.

    Toutes les références de cellules sont relatives au début de la zone des
    hbins (offset absolu 4096). Cette borne est le garde-fou unique du
    parcours : au-delà, une référence est fausse par construction.
    """
    offset = ENTETE
    # 12 octets : la signature (4) plus l'offset interne et la taille (8) lus
    # juste après. Une borne à 8 laisserait struct.unpack_from lever sur un
    # fichier qui s'arrête au milieu de l'en-tête d'un hbin.
    while offset + 12 <= len(donnees):
        if donnees[offset:offset + 4] != b'hbin':
            break
        taille = struct.unpack_from('<I', donnees, offset + 8)[0]
        if taille == 0 or taille % GRAIN_HBIN != 0 or offset + taille > len(donnees):
            break
        offset += taille
    return offset - ENTETE


class Parcours(object):
    """État d'un parcours d'arbre. Utiliser parcourir() plutôt que cette classe."""

    def __init__(self, donnees, profondeur_max=512):
        self.donnees = donnees
        self.profondeur_max = profondeur_max
        self.fin = fin_chaine_hbins(donnees)
        self.racine = 0
        self.erreurs = []
        self.total_erreurs = 0
        self.cles = 0
        self.valeurs = 0
        self.cellules_donnees = 0
        self.grandes_donnees = 0
        self.securite = set()
        self.profondeur = 0
        self.offset_max = 0
        self.vues = set()
        self.listes_vues = set()
        self.nom_racine = ''

    def _erreur(self, message):
        self.total_erreurs += 1
        if len(self.erreurs) < PLAFOND_ERREURS:
            self.erreurs.append(message)

    def _cellule(self, reference):
        """Valide une référence et retourne (taille, offset absolu du contenu).

        None quand la référence est vide ou invalide : l'appelant abandonne
        alors cette branche, l'erreur ayant déjà été enregistrée.
        """
        if reference == REF_VIDE:
            return None
        if reference < 0 or reference + 4 > self.fin:
            self._erreur('référence hors de la chaîne des hbins : 0x%x' % reference)
            return None
        absolu = ENTETE + reference
        taille = struct.unpack_from('<i', self.donnees, absolu)[0]
        # Taille négative = cellule allouée, positive = cellule libre. Une
        # cellule libre atteinte depuis l'arbre serait une incohérence, mais on
        # continue de la lire : l'objectif est de compter les dégâts, pas de
        # s'arrêter au premier.
        utile = -taille if taille < 0 else taille
        if utile < 8 or reference + utile > self.fin:
            self._erreur('taille de cellule invalide à 0x%x : %d' % (reference, taille))
            return None
        if taille > 0:
            self._erreur('cellule libérée mais référencée à 0x%x' % reference)
        if reference + utile > self.offset_max:
            self.offset_max = reference + utile
        return (utile, absolu + 4)

    def _nom_cle(self, offset, taille):
        """Lit le nom d'une clé nk, stocké à la fin de sa propre cellule."""
        drapeaux = struct.unpack_from('<H', self.donnees, offset + 0x02)[0]
        longueur = struct.unpack_from('<H', self.donnees, offset + 0x48)[0]
        if 0x4C + longueur > taille - 4:
            return None
        brut = self.donnees[offset + 0x4C:offset + 0x4C + longueur]
        # Drapeau 0x20 : nom compressé (un octet par caractère).
        codec = 'latin-1' if drapeaux & 0x20 else 'utf-16-le'
        return brut.decode(codec, 'replace')

    def _grandes_donnees(self, offset, taille):
        """Suit une cellule db : liste de segments d'une valeur volumineuse."""
        if 8 > taille - 4:
            self._erreur('cellule db trop courte')
            return
        segments = struct.unpack_from('<H', self.donnees, offset + 0x02)[0]
        liste = struct.unpack_from('<I', self.donnees, offset + 0x04)[0]
        cellule = self._cellule(liste)
        if cellule is None:
            return
        taille_liste, offset_liste = cellule
        if segments * 4 > taille_liste - 4:
            self._erreur('liste de segments db trop courte à 0x%x' % liste)
            return
        for index in range(segments):
            reference = struct.unpack_from('<I', self.donnees, offset_liste + index * 4)[0]
            if self._cellule(reference) is not None:
                self.cellules_donnees += 1

    def _valeurs(self, reference, compte):
        """Parcourt la liste de valeurs d'une clé, puis chaque vk.

        Retourne le nombre de cellules vk RÉELLEMENT reconnues, ou None quand la
        liste elle-même n'a pas pu être lue (l'erreur est alors déjà comptée).
        L'appelant compare ce nombre au compte déclaré par la clé : sans cette
        comparaison, une liste dont toutes les entrées sont vides passerait pour
        parcourue alors qu'elle n'a rien livré.
        """
        cellule = self._cellule(reference)
        if cellule is None:
            return None
        taille, offset = cellule
        if compte * 4 > taille - 4:
            self._erreur('liste de valeurs trop courte à 0x%x (%d annoncée(s))'
                         % (reference, compte))
            return None
        enumerees = 0
        for index in range(compte):
            ref_valeur = struct.unpack_from('<I', self.donnees, offset + index * 4)[0]
            cellule_valeur = self._cellule(ref_valeur)
            if cellule_valeur is None:
                continue
            taille_valeur, offset_valeur = cellule_valeur
            if self.donnees[offset_valeur:offset_valeur + 2] != b'vk':
                self._erreur('signature vk attendue à 0x%x' % ref_valeur)
                continue
            if 0x14 > taille_valeur - 4:
                self._erreur('cellule vk trop courte à 0x%x' % ref_valeur)
                continue
            self.valeurs += 1
            enumerees += 1
            longueur = struct.unpack_from('<I', self.donnees, offset_valeur + 0x04)[0]
            ref_donnees = struct.unpack_from('<I', self.donnees, offset_valeur + 0x08)[0]
            if longueur & INLINE:
                continue  # donnée logée dans le champ d'offset lui-même
            if longueur == 0:
                continue
            cellule_donnees = self._cellule(ref_donnees)
            if cellule_donnees is None:
                continue
            taille_donnees, offset_donnees = cellule_donnees
            if self.donnees[offset_donnees:offset_donnees + 2] == b'db':
                self.grandes_donnees += 1
                self._grandes_donnees(offset_donnees, taille_donnees)
            else:
                self.cellules_donnees += 1
                if longueur > taille_donnees - 4:
                    self._erreur('donnée de %s octets dans une cellule de %s à 0x%x'
                                 % (nombre(longueur), nombre(taille_donnees - 4),
                                    ref_donnees))
        return enumerees

    def _liste_sous_cles(self, reference, profondeur):
        """Parcourt une liste de sous-clés : lf, lh (avec hachage), li, ri.

        Retourne le nombre d'entrées de clé RÉELLEMENT énumérées, ou None quand
        la liste n'a pas pu être lue (l'erreur est alors déjà comptée). La clé
        parente compare ce nombre à ce qu'elle déclare : une liste qui n'énumère
        pas ce que la clé annonce est un dégât, pas un détail de comptage.

        Une liste ri renvoie vers d'autres listes SANS descendre d'un niveau :
        sur une ruche abîmée, une ri qui se pointe elle-même bouclerait sans
        que la profondeur ne bouge. D'où le garde-fou par cellule déjà vue,
        indépendant de celui des clés.
        """
        if reference == REF_VIDE:
            # Une entrée vide dans une liste ri désigne une sous-liste absente,
            # donc une branche entière du registre manquante. _cellule() la
            # passerait en silence (None sans erreur) et le corps serait acquitté
            # à 0 erreur : même faux acquittement que celui gardé dans _cle.
            self._erreur('référence de sous-liste vide (0x%08x) : une branche '
                         'entière manque' % REF_VIDE)
            return None
        if reference in self.listes_vues:
            self._erreur('liste de sous-clés déjà parcourue à 0x%x : boucle dans '
                         'la ruche' % reference)
            return None
        self.listes_vues.add(reference)
        cellule = self._cellule(reference)
        if cellule is None:
            return None
        taille, offset = cellule
        signature = self.donnees[offset:offset + 2]
        compte = struct.unpack_from('<H', self.donnees, offset + 0x02)[0]
        if signature in (b'lf', b'lh'):
            # Entrées de 8 octets : offset de la clé puis hachage du nom.
            if 4 + compte * 8 > taille - 4:
                self._erreur('liste %s trop courte à 0x%x (%d entrée(s))'
                             % (signature.decode('ascii'), reference, compte))
                return None
            for index in range(compte):
                ref_cle = struct.unpack_from('<I', self.donnees, offset + 4 + index * 8)[0]
                self._cle(ref_cle, profondeur + 1)
            return compte
        if signature in (b'li', b'ri'):
            # Entrées de 4 octets : li pointe des clés, ri des sous-listes.
            if 4 + compte * 4 > taille - 4:
                self._erreur('liste %s trop courte à 0x%x (%d entrée(s))'
                             % (signature.decode('ascii'), reference, compte))
                return None
            if signature == b'li':
                for index in range(compte):
                    ref = struct.unpack_from('<I', self.donnees, offset + 4 + index * 4)[0]
                    self._cle(ref, profondeur + 1)
                return compte
            # ri : chaque entrée est une SOUS-LISTE, pas une clé. Le compte
            # déclaré par la clé parente porte sur les clés : on additionne donc
            # ce que chaque sous-liste énumère. Une seule sous-liste illisible
            # rend le total muet (None) plutôt que faussement bas, pour ne pas
            # empiler une erreur de comptage sur une erreur déjà signalée.
            total = 0
            complet = True
            for index in range(compte):
                ref = struct.unpack_from('<I', self.donnees, offset + 4 + index * 4)[0]
                enumerees = self._liste_sous_cles(ref, profondeur)
                if enumerees is None:
                    complet = False
                else:
                    total += enumerees
            return total if complet else None
        self._erreur('signature de liste de sous-clés inconnue %r à 0x%x'
                     % (signature, reference))
        return None

    def _cle(self, reference, profondeur):
        """Parcourt une clé nk : ses valeurs puis ses sous-clés."""
        if reference == REF_VIDE:
            # La racine est contrôlée par executer() : toute référence vide qui
            # arrive ici vient d'une ENTRÉE de liste de sous-clés, donc d'une
            # branche entière absente. _cellule() la passerait en silence, et
            # cette branche jamais descendue ne coûterait aucune erreur.
            self._erreur('entrée vide (0x%08x) dans une liste de sous-clés : une '
                         'branche entière manque' % REF_VIDE)
            return
        if reference in self.vues:
            # Dans une ruche saine, une clé a exactement un parent : la revoir
            # veut dire que deux listes la référencent, donc que le parcours
            # tourne en rond. Un retour silencieux ferait passer une boucle pour
            # un arbre sain, et ferait manquer tout ce que la clé porte.
            self._erreur('boucle : clé déjà visitée à 0x%x (deux listes de '
                         'sous-clés la référencent)' % reference)
            return
        self.vues.add(reference)
        if profondeur > self.profondeur_max:
            self._erreur('profondeur supérieure à %d à 0x%x : boucle probable'
                         % (self.profondeur_max, reference))
            return
        cellule = self._cellule(reference)
        if cellule is None:
            return
        taille, offset = cellule
        if self.donnees[offset:offset + 2] != b'nk':
            self._erreur('signature nk attendue à 0x%x : %r'
                         % (reference, self.donnees[offset:offset + 2]))
            return
        if 0x4C > taille - 4:
            self._erreur('cellule nk trop courte à 0x%x' % reference)
            return
        self.cles += 1
        if profondeur > self.profondeur:
            self.profondeur = profondeur
        nom = self._nom_cle(offset, taille)
        if nom is None:
            self._erreur('nom de clé déborde de sa cellule à 0x%x' % reference)
        elif profondeur == 0:
            self.nom_racine = nom
        sous_cles = struct.unpack_from('<I', self.donnees, offset + 0x14)[0]
        liste_sous_cles = struct.unpack_from('<I', self.donnees, offset + 0x1C)[0]
        compte_valeurs = struct.unpack_from('<I', self.donnees, offset + 0x24)[0]
        liste_valeurs = struct.unpack_from('<I', self.donnees, offset + 0x28)[0]
        securite = struct.unpack_from('<I', self.donnees, offset + 0x2C)[0]
        if securite != REF_VIDE:
            self.securite.add(securite)
        # Ce qu'une clé DÉCLARE et ce que le parcours ATTEINT sont deux choses
        # différentes : une clé qui annonce 40 valeurs et ne pointe aucune liste,
        # ou dont la liste n'en porte que 3, n'a pas été parcourue. Sans ces
        # deux contrôles, ces cellules amputées ne coûtaient aucune erreur et
        # l'arbre ressortait « intact ».
        if compte_valeurs:
            if liste_valeurs == REF_VIDE:
                self._erreur('%s valeur(s) déclarée(s) mais aucune liste de '
                             'valeurs à 0x%x' % (nombre(compte_valeurs), reference))
            else:
                enumerees = self._valeurs(liste_valeurs, compte_valeurs)
                if enumerees is not None and enumerees != compte_valeurs:
                    self._erreur('%s valeur(s) déclarée(s), %s énumérée(s) à 0x%x'
                                 % (nombre(compte_valeurs), nombre(enumerees),
                                    reference))
        if sous_cles:
            if liste_sous_cles == REF_VIDE:
                self._erreur('%s sous-clé(s) déclarée(s) mais aucune liste de '
                             'sous-clés à 0x%x' % (nombre(sous_cles), reference))
            else:
                enumerees = self._liste_sous_cles(liste_sous_cles, profondeur)
                if enumerees is not None and enumerees != sous_cles:
                    self._erreur('%s sous-clé(s) déclarée(s), %s énumérée(s) à 0x%x'
                                 % (nombre(sous_cles), nombre(enumerees), reference))

    def executer(self):
        """Lance le parcours depuis la racine et contrôle les descripteurs sk."""
        if len(self.donnees) < ENTETE:
            self._erreur('fichier plus court que le bloc de base (%d octets)'
                         % len(self.donnees))
            return
        if self.donnees[0:4] != b'regf':
            self._erreur("signature regf absente : ce fichier n'est pas une ruche")
            return
        if self.fin <= 0:
            self._erreur('aucun hbin valide après le bloc de base')
            return
        self.racine = struct.unpack_from('<I', self.donnees, 0x24)[0]
        # Une référence de racine vide ne mène nulle part : _cellule() rendrait
        # None SANS erreur, le parcours s'arrêterait avant d'avoir commencé et
        # le verdict serait « arbre cohérent » sur une ruche jamais parcourue.
        if self.racine == REF_VIDE:
            self._erreur("cellule racine absente ou illisible : l'en-tête ne "
                         'désigne aucune cellule (0x%08x)' % REF_VIDE)
        else:
            self._cle(self.racine, 0)
        # Garde-fou de dernier ressort, sous tous les cas particuliers : un
        # parcours qui n'a énuméré AUCUNE clé n'a rien parcouru, et ne peut donc
        # rien acquitter. Zéro erreur ne doit jamais pouvoir signifier « corps
        # intact » sur un arbre que personne n'a descendu.
        if self.cles == 0:
            self._erreur("aucune clé énumérée : l'arbre n'a pas été parcouru, le "
                         'corps de la ruche ne peut pas être déclaré intact')
        for reference in sorted(self.securite):
            cellule = self._cellule(reference)
            if cellule is None:
                continue
            if self.donnees[cellule[1]:cellule[1] + 2] != b'sk':
                self._erreur('signature sk attendue à 0x%x' % reference)


def parcourir(donnees, profondeur_max=512):
    """Parcourt une ruche déjà chargée en mémoire et retourne un rapport.

    Point d'entrée réutilisable : repare_regf.py s'en sert pour refuser
    d'écrire une copie dont l'arbre ne tient pas debout.
    """
    # Le parcours est récursif et la profondeur d'un registre réel dépasse
    # rarement 30 : la marge couvre une ruche pathologique sans laisser une
    # boucle épuiser la pile.
    limite_precedente = sys.getrecursionlimit()
    parcours = None
    interruption = None
    try:
        sys.setrecursionlimit(max(limite_precedente, profondeur_max * 20 + 1000))
        # La construction lit déjà la chaîne des hbins : sur une ruche tronquée
        # elle peut lever, donc elle reste DANS le filet, et la limite de
        # récursion est rendue par le finally quoi qu'il arrive.
        parcours = Parcours(donnees, profondeur_max=profondeur_max)
        parcours.executer()
    except RecursionError:
        # Filet de dernier recours : une ruche assez abîmée pour déjouer les
        # garde-fous doit rendre un verdict, jamais une trace Python.
        interruption = ('pile de récursion épuisée : structure bouclée, '
                        'parcours interrompu')
    except (struct.error, IndexError) as erreur:
        interruption = ('lecture hors du fichier : ruche TRONQUÉE ou corrompue '
                        '(%s), parcours interrompu' % erreur)
    finally:
        sys.setrecursionlimit(limite_precedente)
    if parcours is None:
        # L'exception a frappé pendant la construction, avant même le premier
        # hbin : rapport vide monté à la main, pour rendre un verdict plutôt
        # qu'une trace Python. Surtout pas une seconde construction, qui
        # relèverait la même exception hors du filet.
        return {
            'fin_chaine': 0,
            'racine': 0,
            'nom_racine': '',
            'cles': 0,
            'valeurs': 0,
            'cellules_donnees': 0,
            'grandes_donnees': 0,
            'securite': 0,
            'profondeur': 0,
            'offset_max': 0,
            'erreurs': [interruption],
            'total_erreurs': 1,
        }
    if interruption is not None:
        parcours._erreur(interruption)
    return {
        'fin_chaine': parcours.fin,
        'racine': parcours.racine,
        'nom_racine': parcours.nom_racine,
        'cles': parcours.cles,
        'valeurs': parcours.valeurs,
        'cellules_donnees': parcours.cellules_donnees,
        'grandes_donnees': parcours.grandes_donnees,
        'securite': len(parcours.securite),
        'profondeur': parcours.profondeur,
        'offset_max': parcours.offset_max,
        'erreurs': parcours.erreurs,
        'total_erreurs': parcours.total_erreurs,
    }


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
        description="Parcours intégral de l'arbre d'une ruche de registre "
                    "Windows (format regf). Lecture seule.",
        epilog="Codes de retour : 0 aucune erreur de structure, 1 erreurs "
               "détectées, 2 erreur d'usage.")
    analyseur.add_argument('ruche', metavar='RUCHE', type=fichier_lisible,
                           help='ruche à parcourir (SYSTEM, SOFTWARE, une copie...)')
    analyseur.add_argument('--profondeur-max', type=int, default=512,
                           help='profondeur au-delà de laquelle on suspecte une '
                                'boucle (défaut : 512)')
    analyseur.add_argument('--erreurs-affichees', type=int, default=20,
                           help="nombre d'erreurs détaillées à afficher (défaut : 20)")
    return analyseur


def main(arguments=None):
    sortie_tolerante()
    options = construire_analyseur().parse_args(arguments)
    # Le contrôle argparse a seulement prouvé que le fichier s'ouvrait : sur un
    # disque mourant, c'est la LECTURE qui échoue. Message net, pas de trace.
    try:
        donnees = options.ruche.read_bytes()
    except OSError as erreur:
        print('LECTURE IMPOSSIBLE : %s (%s)' % (options.ruche.name, erreur))
        print('VERDICT : ruche ILLISIBLE, le disque ou le fichier refuse la '
              "lecture. Travailler sur une copie image du disque, ou restaurer "
              'une sauvegarde.')
        return 1
    rapport = parcourir(donnees, profondeur_max=options.profondeur_max)

    print('ruche                     : %s (%s octets)'
          % (options.ruche.name, nombre(len(donnees))))
    print('fin de la chaîne de hbins : 0x%x (relatif)' % rapport['fin_chaine'])
    print('clé racine                : "%s" à 0x%x'
          % (rapport['nom_racine'], rapport['racine']))
    print('clés (nk)                 : %s' % nombre(rapport['cles']))
    print('valeurs (vk)              : %s' % nombre(rapport['valeurs']))
    print('cellules de données       : %s (dont %s grandes valeurs db)'
          % (nombre(rapport['cellules_donnees']), nombre(rapport['grandes_donnees'])))
    print('descripteurs de sécurité  : %s distincts' % nombre(rapport['securite']))
    print('profondeur maximale       : %d' % rapport['profondeur'])
    print('offset le plus élevé lu   : 0x%x' % rapport['offset_max'])
    print('erreurs de structure      : %s' % nombre(rapport['total_erreurs']))
    for message in rapport['erreurs'][:max(0, options.erreurs_affichees)]:
        print('  - %s' % message)
    reste = rapport['total_erreurs'] - min(len(rapport['erreurs']),
                                           max(0, options.erreurs_affichees))
    if reste > 0:
        print('  - ... %s autre(s) erreur(s) non affichée(s)' % nombre(reste))

    if rapport['total_erreurs'] == 0:
        print('VERDICT : ARBRE COHÉRENT, corps de ruche intact')
        return 0
    print("VERDICT : %s ERREUR(S) DE STRUCTURE : le corps de la ruche est touché, "
          "la réparation d'en-tête est HORS PÉRIMÈTRE" % nombre(rapport['total_erreurs']))
    return 1


if __name__ == '__main__':
    sys.exit(main())
