# 收緊預裝元件的權限與網路

本文整理在**沒有 root、沒有解鎖 bootloader** 的前提下，Slate 能對
`com.mobiletools.systemhelper`、`com.vivo.devicereg` 這類預裝元件做到的收緊程度與邊界。

## 1. Runtime 權限（ON = 允許）

Slate 的權限開關直接對應 `pm grant` / `pm revoke`：

- ON：已授予（`pm grant`）
- OFF：已撤銷（`pm revoke`）
- 狀態即時用 `PackageManager.checkPermission` 讀取
- 可撤：定位、`READ_PHONE_STATE`、SMS、聯絡人、日曆、相機、麥克風、儲存、藍牙掃描／連線
- 不可撤：`INTERNET`、`QUERY_ALL_PACKAGES`、`READ_PRIVILEGED_PHONE_STATE`、`PACKAGE_USAGE_STATS`
  等 install-time／signature／privileged 權限

撤銷前 Slate 會把「當下已授予的 dangerous 權限」存成快照，還原時只 grant 快照裡的項目。

## 2. AppOps

`cmd appops set <pkg> <op> ignore` 可以攔截部分沒有 runtime 開關的能力：

- `GET_USAGE_STATS`：`UsageStatsManager`／`NetworkStatsManager` 查詢回空
- 定位、電話狀態、SMS、藍牙等 op 也可設 `ignore`

AppOps 是可逆的，且不受 vivo daemon 的套件啟用狀態影響。

## 3. netpolicy（計量網路的背景流量）

```bash
cmd netpolicy add restrict-background-blacklist <uid>
cmd netpolicy list restrict-background-blacklist
```

實測（Android 16 / iQOO 15 Ultra）：

```
cmd netpolicy list restrict-background-blacklist
Restrict background blacklisted UIDs: 10111 10159
```

- `10111` = `com.vivo.devicereg`
- `10159` = `com.mobiletools.systemhelper`

效果是 `REJECT_METERED_BACKGROUND`：**只限制行動數據的背景流量**。
前景、Wi-Fi、未計量網路不受影響。

注意：vivo 的 `dumpsys netpolicy` **不會**印出 `blacklist` 字樣，而是
`UID=<uid> policy=1 (REJECT_METERED_BACKGROUND)`；查詢請用
`cmd netpolicy list restrict-background-blacklist`，不要用 `dumpsys | grep blacklist`。

## 4. 完整封鎖（前景＋Wi-Fi＋行動數據）

非 root 下只有一條路：本機 VPN。

Slate 的「網路封鎖（VPN）」用 `VpnService` 只把指定 App 的流量導入隧道並丟棄：

- 同時封鎖行動數據、Wi-Fi、前景與背景
- 其他 App 不受影響
- 需要使用者同意 VPN 權限
- **會佔用系統唯一的 VPN 通道**

### 與代理的衝突

Android 一次只能有一個 VPN。若平常使用 Clash／v2ray／WireGuard 等代理：

- 啟用 Slate VPN 會讓代理斷線
- 要恢復代理必須重新啟動代理 App
- 因此 Slate 的 VPN **預設關閉、不會自動啟動**，且啟用前會警告

如果一定要同時保留代理，只能：

1. 用代理 App 自己的 per-app 規則封鎖這兩個 App（VPN 由代理佔用）
2. 或 root 後用 `iptables -m owner --uid-owner <uid>`，不需要 VPN

## 5. Android 16 的 shell 限制

- shell 可以改「套件層級」狀態（`pm disable-user`、`pm enable`）
- shell **不能**改其他 App 的「元件層級」狀態：

```
SecurityException: Shell cannot change component state for
ComponentInfo{...RegisterHelperService} to 3
```

所以無法只停用 SystemHelper 那個沒有權限保護的 Binder service；
非 root 只能停用整個套件（會停止電信註冊），或接受它可被任何 App 改寫。

## 6. 上報位址

SystemHelper 的 AIDL 只有 setter（transaction 5），沒有 getter；私有
SharedPreferences 也讀不到（`run-as` 不適用非 debuggable App）。
Slate 只能顯示「自己上次寫入的值」與時間，並提供重新套用；
無法偵測其他 App 是否改過。

## 7. 相關連結

- Slate 原始碼與 Releases：<https://github.com/ivankwanpn/slate-fork>
- 研究報告：<https://github.com/ivankwanpn/slate>
- DeviceReg 上報分析：[DEVICEREG.md](DEVICEREG.md)
