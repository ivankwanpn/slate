# Slate — preinstalled component research and management tools

[繁體中文](README.md) · [简体中文](README.zh-CN.md) · **English**

A reverse-engineering study of an Android preinstalled "carrier device management" component, and two tools built on top of it:
a read-only Windows auditor and an Android app (a Shizuku-based fork shipped as a single APK).

The subject is `com.mobiletools.systemhelper` — a China Unicom OMA-DM component preinstalled on some China-market Android phones.
The study used `read-only` methods only: ADB queries, static decompilation, APK analysis, and reverse engineering of a vivo system daemon.
No root, no bootloader unlock, no modification of system partitions.

> All tests were performed on a device owned and authorised by the researcher.
> This document contains no personal identifiers (IMEI, IMSI, ICCID, serial number, MAC address, phone number, IP address).

---

## Download

- **APK (latest v0.3.7)**: [slate-fork Releases](https://github.com/ivankwanpn/slate-fork/releases/latest) (debug-signed, SHA-256 included; [mirror](https://github.com/ivankwanpn/slate/releases/latest))
- **Full source (fork)**: [slate-fork](https://github.com/ivankwanpn/slate-fork)
- This repository: research report, Windows auditor, standalone audit app, patch against upstream

> The `v0.3.7` release in both repositories is the same APK; future builds are published in `slate-fork`.

## Latest

- `com.vivo.devicereg` reporting analysis: [docs/DEVICEREG.md](docs/DEVICEREG.md)
- Hardening boundaries (permissions / AppOps / netpolicy / VPN): [docs/HARDENING.md](docs/HARDENING.md)
- Slate v0.3.7: client-only (official Shizuku), per-permission switches, netpolicy background
  restriction, optional VPN blocking (conflicts with proxy VPNs)

---

## Summary

- The component exists, runs, and schedules itself after boot.
- It reports device and SIM identifiers, cell information, location and the installed-app list to `dm.wo.com.cn:18080` over `plain HTTP`.
- It exposes a `Binder service with no permission protection`; any local app can bind to it and rewrite the report endpoint.
- Disabling, uninstalling for the user, and suspending are all `reverted by the vivo daemon on every boot`. Only permission and AppOps changes survive.
- The restore logic lives in `AppFilter` inside `VivoDaemonService`: it reads `ro.vivo.dm.config` and puts the component on an "enable" list.

---

## Method

1. `Read-only ADB auditing`: `pm list packages`, `dumpsys package`, `appops get`, `dumpsys alarm`, `/proc/net/tcp`, `settings get secure`.
2. `Static analysis`: jadx decompilation, aapt2 manifest dumps, inspection of exported components and permissions.
3. `System component analysis`: decompiling `VivoDaemonService` to locate the restore path.
4. `Behavioural verification`: rebooting after every change and checking package state, permissions, AppOps and processes.
5. `Tooling`: the Windows side drives ADB; the Android side runs `pm` / `cmd appops` through a Shizuku shell channel.

---

## Findings

### 1. Identity

```
package   com.mobiletools.systemhelper
path      /system/app/SystemHelper/SystemHelper.apk
version   3.0.1-20250515 (versionCode 31, targetSdk 33)
size      4,107,356 bytes
```

It holds `READ_PRIVILEGED_PHONE_STATE`, `PACKAGE_USAGE_STATS`, `QUERY_ALL_PACKAGES`, location and boot-receiver permissions,
and contains the string `http://dm.wo.com.cn:18080/register`. The payload is AES-128-ECB encrypted, with the key derived as `MD5(plaintext)`.
(Encryption details come from cross-checking public analyses against this decompilation; this document does not restate details that could be abused.)

### 2. An unprotected Binder

```xml
<service android:name=".service.RegisterHelperService" android:exported="true">
    <intent-filter>
        <action android:name="com.mobiletools.systemhelper.service.IRegisterHelperService" />
    </intent-filter>
</service>
```

No `android:permission` is declared. The AIDL interface exposes five transactions: set the report endpoint, set intervals,
clear preferences, and toggle a debug log. The ability to set the report endpoint means any local app can redirect the data to its own server.

### 3. Who re-enables it at boot

```java
// com.vivo.daemonService.operator.AppFilter
private static final String[] f4689f = {
    "com.mobiletools.systemhelper",
    "com.chinaunicom.registerhelper" };

// started by VivoDaemonServiceApp during app startup
startService(new Intent(this, AppFilter.class));

// onStartCommand, decides from ro.vivo.dm.config / ro.vivo.op.entry
setApplicationEnabledSetting(pkg, 1, 0);  // ENABLED
```

On the test device `ro.vivo.dm.config = CMCC-CTCC-UNICOM`, so the component is force-enabled on every daemon start.

Boot sequence:

```
system_server
  └─ com.vivo.daemonService process starts
       └─ VivoDaemonServiceApp.onCreate
            └─ i0() -> startService(AppFilter)
                 └─ AppFilter.onStartCommand -> a()
                      ├─ read ro.vivo.dm.config / ro.vivo.op.entry / ro.vivo.product.overseas
                      ├─ build enable / disable lists
                      ├─ setApplicationEnabledSetting(systemhelper, 1, 0)   // ENABLED
                      └─ stopSelf()
```

`setApplicationEnabledSetting(pkg, 1, 0)` does not check whether the user explicitly disabled the package, and ignores
the `disabled-user` state — it simply overwrites the state with "enabled". Every `pm disable-user` is therefore overwritten at the next boot.

The same branch `disables` the component when `ro.vivo.product.overseas=yes`, which shows that "must be enabled" is a product policy, not a technical necessity.

How each removal method is defeated, and why permission changes survive, is documented in
[docs/RESTORE-MECHANISM.md](docs/RESTORE-MECHANISM.md).

### 4. Measured results

| Method | Immediate | After reboot | Note |
|---|---|---|---|
| `pm disable-user` | yes | `reverted` | AppFilter force-enables it |
| `pm uninstall -k --user 0` | yes | `reinstalled` | system-partition copy remains |
| `pm suspend` | yes | `cleared` | |
| revoking runtime permissions | yes | `preserved` | survives reboot |
| AppOps set to ignore | yes | `preserved` | survives reboot |
| disabling the AppFilter component | — | — | shell is denied (SecurityException) |

Without root there is no "remove once, permanent" option. The practical strategy is to re-apply after each boot,
with revoked permissions and AppOps as a second layer.

### 5. Other limits

- Install-time permissions (`INTERNET`, `QUERY_ALL_PACKAGES`, `READ_PRIVILEGED_PHONE_STATE`, ...) cannot be revoked with `pm revoke`.
- `cmd firewall` does not exist; `iptables` requires root.
- On Android 16 the shell may change package-level state but not component-level state of other apps.

---

## Reproduction

Every conclusion is mapped to commands in [docs/VERIFY.md](docs/VERIFY.md): from checking package state, permissions and exported
components, to reproducing the disable / uninstall / suspend reverts and decompiling the daemon.

---

## If you have root

The test device was neither rooted nor bootloader-unlocked. [docs/ROOT.md](docs/ROOT.md) documents what root would allow
(boot script re-disable, iptables UID blocking, an LSPosed hook, remount deletion), with the trade-offs, side effects and OTA impact.

---

## Tools

### Slate (Android, single APK)

A fork of Shizuku v13.6.0 with a custom UI and shell channel:

- Home: service state, one-tap connect, scan summary
- Components: matching packages with revoked / permission count / exported count
- Detail: permissions grouped by sensitivity (location / phone / storage / network & system / other), non-revocable system permissions marked
- Actions: disable, enable, uninstall for user, revoke sensitive permissions (per-command results recorded)
- About: summary of this report and known limits

The app obtains an `IShellService` running as shell via `Shizuku.bindUserService`, then runs `pm` / `cmd appops`.
The patch is in `patches/slate-fork.patch` (against Shizuku v13.6.0).

### Windows auditor

`windows/PhoneFix.ps1`: ADB-based GUI and CLI (audit / report / disable / enable / clear / harden / uninstall / restore).
It does not touch system partitions; all actions are reversible except clearing data.

---

## Build

### Android (standalone audit app)

```
cd android-audit
gradle assembleDebug
```

Requirements: JDK 21, Android SDK 35, Gradle 8.11+.

### Slate (fork)

1. clone Shizuku v13.6.0
2. apply `patches/slate-fork.patch`
3. `./gradlew :manager:assembleDebug`

---

## Privacy and ethics

- This repository contains no vendor APKs, decompiled artefacts, device backups or personal data.
- All identifiers (IMEI, IMSI, ICCID, serial, MAC, phone number, IP) have been removed.
- The purpose is to let users understand what runs on their devices and to provide reversible management options.
- Check the legality of such research and publication in your jurisdiction.

## License

- Code and documents written for this repository: MIT
- The Slate fork is based on [Shizuku](https://github.com/RikkaApps/Shizuku) (Apache-2.0); the patch keeps the original license
- The Android audit app depends on [Shizuku-API](https://github.com/RikkaApps/Shizuku-API) (MIT)

## Disclaimer

Provided "as is", without warranty of any kind. Modifying system components carries risk; back up and verify rollback first.
