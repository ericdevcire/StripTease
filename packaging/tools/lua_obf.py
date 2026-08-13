#!/usr/bin/env python3
"""Obfuscateur Lua pour StripTease.

Deux etages :
  1. renommage des liaisons locales, puis suppression des commentaires, de
     l'indentation et des lignes vides ;
  2. encodage : le corps est chiffre (cle additive) puis encode en hexa, et le
     fichier livre se reduit a un stub `load(<decodage>)()`.

Le renommage travaille sur un flux de tokens avec un vrai suivi de blocs, a trois
niveaux :

  Niveau A -- les noms lies UNIQUEMENT au niveau du chunk (constantes, fonctions
  de portee fichier) sont renommes partout dans le fichier.

  Niveau B -- pour chaque fonction de portee fichier, les noms lies A L'INTERIEUR
  de son corps (parametres, locales de tout niveau, variables de boucle) sont
  renommes dans ce corps seulement.

Pourquoi le niveau B est sur sans analyse de portee fine : si un nom est lie dans
le corps d'une fonction et n'existe pas a l'exterieur, alors toute occurrence de
ce nom dans le corps resout forcement vers l'une de ses liaisons du corps. Comme
elles recoivent toutes le meme nouveau nom, le graphe de resolution est
inchange -- y compris avec des liaisons imbriquees qui se masquent. Deux
fonctions differentes reutilisent donc les memes noms, ce qui est voulu : ca
supprime l'indice qu'un lecteur tire d'un nom stable.

  Niveau C -- les noms de champ des tables du programme, renommes partout, mais
  seulement quand leur appartenance est prouvee (voir field_plan) : les champs de
  REAPER et les methodes de la bibliotheque standard vivent dans le meme espace
  syntaxique et ne doivent surtout pas bouger.

Un nom lie a la fois au niveau du chunk et dans un corps de fonction est ecarte :
dans `local x = x`, le membre droit resout vers la liaison exterieure, que les
deux niveaux renommeraient differemment.

Les espaces sont disjoints : A et B ne touchent qu'aux positions de variable, C
qu'aux positions de champ. Un meme nom peut donc etre une variable et un champ
sans que les deux se melangent.

Jamais renommes : les noms globaux Lua/reaper, les mots-cles, et tout champ dont
l'appartenance au programme n'est pas prouvee.

Ce n'est pas un DRM : le chunk decode reste imprimable depuis REAPER. C'est un
ralentisseur contre la reprise d'algorithme.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

LUA_GLOBALS = {
    "_G", "_ENV", "_VERSION", "assert", "collectgarbage", "dofile", "error",
    "getmetatable", "ipairs", "load", "loadstring", "next", "pairs", "pcall",
    "print", "rawequal", "rawget", "rawlen", "rawset", "require", "select",
    "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
    "coroutine", "debug", "io", "math", "os", "package", "string", "table",
    "utf8", "reaper", "gfx", "self", "nil", "true", "false",
}
LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}

RESERVED = LUA_GLOBALS | LUA_KEYWORDS

FILE_PREFIX = "_l"
SPAN_PREFIX = "_s"

CHUNK = -1  # pseudo-portee : le corps du fichier


def tokenize(src: str) -> list[tuple[str, str]]:
    """Decoupe en ('code'|'str'|'comment', texte). Gere '' "" [[ ]] -- --[[ ]].

    Les morceaux se concatenent exactement en `src` : les positions absolues
    calculees par lex() en dependent.
    """
    out: list[tuple[str, str]] = []
    buf: list[str] = []
    i, n = 0, len(src)

    def flush():
        if buf:
            out.append(("code", "".join(buf)))
            buf.clear()

    def long_bracket(start: int):
        """Fin du long bracket ouvert a `start`, ou None si ce n'en est pas un."""
        if src[start] != "[":
            return None
        j = start + 1
        level = 0
        while j < n and src[j] == "=":
            level += 1
            j += 1
        if j < n and src[j] == "[":
            close = "]" + "=" * level + "]"
            end = src.find(close, j + 1)
            end = n if end == -1 else end + len(close)
            return end
        return None

    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            flush()
            lb = long_bracket(i + 2) if i + 2 < n else None
            if lb:
                out.append(("comment", src[i:lb]))
                i = lb
            else:
                j = src.find("\n", i)
                j = n if j == -1 else j
                out.append(("comment", src[i:j]))
                i = j
            continue
        if c in "\"'":
            flush()
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c:
                    j += 1
                    break
                j += 1
            out.append(("str", src[i:j]))
            i = j
            continue
        if c == "[":
            lb = long_bracket(i)
            if lb:
                flush()
                out.append(("str", src[i:lb]))
                i = lb
                continue
        buf.append(c)
        i += 1
    flush()
    return out


