#!/system/bin/sh
# xaga 诊断包：/sdcard/Download/vcut_diag_xaga_<时间>.tar.gz
DATA=/data/adb/vcut_lower
OUTDIR=/sdcard/Download
TMP=/data/local/tmp/vcut_diag.$$
mkdir -p "$TMP" "$OUTDIR"

{
  echo "device=$(getprop ro.product.device)"
  echo "model=$(getprop ro.product.model)"
  echo "build=$(getprop ro.build.display.id)"
  echo "incremental=$(getprop ro.build.version.incremental)"
  echo "kernel=$(uname -a)"
  echo "boot_completed=$(getprop sys.boot_completed)"
} > "$TMP/device.txt"

cp "$DATA/config.sh" "$TMP/config.sh" 2>/dev/null
cp "$DATA/boot.log" "$TMP/boot.log" 2>/dev/null
cp "$DATA/turbo.log" "$TMP/turbo.log" 2>/dev/null
cp /sys/module/vcut_lower/parameters/* "$TMP/" 2>/dev/null

{
  echo "== battery =="
  for f in capacity voltage_now current_now temp status health cycle_count; do
    [ -f "/sys/class/power_supply/battery/$f" ] && echo "$f=$(cat /sys/class/power_supply/battery/$f)"
  done
  echo "== bms =="
  for f in capacity capacity_raw voltage_now current_now temp cycle_count fcc rm soh charge_full charge_done; do
    [ -f "/sys/class/power_supply/bms/$f" ] && echo "$f=$(cat /sys/class/power_supply/bms/$f)"
  done
  echo "== votables =="
  cat /sys/kernel/debug/pmic-votable/CHARGER_FV/status 2>/dev/null
  cat /sys/kernel/debug/pmic-votable/CHARGER_FCC/status 2>/dev/null
} > "$TMP/power.txt"

{
  echo "== vcut dmesg =="
  dmesg 2>/dev/null | grep -E 'vcut_lower|xaga_chg' | tail -200
  echo "== thermal =="
  for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat "$z/type" 2>/dev/null)
    case "$t" in *charger*|*batt*|*conn*) echo "$t $(cat "$z/temp" 2>/dev/null)";; esac
  done
  echo "== thermal_remove =="
  cat /sys/class/power_supply/usb/thermal_remove 2>/dev/null
} > "$TMP/kernel.txt"

TS=$(date +%Y%m%d_%H%M%S)
tar -czf "$OUTDIR/vcut_diag_xaga_$TS.tar.gz" -C "$TMP" . 2>/dev/null
rm -rf "$TMP"
echo "$OUTDIR/vcut_diag_xaga_$TS.tar.gz"
