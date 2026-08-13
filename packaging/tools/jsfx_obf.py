#!/usr/bin/env python3
"""Obfuscateur JSFX / EEL2 pour StripTease.

Deux etages.

  1. Les identifiants du namespace `sb_*` -- toutes les globales et toutes les
     fonctions du moteur -- sont renommes dans l'ensemble des fichiers. Il a ete
     verifie que ce prefixe n'apparait dans aucun mot-cle EEL2, aucun litteral
     chaine et aucune ligne `slider`.

  2. Les parametres et les noms declares en `local(...)` sont renommes corps de
     fonction par corps de fonction, chacun repartant de u0 (voir
     rename_body_locals). En EEL2 ces noms sont locaux au corps et il n'existe pas
     de fonction imbriquee, ce qui rend le decoupage sans ambiguite.

Sont laisses intacts :
  - les directives d'entete : desc: / options: / slider*: / in_pin: / out_pin: /
    filename: / tags: / author: / import
  - les tags ReaPack (lignes commencant par "// @")
  - les marqueurs de section (@init, @slider, @block, @sample, @gfx 80 300, ...)
  - tous les litteraux chaine
  - les natives EEL2 et les variables chaine `#nom`
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Lignes d'entete JSFX a recopier telles quelles.
DIRECTIVE_RE = re.compile(
    r"^\s*(desc|options|slider\d*|in_pin|out_pin|filename|tags|author|graphics_hidepresets)\s*:",
    re.IGNORECASE,
)
IMPORT_RE = re.compile(r"^\s*import\s", re.IGNORECASE)
SECTION_RE = re.compile(r"^\s*@[a-z]")
REAPACK_TAG_RE = re.compile(r"^\s*//\s*@")

SB_TOKEN_RE = re.compile(r"\bsb_[A-Za-z0-9_]+\b")
IDENT_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


def split_code_and_strings(line: str) -> list[tuple[str, str]]:
    """Decoupe une ligne en morceaux ('code'|'str'|'comment', texte).

    EEL2 n'a pas de commentaire bloc dans ce code (verifie), seulement `//`.
    Les chaines sont delimitees par `"` avec echappement `\\`.
    """
    parts: list[tuple[str, str]] = []
    buf = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"':
            if buf:
                parts.append(("code", "".join(buf)))
                buf = []
            j = i + 1
            while j < n:
                if line[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if line[j] == '"':
                    j += 1
                    break
                j += 1
            parts.append(("str", line[i:j]))
            i = j
            continue
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            if buf:
                parts.append(("code", "".join(buf)))
                buf = []
            parts.append(("comment", line[i:]))
            i = n
            continue
        buf.append(c)
        i += 1
    if buf:
        parts.append(("code", "".join(buf)))
    return parts


def collect_identifiers(text: str) -> set[str]:
    """Tous les identifiants presents hors chaines et hors commentaires."""
    found: set[str] = set()
    for line in text.splitlines():
        for kind, chunk in split_code_and_strings(line):
            if kind == "code":
                found.update(IDENT_RE.findall(chunk))
    return found


def collect_sb_tokens(text: str) -> set[str]:
    found: set[str] = set()
    for line in text.splitlines():
        if DIRECTIVE_RE.match(line) or IMPORT_RE.match(line):
            continue
        for kind, chunk in split_code_and_strings(line):
            if kind == "code":
                found.update(SB_TOKEN_RE.findall(chunk))
    return found


def pick_prefix(taken: set[str]) -> str:
    """Choisit un prefixe de renommage qui n'entre en collision avec rien."""
    for cand in ("q", "z", "w", "v", "qq", "zz", "j9", "x7"):
        if not any(t.startswith(cand) for t in taken):
            return cand
    raise SystemExit("obfuscation: aucun prefixe libre trouve")


