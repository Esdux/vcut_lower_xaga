#!/system/bin/sh
#
# vcut_turbo.sh — xaga 适配版
#
# A: usb/thermal_remove
# B: pmic-votable/CHARGER_FCC/force_val + force_active
#    force_active 默认 0444，但底层有 set 回调；root chmod 0644 后写入。
#    ko 的 charger_dev_set_charging_current kprobe 仍作为兜底。
#
CFG=/data/adb/vcut_lower/config.sh
LOG=/data/adb/vcut_lower/turbo.log
STATE=/dev/vcut_turbo.state

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
ENABLE_THERMAL_REMOVE=0
ENABLE_FORCE=0

POLL=5
IDLE_POLL=30
LOG_EVERY=6
MAX_LOG=262144

MIN_BTEMP=230
HYST_MIN_BTEMP=10
VBAT_CEIL=4495
MA_CEIL=18000

DLOG=/dev/vcut_turbo.log
SESS=/data/adb/vcut_lower/sessions
SVAR=/dev/vcut_turbo.sess
KEEP_SESS=30
SYNC_EVERY=12
RELOAD=/dev/vcut_turbo.reload

load_cfg() {
  [ -f "$CFG" ] && . "$CFG"
  [ "$MAX_VBAT" -gt "$VBAT_CEIL" ] 2>/dev/null && MAX_VBAT=$VBAT_CEIL
  [ "$FORCE_MA" -gt "$MA_CEIL" ] 2>/dev/null && FORCE_MA=$MA_CEIL
}
mkdir -p /data/adb/vcut_lower
load_cfg

B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
TR=/sys/class/power_supply/usb/thermal_remove
V=/sys/kernel/debug/pmic-votable/CHARGER_FCC
FV=$V/force_val
FA=$V/force_active
CN=/sys/class/power_supply/usb/connector_temp

mount -t debugfs none /sys/kernel/debug 2>/dev/null

st() { echo "run=$1 sid=${SID:-0} A=${TR_ON:-0} B=${FORCE_ON:-0} step=$((${STEP:--1} + 1)) ma=${CUR_MA:-0} online=${online:-0} soc=${soc:-0} vbat=${vbat:-0} ibat=${ibat:-0} btemp=${btemp:-0} ctherm=${ctherm:-0} conn=${conn:-0} why=${2:-}" > "$STATE"; }

if [ "$ENABLE_THERMAL_REMOVE" != 1 ] && [ "$ENABLE_FORCE" != 1 ]; then
  st off; exit 0
fi
if [ ! -e "$TR" ] && [ ! -e "$FV" ]; then
  st unsupported "没有 thermal_remove / force_val"; exit 0
fi
[ -w "$TR" ] || ENABLE_THERMAL_REMOVE=0
# xaga 的 force_active 默认 0444，但底层有 set 回调；root chmod 后可写。
[ -e "$FA" ] && chmod 0644 "$FA" 2>/dev/null
if [ ! -w "$FV" ] || [ ! -w "$FA" ]; then
  ENABLE_FORCE=0
fi
if [ "$ENABLE_THERMAL_REMOVE" != 1 ] && [ "$ENABLE_FORCE" != 1 ]; then
  st unsupported "模块未加载或节点不可写"; exit 0
fi

resolve_zone() {
  _rz=""
  for _d in /sys/class/thermal/thermal_zone*/; do
    read -r _t < "$_d/type" 2>/dev/null || continue
    if [ "$_t" = "$1" ]; then _rz="${_d}temp"; break; fi
  done
  echo "$_rz"
}
CT=$(resolve_zone charger_therm)
[ -n "$CT" ] || CT=$(resolve_zone charger_therm0)

rd() {
  eval "$1=0"
  [ -n "$2" ] || return 0
  read -r _v < "$2" 2>/dev/null || return 0
  case "$_v" in ''|*[!0-9-]*) return 0;; esac
  eval "$1=\$_v"
}

