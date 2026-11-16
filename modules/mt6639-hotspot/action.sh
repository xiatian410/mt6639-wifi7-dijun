#!/system/bin/sh
MODDIR=${0%/*}
# One press for both layers: 6GHz registration and the 6GHz hotspot.
exec sh "$MODDIR/bin/radio-control.sh" "$MODDIR" toggle