def build_namemap(tokens: set[str], taken: set[str], existing: dict[str, str]) -> dict[str, str]:
    """Table de renommage deterministe et stable entre deux builds."""
    namemap = dict(existing)
    used = set(namemap.values())
    prefix = namemap.pop("__prefix__", None) or pick_prefix(taken)
    counter = 0

    def next_name() -> str:
        nonlocal counter
        while True:
            # base 36 pour rester court
            n = counter
            counter += 1
            s = ""
            while True:
                s = "0123456789abcdefghijklmnopqrstuvwxyz"[n % 36] + s
                n //= 36
                if n == 0:
                    break
            cand = prefix + s
            if cand not in used and cand not in taken:
                return cand

    for tok in sorted(tokens):
        if tok not in namemap:
            new = next_name()
            namemap[tok] = new
            used.add(new)
    namemap["__prefix__"] = prefix
    return namemap


def obfuscate(text: str, namemap: dict[str, str], strip_comments: bool = True) -> str:
    out_lines: list[str] = []
    for line in text.splitlines():
        if DIRECTIVE_RE.match(line) or IMPORT_RE.match(line):
            out_lines.append(line.rstrip())
            continue
        if REAPACK_TAG_RE.match(line):
            out_lines.append(line.rstrip())
            continue
        if SECTION_RE.match(line):
            out_lines.append(line.strip())
            continue

        rebuilt = []
        for kind, chunk in split_code_and_strings(line):
            if kind == "comment":
                if not strip_comments:
                    rebuilt.append(chunk)
                continue
            if kind == "str":
                rebuilt.append(chunk)
                continue
            rebuilt.append(SB_TOKEN_RE.sub(lambda m: namemap[m.group(0)], chunk))

        new_line = "".join(rebuilt).rstrip()
        # compactage : indentation supprimee, lignes vides supprimees
        stripped = new_line.strip()
        if stripped:
            out_lines.append(stripped)
    return "\n".join(out_lines) + "\n"


# --------------------------------------------------------------------------
# Second etage : parametres et local() de chaque fonction
# --------------------------------------------------------------------------
#
# En EEL2 les parametres d'une fonction et les noms declares dans son `local(...)`
# sont locaux a son corps ; tout autre nom du corps est une globale. Renommer
# uniformement ces noms dans le corps est donc sur : toutes leurs occurrences y
# resolvent vers la meme declaration. Les fonctions imbriquees n'existent pas en
# EEL2, ce qui rend le decoupage en corps sans ambiguite.
#
# Chaque fonction repart de u0 : les memes noms reviennent partout, et on ne peut
# plus suivre une variable d'une fonction a l'autre.

FUNC_HEAD_RE = re.compile(r"^function\s+[A-Za-z_][A-Za-z0-9_]*\s*\(", re.M)
BODY_BREAK_RE = re.compile(r"^(?:function\s|@[a-z])", re.M)


def blank_non_code(text: str) -> str:
    """Le texte avec chaines et commentaires remplaces par des espaces.

    Meme longueur que l'original : les offsets restent utilisables pour decouper
    le texte reel.
    """
    out = []
    for line in text.split("\n"):
        buf = []
        for kind, chunk in split_code_and_strings(line):
            buf.append(chunk if kind == "code" else " " * len(chunk))
        out.append("".join(buf))
    return "\n".join(out)