def strip_comments(src: str) -> str:
    rebuilt = []
    for kind, chunk in tokenize(src):
        if kind == "comment":
            # on garde les sauts de ligne pour ne pas coller deux instructions
            rebuilt.append("\n" * chunk.count("\n"))
        else:
            rebuilt.append(chunk)
    text = "".join(rebuilt)
    lines = [ln.strip() for ln in text.splitlines()]
    return "\n".join(ln for ln in lines if ln) + "\n"


def code_only(src: str) -> str:
    """Le source avec chaines et commentaires blanchis (pour l'analyse)."""
    return "".join(
        chunk if kind == "code" else " " * len(chunk) for kind, chunk in tokenize(src)
    )


# --------------------------------------------------------------------------
# Flux de tokens positionne
# --------------------------------------------------------------------------

TOKEN_RE = re.compile(
    r"[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|"
    r"\.\.\.|\.\.|==|~=|<=|>=|::|<<|>>|//|."
)
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")

# (kind, texte, debut, fin) ; kind = "name" | "str" | "other"
Tok = tuple[str, str, int, int]


def lex(src: str) -> list[Tok]:
    toks: list[Tok] = []
    pos = 0
    for kind, chunk in tokenize(src):
        if kind == "comment":
            pos += len(chunk)
            continue
        if kind == "str":
            toks.append(("str", chunk, pos, pos + len(chunk)))
            pos += len(chunk)
            continue
        for m in TOKEN_RE.finditer(chunk):
            t = m.group(0)
            if not t.strip():
                continue
            kind_t = "name" if NAME_RE.match(t) else "other"
            toks.append((kind_t, t, pos + m.start(), pos + m.end()))
        pos += len(chunk)
    return toks


def block_map(toks: list[Tok]) -> tuple[list[int], list[tuple[int, int]]]:
    """(span_of, spans).

    spans  : [(index du `function`, index du `end`)] des fonctions de portee
             fichier, bornes incluses.
    span_of: pour chaque token, l'index de son span, ou CHUNK.

    Le suivi distingue le `do` d'un `for`/`while` -- qui appartient a l'entete et
    n'ouvre pas un bloc de plus -- du `do` autonome. C'est precisement ce que
    l'ancienne version comptait en double, ce qui faisait deriver la profondeur
    et rendait invisible tout ce qui suivait la premiere boucle.
    """
    stack: list[tuple[str, int]] = []
    pending_do = 0
    spans: list[tuple[int, int]] = []

    for i, (k, t, _, _) in enumerate(toks):
        if k != "name":
            continue
        if t in ("function", "if"):
            stack.append((t, i))
        elif t in ("for", "while"):
            stack.append((t, i))
            pending_do += 1
        elif t == "do":
            if pending_do:
                pending_do -= 1
            else:
                stack.append(("do", i))
        elif t == "repeat":
            stack.append((t, i))
        elif t in ("end", "until"):
            if not stack:
                raise ValueError(f"`{t}` sans bloc ouvert (token {i})")
            top, start = stack.pop()
            if not stack and top == "function":
                spans.append((start, i))

    if stack:
        raise ValueError(f"{len(stack)} bloc(s) non fermes : {[s[0] for s in stack]}")

    span_of = [CHUNK] * len(toks)
    for s, (a, b) in enumerate(spans):
        for i in range(a, b + 1):
            span_of[i] = s
    return span_of, spans


