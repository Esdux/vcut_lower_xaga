# VCut Lower (xaga) v2.1

保留 **VCut Lower v1.9** 的 UI 和参数 ABI，把内核控制后端整体换成 xaga / MT6895 实现。
只支持 `xaga` / `xagapro` + 5.10，不再包含 MCA、business-votable、strategy-fg、
fg_master 和多机型分支。

## APK 说明

原版 APK 的控制协议写死在 DEX 中。为了让它真正控制 xaga，而不是做成“能点没效果”：
- 保持原版 UI、包名和配置格式；
- 只改三处行为：
  1. “抬高充电电压上限”开关 → `fv_target_mv`（4530 / 0），实时生效；
  2. 关闭 SOC 接管不再写 xaga 不存在的 `strategy-fg/fake_soc`；
  3. 去掉配置写完后的 `svc power reboot`，关闭开关不再重启手机。
- 模块内置的是重新签名后的 APK；安装时自动覆盖安装。

## 功能落点

| APK 功能 | xaga 实现 |
|---|---|
| 关机电压 `VCUT_FW/DELAY/SW` | `fg_get_property` CAPACITY 下限；实际生效 `VCUT_DELAY`，`VCUT_FW` 只保存 |
| 接管电量显示 `SOC_CTL` | 1s workqueue 采样 `bms` 的 `rm/fcc`，探针只读缓存 |
| 伪装循环 `FAKE_CYCLE` | 写 `/sys/class/power_supply/bms/cycle_count`（bq28z610 的 RAM fake，不写 DF） |
| 抬高充电电压上限 `FAKE_FG_CYCLE` | 1 → `fv_target_mv=4530`，-1 → 0；`fv_watch.sh` 1 秒内同步，实时生效，不重启 |
| 亮屏快充 A | 写 `/sys/class/power_supply/usb/thermal_remove` |
| 提升电流 B | `CHARGER_FCC/force_val` + `force_active`（chmod 后写，原生投票器旁路）；ko 的电流 kprobe 兜底 |
| 电流阶梯/护栏 | `vcut_turbo.sh`：SOC、带载电压、电芯/充电电路/接口温度，超限撤回 |
| 充电记录 | 原 v1.9 会话格式，`/data/adb/vcut_lower/sessions/` |
| 解锁容量估算 | ko 的 `t_cross_*` 遥测 + `unlock.cur/log` |
| 诊断包 | `collect.sh` → `/sdcard/Download/vcut_diag_xaga_*.tar.gz` |

## 与原生 VCut 的差异

1. **没有 `VCUT_FW` 的电量计 DF 传播**：xaga 用 bq28z610，不是小米 MCA；
   `vcut_fw` 会显示/保存，但真正电压闸是 `vcut_delay`。
2. **没有硬编码 3000mV vpack 门控可摘**：`kill_vpack_gate` 仅为 ABI 兼容。
3. **伪装循环只影响 `bms/cycle_count`**：不影响电量计 DF；抬高电压由 `fv_target_mv` 独立控制
   （xaga 的满充电压已由 `fv_target_mv=4530` 独立接管）。
4. **B 强制电流是内核级绕过**：`force_ma` 会覆盖 votable 结果和充电电流设置，
   所以护栏必须在 `vcut_turbo.sh` 里保持运行；默认 `ENABLE_FORCE=0`。

## 安装

1. 刷 `xaga_vcut_v2.0.zip`
2. 重启
3. 打开已有的「VCut Lower」App；模块会重新安装同一 APK
4. KernelSU 给 App 授权 root

安装时会把旧的 `xaga_charge` 模块 `disable`，因为两者 hook 同一组内核函数。
卸载本模块会自动清掉该 `disable`，恢复旧模块。

## 配置

`/data/adb/vcut_lower/config.sh`，由 APK 原位改写并保留注释。
即时参数写 `/sys/module/vcut_lower/parameters/*`，重启回到配置值。

## 验证

```bash
su -c 'lsmod | grep vcut_lower'
su -c 'cat /sys/module/vcut_lower/parameters/armed'
su -c 'cat /sys/module/vcut_lower/parameters/t_hits'
su -c 'cat /sys/module/vcut_lower/parameters/t_vpack'
su -c 'cat /sys/module/vcut_lower/parameters/t_soc_real'
su -c 'cat /sys/module/vcut_lower/parameters/force_ma'
```

APK 首页应显示“运行中”。`armed=1`、`enable=1` 是运行状态的必要条件。

## 回滚

```bash
su -c 'echo 0 > /sys/class/power_supply/usb/thermal_remove'
su -c 'echo 0 > /sys/module/vcut_lower/parameters/force_ma'
su -c 'rmmod vcut_lower'
rm -rf /data/adb/modules/vcut_lower /data/adb/vcut_lower
rm -f /data/adb/modules/xaga_charge/disable
```

## 安全

- 默认关机电压 3000mV，低于 2500mV 会被 ko 钳住。
- `ENABLE_FORCE` 默认关闭；开启后仍受 `MAX_SOC / MAX_VBAT / MAX_BTEMP / MAX_CTHERM / MAX_CONN` 限制。
- `MAX_VBAT` 守护进程硬钳到 4495mV；本模块不会把电流强制到 18A 以上。
- 电芯温度低于 23℃ 不强制大电流（防析锂）。
