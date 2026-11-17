# VCut Lower · xaga

小米 xaga（MT6895，22041216UC，HyperOS / Android 15，内核 5.10）的电池解容与充电调控模块。
KernelSU 模块 + 配套控制 App，内核侧一个 kprobe 模块，App 侧一个 SystemUI hook。

> 这是个人自用项目，为一块已经衰减的硅碳电池多榨出可用容量。默认配置偏保守，改参数前请把下面「风险」一节读完。

## 它做什么

三件事，各自独立开关：

| 功能 | 做法 | 默认 |
|---|---|---|
| **电池解容** | 下调系统判定「没电」的电压下限，让电池多放一段 | 3000 mV（原厂约 3400 mV） |
| **充电增强** | 抬高恒压段的目标电压，让充电更接近电芯满充 | 4530 mV（源码默认 4475 mV） |
| **30 秒关机应急取消** | 拦截 PowerSaveService 的低电关机倒计时，按一次取消本轮 | 关 |

解容不是伪造电量：电量计报多少就是多少，只是把「低电关机」的判定门槛往下挪。所以电量百分比会在低电区间停留更久，这是预期行为。

## 组成

```
module/    KernelSU 模块：service.sh 开机写参数、customize.sh 装 App、action.sh 交互
kmod/      vcut_lower.c —— 内核模块源码（kprobe + 1 秒轮询工作队列 + sysfs 遥测）
app/       控制 App 源码（Kotlin + Compose，含 SystemUI hook），基于上游改写
tools/     构建与打包脚本
docs/      技术文档：版本说明、排查记录、逆向分析
```

内核模块与 App 通过 sysfs 通信：

```
/sys/module/vcut_lower/parameters/
  vcut_delay_mv   解容后的关机电压下限（mV）
  enable          总开关
  fv_target_mv    恒压段目标电压（mV）
  t_*             遥测：电压、电流、容量、状态、各项计数
```

App 侧读不到 sysfs（system_app 无权限），所以走 Settings.Global 单向发布：
`service.sh` 与 App 写入，hook 在 `PowerSaveService` 里读取。

## 构建

需要：JDK 21、Android SDK（build-tools 35.0.0、compileSdk 37）、Android NDK（clang，用于编 ko）、Python 3。

```bash
# 1) 控制 App → module/vcutlower.apk
bash tools/build_apk.sh

# 2) 内核模块 → module/vcut_lower.ko
python kmod/build_ko.py kmod/vcut_lower.c module/vcut_lower.ko

# 3) 打包成 KernelSU 刷机包
python tools/pack_module.py --src module --out vcut_lower_xaga.zip
```

APK 签名：仓库不含密钥。把 `keystore.properties` 放到 `app/` 下就用你的密钥签名，没有则回退 debug 密钥。

内核模块按目标机的 kallsyms/CRC 编（CFI、LTO、CRC 全套）。跨内核版本刷入前先确认符号与 CRC 对得上，否则开机即崩。

## 兼容性

- 只在 22041216UC / xaga（MT6895，HyperOS，5.10 内核）上验证过。别的机型请自己核对符号表
- 需要 KernelSU。Magisk 也能用，但模块脚本里调了 `ksud` 的地方要改
- App 的 hook 目标是 HyperOS 的 `PowerSaveService`，系统升级后方法签名可能变，失效时表现为开关点了没反应

## 风险

- **解容 = 更深放电**。反复放到 2.6~2.7 V 会加速老化，低温下尤其不要深放。电池已经明显老化的请用保守档
- 模块会改内核里电量驱动的运行状态，可能导致电量显示异常或系统不稳定。连续两次开机不稳定时模块会自己停用，KernelSU 安全模式也能一键禁用全部模块
- 充电增强放宽了原厂的充电上限。温度、电压护栏写死在代码里，但仍可能增加发热
- 30 秒关机取消是「按一次取消一轮」，窗口 30 分钟。它不是永久屏蔽——永久屏蔽请用 `vcut_pc_guard=0`
- 因使用本模块造成的设备故障、电池损耗或数据丢失，作者不承担责任

## 致敬与出处

本项目的灵感与 App 界面来自 [**zyl6932/vcut_lower**](https://github.com/zyl6932/vcut_lower)：
控制 App 的界面框架、主题与大部分组件直接沿用该工程，本项目在其基础上增加了 xaga 机型的内核模块、
充电增强与 30 秒关机应急取消。上游同时提供完整的开发说明，值得一读。

内核侧用到的源码：

- [Android Common Kernel (GKI)](https://android.googlesource.com/kernel/common/) —— `android12-5.10` 分支，本项目 `kernel_src` 对应的 5.10 树
- [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource) —— 小米官方开源内核，驱动细节与 DTS 对照用

其他：

- [miuix](https://github.com/compose-miuix-ui/miuix) —— App 使用的 Compose 组件
- [KernelSU](https://github.com/tiann/KernelSU) —— 模块运行环境
- [LSPosed](https://github.com/LSPosed/LSPosed) —— hook 框架（libxposed API）
