# 如果有 root：可以做到什麼

> 這一頁是「假設你有 root」的技術整理，**不是建議**。
> 受測裝置沒有 root、沒有解鎖 bootloader，以下方法都沒有在本機驗證過。

先講清楚三件事：

1. 這台機（vivo，Android 16）在鎖 bootloader 的狀態下沒有可靠的 root 途徑；
   實務上「有 root」幾乎等於「已解鎖 bootloader」。
2. 解鎖 bootloader 會**清除裝置資料**，並可能讓 Play Integrity、銀行 App、支付功能失效。
3. 任何改動系統分區的做法都會在 OTA 後被覆蓋，甚至導致更新失敗。

---

## 方案比較

| 方案 | 效果 | 持久 | 副作用 | 風險 |
|---|---|---|---|---|
| A. 開機腳本重新停用 | 每次開機後停用 | 是（腳本） | 幾乎無 | 低 |
| B. iptables 封鎖 UID | 完全斷網（含硬編碼 IP） | 需腳本重建規則 | 幾乎無 | 低 |
| C. LSPosed hook AppFilter | 從源頭阻止還原 | 是 | 需要 LSPosed | 中 |
| D. resetprop 改 ro.vivo.product.overseas | 讓 AppFilter 主動停用它 | 是（每次開機） | 可能影響其他區域邏輯 | 中 |
| E. 直接刪除 /system 下的 APK | 真正移除 | 直到 OTA | 需要 remount | 高 |
| F. 停用整個 VivoDaemonService | 阻止還原 | 是 | 影響其他 daemon 功能 | 高 |

---

## A. 開機後自動重新停用（最務實）

把腳本放進 Magisk 的 service.d，開機完成後執行一次：

```sh
#!/system/bin/sh
# /data/adb/service.d/99-slate.sh
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
pm disable-user --user 0 com.mobiletools.systemhelper
```

```sh
chmod 755 /data/adb/service.d/99-slate.sh
```

優點：不動系統分區、不改 daemon、OTA 後仍可用。
缺點：只能「每次開機後再關一次」，不是永久移除；停用期間若有程序搶先執行，仍有短暫窗口。

---

## B. 用 iptables 封鎖它的網路

以 UID 為條件，封鎖該應用所有對外流量（含它自己解析的域名與硬編碼 IP）：

```sh
UID=$(pm list packages -U com.mobiletools.systemhelper | sed 's/.*uid://')
iptables  -I OUTPUT -m owner --uid-owner "$UID" -j DROP
ip6tables -I OUTPUT -m owner --uid-owner "$UID" -j DROP
```

規則不會跨重開機保留，放進 service.d 重建：

```sh
#!/system/bin/sh
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
UID=$(pm list packages -U com.mobiletools.systemhelper | sed 's/.*uid://')
iptables  -I OUTPUT -m owner --uid-owner "$UID" -j DROP
ip6tables -I OUTPUT -m owner --uid-owner "$UID" -j DROP
```

這是**唯一能真正阻止它上傳**的手段，因為它不看域名、也不怕改位址。

---

## C. 用 LSPosed hook AppFilter

如果 root 是透過 Magisk + LSPosed，可以寫一個模組，在 AppFilter.a() 或
PackageManager.setApplicationEnabledSetting 上做攔截：

```java
// 概念示意
XposedHelpers.findAndHookMethod(
    "com.vivo.daemonService.operator.AppFilter", lpparam.classLoader, "a",
    new XC_MethodHook() {
        @Override protected void beforeHookedMethod(MethodHookParam param) {
            param.setResult(null);   // 直接跳過整個決策
        }
    });
```

優點：從源頭阻止，不需要每次開機補救。
缺點：需要 LSPosed、需要維護 hook 對應的類名（daemon 更新可能改名）、屬於系統層級的修改。

---

## D. 用 resetprop 讓 AppFilter 自己停用它

前面分析過，AppFilter 在 ro.vivo.product.overseas=yes 時會**停用**這個元件。
Magisk 的 resetprop 可以在開機早期改寫 ro 屬性：

```sh
# /data/adb/post-fs-data.d/99-slate-prop.sh
resetprop ro.vivo.product.overseas yes
```

副作用：其他依賴「是否為海外版」判斷的程式也會跟著改變行為（地區功能、預設設定、部分服務）。
這是一個「用廠商自己的邏輯打敗廠商」的做法，但影響面不限於這個元件，使用前要想清楚。

---

## E. 真正刪除系統分區的 APK

只有在能 remount 系統分區時才做得到：

```sh
adb root
adb disable-verity
adb reboot
adb remount
adb shell rm -rf /system/app/SystemHelper
```

限制：

- 動態分區（super partition）與 AVB 會讓 remount 失敗，通常需要解鎖 bootloader。
- 刪除後套件管理員可能因為掃描失敗而記錄錯誤；OTA 會把檔案放回來。
- 部分機型會因為缺少系統套件而影響電信商功能。

注意：**用 Magisk overlay 替換 APK 通常不可行** —— 系統套件的簽章已記錄在案，
換成不同簽章的 APK 會在掃描時失敗。

---

## F. 停用整個 daemon（不建議）

```sh
pm disable-user --user 0 com.vivo.daemonService
```

可以阻止 AppFilter，但 VivoDaemonService 同時負責主題、雲服務、開機流程等多項工作，
停用後可能出現難以預期的行為。**不建議**。

---

## 建議的組合

如果真的要 root，順序會是：

1. **B（iptables 封鎖）** —— 立即、徹底、副作用最小；
2. **A（開機腳本重新停用）** —— 讓它連執行機會都沒有；
3. 只有在你能承擔 LSPosed 的維護成本時，才考慮 **C**。

E 與 D 都屬於「改動面很大、收益有限」的做法，除非你本來就在維護自己的 ROM。

---

## 與非 root 方案的對照

| 能力 | 非 root | root |
|---|---|---|
| 停用後撐過重開機 | 否（daemon 還原） | 是（腳本或 hook） |
| 完全阻止上傳 | 只能靠撤權限降低採集面 | 是（iptables） |
| 移除系統分區檔案 | 否 | 是，但需要 remount／解鎖 |
| 影響 OTA | 無 | 可能導致更新失敗 |
| 影響保固／Play Integrity | 無 | 可能 |
