#!/system/bin/sh
#
# VCut Lower xaga backend - boot loader
#
# 只支持 xaga / xagapro + 5.10。内核模块保留 vcut APK 需要的参数 ABI，
# 内部全部走 pmic-votable + bq28z610。
#
MODDIR=${0%/*}
DATA=/data/adb/vcut_lower
LOG=$DATA/boot.log
GUARD=$DATA/bootfail
CFG=$DATA/config.sh
MP=/sys/module/vcut_lower/parameters

MAX_FAIL=2
STABLE_SEC=120

mkdir -p "$DATA"
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && : > "$LOG"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

LOCK=/dev/vcut_lower.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  log "已有加载流程在运行，本次跳过"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---------- 开机失败归因 ----------
# 只统计 pstore 中明确带 vcut/xaga 的内核崩溃；system_server/LSPosed 用户态
# 崩溃不计入，避免 HyperOS 4 上把模块误停用。
classify_prev_boot() {
  P=/sys/fs/pstore/console-ramoops-0
  [ -r "$P" ] || return 2
  if grep -qE 'Kernel panic|Unable to handle kernel|Internal error: Oops|BUG: unable to handle' "$P" &&
     grep -qE 'vcut_lower|xaga_chg|xaga_charge' "$P"; then
    return 0
  fi
  if grep -qE 'system_server|SIGABRT|implicit suspend|Fatal signal' "$P"; then
    return 1
  fi
  return 2
}

n=$(cat "$GUARD" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
classify_prev_boot
case $? in
  0)
    n=$((n + 1))
    log "上次为带 vcut/xaga 的内核异常，失败计数 $n/$MAX_FAIL"
    if [ "$n" -ge "$MAX_FAIL" ]; then
      log "★连续 $n 次内核异常，自动停用（删除 $MODDIR/disable 并清空 $GUARD 可恢复）"
      echo "$n" > "$GUARD"
      touch "$MODDIR/disable"
      exit 0
    fi
    echo "$n" > "$GUARD"
    ;;
  1)
    [ "$n" -ne 0 ] && log "上次为用户态 system_server 崩溃，不计入（原计数 $n 清零）"
    echo 0 > "$GUARD"
    ;;
  *)
    log "上次无内核崩溃证据，不计入（保留计数 $n）"
    ;;
esac

# ---------- 默认参数 ----------
ENABLE=1
VCUT_FW=3000
VCUT_DELAY=3000
VCUT_SW=2900
PC_GUARD=1
KILL_VPACK_GATE=1
SOC_CTL=1
FAKE_CYCLE=-1
FAKE_FG_CYCLE=-1
FCC_MAH=0
QBOT_MAH=0
RINT_MOHM=28
ENABLE_THERMAL_REMOVE=0
ENABLE_FORCE=0
FORCE_MA=18000
MAX_SOC=80
MAX_VBAT=4460
MAX_BTEMP=420
MAX_CTHERM=70000
MAX_CONN=45000
HYST_SOC=3
HYST_VBAT=80
HYST_BTEMP=30
HYST_CTHERM=4000
HYST_CONN=3000
LADDER_V=4080,4120,4250
LADDER_MA=18000,18000,15930,12360
VERBOSE=1

[ -f "$CFG" ] && . "$CFG"

# ---------- PowerSave 30 秒护栏：把阈值发布给 LSPosed hook ----------
# hook 跑在 com.miui.securitycenter（system_app），SELinux 禁止它读 sysfs 与
# /data/adb，旧版因此全程没生效。阈值/开关改由 Settings.Global 传递：
# root 写、system_app 读，下一次 BATTERY_CHANGED 即生效，不用重启也不用热重载。
# PC_GUARD: 1 = 只在电压 <= VCUT_DELAY 时放行 30 秒关机；0 = 完全屏蔽。
case "$PC_GUARD" in 0|1) ;; *) PC_GUARD=1 ;; esac
echo "$PC_GUARD" > "$DATA/pc_guard"
chmod 0644 "$DATA/pc_guard" 2>/dev/null   # 兼容旧 hook 与采样脚本

publish_guard() {
  settings put global vcut_delay_mv "$VCUT_DELAY" >/dev/null 2>&1
  settings put global vcut_guard_enabled 1 >/dev/null 2>&1
  settings put global vcut_pc_guard "$PC_GUARD" >/dev/null 2>&1
}
# service.sh 常早于 SettingsProvider 启动，开机完成后在后台补写一次
(
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
  done
  publish_guard
  log "PowerSave guard published: delay=$VCUT_DELAY pc_guard=$PC_GUARD"
) </dev/null >/dev/null 2>&1 &

# ---------- 等电量计就绪，尽早加载 ----------
i=0
while [ ! -e /sys/class/power_supply/bms ] && [ "$i" -lt 30 ]; do
  sleep 1
  i=$((i + 1))
done
sleep 1

log "MODE=xaga device=$(getprop ro.product.device) build=$(getprop ro.build.version.incremental) kernel=$(uname -r)"
log "配置: ENABLE=$ENABLE FW/DELAY/SW=$VCUT_FW/$VCUT_DELAY/$VCUT_SW SOC_CTL=$SOC_CTL FAKE=$FAKE_CYCLE/$FAKE_FG_CYCLE A/B=$ENABLE_THERMAL_REMOVE/$ENABLE_FORCE FORCE_MA=$FORCE_MA"
log "提前加载（boot_completed=$(getprop sys.boot_completed) bms_wait=${i}s）"

# 旧的 xaga_charge 模块与 vcut 后端是同一组 hook，不能同时加载
if lsmod | grep -q '^xaga_charge'; then
  rmmod xaga_charge 2>/dev/null
  log "已卸载旧 xaga_charge，避免双重 hook"
fi
lsmod | grep -q '^vcut_lower' && { rmmod vcut_lower 2>/dev/null; sleep 1; }

if [ "$ENABLE" != "1" ]; then
  log "ENABLE=0，观测模式：不加载内核模块"
  rmdir "$LOCK" 2>/dev/null
  exit 0
fi

# ---------- 伪装循环 + 抬高电压开关状态 ----------
# bq28z610 的 cycle_count 是 RAM fake，不写 DF；重启驱动恢复真值。
cycle0=$(cat /sys/class/power_supply/bms/cycle_count 2>/dev/null)
case "$cycle0" in ''|*[!0-9]*) cycle0=0 ;; esac
echo "$cycle0" > "$DATA/qmax_cyclecount"
# 伪装循环不再写驱动：ko 在 fg_get_property 里按 fake_cycle 改写返回值，
# 驱动缓存始终是真实值，关闭开关下一帧就恢复，不用等电量计巡检。
# 这里只把可能残留的旧 fake 清掉（-1 = 跟随真实寄存器）。
echo -1 > /sys/class/power_supply/bms/cycle_count 2>/dev/null
if [ "$FAKE_CYCLE" -ge 0 ] 2>/dev/null; then
  log "cycle_count: 真实值 $cycle0，显示伪装 $FAKE_CYCLE（ko 读取时改写）"
else
  log "cycle_count: 跟随真实值 ($cycle0)"
fi
# App 第二个开关的选中态读 cyclecount<=5 && qmax_cyclecount>5。
if [ "$FAKE_FG_CYCLE" = "1" ]; then
  echo 1 > "$DATA/cyclecount"
else
  echo "$cycle0" > "$DATA/cyclecount"
fi

# ---------- 加载 ----------
# FAKE_FG_CYCLE 是 vcut App 的“抬高充电电压上限”：
# 1 -> fv_target_mv=FV_TARGET_MV（App 滑块可调）；-1 -> 0（完全跟随原厂 4445/4475）
TRUE_MAH=${TRUE_MAH:-6000}
# COUL_CTL follows SOC_CTL: when user disables "接管电量显示", coulomb
# integration should also stop (it only feeds the capacity override).
COUL_CTL=${COUL_CTL:-$SOC_CTL}
FVT=0
if [ "$FAKE_FG_CYCLE" = "1" ]; then
  FVT=${FV_TARGET_MV:-4475}
  case "$FVT" in ''|*[!0-9]*) FVT=4475 ;; esac
  [ "$FVT" -ge 4400 ] 2>/dev/null && [ "$FVT" -le 4580 ] 2>/dev/null || FVT=4475
fi

insmod "$MODDIR/vcut_lower.ko" \
  enable="$ENABLE" \
  vcut_fw="$VCUT_FW" vcut_delay="$VCUT_DELAY" vcut_sw="$VCUT_SW" \
  kill_vpack_gate="$KILL_VPACK_GATE" \
  soc_ctl="$SOC_CTL" fake_cycle="$FAKE_CYCLE" fake_fg_cycle="$FAKE_FG_CYCLE" \
  fcc_mah="$FCC_MAH" qbot_mah="$QBOT_MAH" rint_mohm="$RINT_MOHM" \
  true_mah="$TRUE_MAH" coul_ctl="$COUL_CTL" \
  fv_target_mv="$FVT" fv_max_mv=4580 force_ma=0 verbose="$VERBOSE" >>"$LOG" 2>&1
rc=$?
log "insmod rc=$rc"
sleep 2

if ! lsmod | grep -q '^vcut_lower'; then
  log "★模块未加载，见上方日志"
  rmdir "$LOCK" 2>/dev/null
  exit 0
fi

# ---------- 自校验：参数 ABI 与首次命中 ----------
w=0
while [ "$(cat $MP/t_hits 2>/dev/null)" = "0" ] && [ "$w" -lt 60 ]; do
  sleep 2
  w=$((w + 2))
done
hits=$(cat $MP/t_hits 2>/dev/null)
armed=$(cat $MP/armed 2>/dev/null)
log "已加载: armed=$armed hits=$hits vbat=$(cat $MP/t_vpack 2>/dev/null)mV real_soc=$(cat $MP/t_soc_real 2>/dev/null 2>&1) fcc=$(cat $MP/t_fcc 2>/dev/null)mAh"
if [ "$armed" != "1" ]; then
  log "★armed=$armed，卸载模块"
  rmmod vcut_lower 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
  exit 0
fi

# ---------- 充电增强守护 ----------
pkill -f vcut_turbo.sh 2>/dev/null
sleep 1
nohup sh "$MODDIR/vcut_turbo.sh" >/dev/null 2>&1 &

# ---------- 解锁容量记录 ----------
UL=$DATA/unlock.log
UC=$DATA/unlock.cur
UPID=/dev/vcut_unlock.pid
ul_archive() {
  [ -s "$UC" ] && { cat "$UC" >> "$UL"; tail -30 "$UL" > "$UL.tmp" && mv "$UL.tmp" "$UL"; }
  rm -f "$UC"
}
unlock_logger() {
  seq0=0; t0=0
  while sleep 60; do
    seq=$(cat $MP/t_cross_seq 2>/dev/null)
    [ "${seq:-0}" -gt 0 ] 2>/dev/null || continue
    if [ "$seq" != "$seq0" ]; then ul_archive; seq0=$seq; t0=$(date +%s); fi
    set -- $(cat $MP/t_cross_rm $MP/t_cross_mv $MP/t_cross_ma $MP/t_cross_temp $MP/t_cross_stock \
                 $MP/t_cross_delay $MP/t_below_mah $MP/t_below_min_mv 2>/dev/null)
    [ $# -eq 8 ] && echo "t=$t0 rm=$1 mv=$2 ma=$3 temp=$4 stock=$5 delay=$6 below=$7 minmv=$8" > "$UC"
  done
}
[ -f "$UPID" ] && kill "$(cat "$UPID")" 2>/dev/null
ul_archive
unlock_logger </dev/null >/dev/null 2>&1 &
echo $! > "$UPID"

# ---------- 稳定后清零 ----------
rmdir "$LOCK" 2>/dev/null
sleep "$STABLE_SEC"
echo 0 > "$GUARD"
log "已稳定运行 ${STABLE_SEC}s，失败计数清零"
