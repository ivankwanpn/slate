# `com.vivo.devicereg` 上報功能分析

研究樣本：`com.vivo.devicereg` 5.4.0.0（vivo OriginOS 內建的電信商 DM 元件，平台簽章）。
本文只討論「上報」，把電信註冊／APN／SMS／IMS 視為另一個功能面。

## 控制鏈

```
vivo 統一配置（content://com.vivo.abe.unifiedconfig.provider/standard_config）
  ├─ dm_switch_cmcc
  ├─ dm_switch_cmcc_appInfo ──► DMSDK.setReportApp(...)
  └─ dm_switch_ctcc
                │
                ▼
電信商 whitelistconfig（CMCC 下發）
  └─ wifi / preInstalledApp / appInfo / network / flowcollect /
     bluetooth / batteryCharging / internationalRoaming / photoReg /
     businessInfo / logReport / keepAlive
                │  解析 JSON
                ▼
SharedPreferences「config_dm」裡的 key_*_switch
```

`switchCheck()` 的規則：空字串＝關，只有 `"Y"`（不分大小寫）＝開。

## 上報清單與預設值

| 上報 | 開關 key | 預設 | 端點 |
|---|---|---|---|
| 應用清單＋使用時長＋流量 | `APP_REPORT_SWITCH` | 關 | `/accept/sdkService?func=tsdk:postapplylog` |
| 預裝應用清單 | `key_pre_installed_report_switch` | 關 | `/accept/preInstalledApp?` |
| 分時流量 | `KEY_TIME_RELATED_TRAFFIC_SWITCH` | 關 | `/accept/flowCollectService?func=tsdk:flowcollect` |
| Wi-Fi 清單 | `key_wifi_list_report_switch` | 開 | `/accept/wifiInfo?` |
| 基地台／網路 | `key_network_report_switch` | 開 | `/accept/network?` |
| 藍牙 | `key_bluetooth_report_switch` | 開 | `/accept/bluetooth?...` |
| 充電狀態 | `key_battery_charging_report_switch` | 開 | `/accept/batteryCharging?` |
| 國際漫遊 | `key_roaming_report_switch` | 開 | `/accept/internationalRoaming?` |
| 5G 狀態 | `key_5g_state_report_switch` | 開 | （待確認） |
| 心跳 | `key_heartbeat_switch` | 開 | `/accept/sdkService?func=tsdk:posthblog` |
| 快照／photoReg | `KEY_SANPSHOT_REPORT_SWITCH` | 開 | `auc.fxltsbl.com/...photoReg` |
| 日誌上傳 | `UPLOAD_LOG_FILE_SWITCH` | 關 | `/accept/logReport?` |

`<base>` 預設 `https://a.fxltsbl.com`；`getBaseAcceptUrl()` 會再加 `/accept`。

## 應用資訊 payload

`a$a.a(Context)` 產生：

```
imei1, imei2, imsi1, imsi2, iccid1, iccid2,
totalFlowW, totalFlowD, brand, model,
sdkVersion, sendTime, startTime, endTime,
logAppAry
```

`logAppAry` 每行（`|` 分隔）：

```
套件名 | 前景使用時間 | 啟動次數 | 首次時間 | 最後時間 |
App 標籤 | 版本/更新時間 | 行動網路 rx | 行動網路 tx |
Wi-Fi rx | Wi-Fi tx
```

採集來源：`PackageManager.getInstalledPackages`、`UsageStatsManager.queryAndAggregateUsageStats`、
`NetworkStatsManager`。回報前檢查 `APP_REPORT_SWITCH == "Y"` 與 `DMSDK.isReportApp()`。

## 分時流量 DB

`table_of_time_related_traffic` 每筆包含：

```
_timestamp, start_time,
_iccid1, _iccid2, _imsi1, _imsi2,
_lac1, _cellid1, _lac2, _cellid2,
collect_Day, day_hour, net_type1, net_type2,
total_flow_wifi, total_flow_now_data, total_flow_now_data2,
router_mac, router_ip
```

## 重點

- 應用清單／使用時長／流量、預裝清單、分時流量**預設關閉**，需電信商 whitelistconfig 開啟。
- Wi-Fi、基地台、藍牙、充電、漫遊、5G、心跳**預設開啟**。
- 這些開關由電信商／vivo 雲端控制，本機沒有 UI 可改。
- 非 root 無法直接讀取其實際開關值；Slate 只能依預設值與記錄推測。

## 相關工具

- Slate（Android）：<https://github.com/ivankwanpn/slate-fork>
- 權限／網路限制與限制邊界：[HARDENING.md](HARDENING.md)