logn=0
log() {
  logn=$((logn + 1))
  if [ $((logn % 50)) = 1 ]; then
    [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG" ] && : > "$LOG"
  fi
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

tr_off()    { echo 0 > "$TR" 2>/dev/null; }
force_off() { echo 0 > "$FA" 2>/dev/null; }
all_off()   { force_off; tr_off; }

lad_step() {
  LV=0; _ifs=$IFS; IFS=,
  for _n in $LADDER_V; do [ "$vbat" -ge "$_n" ] 2>/dev/null && LV=$((LV + 1)); done
  IFS=$_ifs
}
lad_ma() {
  TMA=$FORCE_MA; _i=0; _ifs=$IFS; IFS=,
  for _m in $LADDER_MA; do
    case "$_m" in ''|*[!0-9]*) continue;; esac
    TMA=$_m; [ "$_i" -ge "$1" ] && break; _i=$((_i + 1))
  done
  IFS=$_ifs
  [ "$TMA" -gt "$MA_CEIL" ] && TMA=$MA_CEIL
}

up=0; now=0; SID=; ep0=0; up0=0; dn=0; sn=0; sc=0
uptime_s() { read -r up _ < /proc/uptime; up=${up%.*}; }
now_s() { uptime_s; now=$((ep0 + up - up0)); }
dlog() { now_s; echo "E $now $*" >> "$DLOG"; dn=$((dn + 1)); }
sess_save() { echo "SID=$SID ep0=$ep0 up0=$up0 dn=$dn sn=$sn" > "$SVAR"; }
sess_sync() {
  [ -n "$SID" ] && [ "$dn" -gt "$sn" ] || return 0
  mkdir -p "$SESS"
  sed -n "$((sn + 1)),\$p" "$DLOG" >> "$SESS/$SID.log" && sn=$dn
  sess_save
}
sess_begin() {
  ep0=$(date +%s); uptime_s; up0=$up; SID=$ep0
  : > "$DLOG"; dn=0; sn=0; sc=0
  dlog "插入充电器"; sess_save
}
sess_end() {
  dlog "拔出充电器"; sess_sync
  now_s
  [ $((now - ep0)) -lt 60 ] && rm -f "$SESS/$SID.log"
  SID=; rm -f "$SVAR"
  _n=$(ls "$SESS"/*.log 2>/dev/null | wc -l)
  if [ "$_n" -gt "$KEEP_SESS" ]; then
    ls "$SESS"/*.log | sort | head -n $((_n - KEEP_SESS)) | while read -r _f; do rm -f "$_f"; done
  fi
}

SLP=
trap '[ -n "$SLP" ] && kill "$SLP" 2>/dev/null; sess_sync; all_off; TR_ON=0; FORCE_ON=0; st off "已停止"; log "收到退出信号，已全部撤回"; exit 0' INT TERM HUP

all_off
log "=== xaga 充电增强 A=${ENABLE_THERMAL_REMOVE} B=${ENABLE_FORCE} 阶梯 V=[${LADDER_V:-无}] mA=[${LADDER_MA:-$FORCE_MA}]"
log "    温度节点 charger=${CT:-未找到} conn=${CN:-未找到}  poll=${POLL}/${IDLE_POLL}s"
log "    护栏 soc<${MAX_SOC} vbat<${MAX_VBAT} ${MIN_BTEMP}<=btemp<${MAX_BTEMP} ctherm<${MAX_CTHERM} conn<${MAX_CONN}"

TR_ON=0; FORCE_ON=0; n=0; rescan=0
STEP=-1; up_cnt=0; CUR_MA=0; was_online=0
if [ -s "$DLOG" ] && [ -f "$SVAR" ]; then
  . "$SVAR"
  _last=$(tail -n 1 "$DLOG" | cut -d' ' -f2)
  now_s
  if [ -n "$SID" ] && [ $((now - ${_last:-0})) -lt 120 ]; then was_online=1; else SID=; rm -f "$SVAR"; fi
fi
while true; do
  if [ -f "$RELOAD" ]; then
    rm -f "$RELOAD"; load_cfg; STEP=-1; up_cnt=0
    log "配置已更新: 阶梯 V=[${LADDER_V:-无}] mA=[${LADDER_MA:-$FORCE_MA}] vbat<${MAX_VBAT} soc<${MAX_SOC}"
  fi

  if [ -z "$CT" ]; then
    rescan=$((rescan + 1))
    if [ $((rescan % 20)) = 1 ]; then
      CT=$(resolve_zone charger_therm)
      [ -n "$CT" ] || CT=$(resolve_zone charger_therm0)
      [ -n "$CT" ] && log "温度节点已解析: $CT"
    fi
  fi

  rd online "$U/online"
  rd soc "$B/capacity"
  rd vnow "$B/voltage_now"; vbat=$((vnow / 1000))
  rd btemp "$B/temp"
  rd ctherm "$CT"
  rd ibat "$B/current_now"
  conn=0
  if [ -e "$CN" ]; then
    read -r _c < "$CN" 2>/dev/null
    case "$_c" in ''|*[!0-9-]*) ;; *) conn=$((_c * 100));; esac
  fi

  if [ "$online" = 1 ]; then
    if [ "$was_online" != 1 ]; then sess_begin; STEP=-1; fi
    lad_step
    if [ "$STEP" -lt 0 ]; then STEP=$LV; up_cnt=0
    elif [ "$LV" -gt "$STEP" ]; then
      up_cnt=$((up_cnt + 1))
      [ "$up_cnt" -ge 2 ] && { STEP=$LV; up_cnt=0; }
    else up_cnt=0; fi
  else
    [ "$was_online" = 1 ] && sess_end
    STEP=-1; up_cnt=0
  fi
  was_online=$online

  t_ok=1; t_why=""
  if [ -z "$CT" ]; then
    t_ok=0; t_why="充电温度节点未就绪"
  else
    if [ "$TR_ON" = 1 ] || [ "$FORCE_ON" = 1 ]; then
      lim_b=$MAX_BTEMP; lim_c=$MAX_CTHERM; lim_n=$MAX_CONN
    else
      lim_b=$((MAX_BTEMP - HYST_BTEMP)); lim_c=$((MAX_CTHERM - HYST_CTHERM)); lim_n=$((MAX_CONN - HYST_CONN))
    fi
    [ "$btemp" -ge "$lim_b" ] && { t_ok=0; t_why="电芯 ${btemp}"; }
    [ "$t_ok" = 1 ] && [ "$ctherm" -ge "$lim_c" ] && { t_ok=0; t_why="充电电路 ${ctherm}"; }
    [ "$t_ok" = 1 ] && [ "$conn" -gt 0 ] && [ "$conn" -ge "$lim_n" ] && { t_ok=0; t_why="接口 ${conn}"; }
  fi

  s_ok=1; s_why=""
  if [ "$FORCE_ON" = 1 ]; then
    lim_s=$MAX_SOC; lim_v=$MAX_VBAT
  else
    lim_s=$((MAX_SOC - HYST_SOC)); lim_v=$((MAX_VBAT - HYST_VBAT))
  fi
  [ "$soc" -ge "$lim_s" ] && { s_ok=0; s_why="SOC ${soc}%"; }
  [ "$s_ok" = 1 ] && [ "$vbat" -ge "$lim_v" ] && { s_ok=0; s_why="vbat ${vbat}mV"; }

  l_ok=1
  if [ "$FORCE_ON" = 1 ]; then lim_l=$MIN_BTEMP; else lim_l=$((MIN_BTEMP + HYST_MIN_BTEMP)); fi
  [ "$btemp" -lt "$lim_l" ] && l_ok=0

  if [ "$ENABLE_THERMAL_REMOVE" = 1 ] && [ "$online" = 1 ] && [ "$t_ok" = 1 ]; then
    if [ "$TR_ON" = 0 ]; then echo 1 > "$TR"; TR_ON=1; log "A 生效: 热限流已摘 (ctherm=${ctherm} conn=${conn})"; fi
  else
    if [ "$TR_ON" = 1 ]; then
      tr_off; TR_ON=0
      [ "$online" = 1 ] && log "A 撤回: ${t_why}，恢复原厂热限流" || log "A 撤回: 未充电"
    fi
  fi

  if [ "$ENABLE_FORCE" = 1 ] && [ "$online" = 1 ] && [ "$t_ok" = 1 ] && [ "$s_ok" = 1 ] && [ "$l_ok" = 1 ]; then
    lad_ma "$STEP"
    if [ "$FORCE_ON" = 0 ]; then
      echo "$TMA" > "$FV"; echo 1 > "$FA"; FORCE_ON=1; n=0; CUR_MA=$TMA
      log "B 生效: 第 $((STEP + 1)) 档 force ${TMA}mA (soc=${soc}% vbat=${vbat}mV btemp=${btemp})"
      dlog "强制生效 第 $((STEP + 1)) 档 ${TMA}mA"
    elif [ "$TMA" != "$CUR_MA" ]; then
      echo "$TMA" > "$FV"; CUR_MA=$TMA
      log "B 换档: 第 $((STEP + 1)) 档 force ${TMA}mA (vbat=${vbat}mV)"
      dlog "第 $((STEP + 1)) 档 ${TMA}mA（${vbat}mV）"
    fi
  else
    if [ "$FORCE_ON" = 1 ]; then
      force_off; FORCE_ON=0; CUR_MA=0
      if [ "$online" != 1 ]; then log "B 撤回: 未充电"
      elif [ "$t_ok" = 0 ]; then log "B 撤回: ${t_why} 超限"; dlog "撤回：${t_why} 超限"
      elif [ "$l_ok" = 0 ]; then log "B 撤回: 电芯 ${btemp} 低于下限"; dlog "撤回：电芯 ${btemp} 低于下限"
      else log "B 撤回: ${s_why} 达上限"; dlog "撤回：${s_why} 达上限"; fi
    fi
  fi

  if [ "$online" != 1 ]; then why="未充电"
  elif [ "$t_ok" = 0 ]; then why="$t_why 超限"
  elif [ "$l_ok" = 0 ] && [ "$ENABLE_FORCE" = 1 ]; then why="电芯 ${btemp} 低于下限"
  elif [ "$s_ok" = 0 ] && [ "$ENABLE_FORCE" = 1 ]; then why="$s_why 达上限"
  else why=""; fi
  st on "$why"

  if [ "$TR_ON" = 1 ] || [ "$FORCE_ON" = 1 ]; then
    n=$((n + 1))
    if [ $((n % LOG_EVERY)) = 1 ]; then
      log "  A=${TR_ON} B=${FORCE_ON} ibat=${ibat} vbat=${vbat} soc=${soc} btemp=${btemp} ctherm=${ctherm} conn=${conn} eff=$(grep effective "$V/status" 2>/dev/null | sed 's/.*v=//')"
    fi
  fi

  if [ "$online" = 1 ]; then
    now_s
    echo "D $now $vbat $ibat $soc $btemp $ctherm $conn $((STEP + 1)) $CUR_MA" >> "$DLOG"
    dn=$((dn + 1)); sc=$((sc + 1))
    [ "$sc" -ge "$SYNC_EVERY" ] && { sess_sync; sc=0; }
    if [ "$dn" -gt 6000 ]; then
      sess_sync
      tail -n 3000 "$DLOG" > "$DLOG.t" && mv "$DLOG.t" "$DLOG"; dn=3000; sn=3000; sess_save
    fi
  fi

  if [ "$online" = 1 ]; then sleep "$POLL" & else sleep "$IDLE_POLL" & fi
  SLP=$!; wait "$SLP"; SLP=
done
