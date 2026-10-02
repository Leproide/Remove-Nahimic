#Requires -RunAsAdministrator
<#
    Remove-Nahimic.ps1

    Complete removal of Nahimic / A-Volute / Sonic Studio / A-Studio and
    prevention of reinstallation via Windows Update.

    Author: https://github.com/Leproide
    Repo:   https://github.com/Leproide/Remove-Nahimic/

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

    .SYNOPSIS
    Removes Nahimic / A-Volute / Sonic Studio / A-Studio and blocks reinstall.

    .DESCRIPTION
    Single bilingual (EN/IT) rewrite of the former two divergent scripts.

    Key differences vs the old scripts:
      - Driver Store enumeration uses Win32_PnPSignedDriver (CIM) instead of
        parsing the LOCALIZED text output of `pnputil /enum-drivers`. The old
        regex on "Published Name" / "Provider Name" silently matched nothing
        on non-English Windows. CIM property names are invariant.
      - No global SilentlyContinue: every risky call is wrapped and its real
        outcome tracked. Success banners only print on verified success.
      - -WhatIf / -Confirm supported for all destructive actions.
      - A hard guard refuses takeown/ACL-deny on protected system paths so a
        bad path can never brick the OS.
      - Start-Transcript logging to the Desktop.

    .PARAMETER Language
    'auto' (default), 'en' or 'it'. 'auto' uses the current UI culture.

    .PARAMETER SkipBlacklist
    Do everything except (re)applying the Hardware ID deny policy and creating
    the NahimicPolicyGuard task. Use for a one-shot clean without the permanent
    block.

    .PARAMETER NoBackup
    Skip the audio-class registry export (not recommended).

    .NOTES
    Requires administrator privileges. A reboot prompt is shown at the end.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('auto', 'en', 'it')]
    [string]$Language = 'auto',

    [switch]$SkipBlacklist,

    [switch]$NoBackup
)

Set-StrictMode -Version Latest
# NOTE: deliberately NOT 'SilentlyContinue' globally. Each call decides.
$ErrorActionPreference = 'Continue'

# ============================================================================
#  Localization
# ============================================================================
if ($Language -eq 'auto') {
    $Language = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'it') { 'it' } else { 'en' }
}

$L = @{
    en = @{
        step_precleanup   = 'Pre-cleanup: clearing any existing device install restrictions'
        step_uninstall    = 'Uninstalling Win32 applications'
        step_appx         = 'Removing AppX / Store packages'
        step_services     = 'Stopping and removing services'
        step_processes    = 'Killing related processes'
        step_regkeys      = 'Removing registry keys'
        step_apo          = 'APO cleanup (direct SS3Config / FxProperties deletion)'
        step_drivers      = 'Removing drivers from Driver Store'
        step_pnp          = 'Removing PnP devices'
        step_files        = 'Deleting files and folders'
        step_tasks        = 'Removing scheduled tasks'
        step_wu           = 'Hiding pending Windows Update entries'
        step_blacklist    = 'Blacklisting Hardware IDs (permanent block)'
        step_guard        = 'Creating NahimicPolicyGuard scheduled task'
        guard_disabled    = 'NahimicPolicyGuard task disabled (will be recreated at the end)'
        restrictions_off  = 'Device installation restrictions disabled (temporarily)'
        denylist_cleared  = 'DenyDeviceIDs list cleared'
        gpo_refreshed     = 'Group Policy refreshed'
        backup_ok         = 'Audio class backed up to: {0}'
        backup_fail       = 'Audio class backup failed (non-fatal)'
        audio_backup_skip = 'Audio class backup skipped (-NoBackup)'
        restart_prompt    = "`nRestart now? (y/N)"
        summary_title     = ' Removal complete: Nahimic / A-Volute / Sonic Studio / A-Studio'
        summary_actions   = ' Actions performed (only verified successes counted):'
        no_drivers        = 'No matching drivers found in Driver Store'
        no_tasks          = 'No matching scheduled tasks'
        no_updates        = 'No pending updates found'
        wu_unavailable    = 'WUA COM API unavailable: {0}'
        wu_manual         = '    Hide the updates manually via Windows Update or Windows Update MiniTool.'
        guard_created     = "Task 'NahimicPolicyGuard' created (runs at startup as SYSTEM)"
        protected_path    = 'REFUSED (protected system path): {0}'
        hwid_rejected     = 'Skipped unsafe HW ID (would block real hardware): {0}'
        transcript        = 'Log: {0}'
    }
    it = @{
        step_precleanup   = 'Pre-pulizia: rimozione restrizioni di installazione dispositivi esistenti'
        step_uninstall    = 'Disinstallazione applicazioni Win32'
        step_appx         = 'Rimozione pacchetti AppX / Store'
        step_services     = 'Arresto e rimozione servizi'
        step_processes    = 'Terminazione processi correlati'
        step_regkeys      = 'Rimozione chiavi di registro'
        step_apo          = 'Pulizia APO (eliminazione diretta SS3Config / FxProperties)'
        step_drivers      = 'Rimozione driver dal Driver Store'
        step_pnp          = 'Rimozione dispositivi PnP'
        step_files        = 'Eliminazione file e cartelle'
        step_tasks        = 'Rimozione attivita pianificate'
        step_wu           = 'Occultamento aggiornamenti Windows Update in sospeso'
        step_blacklist    = 'Blacklist Hardware ID (blocco permanente)'
        step_guard        = 'Creazione attivita pianificata NahimicPolicyGuard'
        guard_disabled    = 'Attivita NahimicPolicyGuard disabilitata (verra ricreata alla fine)'
        restrictions_off  = 'Restrizioni installazione dispositivi disabilitate (temporaneamente)'
        denylist_cleared  = 'Lista DenyDeviceIDs svuotata'
        gpo_refreshed     = 'Criteri di gruppo aggiornati'
        backup_ok         = 'Backup classe audio in: {0}'
        backup_fail       = 'Backup classe audio fallito (non critico)'
        audio_backup_skip = 'Backup classe audio saltato (-NoBackup)'
        restart_prompt    = "`nRiavviare ora? (s/N)"
        summary_title     = ' Rimozione completata: Nahimic / A-Volute / Sonic Studio / A-Studio'
        summary_actions   = ' Azioni eseguite (contate solo quelle riuscite e verificate):'
        no_drivers        = 'Nessun driver corrispondente nel Driver Store'
        no_tasks          = 'Nessuna attivita pianificata corrispondente'
        no_updates        = 'Nessun aggiornamento in sospeso'
        wu_unavailable    = 'API COM WUA non disponibile: {0}'
        wu_manual         = '    Nascondere gli aggiornamenti manualmente tramite Windows Update o Windows Update MiniTool.'
        guard_created     = "Attivita 'NahimicPolicyGuard' creata (esegue all'avvio come SYSTEM)"
        protected_path    = 'RIFIUTATO (percorso di sistema protetto): {0}'
        hwid_rejected     = 'HW ID non sicuro ignorato (bloccherebbe hardware reale): {0}'
        transcript        = 'Log: {0}'
    }
}
$M = $L[$Language]