def bracket_ctx(toks: list[Tok]) -> list[str]:
    """Pour chaque token, le delimiteur ouvrant le plus proche ('{', '(', '[')."""
    ctx = [""] * len(toks)
    st: list[str] = []
    for i, (_, t, _, _) in enumerate(toks):
        ctx[i] = st[-1] if st else ""
        if t in ("{", "(", "["):
            st.append(t)
        elif t in ("}", ")", "]") and st:
            st.pop()
    return ctx


def is_field(toks: list[Tok], i: int) -> bool:
    return i > 0 and toks[i - 1][1] in (".", ":")


def is_table_key(toks: list[Tok], ctx: list[str], i: int) -> bool:
    """`{ nom = ... }` : le nom est une cle litterale, pas une variable.

    Le test exige d'etre directement dans un `{` : sans ca, `local a, b = 1, 2`
    ferait passer `b` pour une cle.
    """
    if ctx[i] != "{":
        return False
    if i == 0 or toks[i - 1][1] not in ("{", ",", ";"):
        return False
    return i + 1 < len(toks) and toks[i + 1][1] == "="


def renameable_at(toks: list[Tok], ctx: list[str], i: int) -> bool:
    k, t, _, _ = toks[i]
    if k != "name" or t in RESERVED:
        return False
    return not is_field(toks, i) and not is_table_key(toks, ctx, i)


# --------------------------------------------------------------------------
# Liaisons
# --------------------------------------------------------------------------

def bindings(toks: list[Tok], span_of: list[int]) -> list[tuple[str, int]]:
    """Liaisons declarees, dans l'ordre du source : [(nom, portee)].

    portee = CHUNK ou index de span. Une meme paire peut revenir plusieurs fois
    (plusieurs `local` du meme nom dans la meme portee) : c'est sans consequence,
    ils recevront le meme nouveau nom et continueront de se masquer entre eux.
    """
    out: list[tuple[str, int]] = []
    n = len(toks)
    i = 0
    while i < n:
        k, t, _, _ = toks[i]
        if k == "name" and t == "local":
            scope = span_of[i]
            j = i + 1
            if j < n and toks[j][1] == "function":
                if j + 1 < n and toks[j + 1][0] == "name":
                    out.append((toks[j + 1][1], scope))
                # on recule d'un cran pour que la branche `function` reprenne la
                # main au tour suivant et releve les parametres : sans ca, les
                # parametres des `local function` ne sont jamais collectes.
                i = j - 1
            else:
                while j < n and toks[j][0] == "name" and toks[j][1] not in RESERVED:
                    out.append((toks[j][1], scope))
                    j += 1
                    if j < n and toks[j][1] == ",":
                        j += 1
                        continue
                    break
                i = j - 1
        elif k == "name" and t == "function":
            # parametres : entre la premiere `(` et sa fermante
            j = i + 1
            while j < n and toks[j][1] != "(":
                if toks[j][0] != "name" and toks[j][1] not in (".", ":"):
                    break
                j += 1
            if j < n and toks[j][1] == "(":
                j += 1
                while j < n and toks[j][1] != ")":
                    if toks[j][0] == "name" and toks[j][1] not in RESERVED:
                        out.append((toks[j][1], span_of[j]))
                    j += 1
            i = j
        elif k == "name" and t == "for":
            j = i + 1
            while j < n and toks[j][1] not in ("=", "in", "do"):
                if toks[j][0] == "name" and toks[j][1] not in RESERVED:
                    out.append((toks[j][1], span_of[j]))
                j += 1
            i = j
        i += 1
    return out


LIB_GLOBALS = {
    "math", "string", "table", "io", "os", "reaper", "gfx", "coroutine",
    "debug", "utf8", "package", "_G", "_ENV",
}


