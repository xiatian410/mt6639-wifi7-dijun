#!/bin/sh
# Build the module's WebUI console into a new directory: the Kotlin/Wasm page
# (Compose Multiplatform with the Miuix components) and its font subsets.
# Nothing is installed. Pass the result to tools/build_hotspot_module.sh.
#
# Needs: JDK 21, Gradle 9.x (GRADLE=/path/to/gradle when it is not on PATH),
# network access to Maven Central and the npm registry on the first run,
# python3 with fontTools, and the Noto Sans CJK collections (Debian/Ubuntu
# package fonts-noto-cjk; override with MT6639_WEBUI_FONT_DIR and
# MT6639_WEBUI_FONT_NOTICE).
set -eu
[ "$#" = 1 ] || { echo 'usage: build_webui.sh OUTPUT_DIR' >&2; exit 64; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$1
GRADLE=${GRADLE:-gradle}
FONT_DIR=${MT6639_WEBUI_FONT_DIR:-/usr/share/fonts/opentype/noto}
FONT_NOTICE=${MT6639_WEBUI_FONT_NOTICE:-/usr/share/doc/fonts-noto-cjk/copyright}

[ ! -e "$OUT" ] || { echo 'REJECT output_exists' >&2; exit 73; }
command -v "$GRADLE" >/dev/null 2>&1 || {
    echo 'REJECT gradle_missing: set GRADLE=/path/to/gradle (Gradle 9.x)' >&2; exit 69; }
python3 -c 'import fontTools' 2>/dev/null || {
    echo 'REJECT fonttools_missing: python3 cannot import fontTools' >&2; exit 69; }

# The unit tests of the page logic run first; a failing test stops the build.
# MT6639_WEBUI_INCREMENTAL=1 skips the clean rebuild while developing.
if [ "${MT6639_WEBUI_INCREMENTAL:-0}" = 1 ]; then
    "$GRADLE" --no-daemon --console=plain -q -p "$ROOT/webui" jvmTest wasmJsBrowserDistribution
else
    "$GRADLE" --no-daemon --console=plain -q -p "$ROOT/webui" clean jvmTest wasmJsBrowserDistribution
fi
DIST=$ROOT/webui/build/dist/wasmJs/productionExecutable
for f in index.html console.js bridge.js; do
    [ -f "$DIST/$f" ] || { echo "REJECT webui_build_incomplete missing=$f" >&2; exit 70; }
done
ls "$DIST"/*.wasm >/dev/null 2>&1 || { echo 'REJECT webui_build_incomplete missing=wasm' >&2; exit 70; }

PARENT=$(dirname -- "$OUT")
mkdir -p "$PARENT"
PARENT=$(CDPATH= cd -- "$PARENT" && pwd)
OUT=$PARENT/$(basename -- "$OUT")
TMP=$(mktemp -d "$PARENT/.webui.XXXXXX")
trap 'rm -r "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/webroot"
# Everything the page loads at run time; source maps stay out of the module.
(
    cd "$DIST"
    find . -type f ! -name '*.map' -print | LC_ALL=C sort | while IFS= read -r f; do
        mkdir -p "$TMP/webroot/$(dirname -- "$f")"
        cp "$f" "$TMP/webroot/$f"
    done
)
python3 "$ROOT/tools/build_webui_fonts.py" --repo "$ROOT" --font-dir "$FONT_DIR" \
    --notice "$FONT_NOTICE" --out "$TMP/webroot/fonts" > "$TMP/fonts.txt"

if find "$TMP/webroot" -type l | grep -q .; then
    echo 'REJECT symlink_in_webroot' >&2
    exit 69
fi
if grep -R -n -E 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|(gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{24,}' \
    "$TMP/webroot" >/dev/null 2>&1; then
    echo 'REJECT credential_pattern_in_webroot' >&2
    exit 69
fi

version() { sed -n "s/^$1 = \"\\(.*\\)\"\$/\\1/p" "$ROOT/webui/gradle/libs.versions.toml" | head -1; }
dirty=0
[ -z "$(git -C "$ROOT" status --porcelain -- webui tools/build_webui.sh tools/build_webui_fonts.py 2>/dev/null)" ] || dirty=1
{
    echo "source_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "source_dirty=$dirty"
    echo "kotlin=$(version kotlin)"
    echo "compose_multiplatform=$(version compose-multiplatform)"
    echo "miuix=$(version miuix)"
    echo "gradle=$("$GRADLE" --version 2>/dev/null | sed -n 's/^Gradle \(.*\)$/\1/p' | head -1)"
    grep '^font_' "$TMP/fonts.txt"
} > "$TMP/webroot/WEBUI-PROVENANCE.txt"

find "$TMP/webroot" -type d -exec chmod 0755 {} +
find "$TMP/webroot" -type f -exec chmod 0644 {} +
mv "$TMP/webroot" "$OUT"
trap - EXIT HUP INT TERM
rm -r "$TMP"
echo "BUILT $OUT"
(cd "$OUT" && find . -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print "tree_sha256=" $1}')