# ============================================================================
#  Output helpers + verified-action tracking
# ============================================================================
$script:Actions = [ordered]@{}
function Mark { param([string]$Key) $script:Actions[$Key] = $true }

function Write-Step {
    param([string]$T)
    Write-Host "`n[*] $T" -ForegroundColor Cyan
}
function Write-OK {
    param([string]$T)
    Write-Host "    [+] $T" -ForegroundColor Green
}
function Write-Warn {
    param([string]$T)
    Write-Host "    [!] $T" -ForegroundColor Yellow
}
function Write-Skipped {
    param([string]$T)
    Write-Host "    [-] $T" -ForegroundColor DarkGray
}

# ============================================================================
#  Central matching pattern - extend here to widen cleanup scope
# ============================================================================
$TARGET = 'Nahimic|A[-_ ]Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite|NahimicAPO'

# ============================================================================
#  Protected-path guard
#
#  takeown + icacls + Remove-Item (and especially the Deny-FullControl ACL
#  fallback) are destructive. If any $paths entry ever resolved to a system
#  root we could render Windows unbootable. This guard is the safety net the
#  old script lacked: it refuses to operate on anything that is (or contains)
#  a critical OS directory.
# ============================================================================
function Test-ProtectedPath {
    param([string]$Path)

    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        # Unparseable path -> treat as protected (refuse)
        return $true
    }

    $protected = @(
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'SysWOW64'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:windir,
        'C:\',
        $env:SystemDrive
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    # Exact match on a protected root = refuse. A deeper path under it is fine
    # (e.g. System32\A-Volute is allowed, System32 itself is not).
    foreach ($p in $protected) {
        if ($full -ieq $p) { return $true }
    }
    # Also refuse obvious drive roots like "X:"
    if ($full -match '^[A-Za-z]:$') { return $true }

    return $false
}

# ============================================================================
#  Hardware-ID allowlist guard  (fixes the Realtek-block bug)
#
#  Nahimic ships as an APO *software component* (enumerator SWC) or a virtual
#  ROOT device. It rides on top of the real audio codec but is a DISTINCT
#  device. The real sound card is enumerated under HDAUDIO / PCI / ACPI / USB.
#
#  The old script harvested HW IDs from live PnP devices and, worse, from the
#  DriverHardwareID of Windows Update "Nahimic" entries. Those WU entries are
#  APO *extensions* whose DriverHardwareID is the UNDERLYING Realtek codec ID
#  (e.g. HDAUDIO\FUNC_01&VEN_10EC...). Adding that to DenyDeviceIDs with
#  DenyDeviceIDsRetroactive=1 blocks the real Realtek driver -> no audio.
#
#  This guard lets ONLY unmistakable Nahimic/Sonic software IDs into the deny
#  list and hard-rejects every real-hardware enumerator.
# ============================================================================
function Test-SafeNahimicHwId {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }

    # Hard reject: any real audio-hardware enumerator. Blocking these kills
    # the physical sound card (this is the exact bug being fixed).
    if ($Id -match '(?i)^(HDAUDIO|PCI|ACPI|USB|HID|SWD)\\') { return $false }

    # Accept ONLY Nahimic/Sonic software components:
    #   SWC\...AID_NAHIMIC / AID_SONICSTUDIO   (APO software component)
    if ($Id -match '(?i)^SWC\\.*AID_(NAHIMIC|SONICSTUDIO)') { return $true }
    #   ROOT\<nahimic|sonicstudio|astudio|...>  (virtual root enumerations)
    if ($Id -match '(?i)^ROOT\\(NAHIMIC|SONICSTUDIO|ASTUDIO|NahimicBTLink|NahimicXVAD|Nahimic_Mirroring)') { return $true }

    return $false
}