def match_paren(cb: str, open_at: int) -> int:
    """Index de la parenthese fermante correspondant a cb[open_at] == '('."""
    depth = 0
    for i in range(open_at, len(cb)):
        if cb[i] == "(":
            depth += 1
        elif cb[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("parenthese non fermee")


def function_bodies(cb: str) -> list[tuple[int, int]]:
    """[(debut, fin)] de chaque corps de fonction, bornes sur le texte complet.

    Le corps court de la ligne `function` jusqu'a la prochaine ligne `function`
    ou au prochain marqueur de section.
    """
    starts = [m.start() for m in FUNC_HEAD_RE.finditer(cb)]
    breaks = [m.start() for m in BODY_BREAK_RE.finditer(cb)]
    spans = []
    for s in starts:
        after = [b for b in breaks if b > s]
        spans.append((s, min(after) if after else len(cb)))
    return spans


def body_locals(cb: str, a: int, b: int) -> list[str]:
    """Parametres + noms de `local(...)` declares dans le corps [a, b)."""
    names: list[str] = []
    seen = set()

    def add_list(inner: str):
        for raw in inner.split(","):
            nm = raw.strip()
            if IDENT_RE.fullmatch(nm) and nm not in seen:
                seen.add(nm)
                names.append(nm)

    head = cb.index("(", a)
    add_list(cb[head + 1:match_paren(cb, head)])

    for m in re.finditer(r"\blocal\s*\(", cb[a:b]):
        op = a + m.end() - 1
        add_list(cb[op + 1:match_paren(cb, op)])
    return names


def rename_body_locals(text: str, prefix: str) -> tuple[str, int, list[str]]:
    """Renomme les liaisons internes de chaque fonction. (texte, total, erreurs)."""
    cb = blank_non_code(text)
    taken = set(IDENT_RE.findall(cb))
    errors: list[str] = []
    edits: list[tuple[int, int, str]] = []
    total = 0

    for a, b in function_bodies(cb):
        locs = body_locals(cb, a, b)
        if not locs:
            continue
        mapping = {}
        for i, nm in enumerate(locs):
            new = f"{prefix}{i}"
            if new in taken:
                errors.append(f"nom genere `{new}` deja present dans le fichier")
            mapping[nm] = new
        total += len(mapping)

        for m in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", cb[a:b]):
            nm = m.group(0)
            if nm not in mapping:
                continue
            pos = a + m.start()
            # `.nom` : acces membre. `#nom` : variable chaine EEL2, qui vit dans
            # un espace de noms a part et n'est jamais une liaison de corps.
            if pos > 0 and cb[pos - 1] in ".#":
                continue
            edits.append((pos, a + m.end(), mapping[nm]))

    out = []
    last = 0
    for start, end, new in edits:
        out.append(text[last:start])
        out.append(new)
        last = end
    out.append(text[last:])
    return "".join(out), total, errors


JS_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d+\.?\d*|<<|>>|[<>!=]=|&&|\|\||.")


def token_shape(text: str) -> list[str]:
    """Squelette du code : chaque identifiant reduit a 'ID', le reste tel quel.

    Deux textes qui ne different que par des renommages ont le meme squelette.
    """
    shape = []
    cb = blank_non_code(text)
    for m in JS_TOKEN_RE.finditer(cb):
        t = m.group(0)
        if not t.strip():
            continue
        shape.append("ID" if IDENT_RE.fullmatch(t) else t)
    return shape


def check_bodies(src: str, dst: str, prefix: str) -> list[str]:
    """Aucun nom local d'origine ne doit subsister dans son corps."""
    errors: list[str] = []

    a, b = token_shape(src), token_shape(dst)
    if a != b:
        i = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        errors.append(f"squelette du code modifie au token {i} "
                      f"({len(a)} vs {len(b)} tokens, contexte {' '.join(a[max(0,i-5):i+5])})")
        return errors

    cb_src, cb_dst = blank_non_code(src), blank_non_code(dst)
    a_bodies, b_bodies = function_bodies(cb_src), function_bodies(cb_dst)
    if len(a_bodies) != len(b_bodies):
        return [f"{len(a_bodies)} corps de fonction en entree, {len(b_bodies)} en sortie"]

    for (a, b), (c, d) in zip(a_bodies, b_bodies):
        old = set(body_locals(cb_src, a, b))
        present = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", cb_dst[c:d]))
        residual = sorted(old & present)
        if residual:
            errors.append(f"locales non renommees dans un corps : {residual[:5]}")
            break
        new = body_locals(cb_dst, c, d)
        if len(new) != len(old):
            errors.append(f"{len(old)} liaisons en entree, {len(new)} en sortie dans un corps")
            break
        if any(not n.startswith(prefix) for n in new):
            errors.append(f"liaison non prefixee dans un corps : "
                          f"{[n for n in new if not n.startswith(prefix)][:5]}")
            break

        # Tout ce qui n'est PAS une liaison du corps -- globales, appels de
        # fonction, natives EEL2 -- doit etre intact, position par position.
        def outline(text: str, lo: int, hi: int, locals_: set[str]) -> list[str]:
            return ["LOC" if t in locals_ else t
                    for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text[lo:hi])]

        oa = outline(cb_src, a, b, old)
        ob = outline(cb_dst, c, d, set(new))
        if oa != ob:
            i = next((i for i, (x, y) in enumerate(zip(oa, ob)) if x != y),
                     min(len(oa), len(ob)))
            errors.append(f"un nom hors liaison du corps a change : "
                          f"{oa[i:i + 1]} -> {ob[i:i + 1]}")
            break
    return errors


