# 如何驗證

這份文件把報告中的每一項結論，對應到可以重現的指令。
所有指令都假設你已經用 USB 連接裝置、開啟 USB 偵錯，且 `adb devices` 能看到裝置。

> 先讀完再做。除了標明「唯讀」的章節，其餘都會改變裝置狀態；每一項都有對應的回滾指令。
> 請只在你自己持有並授權的裝置上操作。

---

## 0. 前置

```
adb devices -l
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
```

後面用 `<pkg>` 代表 `com.mobiletools.systemhelper`。

---

## 1. 確認元件存在與目前狀態（唯讀）

```
adb shell pm list packages --user 0 <pkg>
adb shell pm path <pkg>
adb shell dumpsys package <pkg> | grep -E "versionName|User 0:|firstInstallTime"
adb shell pm list packages -U <pkg>          # 取得 UID
adb shell ps -A | grep -i mobiletools        # 是否有行程
adb shell dumpsys alarm | grep -i -c mobiletools
adb shell settings get secure operator_service_improve_plan
```

預期看到：套件存在、`User 0` 那一行有 `enabled=1`、有 UID、可能有行程與鬧鐘。

---

## 2. 權限與 AppOps（唯讀）

```
adb shell dumpsys package <pkg> | grep -E "android.permission.*granted"
adb shell appops get <pkg>
adb shell cmd appops get <pkg> FINE_LOCATION
adb shell cmd appops get <pkg> GET_USAGE_STATS
```

預期：安裝時權限（INTERNET、QUERY_ALL_PACKAGES、READ_PRIVILEGED_PHONE_STATE…）為 `granted=true`；
runtime 權限若曾被撤銷，會是 `granted=false`；AppOps 顯示 `Uid mode: ... ignore`。

---

## 3. 對外開放的元件（唯讀）

需要把 APK 拉回電腦並用 aapt2 解 manifest：

```
adb pull /system/app/SystemHelper/SystemHelper.apk
aapt2 dump xmltree --file AndroidManifest.xml SystemHelper.apk > manifest.txt
```

在 `manifest.txt` 中找：

```
E: service
    A: android:name="...RegisterHelperService"
    A: android:exported=true
```

如果 `exported=true` 但沒有 `android:permission`，代表任何本機應用都能 bind 它。

---

## 4. 網路行為（唯讀，能力有限）

```
adb shell pm list packages -U <pkg>          # 取得 UID，例如 10159
adb shell cat /proc/net/tcp /proc/net/tcp6 | grep " 10159 "
```

預期：多數時間沒有任何連線（元件是週期性上報，不是常駐連線）。

**限制**：這只能看到當下的 TCP socket。看不到 DNS 查詢、看不到已建立又關閉的連線、看不到 TLS 內容。
沒有 root 就無法做完整的流量取證；這是本研究的已知缺口。

---

## 5. 測試「停用」與還原

```
adb shell pm disable-user --user 0 <pkg>
adb shell dumpsys package <pkg> | grep -m1 "User 0:"      # enabled=3
adb shell pm list packages -d | grep mobiletools           # 出現在停用清單
adb reboot
# 等開機完成
adb shell dumpsys package <pkg> | grep -m1 "User 0:"      # 預期 enabled=1（被還原）
```

回滾（若你想先手動還原）：

```
adb shell pm enable <pkg>
```

---

## 6. 測試「對使用者卸載」

```
adb shell pm uninstall -k --user 0 <pkg>
adb shell pm list packages --user 0 <pkg>    # 應為空
adb reboot
adb shell pm list packages --user 0 <pkg>    # 預期又出現
adb shell dumpsys package <pkg> | grep ceDataInode   # 資料目錄通常保留
```

回滾：

```
adb shell cmd package install-existing <pkg>
```

---

## 7. 測試「暫停」

```
adb shell pm suspend --user 0 <pkg>
adb shell dumpsys package <pkg> | grep -m1 "User 0:"   # suspended=true
adb reboot
adb shell dumpsys package <pkg> | grep -m1 "User 0:"   # 預期 suspended=false
```

---

## 8. 測試「撤權限」是否跨開機保留

```
adb shell pm revoke <pkg> android.permission.ACCESS_FINE_LOCATION
adb shell cmd appops set <pkg> FINE_LOCATION ignore
adb reboot
adb shell dumpsys package <pkg> | grep "ACCESS_FINE_LOCATION: granted"   # 預期 granted=false
adb shell cmd appops get <pkg> FINE_LOCATION                              # 預期 Uid mode: ignore
```

這是唯一在實測中跨開機保留的變更。

---

## 9. 驗證 daemon 的還原機制（唯讀）

### 9.1 讀屬性

```
adb shell getprop ro.vivo.dm.config
adb shell getprop ro.vivo.op.entry
adb shell getprop ro.vivo.product.overseas
adb shell getprop ro.product.customize.bbk
```

對照 `AppFilter.a()` 的分支，即可預測該元件會被放進 enable 還是 disable 清單。

### 9.2 反編譯 daemon

```
adb pull /system/app/VivoDaemonService/VivoDaemonService.apk
jadx -d daemon --no-res VivoDaemonService.apk
grep -rn "mobiletools" daemon/sources | head
```

預期找到 `com/vivo/daemonService/operator/AppFilter.java`，內含硬編碼的套件清單。

### 9.3 觀察呼叫痕跡

```
adb shell dumpsys package <pkg> | grep lastDisabledCaller
```

預期看到 `com.vivo.daemonService` —— 代表這個行程在執行期改寫過套件狀態。

---

## 10. 嘗試停用 AppFilter 元件（預期失敗）

```
adb shell pm disable com.vivo.daemonService/com.vivo.daemonService.operator.AppFilter
```

預期：

```
SecurityException: Shell cannot change component state for
ComponentInfo{com.vivo.daemonService/...AppFilter} to 2
```

Android 16 只允許 shell 改套件層級狀態。

---

## 11. 安全與回滾對照表

| 操作 | 回滾 |
|---|---|
| `pm disable-user` | `pm enable` |
| `pm uninstall -k --user 0` | `cmd package install-existing` |
| `pm suspend` | `pm unsuspend` |
| `pm revoke` | 無法一鍵還原，需重新授予 |
| `cmd appops set ... ignore` | `cmd appops set ... default` |
| 重開機 | 不影響資料 |

---

## 12. 已知缺口

- 沒有做完整的封包解密與流量取證（需要 root 或可信任的中間人環境）。
- 卸載後「被重新註冊」的確切呼叫者未隔離驗證（系統 PM 或 daemon，兩者皆有可能）。
- 只在一台裝置、一個系統版本上驗證，結論不保證適用於其他機型。
