# Remove Nahimic

A PowerShell toolkit for the **complete, permanent removal** of Nahimic, A-Volute, Sonic Studio, and A-Studio from Windows, including their tendency to reinstall themselves silently through Windows Update and OEM software.

The toolkit consists of two scripts:

- **`Check-Nahimic.ps1`** — read-only pre-check, run this first
- **`Remove-Nahimic-EN.ps1`** / **`Rimuovi-Nahimic-ITA.ps1`** — full removal (English and Italian, identical logic)

---

## Background

Nahimic (developed by A-Volute) is audio enhancement software bundled by OEMs such as MSI, ASUS, HP, and others. ASUS ships a similar product under the names **Sonic Studio** and **A-Studio**.

Beyond the installation and persistence issues described below, **Nahimic is simply bad software that degrades audio quality**. It injects Audio Processing Object (APO) layers directly into the Windows WASAPI stack to apply its "enhancements", which in practice means:

- **UI freezes, system-wide stuttering, input lag**, and general interface unresponsiveness caused by driver-level interference and audio stack contention, often noticeable during load spikes or after sleep/wake cycles
- **Crackling, popping, and stuttering audio**, a well-documented side effect of its APO interfering with the audio pipeline, especially noticeable under load or after sleep/wake cycles
- **Distorted sound**, the so-called enhancements (virtual surround, bass boost, equalization) are applied system-wide without asking, making everything sound worse than the raw output from a decent audio driver
- **Conflicts with other audio software**, if you run any DAW, virtual audio cable, or other APO-based tool (Equalizer APO, Peace, DTS Sound Unbound, etc.), Nahimic will fight with it, causing glitches or outright audio failure
- **Increased audio latency**, additional processing stages in the signal chain add latency, which matters for gaming and any real-time audio work

There is no reason to have this software on your system unless an OEM forced it there.

The problem is that this software also:

- installs silently without meaningful user consent
- reinstalls itself after manual deletion, because the driver package remains in the Windows Driver Store
- is re-pushed by Windows Update as a `SoftwareComponent` or `MEDIA` update, even after removal
- cannot be cleanly uninstalled through any official OEM tool
- registers Audio Processing Objects (APOs) that inject into the WASAPI stack, potentially conflicting with other audio software

Simply deleting files or removing it from Programs and Features is not enough. This toolkit handles all of it.

---

## Recommended workflow

```
1. Run Check-Nahimic.ps1       (read-only, shows what is present)
2. If anything is found:
   Run Remove-Nahimic-EN.ps1   (requires Administrator)
3. Reboot
4. Run Check-Nahimic.ps1 again (confirm clean)
```

---

## Check-Nahimic.ps1

A read-only pre-check script. Run it before the removal script to get a full picture of what is present on the system. It does not modify anything.

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | One or more items detected — removal script needed |
| `1` | Nothing found — system is clean |

**What it checks:**

- Win32 uninstall entries
- AppX / Store packages
- Windows services
- Running processes
- Known registry keys
- APO subkeys (`PlaybackSS3Config`, `RecordSS3Config`) under the audio device class
- APO property names in `FxProperties` matching known Nahimic/Sonic GUID
- `AudioEngine\AudioProcessingObjects` registrations in HKCR
- Driver Store entries via `pnputil`
- PnP devices
- Known installation folders and files
- Scheduled tasks

Output is grouped by category and sorted, with a total item count.

---

## What the removal script does

| Step | Action |
|------|--------|
| 0 | Uninstalls Win32 applications via registry `UninstallString` |
| 0b | Removes AppX / Microsoft Store packages (including OEM-provisioned ones) |
| 1 | Stops, disables, and deletes matching Windows services |
| 2 | Kills all related running processes |
| 3 | Deletes known registry keys; backs up the audio device class to a `.reg` file on the Desktop before touching anything |
| 3b | APO cleanup — see details below |
| 4 | Removes drivers from the Windows Driver Store via `pnputil /delete-driver /uninstall /force` |
| 5 | Removes PnP devices via `pnputil /remove-device` |
| 6 | Deletes known installation folders; scans `System32` and `SysWOW64` for leftover files. Uses `takeown` + `icacls` to take ownership before deletion. If a file is locked and cannot be deleted, applies a `Deny FullControl` ACL to `Everyone` and `SYSTEM` as fallback — the file survives physically but cannot be loaded or executed |
| 7 | Removes matching entries from Task Scheduler |
| 8 | Hides pending Windows Update entries via the WUA COM API (`Microsoft.Update.Session`), same effect as the "Hide" button in Windows Update MiniTool, but fully automated |
| 9 | Blacklists Hardware IDs under `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs`, including IDs detected live from PnP devices and hidden WU entries |
| 10 | Creates `NahimicPolicyGuard` scheduled task — runs at every startup as SYSTEM and re-applies the HW ID blacklist. Protects against Windows feature updates (24H2, 25H2, etc.) that can silently reset Group Policy registry keys under `HKLM\SOFTWARE\Policies\...`, which would otherwise allow Nahimic to reinstall itself undetected |

