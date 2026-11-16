#!/system/bin/sh

ui_print "========================================"
ui_print "  VCut Lower xaga  (MT6895 / 5.10)"
ui_print "========================================"

DEV=$(getprop ro.product.device)
KREL=$(uname -r)
ui_print "- 设备: $DEV ($(getprop ro.product.model))"
ui_print "- 内核: $KREL"

case "$DEV" in
  xaga|xagapro) ui_print "- 机型匹配 ✓" ;;
  *) abort "! 本包只支持 xaga / xagapro，当前 $DEV" ;;
esac

case "$KREL" in
  5.10.*) ui_print "- 内核系列匹配 ✓" ;;
  *) abort "! 本包只支持 5.10，当前 $KREL" ;;
esac

ui_print "- 检查关键符号..."
missing=""
for sym in vote get_effective_result charger_dev_set_constant_voltage charger_dev_set_charging_current fg_get_property; do
  grep -q "$sym" /proc/kallsyms 2>/dev/null || missing="$missing $sym"
done
[ -n "$missing" ] && abort "! 缺少符号:$missing"
ui_print "  关键符号全部存在 ✓"

ui_print "- 解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in service.sh action.sh uninstall.sh customize.sh vcut_turbo.sh collect.sh; do
  set_perm "$MODPATH/$f" 0 0 0755
done
set_perm "$MODPATH/vcut_lower.ko" 0 0 0644
set_perm "$MODPATH/module.prop" 0 0 0644

# ---------- 配置 ----------
DATA=/data/adb/vcut_lower
mkdir -p "$DATA"
if [ -f "$DATA/config.sh" ]; then
  ui_print "- 保留已有配置 $DATA/config.sh"
else
  cp "$MODPATH/config.sh.default" "$DATA/config.sh"
  ui_print "- 已写入默认配置 $DATA/config.sh"
fi
echo "MODE=full" > "$DATA/mode.sh"
echo 0 > "$DATA/bootfail"
mkdir -p "$DATA/sessions"
set_perm_recursive "$DATA" 0 0 0700 0600

# 从旧 xaga_charge 配置迁移一次
XC=/data/adb/xaga_charge/config.sh
if [ -f "$XC" ] && [ ! -f "$DATA/.migrated_xaga" ]; then
  v=$(sed -n 's/^SHUTDOWN_MV=\([0-9]*\).*/\1/p' "$XC" | head -1)
  s=$(sed -n 's/^SOC_REAL=\([01]\).*/\1/p' "$XC" | head -1)
  f=$(sed -n 's/^FV_TARGET_MV=\([0-9]*\).*/\1/p' "$XC" | head -1)
  [ -n "$v" ] && {
    sed -i "s/^VCUT_FW=.*/VCUT_FW=$v/" "$DATA/config.sh"
    sed -i "s/^VCUT_DELAY=.*/VCUT_DELAY=$v/" "$DATA/config.sh"
    sed -i "s/^VCUT_SW=.*/VCUT_SW=$((v - 100))/" "$DATA/config.sh"
  }
  [ -n "$s" ] && sed -i "s/^SOC_CTL=.*/SOC_CTL=$s/" "$DATA/config.sh"
  [ -n "$f" ] && [ "$f" -gt 0 ] && sed -i "s/^FAKE_FG_CYCLE=.*/FAKE_FG_CYCLE=1/" "$DATA/config.sh"
  grep -q "^FV_TARGET_MV=" "$DATA/config.sh" || echo "FV_TARGET_MV=4530" >> "$DATA/config.sh"
  echo 1 > "$DATA/.migrated_xaga"
  ui_print "- 已迁移旧 xaga 配置: SHUTDOWN=$v SOC_REAL=$s"
fi

# 两个模块是同一组 hook，不能同时开机加载
OLD=/data/adb/modules/xaga_charge
if [ -d "$OLD" ] && [ ! -f "$OLD/disable" ]; then
  touch "$OLD/disable"
  ui_print "- 已停用旧 xaga_charge 模块（同一组 hook）"
fi

