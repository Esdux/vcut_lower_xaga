#!/system/bin/sh
MP=/sys/module/vcut_lower/parameters
B=/sys/class/power_supply/battery
BMS=/sys/class/power_supply/bms
DATA=/data/adb/vcut_lower
[ -f "$DATA/config.sh" ] && . "$DATA/config.sh"

echo "=========== VCut Lower xaga ==========="
if lsmod | grep -q '^vcut_lower'; then
  echo "模块: 已加载"
  printf "  armed=%s enable=%s soc_ctl=%s\n" "$(cat $MP/armed)" "$(cat $MP/enable)" "$(cat $MP/soc_ctl)"
  printf "  关机电压 fw/delay/sw = %s/%s/%s mV\n" "$(cat $MP/vcut_fw)" "$(cat $MP/vcut_delay)" "$(cat $MP/vcut_sw)"
  printf "  真实电量=%s%%  显示=%s%%  raw=%s  FCC=%smAh\n" \
    "$(( $(cat $MP/t_soc_real 2>/dev/null || echo 0) ))" "$(( $(cat $MP/t_disp 2>/dev/null || echo 0) / 100 ))" \
    "$(cat $MP/t_raw_soc 2>/dev/null)" "$(cat $MP/t_fcc 2>/dev/null)"
  printf "  电压=%smV 电流=%sµA 温度=%s(0.1C) 循环=%s\n" \
    "$(cat $MP/t_vpack)" "$(cat $MP/t_current)" "$(cat $MP/t_temp)" "$(cat $MP/t_cycle)"
  printf "  kprobe 命中=%s  force_ma=%s  failsafe=%s\n" \
    "$(cat $MP/t_hits)" "$(cat $MP/force_ma)" "$(cat $MP/t_failsafe)"
else
  echo "模块: ★未加载"
  tail -8 "$DATA/boot.log" 2>/dev/null | sed 's/^/    /'
fi

echo
echo "--- 系统侧 ---"
printf "  battery=%s%%  bms=%s%%  status=%s\n" "$(cat $B/capacity)" "$(cat $BMS/capacity)" "$(cat $B/status)"
printf "  vbat=%smV  ibat=%sµA  cycle=%s\n" "$(( $(cat $B/voltage_now) / 1000 ))" "$(cat $B/current_now)" "$(cat $BMS/cycle_count)"
printf "  thermal_remove=%s  force_active=%s  force_val=%s\n" \
  "$(cat /sys/class/power_supply/usb/thermal_remove 2>/dev/null)" \
  "$(cat /sys/kernel/debug/pmic-votable/CHARGER_FCC/force_active 2>/dev/null)" \
  "$(cat /sys/kernel/debug/pmic-votable/CHARGER_FCC/force_val 2>/dev/null)"
echo "  bootfail=$(cat $DATA/bootfail 2>/dev/null)"
echo
echo "音量上：临时卸载 vcut_lower（rmmod，重启后恢复）"
key="$(timeout 5 getevent -qlc 1 2>/dev/null | awk '/KEY_VOLUMEUP.*UP/ {print $3; exit}')"
case "$key" in
  KEY_VOLUMEUP) rmmod vcut_lower && echo "已卸载" || echo "卸载失败" ;;
  *) echo "未选择操作" ;;
esac