def field_plan(toks: list[Tok], ctx: list[str], taken: set[str]
               ) -> tuple[dict[str, str], list[tuple[str, str]]]:
    """Renommage des noms de champ des tables du programme (niveau C).

    Un nom de champ n'est pris que s'il est *prouve* interne :

      1. il apparait au moins une fois en position de definition -- cle litterale
         d'un constructeur `{ nom = ... }`, ou affectation `x.nom = ...` -- ce qui
         prouve qu'une table du programme le definit ;
      2. il n'est jamais appele en methode (`x:nom(...)`) : ce serait une methode
         de chaine ou de fichier de la bibliotheque standard ;
      3. il n'est jamais accede sur une bibliotheque (`math.nom`, `reaper.nom`) --
         sans ce test, `max` et `min`, qui sont des cles de table ici ET des
         fonctions de `math`, seraient renommes jusque dans `math.max` ;
      4. il n'apparait dans aucun litteral chaine, au cas ou il servirait de cle
         calculee ;
      5. le fichier ne fait nulle part d'acces `t["chaine"]`, sinon le lien entre
         la chaine et le champ echapperait a l'analyse.

    Les noms de champ vivent dans un espace separe des variables : les niveaux
    A/B ne touchent jamais aux positions de champ, et le niveau C ne touche
    qu'a elles.
    """
    ctor: set[str] = set()
    colon: set[str] = set()
    on_lib: set[str] = set()
    for i, (k, t, _, _) in enumerate(toks):
        if k != "name":
            continue
        if is_table_key(toks, ctx, i):
            ctor.add(t)
        if (i and toks[i - 1][1] == "." and i + 1 < len(toks)
                and toks[i + 1][1] == "="):
            ctor.add(t)
        if i and toks[i - 1][1] == ":":
            colon.add(t)
        if i > 1 and toks[i - 1][1] == "." and toks[i - 2][1] in LIB_GLOBALS:
            on_lib.add(t)

    strs = " ".join(t for k, t, _, _ in toks if k == "str")
    in_str = {n for n in ctor if re.search(r"\b" + re.escape(n) + r"\b", strs)}
    dynamic = any(toks[i][1] == "[" and toks[i + 1][0] == "str"
                  for i in range(len(toks) - 1))

    skipped: list[tuple[str, str]] = []
    if dynamic:
        for n in sorted(ctor):
            skipped.append((n, "le fichier fait un acces t[\"chaine\"]"))
        return {}, skipped

    for n in sorted(ctor & colon):
        skipped.append((n, "appele en methode"))
    for n in sorted(ctor & on_lib):
        skipped.append((n, "accede sur une bibliotheque"))
    for n in sorted(in_str):
        skipped.append((n, "apparait dans un litteral chaine"))

    cands = ctor - colon - on_lib - in_str - RESERVED
    fieldmap: dict[str, str] = {}
    counter = 0
    for i, (k, t, _, _) in enumerate(toks):      # ordre du source, stable
        if k == "name" and t in cands and t not in fieldmap:
            while True:
                cand = f"_f{counter}"
                counter += 1
                if cand not in taken and cand not in fieldmap.values():
                    break
            fieldmap[t] = cand
    return fieldmap, skipped


def escaping_names(toks: list[Tok], ctx: list[str], span_of: list[int],
                   scopes: dict[str, set[int]]) -> set[str]:
    """Noms lies uniquement dans des corps de fonction, mais utilises ailleurs.

    Un tel nom designe forcement une globale la ou il n'est pas lie -- une globale
    implicite, typiquement. Le niveau B renommerait alors uniformement dans le
    corps des occurrences qui, avant la liaison, visent la globale. On l'ecarte.

    Les noms lies au niveau du chunk ne passent pas par ici : le niveau A les
    renomme partout, ce qui est correct par construction.
    """
    bad = set()
    for i, (k, t, _, _) in enumerate(toks):
        if k != "name" or t not in scopes or CHUNK in scopes[t]:
            continue
        if not renameable_at(toks, ctx, i):
            continue
        if span_of[i] not in scopes[t]:
            bad.add(t)
    return bad