# ============================================================================
#  Start logging
# ============================================================================
$desktop = [Environment]::GetFolderPath('Desktop')
$logFile = Join-Path $desktop ("RemoveNahimic_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
try {
    Start-Transcript -Path $logFile -Force | Out-Null
    Write-Host ($M.transcript -f $logFile) -ForegroundColor DarkGray
} catch {
    Write-Warn "Transcript could not start: $_"
}

# ============================================================================
#  0a. PRE-CLEANUP - disable any pre-existing Device Installation Restrictions
#
#  A previous run may have left DenyDeviceIDsRetroactive=1, which blocks
#  pnputil /delete-driver with "forbidden by system policy". Disable both the
#  guard task and the policy BEFORE touching drivers; section 9/10 re-apply.
# ============================================================================
Write-Step $M.step_precleanup

$preGuard = Get-ScheduledTask -TaskName 'NahimicPolicyGuard' -ErrorAction SilentlyContinue
if ($preGuard) {
    if ($PSCmdlet.ShouldProcess('NahimicPolicyGuard', 'Disable scheduled task')) {
        try {
            Disable-ScheduledTask -TaskName 'NahimicPolicyGuard' -ErrorAction Stop | Out-Null
            Write-OK $M.guard_disabled
        } catch {
            Write-Warn "Could not disable NahimicPolicyGuard: $_"
        }
    }
} else {
    Write-Skipped 'NahimicPolicyGuard task (not found)'
}

$restrictionsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPathPre  = "$restrictionsPath\DenyDeviceIDs"

if (Test-Path $restrictionsPath) {
    if ($PSCmdlet.ShouldProcess($restrictionsPath, 'Disable device install restrictions')) {
        try {
            Set-ItemProperty -Path $restrictionsPath -Name 'DenyDeviceIDs'            -Value 0 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $restrictionsPath -Name 'DenyDeviceIDsRetroactive' -Value 0 -Type DWord -Force -ErrorAction Stop
            if (Test-Path $denyListPathPre) {
                Remove-Item -Path $denyListPathPre -Recurse -Force -ErrorAction Stop
                Write-OK $M.denylist_cleared
            }
            Write-OK $M.restrictions_off
        } catch {
            Write-Warn "Could not disable restrictions: $_"
        }
    }
} else {
    Write-Skipped 'Device installation restrictions key (not found)'
}

if ($PSCmdlet.ShouldProcess('Group Policy', 'gpupdate /force')) {
    & gpupdate.exe /force /target:computer 2>&1 | Out-Null
    Write-OK $M.gpo_refreshed
}

# ============================================================================
#  0b. Uninstall Win32 applications via registry UninstallString
# ============================================================================
Write-Step $M.step_uninstall

$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$uninstalled = 0
foreach ($root in $uninstallRoots) {
    Get-ItemProperty $root -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $TARGET } |
        ForEach-Object {
            $name = $_.DisplayName
            $qstr = if ($_.PSObject.Properties['QuietUninstallString']) { $_.QuietUninstallString } else { $null }
            $ustr = if ($_.PSObject.Properties['UninstallString'])      { $_.UninstallString }      else { $null }
            if (-not $ustr -and -not $qstr) { return }

            Write-Host "    Found: $name" -ForegroundColor Yellow

            $cmdLine = if ($qstr) { $qstr }
                       elseif ($ustr -match 'msiexec') { "$ustr /qn /norestart" }
                       else { "$ustr /S /silent /quiet" }

            if ($PSCmdlet.ShouldProcess($name, 'Uninstall')) {
                try {
                    if ($cmdLine -match '^"([^"]+)"\s*(.*)$') {
                        $exe = $Matches[1]; $arg = $Matches[2]
                    } elseif ($cmdLine -match '^(\S+)\s*(.*)$') {
                        $exe = $Matches[1]; $arg = $Matches[2]
                    } else {
                        $exe = $cmdLine; $arg = ''
                    }
                    if ([string]::IsNullOrWhiteSpace($arg)) {
                        Start-Process -FilePath $exe -Wait -NoNewWindow -ErrorAction Stop
                    } else {
                        Start-Process -FilePath $exe -ArgumentList $arg -Wait -NoNewWindow -ErrorAction Stop
                    }
                    Write-OK "Uninstalled: $name"
                    $uninstalled++
                } catch {
                    Write-Warn "Could not uninstall '$name': $_"
                }
            }
        }
}
if ($uninstalled -gt 0) { Mark 'uninstall' }

# ============================================================================
#  0c. Remove AppX / Store packages
# ============================================================================
Write-Step $M.step_appx

$appxRemoved = 0
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $TARGET -or $_.PackageFullName -match $TARGET } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.Name, 'Remove AppX package')) {
            Write-Host "    Removing AppX: $($_.Name)" -ForegroundColor Yellow
            try {
                Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
                Write-OK "AppX removed: $($_.Name)"
                $appxRemoved++
            } catch {
                Write-Warn "Could not remove AppX '$($_.Name)': $_"
            }
        }
    }

Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $TARGET -or $_.PackageName -match $TARGET } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.DisplayName, 'Remove provisioned AppX')) {
            Write-Host "    Removing provisioned AppX: $($_.DisplayName)" -ForegroundColor Yellow
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                Write-OK "Provisioned AppX removed: $($_.DisplayName)"
                $appxRemoved++
            } catch {
                Write-Warn "Could not remove provisioned AppX '$($_.DisplayName)': $_"
            }
        }
    }
if ($appxRemoved -gt 0) { Mark 'appx' }

