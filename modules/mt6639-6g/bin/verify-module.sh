#!/system/bin/sh
# module.prop is a presentation file: only description may differ from the
# checksummed build-time template. Never rewrite SHA256SUMS at runtime.
set -eu
MODDIR=${1:-/data/adb/modules/mt6639-6g}
. "$MODDIR/bin/owner.sh"
if [ "$MODULE_EMBEDDED" = 1 ]; then
    exec sh "$MODULE_OWNER/bin/verify-module.sh" "$MODULE_OWNER"
fi
cd "$MODDIR"
for file in module.prop module.prop.template SHA256SUMS; do
    [ -f "$file" ] && [ ! -L "$file" ] || exit 3
done
# Require the template to be part of the manifest, not merely present.
grep -Eq '^[0-9a-f]{64}  module\.prop\.template$' SHA256SUMS || exit 3
sha256sum -c SHA256SUMS >/dev/null 2>&1 || exit 3
for file in module.prop module.prop.template; do
    [ "$(grep -c '^description=' "$file")" = 1 ] || exit 3
done
live=$(sed '/^description=/d' module.prop | sha256sum)
base=$(sed '/^description=/d' module.prop.template | sha256sum)
[ "$live" = "$base" ]