### APO cleanup (step 3b)

Previous approaches to APO cleanup attempted to match Nahimic-related strings against registry value data. This does not work: the values stored under `PlaybackSS3Config`, `RecordSS3Config`, and `FxProperties` are binary **PROPVARIANT** blobs — their `.ToString()` representation is `System.Byte[]`, not a readable string. Pattern matching on them silently fails.

The script solves this differently:

- **`PlaybackSS3Config` and `RecordSS3Config`** are subkeys that exist exclusively for Sonic Studio 3. If SS3 is not installed, they are orphaned garbage. The script deletes them entirely, for every audio device index found under the audio driver class (`0000`, `0001`, etc.), making the cleanup universal regardless of device index.
- **`FxProperties`** is cleaned by matching on the **property name** (a GUID string), not the value. The known Nahimic/Sonic APO GUIDs are listed explicitly.
- **`AudioEngine\AudioProcessingObjects`** in HKCR is cleaned by matching `FriendlyName` and `Copyright` fields, which are readable strings.
- The Windows Audio services (`audiosrv`, `AudioEndpointBuilder`) are stopped before the cleanup and restarted after, so the keys are not held open by the audio engine during deletion.
- If `Remove-Item` fails due to ACL restrictions, the script falls back to `reg.exe delete /f`.
- A `.reg` backup of the entire audio device class is exported to the Desktop before any modification. If anything goes wrong, double-clicking the backup file fully restores the previous state.

### File deletion (step 6)

Before attempting to delete any file or folder, the script calls `takeown /f /r /a` to take ownership and `icacls /grant Administrators:F /t` to ensure write access — bypassing TrustedInstaller protection that would otherwise block deletion.

If a file is still locked (held open by a kernel driver or active process), instead of failing silently the script applies a `Deny FullControl` ACL rule to both `Everyone` and `SYSTEM`. The file cannot be executed, loaded, or read, making it effectively inert until the next reboot in Safe Mode where the driver is not loaded and the file can be cleanly deleted.

### NahimicPolicyGuard (step 10)

Windows feature updates (annual releases like 24H2, 25H2) can reset keys under `HKLM\SOFTWARE\Policies\...`, silently removing the Hardware ID blacklist and allowing Nahimic to reinstall on the next Windows Update cycle. The `NahimicPolicyGuard` scheduled task runs at every startup as SYSTEM and re-writes the blacklist entries, ensuring the block survives feature updates. The task is idempotent and never adds duplicate entries.

---

## Covered software

- **Nahimic** (all versions)
- **A-Volute** (the company behind Nahimic; SoftwareComponent and MEDIA update types)
- **ASUS Sonic Studio** / **Sonic Suite**
- **ASUS A-Studio**
- **NhNotifSys** (Nahimic notification tray component)
- **NahimicAPO** (Audio Processing Object component)
- MSI Dragon Center / One Dragon Center bundled reinstallers

The matching pattern is a single regex variable at the top of each script. You can extend it without touching the rest of the code.

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later (pre-installed on all supported Windows versions)
- **Administrator privileges** for the removal script (`Check-Nahimic.ps1` does not require elevation, but some checks — such as AppX provisioned packages and PnP devices — may return incomplete results without it)

---

## Usage

1. Download both scripts
2. Open PowerShell **as Administrator**
3. If needed, allow script execution:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```
4. Run the pre-check:
   ```powershell
   .\Check-Nahimic.ps1
   ```
5. If anything is found, run the removal script:
   ```powershell
   .\Remove-Nahimic-EN.ps1
   ```
6. Reboot when prompted
7. Run `Check-Nahimic.ps1` again to confirm the system is clean

> **Tip:** If MSI Dragon Center or ASUS Armoury Crate is installed, uninstall it **before** running this script. Both are known to reinstall Nahimic/Sonic Studio as a side effect of their own update mechanisms.

---

## If it comes back

The Hardware ID blacklist (step 9) is the primary permanent block. It prevents Windows PnP and Windows Update from ever reinstalling the driver, including after feature updates.

If the software somehow returns, check:
- Whether MSI Dragon Center / ASUS Armoury Crate / GeForce Experience was reinstalled (they are known reinstallers)
- Whether the WU entries were successfully hidden (verify in Windows Update MiniTool under the "Hidden" tab)
- Whether the `DenyDeviceIDs` registry key survived a Windows feature update

Running the removal script again is safe — it skips anything already absent and will not add duplicate blacklist entries.

---

## What it does NOT touch

- Any audio drivers not matching the target pattern (Realtek, AMD, Intel, etc.)
- ASUS Armoury Crate itself (only its bundled audio components)
- Any scheduled tasks, services, or files outside the known Nahimic/A-Volute/SonicStudio paths
- Windows audio stack configuration beyond the APO registry entries listed above

---

## Credits

Removal procedure originally documented by the community on Reddit. This script automates the full manual process and adds the Windows Update hiding, Hardware ID blacklisting, and binary-safe APO cleanup steps that were missing from existing guides.