# ============================================================================
#  1. Services: stop + disable + delete
# ============================================================================
Write-Step $M.step_services

$servicePatterns = @(
    'NahimicService', 'Nahimic_Mirroring',
    'AVolute*', 'SonicSuite*', 'ASSonicStudio*', 'ASonicStudio*'
)
$svcRemoved = 0
foreach ($pattern in $servicePatterns) {
    Get-Service -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        $svc = $_.Name
        if ($PSCmdlet.ShouldProcess($svc, 'Stop, disable and delete service')) {
            try {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
                $out = & sc.exe delete $svc 2>&1
                # sc.exe returns [SC] DeleteService SUCCESS on success; verify.
                Start-Sleep -Milliseconds 200
                if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
                    Write-OK "Service '$svc' stopped and removed"
                    $svcRemoved++
                } else {
                    Write-Warn "Service '$svc' still present after delete: $out"
                }
            } catch {
                Write-Warn "Could not remove service '$svc': $_"
            }
        }
    }
}
if ($svcRemoved -gt 0) { Mark 'services' }

# ============================================================================
#  2. Processes: kill
# ============================================================================
Write-Step $M.step_processes

$processPatterns = @(
    'NahimicSvc*', 'NahimicService*', 'A-Volute*', 'AVS*', 'NhNotifSys*',
    'MSICenter*', 'MSI*Dragon*', 'DragonCenter*', 'OneDragonCenter*',
    'SonicStudio*', 'SonicSuite*', 'ASSonicStudio*', 'ASonicStudio*',
    'A-Studio*', 'AStudio*'
)
$procKilled = 0
foreach ($pattern in $processPatterns) {
    $procs = Get-Process -Name $pattern -ErrorAction SilentlyContinue
    if ($procs) {
        if ($PSCmdlet.ShouldProcess($pattern, 'Stop process')) {
            try {
                $procs | Stop-Process -Force -ErrorAction Stop
                Write-OK "Process '$pattern' terminated"
                $procKilled++
            } catch {
                Write-Warn "Could not stop '$pattern': $_"
            }
        }
    }
}
if ($procKilled -gt 0) { Mark 'processes' }

# ============================================================================
#  3. Registry: key deletion
# ============================================================================
Write-Step $M.step_regkeys

$audioClassKeyRaw = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'

if (-not $NoBackup) {
    $backupFile = Join-Path $desktop ("AudioClass_backup_{0}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($PSCmdlet.ShouldProcess($audioClassKeyRaw, 'Export registry backup')) {
        & reg.exe export $audioClassKeyRaw $backupFile /y 2>&1 | Out-Null
        if (Test-Path $backupFile) {
            Write-OK ($M.backup_ok -f $backupFile)
            Mark 'backup'
        } else {
            Write-Warn $M.backup_fail
        }
    }
} else {
    Write-Skipped $M.audio_backup_skip
}

$regKeys = @(
    'HKLM:\SYSTEM\CurrentControlSet\Services\NahimicService',
    'HKLM:\SYSTEM\CurrentControlSet\Services\Nahimic_Mirroring',
    'HKCU:\SOFTWARE\A-Volute',
    'HKLM:\SOFTWARE\A-Volute',
    'HKLM:\SOFTWARE\WOW6432Node\A-Volute',
    'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\NahimicService',
    'HKLM:\SOFTWARE\ASUS\ASUS Sonic Studio',
    'HKLM:\SOFTWARE\WOW6432Node\ASUS\ASUS Sonic Studio',
    'HKCU:\SOFTWARE\ASUS\SonicStudio',
    'HKLM:\SOFTWARE\ASUS\A-Studio',
    'HKCU:\SOFTWARE\ASUS\A-Studio',
    'HKLM:\SOFTWARE\ASUSTeK Computer Inc.\ASUS Sonic Studio'
)
$regRemoved = 0
foreach ($key in $regKeys) {
    if (Test-Path $key) {
        if ($PSCmdlet.ShouldProcess($key, 'Remove registry key')) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-OK "Key removed: $key"
                $regRemoved++
            } catch {
                Write-Warn "Could not remove key '$key': $_"
            }
        }
    } else {
        Write-Skipped "$key (not found)"
    }
}
if ($regRemoved -gt 0) { Mark 'regkeys' }

# ============================================================================
#  3b. APO cleanup - direct deletion of SS3Config / FxProperties subkeys
#
#  SS3Config blobs are binary PROPVARIANTs; we delete the whole subkey.
#  FxProperties entries are matched by VALUE NAME (known APO GUIDs).
# ============================================================================
Write-Step $M.step_apo

$audioClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$ss3Subkeys    = @('PlaybackSS3Config', 'RecordSS3Config')

$knownApoPropertyGuids = @(
    '9B8844FE-1650-40E5-A5EA-11B8C83821A1',
    'F363DF17-A750-4AC3-B7B5-2BBEFFA9085F',
    'E0F2C10F-8244-476E-8EBE-B6EE73D8F2FB',
    'D3465FC4-DB6D-4796-8FDE-0CB851BE2EC9'
)
$apoGuidPattern = '(?i)^\{(' + ($knownApoPropertyGuids -join '|') + ')\}'

