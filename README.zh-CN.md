# Slate — 手机预装组件研究与管理工具

[繁體中文](README.md) · **简体中文** · [English](README.en.md)

一项针对 Android 预装「运营商管理组件」的逆向研究，以及由此延伸的两个工具：
一个 Windows 只读审计工具，和一支 Android App（以 Shizuku 为基础的 fork，单一 APK）。

研究对象是 `com.mobiletools.systemhelper` —— 一支预装于部分中国版 Android 手机上的联通终端管理（OMA-DM）组件。
本研究只使用**只读**方法：ADB 查询、静态反编译、APK 分析，以及对 vivo 系统 daemon 的逆向；没有 root、没有解锁 bootloader、没有修改系统分区。

> 所有测试都在研究者本人持有并授权的设备上进行。文中不含任何个人识别信息（IMEI、IMSI、ICCID、序号、MAC、电话号码、IP）。

---

## 下载

- **APK（最新 v0.3.7）**：[slate-fork Releases](https://github.com/ivankwanpn/slate-fork/releases/latest)（debug 签名，含 SHA-256；[镜像](https://github.com/ivankwanpn/slate/releases/latest)）
- **完整源代码（fork）**：[slate-fork](https://github.com/ivankwanpn/slate-fork)
- 本仓库：研究报告、Windows 工具、独立审计 App、与上游的 patch

> 两边的 `v0.3.7` release 是同一份 APK；主要构建与后续版本在 `slate-fork` 发布。

## 最新进展

- 新增 `com.vivo.devicereg` 上报分析：[docs/DEVICEREG.md](docs/DEVICEREG.md)
- 权限／AppOps／netpolicy／VPN 的限制边界：[docs/HARDENING.md](docs/HARDENING.md)
- Slate v0.3.7：纯客户端（需官方 Shizuku）、逐项权限开关、netpolicy 背景限制、
  可选 VPN 网络封锁（会与代理冲突）

---

## 摘要

- 在设备上确认 `com.mobiletools.systemhelper` 存在、正在运行，且开机后会自我调度。
- 该组件以**明文 HTTP** 将设备与 SIM 标识、基站、位置、已安装应用清单上报到 `dm.wo.com.cn:18080`。
- 它对外提供一个**没有权限保护的 Binder 服务**，任何应用都能连接并改写上报地址。
- 停用、对用户卸载、暂停三种方式都会在**每次开机后被 vivo 的 daemon 还原**；只有权限与 AppOps 的变更会保留。
- 还原机制定位在 `VivoDaemonService` 内的 `AppFilter`：它读取系统属性 `ro.vivo.dm.config`，把该组件放进「启用」清单。

---

## 方法

1. **只读 ADB 审计**：`pm list packages`、`dumpsys package`、`appops get`、`dumpsys alarm`、`/proc/net/tcp`、`settings get secure`。
2. **静态分析**：以 jadx 反编译目标 APK，以 aapt2 还原 AndroidManifest，检查 exported 组件与权限。
3. **系统组件分析**：反编译 `VivoDaemonService`，定位还原逻辑。
4. **行为验证**：每次变更后重启，观察软件包状态、权限、AppOps 与进程是否回来。
5. **工具实现**：Windows 端以 ADB 操作；Android 端通过 Shizuku 的 shell 通道执行 `pm`／`cmd appops`。

---

## 发现

### 1. 组件的身份

```
package   com.mobiletools.systemhelper
path      /system/app/SystemHelper/SystemHelper.apk
version   3.0.1-20250515 (versionCode 31, targetSdk 33)
size      4,107,356 bytes
```

它持有 `READ_PRIVILEGED_PHONE_STATE`、`PACKAGE_USAGE_STATS`、`QUERY_ALL_PACKAGES`、定位与开机广播等权限，
并在 APK 内含字符串 `http://dm.wo.com.cn:18080/register`，以 `AES-128-ECB` 加密，密钥为 `MD5(明文)`。
（加密细节来自社区公开分析与本次反编译的交叉比对；本文不重述可能被滥用的细节。）

### 2. 没有权限保护的 Binder

AndroidManifest 中：

```xml
<service android:name=".service.RegisterHelperService" android:exported="true">
    <intent-filter>
        <action android:name="com.mobiletools.systemhelper.service.IRegisterHelperService" />
    </intent-filter>
</service>
```

该 service 没有声明 `android:permission`。反编译可见其 AIDL 接口提供五个方法：设置上报地址、设置间隔、清除偏好、开关调试记录。
其中「设置上报地址」意味着任何本机应用都能把数据导向自己的服务器。

### 3. 谁在开机后把它打开

反编译 `/system/app/VivoDaemonService/VivoDaemonService.apk` 后找到：

```java
// com.vivo.daemonService.operator.AppFilter
private static final String[] f4689f = {
    "com.mobiletools.systemhelper",
    "com.chinaunicom.registerhelper" };

// 由 VivoDaemonServiceApp 在启动时调用
startService(new Intent(this, AppFilter.class));

// onStartCommand，依据 ro.vivo.dm.config / ro.vivo.op.entry 决定
setApplicationEnabledSetting(pkg, 1, 0);  // ENABLED
```

在本机上 `ro.vivo.dm.config = CMCC-CTCC-UNICOM`，因此该组件每次 daemon 启动都会被强制启用。

开机时序：

```
system_server
  └─ com.vivo.daemonService 进程启动
       └─ VivoDaemonServiceApp.onCreate
            └─ i0() -> startService(AppFilter)
                 └─ AppFilter.onStartCommand -> a()
                      ├─ 读取 ro.vivo.dm.config / ro.vivo.op.entry / ro.vivo.product.overseas
                      ├─ 组出 enable / disable 清单
                      ├─ setApplicationEnabledSetting(systemhelper, 1, 0)   // ENABLED
                      └─ stopSelf()
```

`setApplicationEnabledSetting(pkg, 1, 0)` 不检查用户是否曾明确停用，也不理会 `disabled-user` 状态 ——
它就是把状态覆盖成「启用」。所以 `pm disable-user` 无论设置过几次，开机一次就被覆盖。

同一个分支在 `ro.vivo.product.overseas=yes` 时会反过来停用该组件，说明「必须启用」是产品政策，不是技术限制。

停用、卸载、暂停三种手段各自被哪一层破解，以及为什么撤销权限能留下来，详见
[docs/RESTORE-MECHANISM.md](docs/RESTORE-MECHANISM.md)。

### 4. 各种移除手段的实测结果

| 手段 | 立即生效 | 重启后 | 备注 |
|---|---|---|---|
| `pm disable-user` | 是 | **被还原** | daemon 的 AppFilter 强制 enable |
| `pm uninstall -k --user 0` | 是 | **被重新安装** | 系统分区副本仍在 |
| `pm suspend` | 是 | **被解除** | |
| 撤销 runtime 权限 | 是 | **保留** | 跨重启有效 |
| AppOps 设为 ignore | 是 | **保留** | 跨重启有效 |
| 停用 daemon 的 AppFilter 组件 | — | — | shell 无权（SecurityException） |

结论：在不 root 的前提下，**没有任何「一次移除、永久生效」的方法**；可行策略是「开机后重新套用」，
并把权限与 AppOps 的收紧当作第二层。

### 5. 其他限制

- 安装时授予的权限（`INTERNET`、`QUERY_ALL_PACKAGES`、`READ_PRIVILEGED_PHONE_STATE` 等）无法通过 `pm revoke` 撤销。
- `cmd firewall` 不存在；`iptables` 需要 root。
- 在 Android 16 上，shell 只能改「软件包层级」状态，不能改其他 App 的「组件层级」状态。

---

## 重现

每一项结论对应的指令都整理在 [docs/VERIFY.md](docs/VERIFY.md)：从确认组件状态、检查权限与对外组件，
到实测停用／卸载／暂停被还原，以及反编译 daemon 验证还原逻辑。

---

## 如果有 root

受测设备没有 root，也没有解锁 bootloader。作为附录，[docs/ROOT.md](docs/ROOT.md) 整理了有 root 时
可以采用的方法（开机脚本重新停用、iptables 封锁 UID、LSPosed hook、remount 删除），以及各自的风险、
副作用与 OTA 影响，并附上与无 root 方案的对照表。

---

## 工具

### Slate（Android，单一 APK）

以 Shizuku v13.6.0 为基础的 fork，加入自己的 UI 与 shell 通道：

- 首页：服务状态、一键连接、扫描摘要
- 组件：符合条件的软件包清单，显示已停用／权限数／对外组件数
- 详情：权限依敏感度分组（定位／电话／存储／网络与系统／其他），标注不可撤销的系统权限
- 操作：停用、还原、对用户卸载、撤销敏感权限（逐条指令与结果记录）
- 说明：本报告摘要与已知限制

技术上，App 通过 `Shizuku.bindUserService` 取得 shell 身份的 `IShellService`，再执行 `pm`／`cmd appops`。
补丁位于 `patches/slate-fork.patch`（相对于 Shizuku v13.6.0）。

### Windows 审计工具

`windows/PhoneFix.ps1`：以 ADB 连接，提供 GUI 与 CLI（audit / report / disable / enable / clear / harden / uninstall / restore）。
不改动系统分区，所有操作均可逆（清除数据除外）。

---

## 构建

### Android（独立审计 App）

```
cd android-audit
gradle assembleDebug
```

需求：JDK 21、Android SDK 35、Gradle 8.11+。

### Slate（fork）

1. clone Shizuku v13.6.0
2. 应用 `patches/slate-fork.patch`
3. `./gradlew :manager:assembleDebug`

---

## 隐私与伦理

- 本仓库**不包含**任何厂商 APK、反编译产物、设备备份或个人数据。
- 所有标识符（IMEI、IMSI、ICCID、序号、MAC、电话号码、IP）都已从文件中移除。
- 研究目的在于让用户了解自己设备上的软件行为，并提供可逆的管理方式。
- 请自行确认在所在地区进行此类研究与发布的合法性。

## 授权

- 本仓库自行编写的代码与文档：MIT
- Slate fork 基于 [Shizuku](https://github.com/RikkaApps/Shizuku)（Apache-2.0），补丁保留原授权
- Android 审计 App 依赖 [Shizuku-API](https://github.com/RikkaApps/Shizuku-API)（MIT）

## 免责声明

本工具按「现状」提供，不保证适用于所有机型或系统版本。操作系统组件有风险，请自行备份并确认可还原。
