#!/usr/bin/env python3
"""Transformation source -> edition Lite de StripTease.

Applique a une *copie* des sources (jamais aux sources elles-memes) les
restrictions de l'edition gratuite :

  - 16 elements par panneau au lieu de 50
  - 1 seul metre (VU ou barre) par panneau
  - 2 pages d'onglets au lieu de 4
  - pas de selection multiple ni de copier-coller d'elements
  - pas de Copy / Paste layout & links
  - pas de groupes de scroll
  - banque de presets limitee aux deux tailles livrees (150 / 300 px)

Les recettes, elles, sont dans la Lite : les Direct Links voyagent avec un
preset, un template ou une FX chain comme dans la Pro.

Le choix de fond : **retirer le code, pas poser un drapeau**. Un `EDITION = 0`
se retourne en dix secondes dans un fichier livre en clair ; du code absent ne
se retourne pas. Les entrees de menu Pro disparaissent, et le presse-papier
d'elements est retire du fichier.

Chaque patch est ancre sur un extrait litteral de la source et doit s'appliquer
exactement une fois : si le moteur evolue et qu'un extrait ne correspond plus,
le build echoue au lieu de livrer une Lite silencieusement incomplete.
"""

from __future__ import annotations

from dataclasses import dataclass

MAX_ELEMENTS = 16
MAX_METERS = 1
MAX_TABS = 2


@dataclass
class Patch:
    """Remplacement d'un extrait litteral, present exactement une fois."""
    what: str
    old: str
    new: str


@dataclass
class Cut:
    """Suppression d'une region : de `start` (inclus) a `end` (exclu).

    Evite de recopier cent lignes de moteur dans ce fichier pour en demander le
    retrait : les deux bornes suffisent, et chacune doit etre unique.
    """
    what: str
    start: str
    end: str


def _fail(filename: str, what: str, why: str, sample: str) -> None:
    raise SystemExit(
        f"edition lite / {filename} : le patch \"{what}\" {why}.\n"
        f"La source a change - reporter la modification dans lite.py "
        f"avant de builder.\nExtrait attendu :\n"
        + "\n".join("    " + l for l in sample.splitlines()[:6])
    )


def apply_patches(text: str, patches: list, filename: str) -> str:
    for p in patches:
        if isinstance(p, Cut):
            for bound in (p.start, p.end):
                n = text.count(bound)
                if n != 1:
                    _fail(filename, p.what,
                          f"a une borne trouvee {n} fois au lieu d'une", bound)
            i = text.index(p.start)
            j = text.index(p.end)
            if j <= i:
                _fail(filename, p.what,
                      "a ses bornes dans le desordre", p.start)
            text = text[:i] + text[j:]
        else:
            n = text.count(p.old)
            if n != 1:
                _fail(filename, p.what,
                      f"s'applique {n} fois au lieu d'une", p.old)
            text = text.replace(p.old, p.new)
    return text


# --------------------------------------------------------------------------
# striptease_panel.jsfx-inc
# --------------------------------------------------------------------------