$apoChanged = 0
$audioServicesStopped = $false
if ($PSCmdlet.ShouldProcess('AudioEndpointBuilder, audiosrv', 'Stop audio services')) {
    Write-Host "    Stopping audio services..." -ForegroundColor DarkGray
    try {
        Stop-Service 'AudioEndpointBuilder', 'audiosrv' -Force -ErrorAction Stop
        $audioServicesStopped = $true
    } catch {
        Write-Warn "Could not stop audio services (registry keys may be locked): $_"
    }
}

if (Test-Path $audioClassKey) {
    Get-ChildItem -Path $audioClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            $devIndex = $_.PSChildName
            $devPath  = $_.PSPath

            foreach ($ss3 in $ss3Subkeys) {
                $ss3Path    = Join-Path $devPath "InterfaceSetting\$ss3"
                $ss3PathRaw = "$audioClassKeyRaw\$devIndex\InterfaceSetting\$ss3"
                if (Test-Path $ss3Path) {
                    if ($PSCmdlet.ShouldProcess($ss3PathRaw, 'Remove SS3Config subkey')) {
                        Remove-Item -Path $ss3Path -Recurse -Force -ErrorAction SilentlyContinue
                        if (Test-Path $ss3Path) {
                            & reg.exe delete $ss3PathRaw /f 2>&1 | Out-Null
                        }
                        if (Test-Path $ss3Path) {
                            Write-Warn "Could not remove (ACL?): $ss3PathRaw"
                        } else {
                            Write-OK "Deleted: $devIndex\InterfaceSetting\$ss3"
                            $apoChanged++
                        }
                    }
                }
            }

            $fxPath = Join-Path $devPath 'FxProperties'
            if (Test-Path $fxPath) {
                $props = Get-ItemProperty -Path $fxPath -ErrorAction SilentlyContinue
                if ($props) {
                    foreach ($prop in $props.PSObject.Properties) {
                        if ($prop.Name -like 'PS*') { continue }
                        if ($prop.Name -match $apoGuidPattern) {
                            if ($PSCmdlet.ShouldProcess("$devIndex\FxProperties\$($prop.Name)", 'Remove FxProperties value')) {
                                try {
                                    Remove-ItemProperty -Path $fxPath -Name $prop.Name -Force -ErrorAction Stop
                                    Write-OK "FxProperties entry removed: $devIndex \ $($prop.Name)"
                                    $apoChanged++
                                } catch {
                                    Write-Warn "Could not remove FxProperties value '$($prop.Name)': $_"
                                }
                            }
                        }
                    }
                }
            }
        }
} else {
    Write-Skipped 'Audio class key not found'
}

# HKLM AudioProcessingObjects registrations
$apoRegPaths = @(
    'HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects',
    'HKLM:\SOFTWARE\Classes\WOW6432Node\AudioEngine\AudioProcessingObjects'
)
foreach ($ar in $apoRegPaths) {
    if (-not (Test-Path $ar)) { continue }
    Get-ChildItem -Path $ar -ErrorAction SilentlyContinue | ForEach-Object {
        $friendly  = (Get-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -ErrorAction SilentlyContinue).FriendlyName
        $copyright = (Get-ItemProperty -Path $_.PSPath -Name 'Copyright'    -ErrorAction SilentlyContinue).Copyright
        if (($friendly -and $friendly -match $TARGET) -or ($copyright -and $copyright -match $TARGET)) {
            if ($PSCmdlet.ShouldProcess($_.PSChildName, 'Remove APO registration')) {
                try {
                    Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                    Write-OK "APO registration removed: $($_.PSChildName) ($friendly)"
                    $apoChanged++
                } catch {
                    Write-Warn "Could not remove APO registration '$($_.PSChildName)': $_"
                }
            }
        }
    }
}

# Restart audio services only if we stopped them
if ($audioServicesStopped) {
    Write-Host "    Restarting audio services..." -ForegroundColor DarkGray
    $r1 = $false; $r2 = $false
    try { Start-Service 'AudioEndpointBuilder' -ErrorAction Stop; $r1 = $true } catch { Write-Warn "AudioEndpointBuilder restart failed: $_" }
    try { Start-Service 'audiosrv'             -ErrorAction Stop; $r2 = $true } catch { Write-Warn "audiosrv restart failed: $_" }
    if ($r1 -and $r2) { Write-OK 'Audio services restarted' }
}
if ($apoChanged -gt 0) { Mark 'apo' }

# ============================================================================
#  4. Driver Store: removal via CIM (language-independent) + pnputil
#
#  OLD BUG: parsed localized `pnputil /enum-drivers` text ("Published Name",
#  "Provider Name") which is translated on non-English Windows, so nothing
#  matched. We now enumerate via Win32_PnPSignedDriver whose property names
#  are invariant, map to the OEM INF, and delete with pnputil by INF name.
# ============================================================================
Write-Step $M.step_drivers

$infFiles = New-Object System.Collections.Generic.HashSet[string]

# Primary: CIM. InfName gives us oemNN.inf directly; match on provider /
# device / driver-provider-name fields (all invariant property names).
try {
    Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object {
            ($_.DeviceName         -and $_.DeviceName         -match $TARGET) -or
            ($_.DriverProviderName -and $_.DriverProviderName -match $TARGET) -or
            ($_.FriendlyName       -and $_.FriendlyName       -match $TARGET) -or
            ($_.InfName            -and $_.InfName            -match $TARGET)
        } |
        ForEach-Object {
            if ($_.InfName -and $_.InfName -match '^(oem\d+\.inf)$') {
                [void]$infFiles.Add($Matches[1])
            }
        }
} catch {
    Write-Warn "CIM driver enumeration failed, falling back to pnputil parse: $_"
}

