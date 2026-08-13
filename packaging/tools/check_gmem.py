#!/usr/bin/env python3
"""Verifie la coherence de la carte memoire partagee gmem entre JSFX et Lua.

Le protocole StripTease repose sur des adresses gmem declarees en dur dans les deux
langages (sb_LRN = 12288 cote JSFX, LRN = 12288 cote Lua). Un decalage d'un seul
cote ne produit aucune erreur : les deux moitiees continuent de tourner et
s'ecrivent simplement a cote, ce qui donne un bug silencieux tres couteux a
diagnostiquer.

Ce script compare chaque constante aux valeurs de gmem_map.json et verifie
qu'aucun bloc n'en chevauche un autre. Il est appele par build.py, et refuse le
build en cas d'ecart.

    python3 packaging/tools/check_gmem.py [--map gmem_map.json] [--src StripTease]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent.parent


def find_const(text: str, ident: str, is_lua: bool) -> list[int]:
    """Toutes les valeurs numeriques affectees a `ident` dans le fichier."""
    if is_lua:
        pat = rf"^\s*local\s+{re.escape(ident)}\s*=\s*(\d+)\s*(?:$|--)"
    else:
        pat = rf"^\s*{re.escape(ident)}\s*=\s*(\d+)\s*;"
    return [int(m) for m in re.findall(pat, text, re.M)]


def check(map_path: Path, src_dirs: list[Path]) -> list[str]:
    spec = json.loads(map_path.read_text(encoding="utf-8"))
    errors: list[str] = []

    files: dict[str, str] = {}
    for d in src_dirs:
        for p in d.iterdir():
            if p.is_file():
                files.setdefault(p.name, p.read_text(encoding="utf-8", errors="replace"))

    entries = spec["blocks"] + spec["scalars"]

    for e in entries:
        for fname, ident in e["names"].items():
            if fname not in files:
                errors.append(f"{e['name']}: fichier introuvable ({fname})")
                continue
            found = find_const(files[fname], ident, fname.endswith(".lua"))
            if not found:
                errors.append(
                    f"{e['name']}: `{ident}` introuvable dans {fname} "
                    f"(renomme ou supprime ? mettre gmem_map.json a jour)")
            elif len(set(found)) > 1:
                errors.append(f"{e['name']}: `{ident}` a plusieurs valeurs dans {fname}: {found}")
            elif found[0] != e["value"]:
                errors.append(
                    f"{e['name']}: {fname} declare `{ident}` = {found[0]}, "
                    f"la carte dit {e['value']}")

    # chevauchements
    blocks = sorted(spec["blocks"], key=lambda b: b["value"])
    for a, b in zip(blocks, blocks[1:]):
        end = a["value"] + a["size"]
        if end > b["value"]:
            errors.append(
                f"chevauchement : {a['name']} occupe {a['value']}..{end - 1} "
                f"et deborde sur {b['name']} qui commence a {b['value']}")

    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", type=Path, default=TOOLS / "gmem_map.json")
    ap.add_argument("--src", type=Path, nargs="+",
                    default=[ROOT / "StripTease", TOOLS.parent / "src"])
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    errors = check(args.map, [d for d in args.src if d.exists()])

    if errors:
        print("Carte gmem incoherente :", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        return 1

    if not args.quiet:
        spec = json.loads(args.map.read_text(encoding="utf-8"))
        n = len(spec["blocks"]) + len(spec["scalars"])
        last = max(b["value"] + b["size"] for b in spec["blocks"])
        print(f"  carte gmem coherente : {n} constantes, "
              f"{len(spec['blocks'])} blocs, derniere case utilisee {last - 1}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
