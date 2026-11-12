# PhoneFix Android (M1)

唯讀檢查 App。無 INTERNET、無背景服務、無分析 SDK。

## 建置

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.5.11-hotspot"
cd android
..\tools\gradle-8.11.1\bin\gradle.bat assembleDebug
```

輸出：`app/build/outputs/apk/debug/app-debug.apk`

## 目前功能（M1）

- 掃描名稱含 systemhelper / mobiletools / dmreg / guardprovider / fanzha / fraud 的套件
- 顯示版本、啟用狀態、是否系統 App、UID
- 顯示已授予權限與 exported 元件數量
- 顯示 `operator_service_improve_plan` 的值

## 下一階段

- M2：整合 Shizuku（fork 或依賴），取得 shell 後執行停用/還原
- M3：開機後重套
