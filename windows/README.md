# PhoneFix (Windows)

唯讀檢查 + 可逆操作的 ADB 工具，不需要 root。

## 需求

- Windows 10/11
- platform-tools（adb）在 `C:\platform-tools\adb.exe`，或已加入 PATH
- 手機開啟 USB 調試（或無線調試）

## 啟動

雙擊 `run.cmd`，或：

```powershell
pwsh -File .\PhoneFix.ps1
```

## 命令列模式

```powershell
# 檢查
pwsh -File .\PhoneFix.ps1 -Mode audit -Serial <serial>

# 匯出報告
pwsh -File .\PhoneFix.ps1 -Mode report -Serial <serial> -OutFile report.md

# 動作（皆可逆，uninstall 除外需 restore）
pwsh -File .\PhoneFix.ps1 -Mode disable   -Serial <serial>
pwsh -File .\PhoneFix.ps1 -Mode enable    -Serial <serial>
pwsh -File .\PhoneFix.ps1 -Mode clear     -Serial <serial>
pwsh -File .\PhoneFix.ps1 -Mode harden    -Serial <serial>
pwsh -File .\PhoneFix.ps1 -Mode uninstall -Serial <serial>
pwsh -File .\PhoneFix.ps1 -Mode restore   -Serial <serial>
```

## 無線連接

手機開啟「無線調試」→ 取得 `IP:port` → 在 GUI 的 Wi-Fi 欄輸入後按 Connect，或：

```powershell
adb pair <ip>:<pair-port>     # 首次，輸入 6 位碼
adb connect <ip>:<port>
```

## 刪除的語義

`Uninstall for user` 執行 `pm uninstall -k --user 0`：
- 對目前使用者移除，APK 仍在系統分區
- 恢復出廠或 OTA 可能讓它回來 → 再按一次即可
- 還原：`Restore`（`cmd package install-existing`）

真正的「刪除檔案」需要 root 或解 BL，本工具不做。