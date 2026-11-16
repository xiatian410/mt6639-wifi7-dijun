#!/usr/bin/env python3
"""Subset Noto Sans CJK SC for the MT6639 console.

The console draws on a canvas and has neither system fonts nor a CJK font of
its own, and a root console must not fetch one from the network. This writes
three small OpenType files next to the built page:

  ui-400.otf  everything the page can show: ASCII, CJK punctuation, the 3755
              level-1 GB2312 characters, and every character that occurs in
              the page sources or in the two modules' scripts (whose messages
              and status card the page displays verbatim)
  ui-500.otf  the same without the GB2312 set: titles, buttons and labels
  ui-700.otf  as ui-500.otf

Requires fontTools. The source fonts are the distribution's Noto Sans CJK
collections (Debian/Ubuntu package fonts-noto-cjk); their notice is copied
beside the subsets, as the SIL Open Font License requires.
"""
import argparse
import hashlib
import sys
from pathlib import Path

try:
    from fontTools import subset
    from fontTools.ttLib import TTCollection
except ImportError:  # pragma: no cover - environment problem, reported plainly
    sys.exit("build_webui_fonts.py: fontTools is not importable (pip install fonttools)")

FAMILY = "Noto Sans CJK SC"
WEIGHTS = {400: "NotoSansCJK-Regular.ttc", 500: "NotoSansCJK-Medium.ttc", 700: "NotoSansCJK-Bold.ttc"}
PAGE_SOURCES = ("webui/src/commonMain", "webui/src/wasmJsMain")
SCRIPT_SOURCES = ("modules/mt6639-6g", "modules/mt6639-hotspot")
SCRIPT_FILES = ("tools/softap_native_once.sh", "tools/softap_native_config.sh",
                "tools/softap_once.sh", "tools/softap_profile.sh", "tools/twt_recover.sh")
TEXT_SUFFIXES = {".kt", ".html", ".js", ".sh", ".conf", ".prop"}


def characters(paths):
    found = set()
    for path in paths:
        for ch in path.read_text(encoding="utf-8"):
            if ch >= " " and ch != "\x7f" and ch not in "  ":
                found.add(ch)
    return found


def text_files(root, relative):
    base = root / relative
    if base.is_file():
        return [base]
    return sorted(p for p in base.rglob("*") if p.is_file() and p.suffix in TEXT_SUFFIXES)


def gb2312_level1():
    chars = set()
    for high in range(0xB0, 0xD8):
        for low in range(0xA1, 0xFF):
            try:
                chars.add(bytes((high, low)).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return chars


def base_characters():
    chars = {chr(c) for c in range(0x20, 0x7F)}
    chars |= {chr(c) for c in range(0x3000, 0x3040)}   # CJK symbols and punctuation
    chars |= {chr(c) for c in range(0xFF01, 0xFF61)}   # full-width forms
    chars |= set("·—–…‘’“”•°×→←↑↓￥")
    return chars


def face(collection_path):
    collection = TTCollection(str(collection_path), lazy=True)
    for font in collection.fonts:
        names = font["name"]
        # Weights outside regular/bold carry the family in the typographic name.
        if FAMILY in (names.getDebugName(16), names.getDebugName(1)):
            return font
    sys.exit(f"build_webui_fonts.py: {collection_path} has no face named {FAMILY!r}")


def write_subset(collection_path, wanted, out_path):
    font = face(collection_path)
    cmap = font.getBestCmap()
    present = {ch for ch in wanted if ord(ch) in cmap}
    options = subset.Options()
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    options.notdef_outline = True
    options.drop_tables += ["DSIG", "vhea", "vmtx", "VORG"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=sorted(ord(ch) for ch in present))
    subsetter.subset(font)
    font.recalcTimestamp = False            # same input, same bytes
    font.save(str(out_path))
    return present


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--font-dir", type=Path, required=True)
    parser.add_argument("--notice", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    page = characters(p for rel in PAGE_SOURCES for p in text_files(args.repo, rel))
    scripts = characters(p for rel in SCRIPT_SOURCES + SCRIPT_FILES for p in text_files(args.repo, rel))
    base = base_characters()
    sets = {
        400: base | page | scripts | gb2312_level1(),
        500: base | page | scripts,
        700: base | page | scripts,
    }
    for weight, name in WEIGHTS.items():
        if not (args.font_dir / name).is_file():
            sys.exit(f"build_webui_fonts.py: missing source font {args.font_dir / name}")
    if not args.notice.is_file():
        sys.exit(f"build_webui_fonts.py: missing font notice {args.notice}")
    args.out.mkdir(parents=True, exist_ok=True)

    lines = []
    for weight, name in WEIGHTS.items():
        source = args.font_dir / name
        out = args.out / f"ui-{weight}.otf"
        present = write_subset(source, sets[weight], out)
        # Text written for the page must be drawable in every weight it uses.
        missing = sorted(page - present)
        if missing:
            listed = " ".join(f"U+{ord(ch):04X}" for ch in missing)
            sys.exit(f"build_webui_fonts.py: {name} lacks characters used by the page: {listed}")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        lines.append(f"font_{weight}_source={name} sha256={digest} glyphs_for={len(present)}")
        print(f"{out.name}: {len(present)} characters, {out.stat().st_size} bytes")

    notice = (
        "The files ui-400.otf, ui-500.otf and ui-700.otf in this directory are subsets of\n"
        f"{FAMILY} made with fontTools by tools/build_webui_fonts.py. They are\n"
        "Modified Versions under the SIL Open Font License 1.1 and are distributed under\n"
        "that same license. The notice of the unmodified fonts follows.\n\n"
        + "=" * 72 + "\n\n" + args.notice.read_text(encoding="utf-8")
    )
    (args.out / "NOTICE.txt").write_text(notice, encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