ENGINE_PATCHES = [

    # ---- 1. Plafond d'elements -------------------------------------------
    #
    # sb_MAX reste a 50 : il gouverne la taille de l'etat serialise, le nombre
    # de sliders declares et la carte gmem, qui doivent rester identiques a
    # ceux de la Pro pour qu'une mise a niveau soit une simple copie de
    # fichiers. Seule l'allocation d'un slot neuf est bornee.
    Patch(
        "plafond d'elements dans sb_free_slot",
        """function sb_free_slot()
local(i, res)
(
  i = 0; res = -1;
  loop(sb_MAX,""",
        f"""function sb_free_slot()
local(i, res)
(
  i = 0; res = -1;
  loop({MAX_ELEMENTS},""",
    ),

    # ---- 2. Plafond de metres --------------------------------------------
    Patch(
        "plafond de metres dans sb_add",
        """function sb_add(type)
local(i, c)
(
  i = sb_free_slot();""",
        f"""function sb_lite_meters()
local(i, n)
(
  i = 0; n = 0;
  loop(sb_MAX, ( sb_type(i) == 6 || sb_type(i) == 7 ) ? ( n += 1 ); i += 1;);
  n;
);

function sb_lite_meter_full() ( sb_lite_meters() >= {MAX_METERS} );

function sb_add(type)
local(i, c)
(
  i = ( ( type == 6 || type == 7 ) && sb_lite_meter_full() ) ? -1 : sb_free_slot();""",
    ),

    # ---- 3. Plafond de pages ---------------------------------------------
    #
    # Les deux bits de drapeau de la page en portent quatre ; c'est le nombre
    # de pages proposees qui descend. Un etat venu de la Pro se charge donc
    # sans decalage, et ses elements ranges au-dela de la seconde page sont
    # ramenes dessus a la deserialisation (patch 5).
    Patch(
        "plafond de pages",
        """  // Deux bits de drapeau pour la page d'un element : quatre pages au plus.
  sb_NTAB  = 4;""",
        f"""  // Deux pages dans la Lite. Les deux bits de drapeau de la page en
  // porteraient quatre, comme dans la Pro : c'est l'offre qui est bornee.
  sb_NTAB  = {MAX_TABS};""",
    ),

    # ---- 4. Menu du fond --------------------------------------------------
    #
    # Disparaissent : Copy / Paste layout & links, le presse-papier
    # d'elements, et le groupe de scroll. Apparaissent : le bandeau d'edition
    # avec le compteur d'elements, et le grisage des entrees d'ajout quand le
    # plafond est atteint - pour que la limite se lise dans l'interface plutot
    # que de se manifester par un clic sans effet.
    Patch(
        "menu du fond",
        """  sb_mi_reset();
  sb_mi_add(1, "Add knob");
  sb_mi_add(2, "Add toggle");
  sb_mi_add(15, "Add radio");
  sb_mi_add(18, "Add GR meter");

  sb_mi_sub(">Add GR bar...");
  sb_mi_add(20, "Horizontal");
  sb_mi_add(21, "<Vertical");
  sb_mi_add(11, "Add separator");
  sb_mi_add(13, "Add title");
  sb_mi_sep();
  sb_mi_add(3, sb_edit ? "!Edit mode" : "Edit mode");
  sb_mi_add(4, sb_show_names ? "!Show names" : "Show names");
  sb_mi_add(16, sb_show_ring ? "!Show knob rings" : "Show knob rings");
  sb_build_group_menu(sb_group);
  sb_build_color_menu(sb_bg_col);
  sb_build_count_menu(sb_cols, 4);
  sb_mi_add(43, "Fit grid to elements");
  sb_build_tab_menu();
  sb_mi_sep();

  sb_mi_add(7, "Copy layout & links");
  sb_mi_add(8, sb_clip_ok() ? "Paste layout & links" : "#Paste layout & links");
  sb_mi_sep();

  // Le lot colle depuis le fond arrive sous le pointeur : c'est la case qu'on
  // vient de designer du clic droit, comme pour un element neuf.
  v = sb_sel_n();
  v ? ( sprintf(#sb_tmp, "Copy selection  (%d)", v); sb_mi_add(40, #sb_tmp); )
    : sb_mi_add(0, "#Copy selection");

  v = sb_ecb_n();
  v ? ( sprintf(#sb_tmp, "Paste elements  (%d)", v); sb_mi_add(41, #sb_tmp); )
    : sb_mi_add(0, "#Paste elements");

  sb_mi_add(42, sb_sel_n() ? "Clear selection" : "#Clear selection");
  sb_mi_sep();
""",
        f"""  sb_mi_reset();

  sprintf(#sb_tmp, "#StripTease Lite  -  %d/{MAX_ELEMENTS} elements", sb_count());
  sb_mi_add(0, #sb_tmp);
  sb_mi_sep();

  sb_mi_add(1,  sb_free_slot() < 0 ? "#Add knob"   : "Add knob");
  sb_mi_add(2,  sb_free_slot() < 0 ? "#Add toggle" : "Add toggle");
  sb_mi_add(15, sb_free_slot() < 0 ? "#Add radio"  : "Add radio");

  ( sb_free_slot() < 0 || sb_lite_meter_full() ) ? (
    sb_mi_add(0, "#Add GR meter");
    sb_mi_add(0, "#Add GR bar...");
  ) : (
    sb_mi_add(18, "Add GR meter");
    sb_mi_sub(">Add GR bar...");
    sb_mi_add(20, "Horizontal");
    sb_mi_add(21, "<Vertical");
  );

  sb_mi_add(11, sb_free_slot() < 0 ? "#Add separator" : "Add separator");
  sb_mi_add(13, sb_free_slot() < 0 ? "#Add title"     : "Add title");
  sb_mi_sep();
  sb_mi_add(3, sb_edit ? "!Edit mode" : "Edit mode");
  sb_mi_add(4, sb_show_names ? "!Show names" : "Show names");
  sb_mi_add(16, sb_show_ring ? "!Show knob rings" : "Show knob rings");
  sb_build_color_menu(sb_bg_col);
  sb_build_count_menu(sb_cols, 4);
  sb_mi_add(43, "Fit grid to elements");
  sb_build_tab_menu();
  sb_mi_sep();
""",
    ),

    # ---- 5. Chargement d'etat : troncature --------------------------------
    #
    # Un preset, un template ou une FX chain venus de la Pro se chargent sans
    # erreur, mais arrivent aux normes Lite : au-dela de 16 elements et d'un
    # metre, le surplus est efface, et ce qui etait range sur une troisieme ou
    # une quatrieme page revient sur la seconde. Le flux de serialisation reste
    # lu en entier - sinon tout ce qui suit dans l'etat serait decale.
    #
    # La recette, elle, traverse intacte : elle est du domaine de la Lite.
    Patch(
        "troncature a la deserialisation",
        """  sb_group = max(0, min(sb_NGRP, floor(sb_group + 0.5)));

  sb_ser_ver >= 13 ? (
    file_var(0, sb_lfx_occ);
    file_string(0, sb_lfx_name());
    file_mem(0, sb_lpa(), n);
    n < sb_MAX ? ( memset(sb_lpa() + n, 0, sb_MAX - n) );
  ) : (
    sb_lfx_occ = 0;
    strcpy(sb_lfx_name(), "");
    memset(sb_lpa(), 0, 64);
  );
""",
        f"""  sb_group = 0;

  sb_ser_ver >= 13 ? (
    file_var(0, sb_lfx_occ);
    file_string(0, sb_lfx_name());
    file_mem(0, sb_lpa(), n);
    n < sb_MAX ? ( memset(sb_lpa() + n, 0, sb_MAX - n) );
  ) : (
    sb_lfx_occ = 0;
    strcpy(sb_lfx_name(), "");
    memset(sb_lpa(), 0, 64);
  );

  i = {MAX_ELEMENTS};
  loop(sb_MAX - {MAX_ELEMENTS},
    memset(sb_addr(i), 0, 8);
    strcpy(sb_name(i), "");
    strcpy(sb_name2(i), "");
    sb_lp_clear(i);
    i += 1;
  );

  i = 0; n = 0;
  loop({MAX_ELEMENTS},
    ( sb_EL[i * 8] == 6 || sb_EL[i * 8] == 7 ) ? (
      n += 1;
      n > {MAX_METERS} ? (
        memset(sb_addr(i), 0, 8);
        strcpy(sb_name(i), "");
        strcpy(sb_name2(i), "");
        sb_lp_clear(i);
      );
    );
    ( sb_EL[i * 8] > 0 && sb_el_tab(i) > {MAX_TABS - 1} ) ?
      sb_el_settab(i, {MAX_TABS - 1});
    i += 1;
  );
""",
    ),

    # ---- 6. Presse-papier d'elements : retire ------------------------------
    Cut(
        "presse-papier d'elements",
        """// ---------------------------------------------------------------------------
// Presse-papier d'elements""",
        """function sb_menu_elem(i, mx, my)""",
    ),

    # ---- 7. Menu d'element : ni copie, ni collage, ni selection ------------
    Patch(
        "menu d'element",
        """  sb_mi_add(10, sb_edit ? "!Edit mode" : "Edit mode");
  sb_mi_sep();

  // Copier porte sur le lot des que l'element en fait partie : c'est ce que le
  // clic droit designe alors, et l'intitule le dit plutot que de le supposer.
  n = sb_sel_n();
  ( n >= 2 && sb_sel(i) ) ? (
    sprintf(#sb_tmp, "Copy selection  (%d)", n);
    sb_mi_add(40, #sb_tmp);
  ) : (
    sb_mi_add(40, "Copy element");
  );

  n = sb_ecb_n();
  n ? ( sprintf(#sb_tmp, "Paste  (%d)", n); sb_mi_add(41, #sb_tmp); )
    : sb_mi_add(0, "#Paste");

  sb_mi_add(42, sb_sel(i) ? "!Select  (shift-click)" : "Select  (shift-click)");
  sb_mi_sep();
  sb_mi_add(11, "Duplicate");""",
        """  sb_mi_add(10, sb_edit ? "!Edit mode" : "Edit mode");
  sb_mi_add(11, "Duplicate");""",
    ),

    Patch(
        "actions du menu d'element",
        """  a == 40 ? ( sb_ecb_copy( ( sb_sel_n() >= 2 && sb_sel(i) ) ? -1 : i ) ) :
  a == 41 ? ( sb_first_free_cell(sb_cur_tab()); sb_ecb_paste(sb_fc_col, sb_fc_row); ) :
  a == 42 ? ( sb_sel_toggle(i); sb_edit = 1; ) :
""",
        "",
    ),

    Patch(
        "actions du menu du fond",
        """  a == 40 ? sb_ecb_copy(-1) :
  a == 41 ? sb_ecb_paste(sb_at_col, sb_at_row) :
  a == 42 ? sb_sel_clear() :
""",
        "",
    ),

    # ---- 8. Shift + clic : plus rien a selectionner ------------------------
    #
    # Sans candidat, tout ce qui reste de la selection ne s'allume jamais :
    # sb_sel_cand garde le -1 pose a l'initialisation, l'anneau ne se dessine
    # pas, et Shift + glisser redimensionne comme avant.
    Patch(
        "candidat de selection au clic",
        """            sb_ref_sz    = sb_EL[cur * 8 + 5];

            // Shift : le geste n'est pas encore tranche. Tant que la souris n'a
            // pas franchi le jeu, il peut devenir un redimensionnement ; s'il
            // relache sur place, c'est une selection.
            sb_sel_cand = (mouse_cap & 8) ? cur : -1;
            sb_sel_mx   = mx; sb_sel_my = my;

            // Prendre un element hors du lot sans Shift abandonne le lot : on
            // travaille desormais sur celui-la. Prendre un element du lot le
            // garde, c'est le debut d'un deplacement en bloc.
            ( !(mouse_cap & 8) && !sb_SEL[cur] ) ? sb_sel_clear();
""",
        """            sb_ref_sz    = sb_EL[cur * 8 + 5];
""",
    ),

    Patch(
        "abandon du lot au clic dans le vide",
        """          // Clic dans le vide sans Shift : le lot est abandonne.
          ( sb_edit && !(mouse_cap & 8) ) ? sb_sel_clear();

          sb_maxscroll() > 0 ? (""",
        """          sb_maxscroll() > 0 ? (""",
    ),

    # ---- 9. Deplacement en bloc : retire -----------------------------------
    #
    # Sans lot, le glisser retrouve exactement le geste d'avant : un element,
    # une case.
    Patch(
        "deplacement en bloc au glisser",
        """            ( tc != c[3] || tr != c[4] ) ? (

              // L'element tire fait partie du lot : le lot entier suit.
              sb_SEL[sb_drag_idx] ? (
                sb_sel_can_move(tc - c[3], tr - c[4]) ?
                  sb_sel_move(tc - c[3], tr - c[4]);
              ) : (
                sb_cell_owner(tc, tr, sb_drag_idx, sb_cur_tab()) < 0 ? (
                  c[3] = tc; c[4] = tr;
                );
              );
            );""",
        """            ( (tc != c[3] || tr != c[4]) &&
              sb_cell_owner(tc, tr, sb_drag_idx, sb_cur_tab()) < 0 ) ? (
              c[3] = tc; c[4] = tr;
            );""",
    ),

    Cut(
        "fonctions de deplacement en bloc",
        """// Deplacement en bloc.""",
        """// Le panneau n'expose que son interface graphique""",
    ),
]


# --------------------------------------------------------------------------
# StripTease System.lua
# --------------------------------------------------------------------------

SYSTEM_PATCHES = [
    # La banque de presets partagee ne couvre que les tailles livrees : sans
    # cela le service chercherait cinq fichiers .ini qui n'existent pas.
    Patch(
        "tailles de panneau de la banque de presets",
        'local PSIZES      = { "050", "100", "150", "200", "300", "400", "600" }',
        'local PSIZES      = { "150", "300" }',
    ),
]


PATCHES_BY_FILE = {
    "striptease_panel.jsfx-inc": ENGINE_PATCHES,
    "StripTease System.lua": SYSTEM_PATCHES,
}


def transform(filename: str, text: str) -> str:
    """Texte de `filename` transforme pour l'edition Lite (inchange si non concerne)."""
    patches = PATCHES_BY_FILE.get(filename)
    return apply_patches(text, patches, filename) if patches else text


def files_touched() -> list[str]:
    return sorted(PATCHES_BY_FILE)
