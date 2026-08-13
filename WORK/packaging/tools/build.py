#!/usr/bin/env python3
"""Build StripTease : generation des panneaux, obfuscation, index ReaPack.

    python3 packaging/tools/build.py --version 1.0.0

Tout est lu depuis StripTease/ + FXChains/ (jamais modifies) et packaging/src/, tout
est ecrit dans packaging/out/ :
    packaging/out/index.xml       <- a deposer a la racine du dossier publie
    packaging/out/v<version>/...  <- les fichiers obfusques, references par l'index

Rien n'est jamais ecrit hors du depot : la copie vers les dossiers REAPER est faite
a la main.

L'index est ecrit directement plutot que via `reapack-index` : ce dernier suppose
un depot git dont il derive les URL GitHub, alors que StripTease est servi depuis un
hebergement statique. Ecrire l'index nous donne aussi la main sur le nom de
categorie, dont depend le chemin d'installation (voir --category).

Chemins d'installation appliques par ReaPack :
    type="effect"  -> Effects/<nom index>/<categorie>/<fichier>
    type="script"  -> Scripts/<nom index>/<categorie>/<fichier>
    type="data"    -> Data/<fichier>            (aucun prefixe)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

import lite

TOOLS = Path(__file__).resolve().parent          # packaging/tools
PKG = TOOLS.parent                               # packaging
ROOT = PKG.parent                                # racine du depot
SRC = ROOT / "StripTease"                          # sources d'origine, jamais modifiees
PKG_SRC = PKG / "src"                            # sources ajoutees par le packaging
FXCHAINS = ROOT / "FXChains"

PANEL_HEIGHTS = [50, 100, 150, 200, 300, 400, 600]
PANEL_TEMPLATE = SRC / "StripTease Panel 100 px"
TEMPLATE_HEIGHT = 100

ENGINE = "striptease_panel.jsfx-inc"
GR_JSFX = "StripTease.jsfx"
SCRIPTS = [
    "StripTease System.lua",
    "StripTease Check.lua",
    "StripTease Install FX chains.lua",
]


# Fichiers livres tels quels, sans obfuscation ni en-tete reinjecte.
VERBATIM = ["LICENSE.txt"]


def script_source(name: str) -> Path:
    """Les scripts d'origine vivent dans StripTease/, ceux du packaging dans packaging/src/."""
    return SRC / name if (SRC / name).exists() else PKG_SRC / name

DEFAULT_CONFIG = {
    "index_name": "StripTease",
    "category": ".",
    "author": "Eric Avondo",
    "base_url": "https://example.invalid/r/CHANGE-ME",
    "website": "https://github.com/ericdevcire/StripTease",
    "donation": "https://ko-fi.com/ericire58504",
    "about": (
        "StripTease transforme n'importe quelle piste REAPER en tranche de console : "
        "boutons, interrupteurs et VU de gain reduction directement dans le mixer, "
        "pilotant vos vrais plugins."
    ),
    "license_notice": "Licence commerciale - redistribution interdite.",
}


# --------------------------------------------------------------------------
# Editions
# --------------------------------------------------------------------------
#
# Une seule source, deux livraisons. La Lite se distingue d'abord par ce qui
# n'est pas dans le paquet -- le JSFX de mesure, les FX chains, cinq des sept
# tailles -- et ensuite par les restrictions que lite.py retire du code lui-meme.
# Les noms de fichiers et le desc: sont identiques dans les deux editions :
# passer a la Pro est une copie de fichiers par-dessus, sans rien casser dans les
# projets existants.

