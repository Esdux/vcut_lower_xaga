#!/system/bin/sh
# 卸载：先撤回热限流/强制电流，再卸载 ko
[ -w /sys/class/power_supply/usb/thermal_remove ] && echo 0 > /sys/class/power_supply/usb/thermal_remove
[ -w /sys/module/vcut_lower/parameters/force_ma ] && echo 0 > /sys/module/vcut_lower/parameters/force_ma
pkill -f vcut_turbo.sh 2>/dev/null
rmmod vcut_lower 2>/dev/null
rm -rf /data/adb/vcut_lower
# 恢复旧 xaga 模块，便于继续使用原 App
rm -f /data/adb/modules/xaga_charge/disable
exit 0
