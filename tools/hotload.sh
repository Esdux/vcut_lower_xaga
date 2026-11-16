#!/system/bin/sh
# vcut_lower 热加载：所有参数从设备 config.sh 读取，绝不硬编码。
#
# 为什么要有这个脚本：
# 早期手工热加载时把 fv_target_mv 写死成 4530，而 App 里用户设的是 4535，
# 结果内核拿到 4530、App 显示 4535，用户以为"重新加载后 App 设置没生效"，
# 其实是热加载把它覆盖了。这个脚本的边界处理与 service.sh 完全一致。
#
# 用法（设备上）：
#   su -c "sh /data/local/tmp/hotload.sh [可选的 .ko 路径]"
#
# 警告：rmmod/insmod 会重置内核内存态，包括库仑积分的基准
#       （t_coul_state 归 0、t_coul_soc 归 -1）。正在放电验证时不要用。

M=/data/adb/modules/vcut_lower
CFG=/data/adb/vcut_lower/config.sh
KO=${1:-$M/vcut_lower.ko}

[ -f "$CFG" ] || { echo "缺 config: $CFG"; exit 1; }
[ -f "$KO" ] || { echo "缺 ko: $KO"; exit 1; }

# shellcheck disable=SC1090
. "$CFG"

# 与 service.sh 里同一套上限钳制逻辑：越界一律回落到 4475
FVT=0
if [ "$FAKE_FG_CYCLE" = "1" ]; then
  FVT=${FV_TARGET_MV:-4475}
  case "$FVT" in ''|*[!0-9]*) FVT=4475 ;; esac
  [ "$FVT" -ge 4400 ] 2>/dev/null && [ "$FVT" -le 4580 ] 2>/dev/null || FVT=4475
fi

echo "--- 即将加载（取自 $CFG）---"
echo "  enable=${ENABLE:-1} soc_ctl=${SOC_CTL:-1} coul_ctl=${COUL_CTL:-1} true_mah=${TRUE_MAH:-6000}"
echo "  vcut_delay=${VCUT_DELAY:-3200} fake_fg_cycle=${FAKE_FG_CYCLE:--1} fv_target_mv=$FVT"

rmmod vcut_lower 2>/dev/null
sleep 1
insmod "$KO" \
  enable="${ENABLE:-1}" \
  vcut_fw="${VCUT_FW:-3200}" vcut_delay="${VCUT_DELAY:-3200}" vcut_sw="${VCUT_SW:-3100}" \
  kill_vpack_gate="${KILL_VPACK_GATE:-0}" \
  soc_ctl="${SOC_CTL:-1}" fake_cycle="${FAKE_CYCLE:--1}" fake_fg_cycle="${FAKE_FG_CYCLE:-1}" \
  fcc_mah="${FCC_MAH:-0}" qbot_mah="${QBOT_MAH:-0}" rint_mohm="${RINT_MOHM:-28}" \
  true_mah="${TRUE_MAH:-6000}" coul_ctl="${COUL_CTL:-1}" \
  fv_target_mv="$FVT" fv_max_mv=4580 force_ma=0 verbose="${VERBOSE:-0}"
echo "insmod rc=$?"
sleep 2

MP=/sys/module/vcut_lower/parameters
echo "--- 加载后实值 ---"
for p in fv_target_mv fake_fg_cycle soc_ctl coul_ctl true_mah t_coul_state t_coul_soc; do
  [ -f "$MP/$p" ] && echo "  $p = $(cat "$MP/$p")"
done