EDITIONS = {
    "pro": {
        "panels": PANEL_HEIGHTS,
        "gr_jsfx": True,
        "scripts": SCRIPTS,
        "fxchains": True,
        "outdir": "out",
        "versions": "versions.json",
        "namemap": "namemap.json",
        "transform": False,
        "cfg": {},
    },
    "lite": {
        "panels": [150, 300],
        "gr_jsfx": False,
        "scripts": ["StripTease System.lua", "StripTease Check.lua"],
        "fxchains": False,
        "outdir": "out-lite",
        "versions": "versions-lite.json",
        "namemap": "namemap-lite.json",
        "transform": True,
        "cfg": {
            "about": (
                "StripTease Lite transforme n'importe quelle piste REAPER en tranche de "
                "console : boutons, interrupteurs et VU de gain reduction directement "
                "dans le mixer, pilotant vos vrais plugins.\n\n"
                "Version gratuite : 2 tailles de panneau, 16 elements, 1 metre et 2 "
                "pages d'onglets par panneau, Direct Link complet avec ses recettes -- "
                "les liens voyagent avec un preset, un template ou une FX chain. La "
                "selection multiple et le copier-coller d'elements, le Copy/Paste "
                "layout, les groupes de defilement, le JSFX de mesure de gain "
                "reduction et la bibliotheque de FX chains sont reserves a StripTease "
                "Pro."
            ),
            "license_notice": "StripTease Lite - gratuit, redistribution interdite.",
        },
    },
}


def panel_name(height: int) -> str:
    return f"StripTease Panel {height:03d} px"


# --------------------------------------------------------------------------
# 1. Generation des 7 panneaux depuis un gabarit unique
# --------------------------------------------------------------------------

def render_panel(template: str, height: int) -> str:
    old, new = panel_name(TEMPLATE_HEIGHT), panel_name(height)
    text = template.replace(old, new)
    text = re.sub(r"^@gfx(\s+\S+\s+)\d+\s*$", rf"@gfx\g<1>{height}", text, flags=re.M)
    return text


def generate_panels(outdir: Path, keep: list[int]) -> list[Path]:
    """Genere et verifie les 7 panneaux ; ne renvoie que ceux de l'edition.

    Le garde-fou de non-divergence porte toujours sur les 7, meme quand la
    livraison n'en emporte que deux : c'est le gabarit qu'il protege, pas le
    paquet.
    """
    template = PANEL_TEMPLATE.read_text(encoding="utf-8")
    outdir.mkdir(parents=True, exist_ok=True)
    written = []
    mismatches = []
    for h in PANEL_HEIGHTS:
        text = render_panel(template, h)
        existing = SRC / panel_name(h)
        if existing.exists() and existing.read_text(encoding="utf-8") != text:
            mismatches.append(panel_name(h))
        if h not in keep:
            continue
        path = outdir / panel_name(h)
        path.write_text(text, encoding="utf-8")
        written.append(path)
    if mismatches:
        raise SystemExit(
            "Le gabarit ne reproduit pas a l'identique : "
            + ", ".join(mismatches)
            + "\n(les panneaux ont diverge : reporter les differences dans "
            + str(PANEL_TEMPLATE) + " avant de builder)"
        )
    print(f"  7 panneaux verifies depuis {PANEL_TEMPLATE.name}, "
          f"{len(written)} retenu(s) pour cette edition")
    return written


# --------------------------------------------------------------------------
# 2. En-tete de copyright reinjecte apres obfuscation
# --------------------------------------------------------------------------

def jsfx_header(title: str, version: str, cfg: dict) -> str:
    return "\n".join([
        "// " + "=" * 74,
        f"// {title}",
        f"// Version: {version}",
        f"// Developer: {cfg['author']}",
        "//",
        f"// {cfg['license_notice']}",
        "// " + "=" * 74,
    ])


def lua_header(title: str, version: str, cfg: dict) -> str:
    return "\n".join([
        "-- " + "=" * 74,
        f"-- {title}",
        f"-- Version: {version}",
        f"-- Developer: {cfg['author']}",
        "--",
        f"-- {cfg['license_notice']}",
        "-- " + "=" * 74,
        "",
    ])