# --------------------------------------------------------------------------
# Garde-fous : ce qui doit etre identique entre source et sortie
# --------------------------------------------------------------------------

def string_literals(text: str) -> list[str]:
    lits: list[str] = []
    for line in text.splitlines():
        for kind, chunk in split_code_and_strings(line):
            if kind == "str":
                lits.append(chunk)
    return lits


def directive_lines(text: str) -> list[str]:
    return [
        ln.rstrip()
        for ln in text.splitlines()
        if DIRECTIVE_RE.match(ln) or IMPORT_RE.match(ln)
    ]


def check(src: str, dst: str, path: str) -> list[str]:
    errors: list[str] = []

    residual = collect_sb_tokens(dst)
    if residual:
        errors.append(f"{path}: {len(residual)} token(s) sb_ residuel(s): {sorted(residual)[:5]}")

    a, b = string_literals(src), string_literals(dst)
    if a != b:
        errors.append(f"{path}: litteraux chaine modifies ({len(a)} -> {len(b)})")

    a, b = directive_lines(src), directive_lines(dst)
    if a != b:
        diff = [x for x in a if x not in b][:3]
        errors.append(f"{path}: lignes d'entete/slider modifiees, ex: {diff}")

    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("inputs", nargs="+", type=Path)
    ap.add_argument("--outdir", type=Path, required=True)
    ap.add_argument("--namemap", type=Path, required=True)
    ap.add_argument("--keep-comments", action="store_true")
    args = ap.parse_args()

    sources = {p: p.read_text(encoding="utf-8") for p in args.inputs}

    tokens: set[str] = set()
    taken: set[str] = set()
    for text in sources.values():
        tokens |= collect_sb_tokens(text)
        taken |= collect_identifiers(text)
    taken -= tokens

    existing = {}
    if args.namemap.exists():
        existing = json.loads(args.namemap.read_text(encoding="utf-8"))

    namemap = build_namemap(tokens, taken, existing)
    args.namemap.parent.mkdir(parents=True, exist_ok=True)
    args.namemap.write_text(json.dumps(namemap, indent=2, sort_keys=True), encoding="utf-8")

    body_prefix = pick_prefix(taken | tokens | set(namemap.values()))

    errors: list[str] = []
    nbody = 0
    args.outdir.mkdir(parents=True, exist_ok=True)
    for path, text in sources.items():
        out = obfuscate(text, namemap, strip_comments=not args.keep_comments)
        errors += check(text, out, path.name)

        # second etage, applique au resultat du premier : le decoupage en corps
        # de fonction est inchange par une simple substitution d'identifiants
        renamed, n, errs = rename_body_locals(out, body_prefix)
        errors += [f"{path.name}: {e}" for e in errs]
        errors += [f"{path.name}: {e}" for e in check_bodies(out, renamed, body_prefix)]
        errors += check(text, renamed, path.name)
        nbody += n
        out = renamed

        (args.outdir / path.name).write_text(out, encoding="utf-8")
        print(f"  {path.name}: {len(text.splitlines())} -> {len(out.splitlines())} lignes")

    print(f"  {len(tokens)} identifiants sb_ renommes (prefixe '{namemap['__prefix__']}')")
    print(f"  {nbody} liaison(s) interne(s) de fonction renommee(s) (prefixe '{body_prefix}')")

    if errors:
        print("\nECHEC des garde-fous :", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
