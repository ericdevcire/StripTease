#!/usr/bin/env python3
"""Community presets: validation, catalog and ReaPack package.

    python3 .github/scripts/community.py validate              # every file in Community/
    python3 .github/scripts/community.py validate --diff HEAD^1 # only what a PR changes
    python3 .github/scripts/community.py catalog [--check]      # Community/README.md
    python3 .github/scripts/community.py publish                # catalog + index.xml

A preset is one flat file:  Community/<Plugin> - <Author>.RfxChain
"<Plugin>" is the plugin the panel drives, or "Panel only" for a chain holding
no third-party plugin.

publish is idempotent: when no preset changed, it only re-inserts the community
package into index.xml -- which a release overwrites with a hand-written copy.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parents[2]
COMMUNITY = ROOT / "Community"
CATALOG = COMMUNITY / "README.md"
INDEX = ROOT / "index.xml"
HISTORY = ROOT / ".github" / "community-versions.json"

BASE_URL = "https://raw.githubusercontent.com/ericdevcire/StripTease/main/Community"
WEBSITE = "https://github.com/ericdevcire/StripTease/tree/main/Community"
PACKAGE = "StripTease Community Presets"
INSTALL_DIR = "StripTease/Community"       # under Data/, see Install FX chains.lua
KEPT_VERSIONS = 10                          # older entries stay in the history file only

EXT = ".RfxChain"
PANEL_ONLY = "panel only"
MAX_BYTES = 1_000_000
MAX_NAME = 150
HEIGHTS = ("050", "100", "150", "200", "300", "400", "600")
FORBIDDEN_CHARS = set('<>:"/\\|?*')

PANEL_RE = re.compile(r"^StripTease/StripTease Panel (\d{3}) px$")
OWN_JS = {"StripTease/StripTease.jsfx"}
FX_RE = re.compile(r'^\s*<(VST|AU|CLAP|LV2|DX|JS|VIDEO_EFFECT)\s+("([^"]*)"|(\S+))')
ABS_PATH_RE = re.compile(r'(?:\b[A-Za-z]:\\|/Users/|/home/|/Volumes/)')


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

def split_name(name: str) -> tuple[str, str] | None:
    if not name.endswith(EXT):
        return None
    parts = name[: -len(EXT)].split(" - ")
    if len(parts) != 2 or any(not p or p != p.strip() for p in parts):
        return None
    return parts[0], parts[1]


def inspect(data: bytes) -> dict:
    """Panels and third-party plugins found in a chain, plus structural errors."""
    text = data.decode("utf-8", errors="replace")
    panels, plugins, errors = [], [], []
    depth = 0
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith("<"):
            depth += 1
        elif s == ">":
            depth -= 1
            if depth < 0:
                errors.append(f"line {n}: unbalanced '>'")
                depth = 0
        m = FX_RE.match(line)
        if not m:
            continue
        kind, arg = m.group(1), m.group(3) if m.group(3) is not None else m.group(4)
        if kind == "JS":
            p = PANEL_RE.match(arg)
            if p and p.group(1) in HEIGHTS:
                panels.append(int(p.group(1)))
                continue
            if arg in OWN_JS:
                continue
            if "StripTease Panel" in arg or arg.startswith("StripTease"):
                errors.append(
                    f'line {n}: panel path "{arg}" -- it must read '
                    '"StripTease/StripTease Panel NNN px" to load on a ReaPack install')
                continue
        plugins.append(arg)
    if depth != 0:
        errors.append("truncated chain: '<' and '>' blocks do not balance")
    if ABS_PATH_RE.search(text):
        errors.append("contains an absolute path (a file on your disk): remove it")
    return {"panels": panels, "plugins": plugins, "errors": errors}


def check_file(path: Path, siblings: list[str]) -> list[str]:
    name = path.name
    errors = []
    if path.parent != COMMUNITY:
        return ["presets go directly in Community/, without sub-folder"]
    if not name.endswith(EXT):
        return [f"only {EXT} files are accepted in Community/"]
    parts = split_name(name)
    if parts is None:
        errors.append(f'name must be "<Plugin> - <Author>{EXT}" '
                      '(exactly one " - " separator)')
    if len(name) > MAX_NAME:
        errors.append(f"name longer than {MAX_NAME} characters")
    bad = sorted(c for c in set(name) if c in FORBIDDEN_CHARS or ord(c) < 32)
    if bad:
        errors.append("name contains forbidden characters: " + " ".join(repr(c) for c in bad))
    clash = [s for s in siblings if s != name and s.lower() == name.lower()]
    if clash:
        errors.append(f'same name as "{clash[0]}" apart from letter case')

    data = path.read_bytes()
    if not data.strip():
        return errors + ["file is empty"]
    if len(data) > MAX_BYTES:
        errors.append(f"file is {len(data) // 1024} KB, the limit is {MAX_BYTES // 1000} KB")
    info = inspect(data)
    errors += info["errors"]
    if not info["panels"]:
        errors.append('no StripTease panel found (<JS "StripTease/StripTease Panel NNN px">)')
    if parts is not None:
        if parts[0].lower() == PANEL_ONLY:
            if info["plugins"]:
                errors.append('"Panel only" preset contains a plugin: '
                              + ", ".join(info["plugins"]))
        elif not info["plugins"]:
            errors.append('no plugin in the chain: name it "Panel only - <Author>"')
    return errors


def presets() -> list[Path]:
    return sorted(COMMUNITY.glob("*" + EXT), key=lambda p: p.name.lower())


# --------------------------------------------------------------------------
# validate
# --------------------------------------------------------------------------

def changed_files(base: str) -> list[tuple[str, str]]:
    out = subprocess.run(
        ["git", "diff", "--name-status", "--no-renames", "-z", base, "HEAD"],
        cwd=ROOT, check=True, capture_output=True).stdout.decode("utf-8")
    f = out.split("\0")
    return [(f[i], f[i + 1]) for i in range(0, len(f) - 1, 2)]


def annotate(path: str, msg: str) -> None:
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error file={path}::{msg}")
    else:
        print(f"  {path}: {msg}")


def cmd_validate(args) -> int:
    siblings = [p.name for p in COMMUNITY.iterdir()] if COMMUNITY.exists() else []
    problems: dict[str, list[str]] = {}

    if args.diff:
        targets = []
        for status, rel in changed_files(args.diff):
            if not rel.startswith("Community/"):
                problems.setdefault(rel, []).append(
                    "this pull request also changes files outside Community/: "
                    "submit presets in a pull request of their own")
            elif rel == "Community/README.md":
                problems.setdefault(rel, []).append(
                    "Community/README.md is generated after the merge: do not edit it")
            elif status == "D":
                problems.setdefault(rel, []).append(
                    "removing a preset is done by the maintainer: open an issue instead")
            else:
                targets.append(ROOT / rel)
    else:
        targets = presets()
        for p in sorted(COMMUNITY.iterdir()) if COMMUNITY.exists() else []:
            if p.name != "README.md" and p.suffix != EXT and not p.name.startswith("."):
                problems.setdefault(p.relative_to(ROOT).as_posix(), []).append(
                    f"only {EXT} files are accepted in Community/")

    rows = []
    for path in targets:
        rel = path.relative_to(ROOT).as_posix()
        errs = check_file(path, siblings)
        if errs:
            problems.setdefault(rel, []).extend(errs)
        info = inspect(path.read_bytes()) if path.suffix == EXT else None
        rows.append((path.name, info, not errs))

    for rel, errs in problems.items():
        for e in errs:
            annotate(rel, e)

    summary = ["## StripTease community presets", "",
               "| File | Panel | Plugins | Result |", "| --- | --- | --- | --- |"]
    for name, info, ok in rows:
        panels = ", ".join(f"{h} px" for h in info["panels"]) if info else "-"
        plugins = ", ".join(info["plugins"]) if info and info["plugins"] else "-"
        summary.append(f"| {name} | {panels} | {plugins} | {'OK' if ok else 'FAILED'} |")
    if problems:
        summary += ["", "Errors are listed in the Annotations of this check. "
                    "See CONTRIBUTING.md for the rules."]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write("\n".join(summary) + "\n")

    n = sum(len(e) for e in problems.values())
    print(f"{len(targets)} preset(s) checked, {n} error(s)")
    return 1 if n else 0


# --------------------------------------------------------------------------
# catalog
# --------------------------------------------------------------------------

def render_catalog() -> str:
    lines = [
        "# StripTease Community Presets",
        "",
        "FX chains shared by StripTease users: a StripTease panel already mapped to its plugin "
        "(load it, and the Direct Links rebuild themselves), or a *Panel only* layout.",
        "",
        "**Install:** in ReaPack, install the **StripTease Community Presets** package, then run "
        "the *StripTease Install FX chains* action -- the same one that installs the StripTease "
        "presets; it handles both. The community chains appear in the FX browser, under "
        "*FX Chains > StripTease Community*.",
        "",
        "**Share yours:** see [CONTRIBUTING.md](../CONTRIBUTING.md).",
        "",
        "You need the plugin named in the first column; *Panel only* presets need nothing else.",
        "",
    ]
    files = presets()
    if not files:
        return "\n".join(lines + ["*No preset yet -- be the first!*", ""])
    lines += ["| Plugin | Author | Panel |", "| --- | --- | --- |"]
    for p in files:
        parts = split_name(p.name)
        if parts is None:
            continue
        info = inspect(p.read_bytes())
        link = "./" + urllib.parse.quote(p.name)
        panels = ", ".join(f"{h} px" for h in info["panels"])
        lines.append(f"| [{parts[0]}]({link}) | {parts[1]} | {panels} |")
    return "\n".join(lines + [""])


def cmd_catalog(args) -> int:
    text = render_catalog()
    current = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else ""
    if args.check:
        if current != text:
            print("Community/README.md is out of date: run  community.py catalog")
            return 1
        return 0
    if current != text:
        COMMUNITY.mkdir(exist_ok=True)
        CATALOG.write_text(text, encoding="utf-8")
        print("Community/README.md updated")
    return 0


# --------------------------------------------------------------------------
# publish : ReaPack package spliced into index.xml
# --------------------------------------------------------------------------

def rtf(text: str) -> str:
    body = "".join(f"{{\\pard \\ql \\f0 \\sa180 \\li0 \\fi0 {p.strip()}\\par}}\n"
                   for p in text.split("\n\n") if p.strip())
    return ("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 \\fswiss Helvetica;}}\n"
            "\\widowctrl\\hyphauto\n\n" + body + "}\n")


ABOUT = (
    "FX chains shared by StripTease users: a StripTease panel already mapped to its plugin "
    "(Direct Links rebuilt on load), or a Panel only layout.\n\n"
    "After installing or updating this package, run the action 'StripTease Install FX chains', "
    "provided by the StripTease package: it installs both the StripTease and the community "
    "chains, the latter in FXChains/StripTease Community/.\n\n"
    "Each preset needs the plugin named at the start of its file name (Panel only presets need "
    "none), and the StripTease package. Share yours: see CONTRIBUTING.md on the StripTease "
    "GitHub page."
)


def next_version(history: list[dict]) -> str:
    if not history:
        return "1.0"
    major, minor = history[-1]["version"].split(".")
    return f"{major}.{int(minor) + 1}"


def describe(old: dict, new: dict) -> str:
    def label(name: str) -> str:
        parts = split_name(name)
        if parts is None:
            return name
        target = "Panel only" if parts[0].lower() == PANEL_ONLY else parts[0]
        return f"{target} by {parts[1]}"
    added = [label(n) for n in new if n not in old]
    updated = [label(n) for n in new if n in old and new[n] != old[n]]
    removed = [label(n) for n in old if n not in new]
    out = []
    for title, items in (("Added", added), ("Updated", updated), ("Removed", removed)):
        if items:
            out.append(f"{title}: " + "; ".join(items) + ".")
    return " ".join(out)


def package_xml(history: list[dict]) -> str:
    lines = [
        f"    <reapack name={quoteattr(PACKAGE)} type=\"data\" desc={quoteattr(PACKAGE)}>",
        "      <metadata>",
        f"        <description><![CDATA[{rtf(ABOUT)}]]></description>",
        f'        <link rel="website">{escape(WEBSITE)}</link>',
        "      </metadata>",
    ]
    for v in history[-KEPT_VERSIONS:]:
        lines.append(f'      <version name={quoteattr(v["version"])} '
                     f'author="StripTease community" time="{v["time"]}">')
        if v.get("changelog"):
            lines.append(f"        <changelog><![CDATA[{v['changelog']}]]></changelog>")
        for name in sorted(v["files"], key=str.lower):
            url = f"{BASE_URL}/{urllib.parse.quote(name)}"
            lines.append(f'        <source type="data" file={quoteattr(INSTALL_DIR + "/" + name)}>'
                         f"{escape(url)}</source>")
        lines.append("      </version>")
    lines.append("    </reapack>")
    return "\n".join(lines) + "\n"


BLOCK_RE = re.compile(r"    <reapack name=" + re.escape(quoteattr(PACKAGE)) + r".*?</reapack>\n",
                      re.S)


def cmd_publish(args) -> int:
    bad = {p.name: check_file(p, [q.name for q in COMMUNITY.iterdir()]) for p in presets()}
    bad = {k: v for k, v in bad.items() if v}
    if bad:
        for name, errs in bad.items():
            for e in errs:
                annotate(f"Community/{name}", e)
        print("publish aborted: fix the presets above first")
        return 1

    cmd_catalog(argparse.Namespace(check=False))

    history = json.loads(HISTORY.read_text(encoding="utf-8")) if HISTORY.exists() else []
    files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in presets()}
    old = history[-1]["files"] if history else {}
    if files != old:
        history.append({
            "version": next_version(history),
            "time": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "changelog": describe(old, files),
            "files": files,
        })
        HISTORY.write_text(json.dumps(history, indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8")
        print(f"{PACKAGE} {history[-1]['version']}: {history[-1]['changelog']}")

    index = INDEX.read_text(encoding="utf-8")
    new = BLOCK_RE.sub("", index)
    if history and history[-1]["files"]:
        if "  </category>" not in new:
            raise SystemExit("index.xml: no </category> to insert the package before")
        head, sep, tail = new.rpartition("  </category>")
        new = head + package_xml(history) + sep + tail
    if new != index:
        INDEX.write_text(new, encoding="utf-8")
        print("index.xml updated")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate", help="check the presets")
    v.add_argument("--diff", metavar="REF",
                   help="only check what changed between REF and HEAD (pull request mode)")
    c = sub.add_parser("catalog", help="regenerate Community/README.md")
    c.add_argument("--check", action="store_true", help="fail if it is out of date")
    sub.add_parser("publish", help="catalog + ReaPack package in index.xml")
    args = ap.parse_args()
    return {"validate": cmd_validate, "catalog": cmd_catalog, "publish": cmd_publish}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
