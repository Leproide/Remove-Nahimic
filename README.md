# Remove Nahimic

A PowerShell script for the **complete, permanent removal** of Nahimic, A-Volute, Sonic Studio, and A-Studio from Windows — including their tendency to reinstall themselves silently through Windows Update and OEM software.

Available in **English** (`Remove_Nahimic_EN.ps1`) and **Italian** (`Rimuovi_Nahimic_ITA.ps1`). Both files are identical in logic.

---

## Background

Nahimic (developed by A-Volute) is audio enhancement software bundled by OEMs such as MSI, ASUS, HP, and others. ASUS ships a similar product under the names **Sonic Studio** and **A-Studio**.

Beyond the installation and persistence issues described below, **Nahimic is simply bad software that degrades audio quality**. It injects Audio Processing Object (APO) layers directly into the Windows WASAPI stack to apply its "enhancements", which in practice means:

- **Crackling, popping, and stuttering audio** — a well-documented side effect of its APO interfering with the audio pipeline, especially noticeable under load or after sleep/wake cycles
- **Distorted sound** — the so-called enhancements (virtual surround, bass boost, equalization) are applied system-wide without asking, making everything sound worse than the raw output from a decent audio driver
- **Conflicts with other audio software** — if you run any DAW, virtual audio cable, or other APO-based tool (Equalizer APO, Peace, DTS Sound Unbound, etc.), Nahimic will fight with it, causing glitches or outright audio failure
- **Increased audio latency** — additional processing stages in the signal chain add latency, which matters for gaming and any real-time audio work

There is no reason to have this software on your system unless an OEM forced it there.

The problem is that this software also:

- installs silently without meaningful user consent
- reinstalls itself after manual deletion, because the driver package remains in the Windows Driver Store
- is re-pushed by Windows Update as a `SoftwareComponent` or `MEDIA` update, even after removal
- cannot be cleanly uninstalled through any official OEM tool
- registers Audio Processing Objects (APOs) that inject into the WASAPI stack, potentially conflicting with other audio software

Simply deleting files or removing it from Programs and Features is not enough. This script handles all of it.

---

## What the script does

| Step | Action |
|------|--------|
| 0 | Uninstalls Win32 applications via registry `UninstallString` |
| 0b | Removes AppX / Microsoft Store packages (including OEM-provisioned ones) |
| 1 | Stops, disables, and deletes matching Windows services |
| 2 | Kills all related running processes |
| 3 | Deletes registry keys; scans and removes registered APOs from audio driver classes |
| 4 | Removes drivers from the Windows Driver Store via `pnputil /delete-driver /uninstall /force` |
| 5 | Removes PnP devices via `pnputil /remove-device` |
| 6 | Deletes known installation folders; scans `System32` and `SysWOW64` for leftover files |
| 7 | Removes matching entries from Task Scheduler |
| 8 | Hides pending Windows Update entries via the WUA COM API (`Microsoft.Update.Session`) — same effect as the "Hide" button in Windows Update MiniTool, but fully automated |
| 9 | Blacklists Hardware IDs under `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs`, including IDs detected live from PnP devices and hidden WU entries |

---

## Covered software

- **Nahimic** (all versions)
- **A-Volute** (the company behind Nahimic; SoftwareComponent and MEDIA update types)
- **ASUS Sonic Studio** / **Sonic Suite**
- **ASUS A-Studio**
- **NhNotifSys** (Nahimic notification tray component)
- **NahimicAPO** (Audio Processing Object component)
- MSI Dragon Center / One Dragon Center bundled reinstallers

The matching pattern is a single regex variable at the top of the script. You can extend it without touching the rest of the code.

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later (pre-installed on all supported Windows versions)
- **Administrator privileges** (the script will refuse to run without them)

---

## Usage

1. Download `Remove-Nahimic-EN.ps1` (or the Italian version)
2. Open PowerShell **as Administrator**
3. If needed, allow script execution:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```
4. Run the script:
   ```powershell
   .\Remove-Nahimic-EN.ps1
   ```
5. Reboot when prompted

> **Tip:** If MSI Dragon Center or ASUS Armoury Crate is installed, uninstall it **before** running this script. Both are known to reinstall Nahimic/Sonic Studio as a side effect of their own update mechanisms.

---

## If it comes back

The Hardware ID blacklist (step 9) is the primary permanent block — it prevents Windows PnP and Windows Update from ever reinstalling the driver, including after feature updates.

If the software somehow returns, check:
- Whether MSI Dragon Center / ASUS Armoury Crate / GeForce Experience was reinstalled (they are known reinstallers)
- Whether the WU entries were successfully hidden (verify in Windows Update MiniTool under the "Hidden" tab)
- Whether the `DenyDeviceIDs` registry key survived a Windows feature update

Running the script again is safe — it skips anything already absent and will not add duplicate blacklist entries.

---

## What it does NOT touch

- Any audio drivers not matching the target pattern (Realtek, AMD, Intel, etc.)
- ASUS Armoury Crate itself (only its bundled audio components)
- Any scheduled tasks, services, or files outside the known Nahimic/A-Volute/SonicStudio paths
- Windows audio stack configuration beyond the APO registry entries

---

## Credits

Removal procedure originally documented by the community on Reddit. This script automates the full manual process and adds the Windows Update hiding and Hardware ID blacklisting steps that were missing from existing guides.