def plan(toks: list[Tok], ctx: list[str], span_of: list[int], spans: list[tuple[int, int]],
         taken: set[str]) -> tuple[dict[str, str], list[dict[str, str]], list[tuple[str, str]]]:
    """(filemap, spanmaps, ecartes)."""
    binds = bindings(toks, span_of)

    scopes: dict[str, set[int]] = {}
    for name, sc in binds:
        scopes.setdefault(name, set()).add(sc)

    # Un nom lie a la fois au niveau du chunk et dans un corps : les deux niveaux
    # lui donneraient des noms differents, or une occurrence du corps peut resoudre
    # vers la liaison exterieure (`local x = x`). On l'ecarte.
    ambiguous = {n for n, sc in scopes.items() if CHUNK in sc and len(sc) > 1}

    # Meme raisonnement pour un nom qui deborde de ses corps de fonction.
    shadowed_globals = escaping_names(toks, ctx, span_of, scopes)
    ambiguous |= shadowed_globals

    skipped: list[tuple[str, str]] = []
    for n in sorted(ambiguous - shadowed_globals):
        skipped.append((n, "lie au niveau du chunk ET dans une fonction"))
    for n in sorted(shadowed_globals):
        skipped.append((n, "globale implicite masquee par une locale"))
    for n in sorted({n for n in scopes if n in RESERVED}):
        skipped.append((n, "nom reserve"))

    filemap: dict[str, str] = {}
    spanmaps: list[dict[str, str]] = [{} for _ in spans]

    # Un compteur par portee : chaque fonction repart de _s0. Les memes noms
    # servent donc dans toutes les fonctions, et un lecteur ne peut plus suivre
    # une variable d'une fonction a l'autre. C'est sur parce qu'un nom de niveau B
    # est invisible hors de son corps.
    counters = {CHUNK: 0}

    def fresh(scope: int, prefix: str, used: set[str]) -> str:
        while True:
            cand = f"{prefix}{counters[scope]}"
            counters[scope] += 1
            if cand not in taken and cand not in used:
                return cand

    for name, sc in binds:
        if name in ambiguous or name in RESERVED:
            continue
        counters.setdefault(sc, 0)
        if sc == CHUNK:
            if name not in filemap:
                filemap[name] = fresh(CHUNK, FILE_PREFIX, set(filemap.values()))
        else:
            m = spanmaps[sc]
            if name not in m:
                m[name] = fresh(sc, SPAN_PREFIX, set(m.values()))
    return filemap, spanmaps, skipped


def is_member_pos(toks: list[Tok], ctx: list[str], i: int) -> bool:
    return is_field(toks, i) or is_table_key(toks, ctx, i)


def target(toks: list[Tok], ctx: list[str], span_of: list[int],
           filemap: dict[str, str], spanmaps: list[dict[str, str]],
           fieldmap: dict[str, str], i: int) -> str | None:
    """Le nouveau nom du token i, ou None s'il ne bouge pas."""
    k, t, _, _ = toks[i]
    if k != "name" or t in RESERVED:
        return None
    if is_member_pos(toks, ctx, i):
        return fieldmap.get(t)
    s = span_of[i]
    if s != CHUNK and t in spanmaps[s]:
        return spanmaps[s][t]
    return filemap.get(t)


def rewrite(src: str, toks: list[Tok], ctx: list[str], span_of: list[int],
            filemap: dict[str, str], spanmaps: list[dict[str, str]],
            fieldmap: dict[str, str]) -> str:
    out: list[str] = []
    last = 0
    for i, (_, _, a, b) in enumerate(toks):
        new = target(toks, ctx, span_of, filemap, spanmaps, fieldmap, i)
        if new is None:
            continue
        out.append(src[last:a])
        out.append(new)
        last = b
    out.append(src[last:])
    return "".join(out)


# --------------------------------------------------------------------------
# Garde-fous
# --------------------------------------------------------------------------

