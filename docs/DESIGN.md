# Slate — Design Notes

## Goal

A single Android app that can audit preinstalled components and perform reversible actions
(disable / uninstall for user / revoke permissions) without a PC, without root, and without
unlocking the bootloader.

## Architecture

The app is a fork of Shizuku (v13.6.0, Apache-2.0). Shizuku provides the hard part: pairing with
the device's own adbd over wireless debugging, starting a shell-uid server, and exposing it to
the app. On top of that we add:

- `PhoneFixActivity` — five screens (Home, Components, Record, Settings, About)
- `ShellService` — an AIDL user service executed as shell, running whitelisted `pm` / `cmd appops` commands
- `ic_slate` — app icon, and a rebranded label

## Flows

1. User enables Wireless debugging in Developer options.
2. Taps "Start service" — Shizuku's own pairing UI handles the handshake.
3. App binds the user service and can execute commands.
4. Scan uses PackageManager only; actions go through the shell service.

## Security posture

- No background service; no network requests of our own.
- Commands are fixed strings built from the selected package name.
- Records live in memory only.

## Known constraints

- Wireless debugging must be re-enabled after every reboot (Android limitation).
- Package-level state changes are reverted by the vendor daemon at boot.
- Install-time permissions cannot be revoked.
- Component-level changes are rejected for shell on Android 16.