# Fallback: parse pnputil for both EN and IT field labels, in case CIM missed
# a driver that is in the store but not bound to a present device.
$pnputilFieldRegex = 'Published Name|Nome pubblicato'
$providerRegex     = 'Provider Name|Nome provider|Fornitore'
$originalRegex     = 'Original Name|Nome originale'

$driverList = & pnputil /enum-drivers 2>&1
$currentInf = $null
foreach ($line in $driverList) {
    if ($line -match "($pnputilFieldRegex)\s*:\s*(oem\d+\.inf)") {
        $currentInf = $Matches[2]
        continue
    }
    if ($currentInf) {
        if ($line -match "($providerRegex)\s*:\s*.*($TARGET)" -or
            $line -match "($originalRegex)\s*:\s*\S*($TARGET)\S*") {
            [void]$infFiles.Add($currentInf)
            $currentInf = $null
        }
    }
}

if ($infFiles.Count -eq 0) {
    Write-Skipped $M.no_drivers
} else {
    $drvRemoved = 0
    foreach ($inf in $infFiles) {
        if ($PSCmdlet.ShouldProcess($inf, 'Delete driver from Driver Store')) {
            Write-Host "    Force-removing: $inf" -ForegroundColor Yellow
            $pnpOut = & pnputil /delete-driver $inf /uninstall /force 2>&1
            $pnpOut | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }

            # Localized success/failure: don't trust text. Re-check presence.
            Start-Sleep -Milliseconds 200
            $still = & pnputil /enum-drivers 2>&1 | Select-String -SimpleMatch $inf
            if ($pnpOut -match 'forbidden by system policy') {
                Write-Warn "Driver $inf still blocked by an external policy."
                Write-Warn "Check HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall"
                Write-Warn "and any domain-pushed Group Policy, then re-run this script."
            } elseif ($still) {
                Write-Warn "Driver $inf still present in the store after delete."
            } else {
                Write-OK "Driver $inf removed"
                $drvRemoved++
            }
        }
    }
    if ($drvRemoved -gt 0) { Mark 'drivers' }
}

# ============================================================================
#  5. PnP devices: removal
# ============================================================================
Write-Step $M.step_pnp
$pnpRemoved = 0
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FriendlyName, 'Remove PnP device')) {
            Write-Host "    Removing: $($_.FriendlyName) [$($_.InstanceId)]" -ForegroundColor Yellow
            $o = & pnputil /remove-device "$($_.InstanceId)" 2>&1
            Start-Sleep -Milliseconds 150
            $gone = -not (Get-PnpDevice -InstanceId $_.InstanceId -ErrorAction SilentlyContinue)
            if ($gone) {
                Write-OK "Device removed: $($_.FriendlyName)"
                $pnpRemoved++
            } else {
                Write-Warn "Device may still be present: $($_.FriendlyName) ($o)"
            }
        }
    }
if ($pnpRemoved -gt 0) { Mark 'pnp' }

# ============================================================================
#  6. File system: delete files and folders (guarded)
# ============================================================================
Write-Step $M.step_files

$paths = @(
    "$env:SystemRoot\System32\A-Volute",
    "$env:SystemRoot\System32\NahimicService.exe",
    "$env:ProgramFiles\MSI\One Dragon Center\Nahimic",
    "${env:ProgramFiles(x86)}\MSI\One Dragon Center\Nahimic",
    "$env:LOCALAPPDATA\NhNotifSys",
    "$env:ProgramData\A-Volute",
    "$env:APPDATA\A-Volute",
    "$env:ProgramFiles\ASUS\SonicStudio3",
    "${env:ProgramFiles(x86)}\ASUS\SonicStudio3",
    "$env:ProgramFiles\ASUS\Sonic Suite",
    "${env:ProgramFiles(x86)}\ASUS\Sonic Suite",
    "$env:ProgramFiles\ASUS\A-Studio",
    "${env:ProgramFiles(x86)}\ASUS\A-Studio",
    "$env:LOCALAPPDATA\ASUS\SonicStudio",
    "$env:APPDATA\ASUS\SonicStudio",
    "$env:ProgramData\ASUS\SonicStudio"
)

# Take ownership, grant Admins, delete. If still locked, apply Deny ACL so the
# binary can't execute even if it survives. REFUSES protected system roots.
function Remove-Forced {
    # Advanced function so it has its OWN $PSCmdlet / ShouldProcess: a plain
    # function does NOT inherit the script's $PSCmdlet, so calling it there
    # would throw. ConfirmImpact High keeps it under the script's -WhatIf.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path $Path)) { Write-Skipped "$Path (not found)"; return $false }

    if (Test-ProtectedPath $Path) {
        Write-Warn ($M.protected_path -f $Path)
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Take ownership and delete')) { return $false }

    & takeown /f $Path /r /a /d y                 2>&1 | Out-Null
    & icacls  $Path /grant "Administrators:F" /t  2>&1 | Out-Null

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-OK "Removed: $Path"
        return $true
    } catch {
        Write-Warn "Could not delete (locked?) - applying ACL deny: $Path"
        try {
            $acl = Get-Acl $Path
            $deny       = New-Object System.Security.AccessControl.FileSystemAccessRule('Everyone', 'FullControl', 'Deny')
            $denySystem = New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',   'FullControl', 'Deny')
            $acl.SetAccessRule($deny)
            $acl.SetAccessRule($denySystem)
            Set-Acl $Path $acl -ErrorAction Stop
            Write-OK "ACL deny applied (file inert): $Path"
            return $true
        } catch {
            Write-Warn "ACL deny also failed: $Path - $_"
            return $false
        }
    }
}