def verify(src: str, out: str, toks: list[Tok], ctx: list[str], span_of: list[int],
           spans: list[tuple[int, int]], filemap: dict[str, str],
           spanmaps: list[dict[str, str]], fieldmap: dict[str, str],
           taken: set[str]) -> list[str]:
    errors: list[str] = []

    # a) le flux de tokens de la sortie est exactement celui prevu
    expected = [
        (k, target(toks, ctx, span_of, filemap, spanmaps, fieldmap, i) or t)
        for i, (k, t, _, _) in enumerate(toks)
    ]
    got = [(k, t) for k, t, _, _ in lex(out)]
    if len(expected) != len(got):
        errors.append(f"flux de tokens : {len(expected)} attendus, {len(got)} obtenus")
    else:
        for i, (e, g) in enumerate(zip(expected, got)):
            if e != g:
                ctxt = " ".join(t for _, t in expected[max(0, i - 5):i + 5])
                errors.append(f"token {i} : attendu {e!r}, obtenu {g!r} (contexte: {ctxt})")
                break

    # b) injectivite et absence de collision avec un nom deja present
    def check_map(label: str, m: dict[str, str]):
        if len(set(m.values())) != len(m):
            errors.append(f"{label} : deux noms distincts recoivent le meme nouveau nom")
        clash = sorted(set(m.values()) & taken)
        if clash:
            errors.append(f"{label} : nouveaux noms deja utilises dans le source : {clash[:5]}")

    check_map("niveau A", filemap)
    check_map("niveau C", fieldmap)
    for s, m in enumerate(spanmaps):
        check_map(f"span {s}", m)

    # Les niveaux doivent viser des espaces disjoints : un nom qui est a la fois
    # variable et champ ne doit pas voir les deux espaces se melanger.
    overlap = set(fieldmap.values()) & (set(filemap.values())
                                        | {v for m in spanmaps for v in m.values()})
    if overlap:
        errors.append(f"noms generes partages entre espaces variable et champ : {sorted(overlap)[:5]}")

    # c) aucun residu : un nom renomme ne doit plus apparaitre en position
    #    renommable dans la portee ou il a ete renomme
    out_toks = lex(out)
    out_ctx = bracket_ctx(out_toks)
    try:
        out_span_of, out_spans = block_map(out_toks)
    except ValueError as exc:
        errors.append(f"structure de blocs de la sortie invalide : {exc}")
        return errors

    if len(out_spans) != len(spans):
        errors.append(f"{len(spans)} fonctions de portee fichier en entree, "
                      f"{len(out_spans)} en sortie")
        return errors

    for i, (k, t, _, _) in enumerate(out_toks):
        if k != "name" or t in RESERVED:
            continue
        if is_member_pos(out_toks, out_ctx, i):
            if t in fieldmap:
                errors.append(f"residu : le champ `{t}` subsiste")
                break
            continue
        s = out_span_of[i]
        if s != CHUNK and t in spanmaps[s]:
            errors.append(f"residu : `{t}` subsiste dans le span {s}")
            break
        if t in filemap:
            errors.append(f"residu : `{t}` subsiste au niveau du chunk")
            break

    # d) le nombre d'occurrences de chaque nom est conserve, espace par espace et
    #    portee par portee : une fusion accidentelle de deux noms se verrait ici
    MEMBER = -2

    def census(toks_, ctx_, span_of_):
        c: dict[tuple[int, str], int] = {}
        for i, (k, t, _, _) in enumerate(toks_):
            if k != "name" or t in RESERVED:
                continue
            key = (MEMBER if is_member_pos(toks_, ctx_, i) else span_of_[i], t)
            c[key] = c.get(key, 0) + 1
        return c

    a_cen = census(toks, ctx, span_of)
    b_cen = census(out_toks, out_ctx, out_span_of)
    for (sc, name), cnt in a_cen.items():
        if sc == MEMBER:
            new = fieldmap.get(name, name)
        elif sc != CHUNK:
            new = spanmaps[sc].get(name) or filemap.get(name) or name
        else:
            new = filemap.get(name, name)
        if b_cen.get((sc, new), 0) != cnt:
            errors.append(
                f"espace {sc} : `{name}` -> `{new}` compte {cnt} occurrence(s) "
                f"en entree, {b_cen.get((sc, new), 0)} en sortie")
            break

    return errors


