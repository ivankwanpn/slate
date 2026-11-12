# 還原機制：vivo daemon 如何讓移除措施失效

這份文件說明：為什麼停用、卸載、暫停都會在重開機後失效，而撤權限卻能保留下來。
結論來自對 `VivoDaemonService.apk` 的靜態反編譯，以及每次變更後的實機重開機驗證。

---

## 1. 先看現象

在受測裝置上，同一輪操作依序得到以下結果（每次都在重開機後檢查）：

| 操作 | 指令 | 重開機後 |
|---|---|---|
| 停用 | `pm disable-user --user 0 com.mobiletools.systemhelper` | `enabled=1`，重新出現在 `pm list packages -d` 之外 |
| 卸載 | `pm uninstall -k --user 0 com.mobiletools.systemhelper` | 重新出現在 `pm list packages --user 0` |
| 暫停 | `pm suspend --user 0 com.mobiletools.systemhelper` | `suspended=false` |
| 撤權限 | `pm revoke ...` | `granted=false` 保留 |
| AppOps | `cmd appops set ... ignore` | `ignore` 保留 |

前三種都回到原狀，後兩種留下來了。這個差異是找機制的起點。

---

## 2. 定位：`AppFilter`

在 `/system/app/VivoDaemonService/VivoDaemonService.apk` 中，有一個 Service：

```java
// com.vivo.daemonService.operator.AppFilter
public class AppFilter extends Service {
    private static final boolean f4687d =
        "yes".equalsIgnoreCase(SystemProperties.get("ro.vivo.product.overseas", "no"));

    private static final String[] f4688e = {
        "com.vivo.devicereg", "com.vivo.devicereg2", "com.dmclient.debug" };

    private static final String[] f4689f = {
        "com.mobiletools.systemhelper", "com.chinaunicom.registerhelper" };
    ...
}
```

它是被 `VivoDaemonServiceApp`（Application 類）在啟動流程中呼叫的：

```java
void i0() {
    startService(new Intent(this, (Class<?>) AppFilter.class));
}
```

`onStartCommand` 會執行一次 `a()`，然後 `stopSelf()`。也就是說：**每次 daemon 行程啟動，它就跑一次**。

---

## 3. 決策邏輯

`a()` 先讀四個系統屬性：

```
ro.vivo.op.entry          // 例如 FULL_SC、UNICOM、CTCC
ro.vivo.dm.config         // 例如 CMCC-CTCC-UNICOM；未設定時為 NONE
ro.vivo.product.overseas  // yes / no
ro.product.customize.bbk  // 例如 CN-YD
```

然後把它們分成兩份清單：`enable` 與 `disable`：

```java
if ("NONE".equals(dmConfig)) {
    if (customize.contains("CN-YD") || opEntry.contains("CTCC")) {
        enable.addAll(f4688e);   disable.addAll(f4689f);
    } else if (opEntry.contains("UNICOM")) {
        enable.addAll(f4689f);   disable.addAll(f4688e);
    } else if (opEntry.contains("FULL")) {
        enable.addAll(f4688e);   enable.addAll(f4689f);
    } else { ... }
} else if (dmConfig.contains("UNICOM")) {
    enable.addAll(f4689f);
} else {
    disable.addAll(f4689f);
}

if (overseas) {                    // 海外機覆寫
    enable.clear();  enable.addAll(f4688e);
    disable.clear(); disable.addAll(f4689f);
}
```

最後套用：

```java
for (String pkg : enable)  setApplicationEnabledSetting(pkg, 1, 0);  // ENABLED
for (String pkg : disable) setApplicationEnabledSetting(pkg, 2, 0);  // DISABLED
```

在受測裝置上：

```
ro.vivo.dm.config        = CMCC-CTCC-UNICOM
ro.vivo.op.entry         = FULL_SC
ro.vivo.product.overseas = no
```

因為 `dm.config` 不是 `NONE` 且包含 `UNICOM`，直接進入第二個分支：
**`com.mobiletools.systemhelper` 被放進 enable 清單**。

值得注意的是，同一段程式在 `ro.vivo.product.overseas=yes` 時會**反過來把它停用**。
這說明「必須啟用」不是技術限制，而是這批產品的政策選擇。

