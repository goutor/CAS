# Codex Account Switcher (Windows)

Local account switcher for the Codex desktop app on Windows.

## What It Does

- Saves current Codex login into a named profile.
- Switches between saved profiles.
- Keeps `~/.codex/auth.json` in sync per profile.
- Copies browser session data from Codex app data (cookies/local storage/session storage) to keep full login state.

Profiles are stored locally in:

`~/.codex-account-switcher/profiles`

## Desktop EXE (Recommended)

Build and run native `exe`:

```powershell
.\build-app.ps1
.\dist\CodexAccountSwitcher.exe
```

Or double-click:

- `Windows\Codex Account Switcher.cmd`

The app is now a compiled WinForms executable (not a PowerShell UI script).

The UI supports:

- login flow for new profile;
- save current session into profile;
- switch/rename/delete profiles;
- open profiles folder;
- auto-detect successful login and save pending profile.

## Session Safety

- Existing saved profiles are never deleted on startup.
- Current active profile is refreshed before switching/login flow, so latest cookies/tokens are preserved.
- Deletion happens only if you explicitly press `Delete` and confirm.

## CLI Quick Start

Run PowerShell in this folder and execute:

```powershell
.\scripts\codex-account-switcher.ps1 help
```

If script execution is blocked:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codex-account-switcher.ps1 help
```

First-time flow:

1. Sign in to Codex manually as account #1.
2. Save it:
```powershell
.\scripts\codex-account-switcher.ps1 save my
```
3. Sign in to Codex manually as account #2.
4. Save it:
```powershell
.\scripts\codex-account-switcher.ps1 save brother
```
5. Switch any time:
```powershell
.\scripts\codex-account-switcher.ps1 run
```

## CLI Commands

```powershell
.\scripts\codex-account-switcher.ps1 run
.\scripts\codex-account-switcher.ps1 choose
.\scripts\codex-account-switcher.ps1 switch <profile>
.\scripts\codex-account-switcher.ps1 save <profile>
.\scripts\codex-account-switcher.ps1 list
.\scripts\codex-account-switcher.ps1 status
.\scripts\codex-account-switcher.ps1 help
```

## Notes

- `CODEX_HOME` is supported. If unset, script uses `~/.codex`.
- Session source is auto-detected from common Windows Codex paths:
  - `%APPDATA%\Codex`
  - `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Roaming\Codex`
  - `%LOCALAPPDATA%\Codex`
- Each switch creates an auth backup in:
  - `~/.codex-account-switcher/backups`
