# Slate — 手機預裝元件研究與管理工具

**繁體中文** · [简体中文](README.zh-CN.md) · [English](README.en.md)

一個針對 Android 預裝「電信商管理元件」的逆向研究，以及由此延伸的兩個工具：
一個 Windows 唯讀稽核工具，與一支 Android App（以 Shizuku 為基礎的 fork，單一 APK）。

研究對象是 `com.mobiletools.systemhelper` —— 一支預裝在部分中國版 Android 手機上的聯通終端管理（OMA-DM）元件。
本研究只使用**唯讀**方法：ADB 查詢、靜態反編譯、APK 分析、以及對 vivo 系統 daemon 的逆向；沒有 root、沒有解鎖 bootloader、沒有修改系統分區。

> 所有測試都在研究者本人持有並授權的裝置上進行。文中不含任何個人識別資料（IMEI、IMSI、ICCID、序號、MAC、電話號碼、IP）。

---

## 下載

- **APK（最新 v0.3.7）**：[slate-fork Releases](https://github.com/ivankwanpn/slate-fork/releases/latest)（debug 簽名，含 SHA-256；[鏡像](https://github.com/ivankwanpn/slate/releases/latest)）
- **完整原始碼（fork）**：[slate-fork](https://github.com/ivankwanpn/slate-fork)
- 本倉庫：研究報告、Windows 工具、獨立稽核 App、與上游的 patch

> 兩邊的 `v0.3.7` release 是同一份 APK；主要建置與後續版本在 `slate-fork` 發佈。

## 最新進展

- 新增 `com.vivo.devicereg` 上報分析：[docs/DEVICEREG.md](docs/DEVICEREG.md)
- 權限／AppOps／netpolicy／VPN 的限制邊界：[docs/HARDENING.md](docs/HARDENING.md)
- Slate v0.3.7：純客戶端（需官方 Shizuku）、逐項權限開關、netpolicy 背景限制、
  可選 VPN 網路封鎖（會與代理衝突）

---

## 摘要

- 在裝置上確認 `com.mobiletools.systemhelper` 存在、執行中，且開機後會自我排程。
- 該元件以**明文 HTTP** 將裝置與 SIM 識別碼、基地台、位置、已安裝應用清單上報到 `dm.wo.com.cn:18080`。
- 它對外開放一個**沒有權限保護的 Binder 服務**，任何應用程式都能連上並改寫上報位址。
- 停用、對使用者卸載、暫停三種方式都會在**每次開機後被 vivo 的 daemon 還原**；只有權限與 AppOps 的變更能保留。
- 還原機制已定位到 `VivoDaemonService` 內的 `AppFilter`：它讀取系統屬性 `ro.vivo.dm.config`，把該元件放進「啟用」清單。
- 另一支 `com.vivo.devicereg` 也有電信商上報；Wi-Fi／基地台／藍牙等預設開啟，應用清單預設關閉，詳見
  [docs/DEVICEREG.md](docs/DEVICEREG.md)。

---

## 方法

1. **唯讀 ADB 稽核**：`pm list packages`、`dumpsys package`、`appops get`、`dumpsys alarm`、`/proc/net/tcp`、`settings get secure`。
2. **靜態分析**：以 jadx 反編譯目標 APK，以 aapt2 還原 AndroidManifest，檢查 exported 元件與權限。
3. **系統元件分析**：反編譯 `VivoDaemonService`，定位還原邏輯。
4. **行為驗證**：在每次變更後重開機，觀察套件狀態、權限、AppOps 與行程是否回來。
5. **工具實作**：Windows 端以 ADB 操作；Android 端以 Shizuku 的 shell 通道執行 `pm`／`cmd appops`。

---

## 發現

### 1. 元件的身份

```
package   com.mobiletools.systemhelper
path      /system/app/SystemHelper/SystemHelper.apk
version   3.0.1-20250515 (versionCode 31, targetSdk 33)
size      4,107,356 bytes
```

它持有 `READ_PRIVILEGED_PHONE_STATE`、`PACKAGE_USAGE_STATS`、`QUERY_ALL_PACKAGES`、定位與開機廣播等權限，
並在 APK 內含字串 `http://dm.wo.com.cn:18080/register`，以 `AES-128-ECB` 加密，金鑰為 `MD5(明文)`。
（加密細節來自社群公開分析與本次反編譯的交叉比對；本文不重述可被濫用的細節。）

### 2. 沒有權限保護的 Binder

AndroidManifest 中：

```xml
<service android:name=".service.RegisterHelperService" android:exported="true">
    <intent-filter>
        <action android:name="com.mobiletools.systemhelper.service.IRegisterHelperService" />
    </intent-filter>
</service>
```

該 service 沒有宣告 `android:permission`。反編譯可見其 AIDL 介面提供五個交易：設定上報位址、設定間隔、清除偏好、開關除錯記錄。
其中「設定上報位址」意味著任何本機應用都能把資料導向自己的伺服器。

### 3. 誰在開機後把它打開

反編譯 `/system/app/VivoDaemonService/VivoDaemonService.apk` 後找到：

```java
// com.vivo.daemonService.operator.AppFilter
private static final String[] f4689f = {
    "com.mobiletools.systemhelper",
    "com.chinaunicom.registerhelper" };

// 由 VivoDaemonServiceApp 在啟動時呼叫
startService(new Intent(this, AppFilter.class));

// onStartCommand → 依 ro.vivo.dm.config / ro.vivo.op.entry 決定
setApplicationEnabledSetting(pkg, 1, 0);  // ENABLED
```

在本機上 `ro.vivo.dm.config = CMCC-CTCC-UNICOM`，因此該元件每次 daemon 啟動都會被強制啟用。

開機時序：

```
system_server
  └─ com.vivo.daemonService 行程啟動
       └─ VivoDaemonServiceApp.onCreate
            └─ i0() → startService(AppFilter)
                 └─ AppFilter.onStartCommand → a()
                      ├─ 讀 ro.vivo.dm.config / ro.vivo.op.entry / ro.vivo.product.overseas
                      ├─ 組出 enable / disable 清單
                      ├─ setApplicationEnabledSetting(systemhelper, 1, 0)   // ENABLED
                      └─ stopSelf()
```

`setApplicationEnabledSetting(pkg, 1, 0)` 不檢查使用者是否曾明確停用，也不理會 `disabled-user` 狀態 ——
它就是把狀態覆寫成「啟用」。所以 `pm disable-user` 無論設定過幾次，開機一次就被蓋掉。

同一個分支在 `ro.vivo.product.overseas=yes` 時會反過來停用該元件，說明「必須啟用」是產品政策，不是技術限制。

停用、卸載、暫停三種手段各自被哪一層破解，以及為什麼撤權限能留下來，詳見
[docs/RESTORE-MECHANISM.md](docs/RESTORE-MECHANISM.md)。

### 4. 各種移除手段的實測結果

| 手段 | 立即生效 | 重開機後 | 備註 |
|---|---|---|---|
| `pm disable-user` | 是 | **被還原** | daemon 的 AppFilter 強制 enable |
| `pm uninstall -k --user 0` | 是 | **被重新安裝** | 系統分區副本仍在 |
| `pm suspend` | 是 | **被解除** | |
| 撤銷 runtime 權限 | 是 | **保留** | 跨重開機有效 |
| AppOps 設為 ignore | 是 | **保留** | 跨重開機有效 |
| 停用 daemon 的 AppFilter 元件 | — | — | shell 無權限（SecurityException） |

結論：在不 root 的前提下，**沒有任何「一次移除、永久生效」的方法**；可行策略是「開機後重新套用」，
並把權限與 AppOps 的收緊當作第二層。

### 5. 其他限制

- 安裝時授予的權限（`INTERNET`、`QUERY_ALL_PACKAGES`、`READ_PRIVILEGED_PHONE_STATE` 等）無法透過 `pm revoke` 撤銷。
- `cmd firewall` 不存在；`iptables` 需要 root。
- 在 Android 16 上，shell 只能改「套件層級」狀態，不能改其他 App 的「元件層級」狀態。

---

## 重現

每一項結論對應的指令都整理在 [docs/VERIFY.md](docs/VERIFY.md)：從確認元件狀態、檢查權限與對外元件，
到實測停用／卸載／暫停被還原，以及反編譯 daemon 驗證還原邏輯。

---

## 如果有 root

受測裝置沒有 root，也沒有解鎖 bootloader。作為附錄，[docs/ROOT.md](docs/ROOT.md) 整理了有 root 時
可以採用的方法（開機腳本重新停用、iptables 封鎖 UID、LSPosed hook、remount 刪除），以及各自的風險、
副作用與 OTA 影響，並附上與非 root 方案的對照表。

---

## 工具

### Slate（Android，單一 APK）

以 Shizuku v13.6.0 為基礎的 fork，改成**純客戶端**：需要先安裝並啟動官方
[Shizuku](https://github.com/RikkaApps/Shizuku)，Slate 只負責 UI 與 shell 指令。

- 首頁：服務狀態、掃描摘要
- 元件：符合條件的套件清單，顯示執行中／已停用／已卸載
- 詳情：runtime 權限逐項開關（ON = 允許）、AppOps、netpolicy、對外元件
- 操作：批次撤銷／還原、停用／卸載、背景限制、可選 VPN 網路封鎖
- 記錄：每條 shell 指令與結果
- 說明：限制與資料來源

技術上，App 透過 `Shizuku.bindUserService` 取得 shell 身份的 `IShellService`，再執行 `pm`／`cmd appops`／
`cmd netpolicy`。完整原始碼在 [slate-fork](https://github.com/ivankwanpn/slate-fork)；本倉庫的
`patches/slate-fork.patch` 是早期版本，可能落後於 fork。

### Windows 稽核工具

`windows/PhoneFix.ps1`：以 ADB 連線，提供 GUI 與 CLI（audit / report / disable / enable / clear / harden / uninstall / restore）。
不改動系統分區，所有操作皆可逆（清資料除外）。

---

## 建置

### Android（獨立稽核 App）

```
cd android-audit
gradle assembleDebug
```

需求：JDK 21、Android SDK 35、Gradle 8.11+。

### Slate（fork）

直接 clone [slate-fork](https://github.com/ivankwanpn/slate-fork)，不需要套用舊 patch：

1. `git clone https://github.com/ivankwanpn/slate-fork.git`
2. 在 `local.properties` 設定 Android SDK 路徑
3. `./gradlew :manager:assembleRelease`

需要 JDK 21、Android SDK 36；`api` 是 Shizuku-API 子模組，需一併初始化。

---

## 隱私與倫理

- 本倉庫**不包含**任何廠商 APK、反編譯產物、裝置備份或個人資料。
- 所有識別碼（IMEI、IMSI、ICCID、序號、MAC、電話號碼、IP）都已從文件中移除。
- 研究目的在於讓使用者了解自己裝置上的軟體行為，並提供可逆的管理方式。
- 請自行確認在所在地區進行此類研究與發佈的合法性。

## 授權

- 本倉庫自行撰寫的程式碼與文件：MIT
- Slate fork 基於 [Shizuku](https://github.com/RikkaApps/Shizuku)（Apache-2.0），patch 保留原授權
- Android 稽核 App 依賴 [Shizuku-API](https://github.com/RikkaApps/Shizuku-API)（MIT）

## 免責聲明

本工具按「現狀」提供，不保證適用於所有機型或系統版本。操作系統元件有風險，請自行備份並確認可還原。