# ---------- 充电阶梯默认值：安装时读本机设备树原厂表 ----------
# step_jeita_charge 驱动的 step_chg_cfg_{low,middle,high}_cycle 是三元组数组：
# 每行 = low_threshold(mV) high_threshold(mV) fcc(mA)。取 low_cycle（新电池）表，
# 生成 LADDER_V（拐点，去掉最高一档的 high）与 LADDER_MA（各档电流）。
if ! grep -q "^LADDER_DT=" "$DATA/config.sh" 2>/dev/null; then
  DTN=$(find /proc/device-tree -name "step_chg_cfg_low_cycle" 2>/dev/null | head -n 1)
  if [ -n "$DTN" ] && [ -s "$DTN" ]; then
    L_OUT=$(od -A n -t x1 -v "$DTN" | tr -s ' \n' ' ' | awk '{
      n = 0
      for (i = 1; i <= NF; i++) {
        hx = $i; v = 0
        for (k = 1; k <= 2; k++) {
          c = substr(hx, k, 1)
          d = index("0123456789abcdef", c) - 1
          if (d < 0) d = 0
          v = v * 16 + d
        }
        b[n++] = v
      }
      rows = int(n / 12)
      # 逐行读三元组，按 low_threshold 升序做插入排序（行数少，无所谓复杂度）
      m = 0
      for (r = 0; r < rows; r++) {
        lo = b[r*12]*16777216 + b[r*12+1]*65536 + b[r*12+2]*256 + b[r*12+3]
        hi = b[r*12+4]*16777216 + b[r*12+5]*65536 + b[r*12+6]*256 + b[r*12+7]
        va = b[r*12+8]*16777216 + b[r*12+9]*65536 + b[r*12+10]*256 + b[r*12+11]
        if (lo <= 0 || hi <= lo || va <= 0 || va > 18000) continue
        if (hi > 4495 || lo > 4495) continue
        j = m
        while (j > 0 && L[j-1] > lo) { L[j] = L[j-1]; H[j] = H[j-1]; V[j] = V[j-1]; j-- }
        L[j] = lo; H[j] = hi; V[j] = va; m++
      }
      if (m >= 2) {
        vs = ""; ks = ""
        for (r = 0; r < m; r++) {
          vs = vs (r ? "," : "") V[r]
          if (r < m - 1) ks = ks (r ? "," : "") H[r]
        }
        print ks " " vs
      }
    }')
    if [ -n "$L_OUT" ]; then
      KS=$(echo "$L_OUT" | cut -d' ' -f1)
      VS=$(echo "$L_OUT" | cut -d' ' -f2)
      OLD_V=$(sed -n 's/^LADDER_V=//p' "$DATA/config.sh" | head -n 1)
      OLD_M=$(sed -n 's/^LADDER_MA=//p' "$DATA/config.sh" | head -n 1)
      sed -i "s/^LADDER_V=.*/LADDER_V=$KS/" "$DATA/config.sh"
      sed -i "s/^LADDER_MA=.*/LADDER_MA=$VS/" "$DATA/config.sh"
      echo "LADDER_DT=1" >> "$DATA/config.sh"
      ui_print "- 充电阶梯取自设备树原厂表"
      ui_print "  拐点: $KS (原: ${OLD_V:-无})"
      ui_print "  电流: $VS (原: ${OLD_M:-无})"
    else
      ui_print "! 设备树阶梯表解析失败，沿用现有配置"
    fi
  else
    ui_print "! 未找到设备树阶梯表(step_chg_cfg)，沿用现有配置"
  fi
fi

# 回滚旧模块时保留其配置，不删除目录

# ---------- 配套 APK ----------
if [ -f "$MODPATH/vcutlower.apk" ]; then
  ui_print "- 安装 VCut Lower App..."
  cp "$MODPATH/vcutlower.apk" /data/local/tmp/vcutlower.apk
  chmod 0644 /data/local/tmp/vcutlower.apk
  if pm install -r /data/local/tmp/vcutlower.apk >/dev/null 2>&1; then
    ui_print "  已安装 ✓（内含 PowerSave 护栏 hook）"
    rm -f "$MODPATH/vcutlower.apk"
  else
    ui_print "! 自动安装失败，可手动安装：$MODPATH/vcutlower.apk"
  fi
  rm -f /data/local/tmp/vcutlower.apk
fi

# ---------- PowerSave 护栏运行环境 ----------
# hook 编进 vcutlower.apk 本体（libxposed API 102，静态作用域，免手动勾选）。
# 没有 LSPosed 时内核 3% 钳制仍然兜底，但拦不住粘性广播重放。
if [ -d /data/adb/modules/zygisk_lsposed ] && [ ! -f /data/adb/modules/zygisk_lsposed/disable ]; then
  ui_print "- LSPosed 已启用 ✓ 作用域固定 com.miui.securitycenter"
else
  ui_print "! 未检测到启用的 LSPosed（需 API 102），护栏 hook 不会加载"
  ui_print "  内核 3% 钳制仍生效，但服务启用瞬间的粘性重放无法拦截"
fi

ui_print ""
ui_print "安装完成，重启生效"
ui_print "配置: $DATA/config.sh"
ui_print "日志: $DATA/boot.log / turbo.log"
ui_print "仅支持 xaga 5.10；卸载即还原"