def inject_jsfx_header(text: str, header: str) -> str:
    """Insere le bloc de commentaires juste apres desc:/options:."""
    lines = text.splitlines()
    i = 0
    while i < len(lines) and re.match(r"^(desc|options|filename|tags|author)\s*:", lines[i]):
        i += 1
    return "\n".join(lines[:i] + header.splitlines() + lines[i:]) + "\n"


# --------------------------------------------------------------------------
# 3. FX chains : reecriture du chemin JSFX
# --------------------------------------------------------------------------

def install_prefix(cfg: dict) -> str:
    """Chemin des JSFX relatif a Effects/, tel que ReaPack les installera."""
    parts = [cfg["index_name"]]
    cat = cfg["category"].strip("/")
    if cat and cat != ".":
        parts.append(cat)
    return "/".join(parts)


def layout(cfg: dict) -> dict[str, str]:
    """Sous-dossiers de la livraison, calques sur la resource path de REAPER.

    Copier Effects/, Scripts/ et FXChains/ dans le dossier ressource de REAPER
    fusionne au bon endroit, sans avoir a savoir quel fichier va ou.
    """
    p = install_prefix(cfg)
    return {"effect": f"Effects/{p}", "script": f"Scripts/{p}", "data": "FXChains"}


JS_LINE_RE = re.compile(rb'<JS "([^"]*)"')


def rewrite_fxchains(outdir: Path, cfg: dict) -> list[Path]:
    outdir.mkdir(parents=True, exist_ok=True)
    prefix = install_prefix(cfg).encode("utf-8")
    written = []
    for path in sorted(FXCHAINS.glob("*.RfxChain")):
        data = path.read_bytes()

        def repl(m: re.Match) -> bytes:
            old = m.group(1)
            leaf = old.rsplit(b"/", 1)[-1]
            return b'<JS "' + prefix + b"/" + leaf + b'"'

        new, n = JS_LINE_RE.subn(repl, data)
        if n == 0:
            raise SystemExit(f"{path.name}: aucune reference <JS \"...\"> trouvee")
        out = outdir / path.name
        out.write_bytes(new)
        written.append(out)
    print(f"  {len(written)} FX chains repointees vers Effects/{install_prefix(cfg)}/")
    return written


# --------------------------------------------------------------------------
# 4. index.xml
# --------------------------------------------------------------------------

def rtf(text: str) -> str:
    """RTF minimal accepte par le panneau About de ReaPack."""
    body = "".join(
        f"{{\\pard \\ql \\f0 \\sa180 \\li0 \\fi0 {p.strip()}\\par}}\n"
        for p in text.split("\n\n") if p.strip()
    )
    return (
        "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 \\fswiss Helvetica;}}\n"
        "\\widowctrl\\hyphauto\n\n" + body + "}\n"
    )


def source_el(kind: str, filename: str, url: str, main: str | None = None) -> str:
    attrs = f'type="{kind}" '
    if main:
        attrs += f'main="{main}" '
    attrs += f"file={quoteattr(filename)}"
    return f"        <source {attrs}>{escape(url)}</source>"


def build_index(cfg: dict, versions: list[dict], ed: dict) -> str:
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<index version="1" name={quoteattr(cfg["index_name"])}>',
        f'  <category name={quoteattr(cfg["category"])}>',
        f'    <reapack name="StripTease" type="effect" desc="StripTease">',
        "      <metadata>",
        f"        <description><![CDATA[{rtf(cfg['about'])}]]></description>",
        f'        <link rel="website">{escape(cfg["website"])}</link>',
        f'        <link rel="donation">{escape(cfg["donation"])}</link>',
        "      </metadata>",
    ]

    dirs = layout(cfg)

    for v in versions:
        base = f"{cfg['base_url'].rstrip('/')}/v{v['version']}"

        def url(name: str, kind: str = "effect") -> str:
            sub = urllib.parse.quote(dirs[kind])
            return f"{base}/{sub}/{urllib.parse.quote(name)}"

        lines.append(
            f'      <version name={quoteattr(v["version"])} '
            f'author={quoteattr(cfg["author"])} time="{v["time"]}">'
        )
        if v.get("changelog"):
            lines.append(f"        <changelog><![CDATA[{v['changelog']}]]></changelog>")

        lines.append(source_el("effect", ENGINE, url(ENGINE)))
        if ed["gr_jsfx"]:
            lines.append(source_el("effect", GR_JSFX, url(GR_JSFX)))
        for h in ed["panels"]:
            n = panel_name(h)
            lines.append(source_el("effect", n, url(n)))
        for s in ed["scripts"]:
            lines.append(source_el("script", s, url(s, "script"), main="main"))
        for name in VERBATIM:
            lines.append(source_el("effect", name, url(name)))
        if ed["fxchains"]:
            for path in sorted(FXCHAINS.glob("*.RfxChain")):
                lines.append(source_el("data", f"StripTease/{path.name}", url(path.name, "data")))

        lines.append("      </version>")

    lines += ["    </reapack>", "  </category>", "</index>", ""]
    return "\n".join(lines)


