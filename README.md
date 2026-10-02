# Remove-Nahimic

Complete, permanent removal of **Nahimic / A-Volute / Sonic Studio / A-Studio**
on Windows, with an optional permanent block against reinstallation through
Windows Update.

Single bilingual script (English / Italian). It replaces the two previous
divergent scripts (`Remove-Nahimic-EN.ps1`, `Remove-Nahimic-ITA.ps1`).

## What it does

1. Pre-cleanup of any existing *Device Installation Restrictions* policy so
   driver removal can't be blocked by a previous run.
2. Uninstalls Win32 apps (via `UninstallString`) and AppX / provisioned Store
   packages.
3. Stops, disables and deletes related services; kills related processes.
4. Removes registry keys and registered APOs (`SS3Config`, `FxProperties`,
   `AudioProcessingObjects`), after backing up the audio device class to the
   Desktop.
5. Removes drivers from the Driver Store and removes PnP devices.
6. Deletes leftover files and folders (`takeown` + ACL-deny fallback for locked
   files), **with a hard guard that refuses to touch protected system roots**.
7. Removes matching scheduled tasks.
8. Hides pending Nahimic/Sonic Windows Update entries (WUA COM API).
9. *(optional)* Blacklists Hardware IDs and installs the `NahimicPolicyGuard`
   startup task to survive Windows feature updates.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 or PowerShell 7+
- **Administrator** privileges (the script declares `#Requires -RunAsAdministrator`)

## Usage

```powershell
# From an elevated PowerShell prompt, in the script's folder:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Dry run first — shows every action without changing anything:
.\Remove-Nahimic.ps1 -WhatIf

# Full run (language auto-detected from the current UI culture):
.\Remove-Nahimic.ps1

# Force a language:
.\Remove-Nahimic.ps1 -Language it
.\Remove-Nahimic.ps1 -Language en

# One-shot clean WITHOUT the permanent HW-ID block / guard task:
.\Remove-Nahimic.ps1 -SkipBlacklist

# Skip the audio-class registry backup (not recommended):
.\Remove-Nahimic.ps1 -NoBackup
```

### Parameters

| Parameter        | Default | Description                                                        |
|------------------|---------|--------------------------------------------------------------------|
| `-Language`      | `auto`  | `auto` \| `en` \| `it`. `auto` uses the current UI culture.        |
| `-SkipBlacklist` | off     | Clean only; do not apply the permanent block or the guard task.    |
| `-NoBackup`      | off     | Skip the audio-class registry export.                              |
| `-WhatIf`        | —       | Preview every destructive action without performing it.            |
| `-Confirm`       | —       | Prompt before each destructive action.                             |

## Logging

Every run writes a transcript to the Desktop:
`RemoveNahimic_<timestamp>.log`. The audio-class backup (unless `-NoBackup`)
is `AudioClass_backup_<timestamp>.reg`, also on the Desktop.

## Notes on reliability

- Driver enumeration uses `Win32_PnPSignedDriver` (CIM), whose property names
  are locale-invariant, with a `pnputil` text fallback that matches both
  English and Italian field labels. The previous scripts parsed only English
  `pnputil` output and silently matched nothing on localized Windows.
- No global `SilentlyContinue`: each step reports its real outcome, and the
  final summary lists only verified successes.
- The file-deletion guard (`Test-ProtectedPath`) refuses `takeown` / ACL-deny
  on `C:\`, `%SystemRoot%`, `System32`, `SysWOW64`, `Program Files`,
  `ProgramData` and drive roots, so a bad path can't damage the OS.

## Recovery: my Realtek / audio device got blocked by a previous version

Earlier versions could add a real audio-hardware ID (e.g. the Realtek HD Audio
codec) to the deny list, because they harvested `DriverHardwareID` values from
Windows Update "Nahimic" entries — which actually point at the *underlying*
codec. With `DenyDeviceIDsRetroactive=1` that blocks the real driver and you
get *"The installation of this device is forbidden by system policy"* on
Realtek High Definition Audio.

This version fixes the cause (see below), but if a previous run already damaged
your system, clear the policy once:

```powershell
# Elevated PowerShell
Unregister-ScheduledTask -TaskName 'NahimicPolicyGuard' -Confirm:$false -ErrorAction SilentlyContinue
$p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
Set-ItemProperty $p DenyDeviceIDs 0
Set-ItemProperty $p DenyDeviceIDsRetroactive 0
Remove-Item "$p\DenyDeviceIDs" -Recurse -Force -ErrorAction SilentlyContinue
gpupdate /force
```

Then reinstall the Realtek driver (Device Manager → the flagged device →
*Update driver*, or re-run the OEM/Realtek audio package) and reboot. The audio
device class backup written to your Desktop (`AudioClass_backup_*.reg`) can
restore endpoint properties if needed.

### What changed

The deny list is now built through a strict allowlist (`Test-SafeNahimicHwId`):
only unmistakable Nahimic/Sonic **software component** IDs (`SWC\...AID_NAHIMIC`,
`SWC\...AID_SONICSTUDIO`, `ROOT\NAHIMIC*`, `ROOT\SONICSTUDIO`, `ROOT\ASTUDIO`)
are accepted. Any real-hardware enumerator — `HDAUDIO\`, `PCI\`, `ACPI\`,
`USB\`, `HID\`, `SWD\` — is hard-rejected and logged, so the physical sound
card can never be blocked.

## Reverting the permanent block

If you ran without `-SkipBlacklist` and later want to allow the drivers again:

```powershell
Unregister-ScheduledTask -TaskName 'NahimicPolicyGuard' -Confirm:$false
$p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
Set-ItemProperty $p DenyDeviceIDs 0
Set-ItemProperty $p DenyDeviceIDsRetroactive 0
Remove-Item "$p\DenyDeviceIDs" -Recurse -Force
gpupdate /force
```

## License

This project is licensed under the **GNU General Public License v3.0**
(GPL-3.0). See the `LICENSE` file for the full text.

## Author

[https://github.com/Leproide](https://github.com/Leproide)