# Forward the script's -WhatIf / -Confirm into the advanced function.
$removeFwd = @{
    WhatIf  = [bool]$WhatIfPreference
    Confirm = ($ConfirmPreference -eq 'Low')
}

$filesRemoved = 0
foreach ($p in $paths) { if (Remove-Forced -Path $p @removeFwd) { $filesRemoved++ } }

Write-Host "    Scanning for leftovers in System32 / SysWOW64..." -ForegroundColor DarkGray
foreach ($dir in @("$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64")) {
    Get-ChildItem -Path $dir -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $TARGET } |
        ForEach-Object { if (Remove-Forced -Path $_.FullName @removeFwd) { $filesRemoved++ } }
}
if ($filesRemoved -gt 0) { Mark 'files' }

# ============================================================================
#  7. Task Scheduler: remove matching tasks
# ============================================================================
Write-Step $M.step_tasks
$tasksRemoved = 0
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match $TARGET -or $_.TaskPath -match $TARGET } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess("$($_.TaskPath)$($_.TaskName)", 'Unregister scheduled task')) {
            try {
                Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
                Write-OK "Task removed: $($_.TaskPath)$($_.TaskName)"
                $tasksRemoved++
            } catch {
                Write-Warn "Could not remove task '$($_.TaskName)': $_"
            }
        }
    }
if ($tasksRemoved -gt 0) { Mark 'tasks' } else { Write-Skipped $M.no_tasks }

# ============================================================================
#  8. Windows Update: hide pending updates via WUA COM API
# ============================================================================
Write-Step $M.step_wu
$wuSearcher = $null
$wuHidden = 0
try {
    $wuSession  = New-Object -ComObject Microsoft.Update.Session
    $wuSearcher = $wuSession.CreateUpdateSearcher()

    Write-Host "    Searching for pending updates..." -ForegroundColor DarkGray
    $wuResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=0")

    if ($wuResult.Updates.Count -eq 0) {
        Write-Skipped $M.no_updates
    } else {
        foreach ($upd in $wuResult.Updates) {
            if ($upd.Title -match $TARGET -or $upd.Description -match $TARGET) {
                if ($PSCmdlet.ShouldProcess($upd.Title, 'Hide Windows Update entry')) {
                    try {
                        $upd.IsHidden = $true
                        Write-OK "Hidden: $($upd.Title)"
                        $wuHidden++
                    } catch {
                        Write-Warn "Could not hide '$($upd.Title)': $_"
                    }
                }
            }
        }
        if ($wuHidden -eq 0) {
            Write-Skipped "No matching updates among the $($wuResult.Updates.Count) pending entries"
        }
    }
} catch {
    Write-Warn ($M.wu_unavailable -f $_)
    Write-Host $M.wu_manual -ForegroundColor DarkGray
}
if ($wuHidden -gt 0) { Mark 'wu' }

# ============================================================================
#  9. Hardware ID blacklist - permanent block via Group Policy registry
# ============================================================================
if (-not $SkipBlacklist) {
    Write-Step $M.step_blacklist

    $hwIdRegPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
    $denyListPath = "$hwIdRegPath\DenyDeviceIDs"

    if ($PSCmdlet.ShouldProcess('DeviceInstall Restrictions', 'Enable HW ID deny policy')) {
        try {
            if (-not (Test-Path $hwIdRegPath))  { New-Item -Path $hwIdRegPath  -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDs'            -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force -ErrorAction Stop
            if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force -ErrorAction Stop | Out-Null }

            $knownHwIds = @(
                'SWC\VEN_103C&AID_NAHIMIC',
                'SWC\VEN_1462&AID_NAHIMIC',
                'SWC\VEN_10DE&AID_NAHIMIC',
                'SWC\VEN_1043&AID_NAHIMIC',
                'ROOT\NAHIMIC_MIRRORING',
                'SWC\VEN_1043&AID_SONICSTUDIO',
                'ROOT\SONICSTUDIO',
                'ROOT\ASTUDIO'
            )

            $liveIds = Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -match $TARGET } |
                ForEach-Object { $_.HardwareID } |
                Where-Object { $_ }

            $wuIds = @()
            if ($wuSearcher) {
                try {
                    $hiddenResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=1")
                    foreach ($u in $hiddenResult.Updates) {
                        if ($u.Title -match $TARGET) {
                            $u.DriverHardwareID | Where-Object { $_ } | ForEach-Object { $wuIds += $_ }
                        }
                    }
                } catch {}
            }

            # Curated list is allowlist-conformant by construction. Harvested
            # IDs ($liveIds, $wuIds) are the dangerous ones: filter EVERYTHING
            # through Test-SafeNahimicHwId so no real-hardware ID (Realtek HD
            # Audio etc.) can ever enter the deny list. Rejected IDs are logged.
            $candidateHwIds = ($knownHwIds + $liveIds + $wuIds) | Sort-Object -Unique
            $allHwIds = @()
            foreach ($cand in $candidateHwIds) {
                if (Test-SafeNahimicHwId $cand) {
                    $allHwIds += $cand
                } else {
                    Write-Warn ($M.hwid_rejected -f $cand)
                }
            }

            $existingValues = @{}
            (Get-Item -Path $denyListPath -ErrorAction SilentlyContinue).Property | ForEach-Object {
                $v = Get-ItemPropertyValue -Path $denyListPath -Name $_ -ErrorAction SilentlyContinue
                if ($v) { $existingValues[$v] = $true }
            }

            $counter = if ($existingValues.Count -gt 0) { $existingValues.Count + 1 } else { 1 }
            foreach ($hwId in $allHwIds) {
                if ($existingValues.ContainsKey($hwId)) {
                    Write-Host "    [=] Already present: $hwId" -ForegroundColor DarkGray
                    continue
                }
                Set-ItemProperty -Path $denyListPath -Name $counter.ToString() -Value $hwId -Type String -Force -ErrorAction Stop
                Write-OK "Blacklisted: $hwId"
                $counter++
                $existingValues[$hwId] = $true
            }

            & gpupdate.exe /force /target:computer 2>&1 | Out-Null
            Mark 'blacklist'
        } catch {
            Write-Warn "Blacklist step failed: $_"
        }
    }

    # ========================================================================
    #  10. Scheduled task: NahimicPolicyGuard (re-applies blacklist at startup)
    # ========================================================================
    Write-Step $M.step_guard

    $guardTaskName = 'NahimicPolicyGuard'
    Unregister-ScheduledTask -TaskName $guardTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $guardScript = @'
$hwIdRegPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPath = "$hwIdRegPath\DenyDeviceIDs"
if (-not (Test-Path $hwIdRegPath))  { New-Item -Path $hwIdRegPath  -Force | Out-Null }
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDs'            -Value 1 -Type DWord -Force
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force
if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force | Out-Null }
$ids = @(
    'SWC\VEN_103C&AID_NAHIMIC', 'SWC\VEN_1462&AID_NAHIMIC',
    'SWC\VEN_10DE&AID_NAHIMIC', 'SWC\VEN_1043&AID_NAHIMIC',
    'ROOT\NAHIMIC_MIRRORING',  'ROOT\NahimicBTLink',
    'ROOT\Nahimic_Mirroring',  'ROOT\NahimicXVAD',
    'SWC\VEN_1043&AID_SONICSTUDIO', 'ROOT\SONICSTUDIO', 'ROOT\ASTUDIO'
)
$existing = @{}
(Get-Item -Path $denyListPath -ErrorAction SilentlyContinue).Property | ForEach-Object {
    $v = Get-ItemPropertyValue -Path $denyListPath -Name $_ -ErrorAction SilentlyContinue
    if ($v) { $existing[$v] = $true }
}
$i = if ($existing.Count -gt 0) { $existing.Count + 1 } else { 1 }
foreach ($id in $ids) {
    if (-not $existing.ContainsKey($id)) {
        Set-ItemProperty -Path $denyListPath -Name "$i" -Value $id -Type String -Force
        $i++; $existing[$id] = $true
    }
}
'@

    if ($PSCmdlet.ShouldProcess($guardTaskName, 'Register startup scheduled task')) {
        $encoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guardScript))
        $action    = New-ScheduledTaskAction    -Execute 'powershell.exe' `
                          -Argument "-NonInteractive -NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger   = New-ScheduledTaskTrigger   -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                          -MultipleInstances IgnoreNew
        try {
            Register-ScheduledTask -TaskName $guardTaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force `
                -Description 'Re-applies Nahimic HW ID blacklist at startup. Survives Windows feature updates.' `
                -ErrorAction Stop | Out-Null
            Write-OK $M.guard_created
            Mark 'guard'
        } catch {
            Write-Warn "Could not create scheduled task: $_"
        }
    }
} else {
    Write-Step $M.step_blacklist
    Write-Skipped 'SkipBlacklist specified: permanent block NOT applied'
}

# ============================================================================
#  11. Summary (reflects verified results, not intentions)
# ============================================================================
$line = "-" * 62
Write-Host "`n$line" -ForegroundColor DarkGray
Write-Host $M.summary_title   -ForegroundColor Green
Write-Host $M.summary_actions -ForegroundColor White

$labels = @{
    uninstall = 'Win32 apps uninstalled'
    appx      = 'AppX / Store packages removed'
    services  = 'Services stopped and removed'
    processes = 'Processes terminated'
    backup    = 'Audio class registry backed up'
    regkeys   = 'Registry keys removed'
    apo       = 'APO cleanup (SS3Config / FxProperties)'
    drivers   = 'Drivers removed from Driver Store'
    pnp       = 'PnP devices removed'
    files     = 'Leftover files deleted'
    tasks     = 'Scheduled tasks removed'
    wu        = 'Windows Update entries hidden'
    blacklist = 'Hardware IDs blacklisted'
    guard     = 'NahimicPolicyGuard task created'
}
foreach ($k in $labels.Keys) {
    if ($script:Actions[$k]) {
        Write-Host ("   [+] " + $labels[$k]) -ForegroundColor Green
    } else {
        Write-Host ("   [ ] " + $labels[$k] + ' (nothing done / failed)') -ForegroundColor DarkGray
    }
}
Write-Host "$line" -ForegroundColor DarkGray

try { Stop-Transcript | Out-Null } catch {}

if (-not $WhatIfPreference) {
    $restart = Read-Host $M.restart_prompt
    if ($Language -eq 'it') {
        if ($restart -match '^[sSyY]$') { Restart-Computer -Force }
    } else {
        if ($restart -match '^[yY]$') { Restart-Computer -Force }
    }
}