# --------------------------------------------------------------------------

def run(cmd: list[str]) -> None:
    res = subprocess.run(cmd)
    if res.returncode != 0:
        raise SystemExit(f"echec: {' '.join(cmd)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True, help="ex. 1.0.0")
    ap.add_argument("--changelog", default="", help="texte du changelog de cette version")
    ap.add_argument("--edition", choices=sorted(EDITIONS), default="pro",
                    help="pro (defaut) ou lite : voir EDITIONS et lite.py")
    ap.add_argument("--outdir", type=Path, default=None,
                    help="defaut: packaging/out pour la Pro, packaging/out-lite pour la Lite")
    ap.add_argument("--config", type=Path, default=TOOLS / "build_config.json")
    ap.add_argument("--category", help="surcharge la categorie ReaPack (defaut: '.')")
    ap.add_argument("--index-name", help="surcharge le nom du depot (utile pour un build de test isole)")
    ap.add_argument("--base-url", help="surcharge l'URL de base de publication")
    ap.add_argument("--no-obfuscate", action="store_true", help="build en clair, pour deboguer")
    args = ap.parse_args()

    if not args.config.exists():
        args.config.write_text(json.dumps(DEFAULT_CONFIG, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Config par defaut ecrite dans {args.config} - a completer (base_url !).")
    ed = EDITIONS[args.edition]
    if args.outdir is None:
        args.outdir = PKG / ed["outdir"]

    cfg = {**DEFAULT_CONFIG, **json.loads(args.config.read_text(encoding="utf-8")), **ed["cfg"]}
    if args.category:
        cfg["category"] = args.category
    if args.base_url:
        cfg["base_url"] = args.base_url
    if args.index_name:
        cfg["index_name"] = args.index_name

    stage = args.outdir / "_stage"
    payload = args.outdir / f"v{args.version}"
    for d in (stage, payload):
        if d.exists():
            shutil.rmtree(d)
    payload.mkdir(parents=True)

    dirs = layout(cfg)
    d_fx    = payload / dirs["effect"]
    d_lua   = payload / dirs["script"]
    d_chain = payload / dirs["data"]
    for d in (d_fx, d_lua):
        d.mkdir(parents=True, exist_ok=True)
    if ed["fxchains"]:
        d_chain.mkdir(parents=True, exist_ok=True)

    print("1/7  Verification de la carte gmem")
    run([sys.executable, str(TOOLS / "check_gmem.py")])

    print("2/7  Generation des panneaux")
    panels = generate_panels(stage / "panels", ed["panels"])

    jsfx_inputs = [SRC / ENGINE] + ([SRC / GR_JSFX] if ed["gr_jsfx"] else []) + panels
    lua_inputs = [script_source(s) for s in ed["scripts"]]

    print(f"3/7  Edition ({args.edition})")
    if ed["transform"]:
        # Les sources ne sont jamais touchees : la transformation ecrit une copie
        # dans le stage, et c'est elle qui part a l'obfuscation.
        d_ed = stage / "edition"
        d_ed.mkdir(parents=True, exist_ok=True)
        rewritten = []
        for i, group in enumerate((jsfx_inputs, lua_inputs)):
            for j, p in enumerate(group):
                text = p.read_text(encoding="utf-8")
                new = lite.transform(p.name, text)
                if new == text:
                    continue
                out = d_ed / p.name
                out.write_text(new, encoding="utf-8")
                group[j] = out
                rewritten.append(p.name)
        missing = [f for f in lite.files_touched() if f not in rewritten]
        if missing:
            raise SystemExit(
                f"edition lite : aucun patch applique a {', '.join(missing)} "
                "(fichier absent de la livraison ?)"
            )
        print(f"  restrictions appliquees a : {', '.join(rewritten)}")
    else:
        print("  aucune restriction (edition complete)")

    print("4/7  Obfuscation JSFX")
    if args.no_obfuscate:
        for p in jsfx_inputs:
            shutil.copy2(p, d_fx / p.name)
    else:
        run([
            sys.executable, str(TOOLS / "jsfx_obf.py"),
            *[str(p) for p in jsfx_inputs],
            "--outdir", str(d_fx),
            "--namemap", str(TOOLS / ed["namemap"]),
        ])

    print("5/7  Obfuscation Lua")
    if args.no_obfuscate:
        for p in lua_inputs:
            shutil.copy2(p, d_lua / p.name)
    else:
        run([
            sys.executable, str(TOOLS / "lua_obf.py"),
            *[str(p) for p in lua_inputs],
            "--outdir", str(d_lua),
        ])

    print("6/7  En-tetes et FX chains")
    for p in jsfx_inputs:
        target = d_fx / p.name
        title = p.stem if p.suffix else p.name
        if p.name == ENGINE:
            title = "StripTease Panel engine"
        target.write_text(
            inject_jsfx_header(target.read_text(encoding="utf-8"),
                               jsfx_header(title, args.version, cfg)),
            encoding="utf-8",
        )
    for s in ed["scripts"]:
        target = d_lua / s
        target.write_text(
            lua_header(Path(s).stem, args.version, cfg) + target.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    for name in VERBATIM:
        shutil.copy2(PKG_SRC / name, d_fx / name)
    print(f"  {len(VERBATIM)} fichier(s) livre(s) tel quel : {', '.join(VERBATIM)}")

    if ed["fxchains"]:
        rewrite_fxchains(d_chain, cfg)
    else:
        print("  pas de FX chains dans cette edition")

    print("7/7  index.xml")
    history_path = TOOLS / ed["versions"]
    history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else []
    history = [v for v in history if v["version"] != args.version]
    history.append({
        "version": args.version,
        "time": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "changelog": args.changelog,
    })
    history.sort(key=lambda v: [int(x) for x in re.findall(r"\d+", v["version"])])
    history_path.write_text(json.dumps(history, indent=2, ensure_ascii=False), encoding="utf-8")

    (args.outdir / "index.xml").write_text(build_index(cfg, history, ed), encoding="utf-8")
    shutil.rmtree(stage, ignore_errors=True)

    n = sum(1 for _ in payload.rglob("*") if _.is_file())
    print(f"\nOK - edition {args.edition} - {n} fichiers dans {payload}")
    for kind, sub in dirs.items():
        d = payload / sub
        if d.exists():
            print(f"       {sub}/  ({len(list(d.iterdir()))} fichiers)")
    print(f"     index : {args.outdir / 'index.xml'}")
    print(f"     JSFX installes dans : Effects/{install_prefix(cfg)}/")
    print(f"     scripts dans        : Scripts/{install_prefix(cfg)}/")
    if ed["fxchains"]:
        print(f"     FX chains dans      : Data/StripTease/  (puis 'StripTease Install FX chains')")
    if "example.invalid" in cfg["base_url"]:
        print("\nATTENTION : base_url n'est pas configuree, l'index n'est pas publiable tel quel.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