---

## 4. 開機時序

```
system_server
  └─ 啟動 com.vivo.daemonService 行程
       └─ VivoDaemonServiceApp.onCreate
            └─ ... i0()
                 └─ startService(AppFilter)
                      └─ AppFilter.onStartCommand → a()
                           ├─ 讀 ro.vivo.dm.config 等屬性
                           ├─ 組出 enable / disable 清單
                           ├─ setApplicationEnabledSetting(systemhelper, ENABLED, 0)
                           └─ stopSelf()
```

`dumpsys package` 中的 `lastDisabledCaller: com.vivo.daemonService` 也印證了這個行程確實會在執行期改寫套件的 enabled 狀態。

---

## 5. 為什麼每一種手段會失效（或不失效）

### 停用：被直接覆寫

`setApplicationEnabledSetting(pkg, 1, 0)` 的第二個參數 1 是 `COMPONENT_ENABLED_STATE_ENABLED`。
這個呼叫不檢查「使用者是否明確停用」，也不看 `disabled-user` 這個狀態 —— 它就是把狀態設回啟用。
所以不論你之前用 `pm disable-user` 設成什麼，開機一次就被蓋掉。

### 卸載：不是 AppFilter 做的

`setApplicationEnabledSetting` 對「未安裝」的套件只會丟 `IllegalArgumentException`，程式碼有 catch 並記錄
`is package: ... installed ?`。所以重新安裝不是這一段做的。

觀察到重開機後套件回到 `installed=true`，候選機制有兩個：

1. `PackageManagerService` 在開機時把「系統分區存在、但被對使用者卸載」的套件重新註冊；
2. daemon 內另一條路徑（APK 內確實有 `preinstall` 相關字串）。

本次沒有把兩者隔離驗證，因此只陳述「重開機後會被重新註冊」，不指定單一呼叫者。

### 暫停：狀態在開機時被清掉

`pm suspend` 設定的是套件的 suspended 狀態。實測重開機後 `suspended=false`。
這與 AppFilter 無關 —— AppFilter 只碰 enabled 狀態；比較可能是系統在開機時重置了暫停狀態。

### 撤權限與 AppOps：沒有人碰

runtime 權限存在 `runtime-permissions.xml`，AppOps 存在 `appops.xml`。
`setApplicationEnabledSetting` 不會動這兩份資料，daemon 也沒有對應的呼叫。
所以這兩個變更跨重開機保留 —— 這是目前唯一穩定的收緊手段。

### 只停用 AppFilter 元件：shell 被拒絕

理論上只要讓 `startService(AppFilter)` 失敗，就不會被還原。但：

```
pm disable com.vivo.daemonService/com.vivo.daemonService.operator.AppFilter
→ SecurityException: Shell cannot change component state ...
```

Android 16 只允許 shell 改「套件層級」狀態，不允許改其他 App 的「元件層級」狀態。
所以這條路在不 root 的前提下走不通。

---

## 6. 小結

| 手段 | 被誰破解 | 機制 |
|---|---|---|
| 停用 | AppFilter | 開機時 `setApplicationEnabledSetting(ENABLED)`，無條件覆寫 |
| 卸載 | 系統或 daemon（未隔離） | 開機時重新註冊系統套件 |
| 暫停 | 系統 | 開機時清除 suspended 狀態 |
| 停用元件 | Android 權限模型 | shell 無權改元件狀態 |
| 撤權限／AppOps | 沒有人 | 狀態存在另一份資料，daemon 不碰 |

因此在不 root 的前提下，可持續的策略只有兩個：

1. **每次開機後重新套用**（App 的「重新連線」或 Windows 工具的一鍵停用）；
2. **撤權限 + AppOps**，作為跨開機仍然有效的第二層。

---

## 附錄：觀察到的屬性與輸出

```
ro.vivo.dm.config        = CMCC-CTCC-UNICOM
ro.vivo.op.entry         = FULL_SC
ro.vivo.product.overseas = no
ro.product.customize.bbk = N
```

```
# 停用後、重開機前
enabled=3   (disabled-user)

# 重開機後
enabled=1   (enabled)
```