def decode_roundtrip(stub: str, expected: str, key: bytes) -> list[str]:
    """Rejoue le decodage du stub en Python pour verifier l'encodage."""
    m = re.search(r"local H=(.+)\n", stub)
    if not m:
        return ["stub : chaine hexa introuvable"]
    hexs = "".join(re.findall(r'"([0-9a-f]*)"', m.group(1)))
    enc = bytes.fromhex(hexs)
    raw = bytes((enc[i] - key[i % len(key)]) % 256 for i in range(len(enc)))
    got = raw.decode("utf-8")
    return [] if got == expected else ["decodage != corps encode"]


def encode(body: str, chunkname: str, key: bytes) -> str:
    raw = body.encode("utf-8")
    enc = bytes((raw[i] + key[i % len(key)]) % 256 for i in range(len(raw)))
    hexs = enc.hex()
    keylist = ",".join(str(b) for b in key)
    # decoupage de la chaine hexa pour ne pas produire une ligne de 60 ko
    chunks = [hexs[i:i + 4000] for i in range(0, len(hexs), 4000)]
    parts = "..".join(f'"{c}"' for c in chunks)
    return (
        f"local K={{{keylist}}}\n"
        f"local H={parts}\n"
        'local S=(H:gsub("%x%x",function(h) return string.char(tonumber(h,16)) end))\n'
        "local T,N={},#K\n"
        "for i=1,#S do T[i]=string.char((string.byte(S,i)-K[(i-1)%N+1])%256) end\n"
        f'load(table.concat(T),"@{chunkname}")()\n'
    )


def rename_locals(src: str, verbose: bool = True):
    toks = lex(src)
    ctx = bracket_ctx(toks)
    span_of, spans = block_map(toks)
    taken = {t for k, t, _, _ in toks if k == "name"}

    filemap, spanmaps, skipped = plan(toks, ctx, span_of, spans, taken)
    fieldmap, fskipped = field_plan(toks, ctx, taken)
    skipped += fskipped
    out = rewrite(src, toks, ctx, span_of, filemap, spanmaps, fieldmap)
    out = strip_comments(out)

    errors = verify(src, out, toks, ctx, span_of, spans, filemap, spanmaps,
                    fieldmap, taken)

    nspan = sum(len(m) for m in spanmaps)
    if verbose:
        print(f"    {len(spans)} fonction(s) de portee fichier")
        print(f"    niveau A : {len(filemap)} nom(s) de portee fichier renomme(s)")
        print(f"    niveau B : {nspan} liaison(s) interne(s) renommee(s)")
        print(f"    niveau C : {len(fieldmap)} nom(s) de champ renomme(s)")
        if skipped:
            print(f"    ecartes ({len(skipped)}) : "
                  + ", ".join(f"{n} [{w}]" for n, w in skipped[:6])
                  + ("..." if len(skipped) > 6 else ""))
    return out, errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("inputs", nargs="+", type=Path)
    ap.add_argument("--outdir", type=Path, required=True)
    ap.add_argument("--no-rename", action="store_true")
    ap.add_argument("--no-encode", action="store_true")
    ap.add_argument("--key", default="StripTease")
    args = ap.parse_args()

    args.outdir.mkdir(parents=True, exist_ok=True)
    key = args.key.encode("utf-8")

    errors: list[str] = []
    for path in args.inputs:
        src = path.read_text(encoding="utf-8")
        print(f"  {path.name}")
        if args.no_rename:
            body, errs = strip_comments(src), []
        else:
            body, errs = rename_locals(src)
        errors += [f"{path.name}: {e}" for e in errs]

        if args.no_encode:
            out = body
        else:
            out = encode(body, path.name, key)
            errors += [f"{path.name}: {e}" for e in decode_roundtrip(out, body, key)]

        (args.outdir / path.name).write_text(out, encoding="utf-8")
        print(f"    {len(src)} -> {len(out)} octets")

    if errors:
        print("\nECHEC des garde-fous :", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
