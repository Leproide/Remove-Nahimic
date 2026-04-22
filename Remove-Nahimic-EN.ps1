#Requires -RunAsAdministrator
<#
Author: Leprechaun
Repo: https://github.com/Leproide/Remove-Nahimic/

.SYNOPSIS
    Complete removal of Nahimic / A-Volute / Sonic Studio / A-Studio and
    prevention of reinstallation via Windows Update.
.DESCRIPTION
    - Uninstalls related Win32 and Store (AppX) applications
    - Stops and removes services
    - Kills related processes
    - Deletes registry keys and registered APOs
    - Direct APO cleanup (SS3Config + FxProperties) without relying on value types
    - Removes drivers from the Driver Store (pnputil)
    - Removes PnP devices
    - Deletes leftover files and folders (takeown + ACL deny fallback for locked files)
    - Removes scheduled tasks
    - Hides pending Windows Update entries (WUA COM API)
    - Blacklists Hardware IDs to block future reinstallations
    - Creates NahimicPolicyGuard scheduled task to survive Windows feature updates
.NOTES
    Requires administrator privileges.
    A reboot prompt is shown at the end.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
# Central pattern — add terms here to extend the cleanup scope
# ─────────────────────────────────────────────────────────────────────────────
$TARGET = 'Nahimic|A[-_ ]Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite|NahimicAPO'

function Write-Step    { param([string]$T); Write-Host "`n[*] $T" -ForegroundColor Cyan }
function Write-OK      { param([string]$T); Write-Host "    [+] $T" -ForegroundColor Green }
function Write-Warn    { param([string]$T); Write-Host "    [!] $T" -ForegroundColor Yellow }
function Write-Skipped { param([string]$T); Write-Host "    [-] $T (not found, skipping)" -ForegroundColor DarkGray }

# ─────────────────────────────────────────────────────────────────────────────
# 0. Uninstall Win32 applications via registry UninstallString
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Uninstalling Win32 applications"

$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

foreach ($root in $uninstallRoots) {
    Get-ItemProperty $root -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $TARGET } |
        ForEach-Object {
            $name  = $_.DisplayName
            $qstr  = $_.QuietUninstallString
            $ustr  = $_.UninstallString

            Write-Host "    Found: $name" -ForegroundColor Yellow

            $cmdLine = if ($qstr) { $qstr }
                       elseif ($ustr -match 'msiexec') { "$ustr /qn /norestart" }
                       else { "$ustr /S /silent /quiet" }

            try {
                if ($cmdLine -match '^"([^"]+)"\s*(.*)$') {
                    $exe = $Matches[1]; $arg = $Matches[2]
                } elseif ($cmdLine -match '^(\S+)\s*(.*)$') {
                    $exe = $Matches[1]; $arg = $Matches[2]
                } else {
                    $exe = $cmdLine; $arg = ''
                }
                Start-Process -FilePath $exe -ArgumentList $arg -Wait -NoNewWindow
                Write-OK "Uninstalled: $name"
            } catch {
                Write-Warn "Could not uninstall '$name': $_"
            }
        }
}

# ─────────────────────────────────────────────────────────────────────────────
# 0b. Remove AppX / Store packages
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing AppX / Store packages"

Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $TARGET -or $_.PackageFullName -match $TARGET } |
    ForEach-Object {
        Write-Host "    Removing AppX: $($_.Name)" -ForegroundColor Yellow
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        Write-OK "AppX removed: $($_.Name)"
    }

Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $TARGET -or $_.PackageName -match $TARGET } |
    ForEach-Object {
        Write-Host "    Removing provisioned AppX: $($_.DisplayName)" -ForegroundColor Yellow
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        Write-OK "Provisioned AppX removed: $($_.DisplayName)"
    }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Services: stop + disable + delete
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Stopping and removing services"

$servicePatterns = @(
    'NahimicService', 'Nahimic_Mirroring',
    'AVolute*', 'SonicSuite*', 'ASSonicStudio*', 'ASonicStudio*'
)

foreach ($pattern in $servicePatterns) {
    Get-Service -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        $svc = $_.Name
        Stop-Service -Name $svc -Force
        Set-Service  -Name $svc -StartupType Disabled
        sc.exe delete $svc | Out-Null
        Write-OK "Service '$svc' stopped and removed"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Processes: kill
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Killing related processes"

$processPatterns = @(
    'NahimicSvc*', 'NahimicService*', 'A-Volute*', 'AVS*', 'NhNotifSys*',
    'MSICenter*', 'MSI*Dragon*', 'DragonCenter*', 'OneDragonCenter*',
    'SonicStudio*', 'SonicSuite*', 'ASSonicStudio*', 'ASonicStudio*',
    'A-Studio*', 'AStudio*'
)

foreach ($pattern in $processPatterns) {
    $procs = Get-Process -Name $pattern -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Write-OK "Process '$pattern' terminated"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Registry: key deletion + APO scan (string-based)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing registry keys"

# Preventive backup of the audio device class before touching endpoint props
$audioClassKeyRaw = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$backupDir = "$env:USERPROFILE\Desktop"
$backupFile = Join-Path $backupDir ("AudioClass_backup_{0}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
& reg.exe export $audioClassKeyRaw $backupFile /y 2>&1 | Out-Null
if (Test-Path $backupFile) {
    Write-OK "Audio class backed up to: $backupFile"
} else {
    Write-Warn "Audio class backup failed (non-fatal)"
}

$regKeys = @(
    # Nahimic / A-Volute
    'HKLM:\SYSTEM\CurrentControlSet\Services\NahimicService',
    'HKLM:\SYSTEM\CurrentControlSet\Services\Nahimic_Mirroring',
    'HKCU:\SOFTWARE\A-Volute',
    'HKLM:\SOFTWARE\A-Volute',
    'HKLM:\SOFTWARE\WOW6432Node\A-Volute',
    'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\NahimicService',
    # Sonic Studio / A-Studio (ASUS)
    'HKLM:\SOFTWARE\ASUS\ASUS Sonic Studio',
    'HKLM:\SOFTWARE\WOW6432Node\ASUS\ASUS Sonic Studio',
    'HKCU:\SOFTWARE\ASUS\SonicStudio',
    'HKLM:\SOFTWARE\ASUS\A-Studio',
    'HKCU:\SOFTWARE\ASUS\A-Studio',
    'HKLM:\SOFTWARE\ASUSTeK Computer Inc.\ASUS Sonic Studio'
)

foreach ($key in $regKeys) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
        Write-OK "Key removed: $key"
    } else {
        Write-Skipped $key
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3b. APO cleanup — direct deletion of SS3Config / FxProperties subkeys
#
#     PlaybackSS3Config and RecordSS3Config are Sonic Studio 3 config blobs.
#     Their values are binary PROPVARIANTs whose .ToString() is "System.Byte[]",
#     so string/regex matching on values is unreliable. We delete the entire
#     subkey instead — if SS3/Nahimic is gone, these are orphaned garbage.
#     FxProperties is also cleaned for any properties whose NAME matches the
#     known Sonic/Nahimic APO property-key GUIDs.
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "APO cleanup (direct SS3Config / FxProperties deletion)"

$audioClassKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$audioClassKeyRaw = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'

# Subkeys that are exclusively Sonic Studio 3 / Nahimic — delete entire key
$ss3Subkeys = @('PlaybackSS3Config', 'RecordSS3Config')

# Known Sonic Studio 3 / Nahimic APO property-key GUIDs stored as VALUE NAMES
# under FxProperties / EP\N. Matching by name, not value (values are binary).
$knownApoPropertyGuids = @(
    '9B8844FE-1650-40E5-A5EA-11B8C83821A1',   # FX stream/mode APO refs
    'F363DF17-A750-4AC3-B7B5-2BBEFFA9085F',   # FX mode APO refs
    'E0F2C10F-8244-476E-8EBE-B6EE73D8F2FB',   # APO notification CLSID
    'D3465FC4-DB6D-4796-8FDE-0CB851BE2EC9'    # APO UI CLSID
)
# Build a regex that matches any property name starting with one of these GUIDs
$apoGuidPattern = '(?i)^\{(' + ($knownApoPropertyGuids -join '|') + ')\}'

# Stop audio services so the registry keys are not held open
Write-Host "    Stopping audio services..." -ForegroundColor DarkGray
Stop-Service 'AudioEndpointBuilder', 'audiosrv' -Force -ErrorAction SilentlyContinue

if (Test-Path $audioClassKey) {
    # Iterate device instances (0000, 0001, ... under the audio class)
    Get-ChildItem -Path $audioClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            $devIndex = $_.PSChildName
            $devPath  = $_.PSPath

            # 3b-i: delete entire SS3Config subkeys
            foreach ($ss3 in $ss3Subkeys) {
                $ss3Path    = Join-Path $devPath "InterfaceSetting\$ss3"
                $ss3PathRaw = "$audioClassKeyRaw\$devIndex\InterfaceSetting\$ss3"
                if (Test-Path $ss3Path) {
                    Remove-Item -Path $ss3Path -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path $ss3Path) {
                        # Fallback to reg.exe if PS Remove-Item fails (ACL edge case)
                        & reg.exe delete $ss3PathRaw /f 2>&1 | Out-Null
                    }
                    if (Test-Path $ss3Path) {
                        Write-Warn "Could not remove (ACL?): $ss3PathRaw"
                    } else {
                        Write-OK "Deleted: $devIndex\InterfaceSetting\$ss3"
                    }
                }
            }

            # 3b-ii: remove known Nahimic/Sonic APO property names from FxProperties
            $fxPath = Join-Path $devPath 'FxProperties'
            if (Test-Path $fxPath) {
                $props = Get-ItemProperty -Path $fxPath -ErrorAction SilentlyContinue
                if ($props) {
                    foreach ($prop in $props.PSObject.Properties) {
                        if ($prop.Name -like 'PS*') { continue }
                        if ($prop.Name -match $apoGuidPattern) {
                            Remove-ItemProperty -Path $fxPath -Name $prop.Name -Force -ErrorAction SilentlyContinue
                            Write-OK "FxProperties entry removed: $devIndex \ $($prop.Name)"
                        }
                    }
                }
            }
        }
} else {
    Write-Skipped "Audio class key not found"
}

# Also clean HKCR\AudioEngine\AudioProcessingObjects for Nahimic entries
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
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "APO registration removed: $($_.PSChildName) ($friendly)"
        }
    }
}

# Restart audio services
Write-Host "    Restarting audio services..." -ForegroundColor DarkGray
Start-Service 'AudioEndpointBuilder' -ErrorAction SilentlyContinue
Start-Service 'audiosrv'             -ErrorAction SilentlyContinue
Write-OK "Audio services restarted"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Driver Store: removal via pnputil
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing drivers from Driver Store (pnputil)"

$driverList = pnputil /enum-drivers 2>&1
$infFiles   = @()
$currentInf = $null

foreach ($line in $driverList) {
    if ($line -match 'Published Name\s*:\s*(oem\d+\.inf)') {
        $currentInf = $Matches[1]
    }
    if ($currentInf) {
        if ($line -match "Provider Name\s*:\s*($TARGET)" -or
            $line -match "Original Name\s*:\s*\S*($TARGET)\S*") {
            if ($infFiles -notcontains $currentInf) { $infFiles += $currentInf }
            $currentInf = $null
        }
    }
}

if ($infFiles.Count -eq 0) {
    Write-Skipped "No matching drivers found in Driver Store"
} else {
    foreach ($inf in $infFiles) {
        Write-Host "    Force-removing: $inf" -ForegroundColor Yellow
        pnputil /delete-driver $inf /uninstall /force 2>&1 |
            ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        Write-OK "Driver $inf removed"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. PnP devices: removal
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing PnP devices"

Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET } |
    ForEach-Object {
        Write-Host "    Removing: $($_.FriendlyName) [$($_.InstanceId)]" -ForegroundColor Yellow
        pnputil /remove-device "$($_.InstanceId)" 2>&1 | Out-Null
        Write-OK "Device removed: $($_.FriendlyName)"
    }

# ─────────────────────────────────────────────────────────────────────────────
# 6. File system: delete files and folders
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Deleting files and folders"

$paths = @(
    # Nahimic / A-Volute
    "$env:SystemRoot\System32\A-Volute",
    "$env:SystemRoot\System32\NahimicService.exe",
    "$env:ProgramFiles\MSI\One Dragon Center\Nahimic",
    "${env:ProgramFiles(x86)}\MSI\One Dragon Center\Nahimic",
    "$env:LOCALAPPDATA\NhNotifSys",
    "$env:ProgramData\A-Volute",
    "$env:APPDATA\A-Volute",
    # Sonic Studio / A-Studio (ASUS)
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

# Helper: take ownership, grant Administrators full control, then delete.
# If deletion still fails (file locked), applies Deny-FullControl ACL as fallback
# so the file cannot be executed even if it survives.
function Remove-Forced {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Skipped $Path; return }
    & takeown /f $Path /r /a /d y 2>&1 | Out-Null
    & icacls $Path /grant "Administrators:F" /t 2>&1 | Out-Null
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-OK "Removed: $Path"
    } catch {
        Write-Warn "Could not delete (locked?) — applying ACL deny: $Path"
        try {
            $acl = Get-Acl $Path
            $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'Everyone', 'FullControl', 'Deny')
            $denySystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'SYSTEM', 'FullControl', 'Deny')
            $acl.SetAccessRule($deny)
            $acl.SetAccessRule($denySystem)
            Set-Acl $Path $acl
            Write-OK "ACL deny applied (file inert): $Path"
        } catch {
            Write-Warn "ACL deny also failed: $Path — $_"
        }
    }
}

foreach ($p in $paths) { Remove-Forced $p }

Write-Host "    Scanning for leftovers in System32 / SysWOW64..." -ForegroundColor DarkGray
foreach ($dir in @("$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64")) {
    Get-ChildItem -Path $dir -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $TARGET } |
        ForEach-Object { Remove-Forced $_.FullName }
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Task Scheduler: remove matching tasks
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing scheduled tasks"

$found = $false
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match $TARGET -or $_.TaskPath -match $TARGET } |
    ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false
        Write-OK "Task removed: $($_.TaskPath)$($_.TaskName)"
        $found = $true
    }
if (-not $found) { Write-Skipped "No matching scheduled tasks" }

# ─────────────────────────────────────────────────────────────────────────────
# 8. Windows Update: hide pending updates via WUA COM API
#    Equivalent to the "Hide" button in Windows Update MiniTool, fully
#    automated with no GUI required.
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Hiding pending Windows Update entries"

$wuSearcher = $null
try {
    $wuSession  = New-Object -ComObject Microsoft.Update.Session
    $wuSearcher = $wuSession.CreateUpdateSearcher()

    Write-Host "    Searching for pending updates..." -ForegroundColor DarkGray
    $wuResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=0")

    if ($wuResult.Updates.Count -eq 0) {
        Write-Skipped "No pending updates found"
    } else {
        $hiddenCount = 0
        foreach ($upd in $wuResult.Updates) {
            if ($upd.Title -match $TARGET -or $upd.Description -match $TARGET) {
                $upd.IsHidden = $true
                Write-OK "Hidden: $($upd.Title)"
                $hiddenCount++
            }
        }
        if ($hiddenCount -eq 0) {
            Write-Skipped "No matching updates among the $($wuResult.Updates.Count) pending entries"
        }
    }
} catch {
    Write-Warn "WUA COM API unavailable: $_"
    Write-Host "    Hide the updates manually via Windows Update or Windows Update MiniTool." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Hardware ID blacklist — permanent block via Group Policy registry
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Blacklisting Hardware IDs (permanent block)"

$hwIdRegPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPath = "$hwIdRegPath\DenyDeviceIDs"

if (-not (Test-Path $hwIdRegPath)) { New-Item -Path $hwIdRegPath -Force | Out-Null }
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDs'            -Value 1 -Type DWord -Force
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force
if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force | Out-Null }

$knownHwIds = @(
    # Nahimic / A-Volute (various vendors: HP, MSI, NVIDIA, ASUS)
    'SWC\VEN_103C&AID_NAHIMIC',
    'SWC\VEN_1462&AID_NAHIMIC',
    'SWC\VEN_10DE&AID_NAHIMIC',
    'SWC\VEN_1043&AID_NAHIMIC',
    'ROOT\NAHIMIC_MIRRORING',
    # Sonic Studio / A-Studio (ASUS)
    'SWC\VEN_1043&AID_SONICSTUDIO',
    'ROOT\SONICSTUDIO',
    'ROOT\ASTUDIO'
)

# HW IDs from PnP devices still present on the system
$liveIds = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET } |
    ForEach-Object { $_.HardwareID } |
    Where-Object { $_ }

# HW IDs from Windows Update entries just hidden above
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

$allHwIds = ($knownHwIds + $liveIds + $wuIds) | Sort-Object -Unique

# Read existing entries to avoid duplicates
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
    Set-ItemProperty -Path $denyListPath -Name $counter.ToString() -Value $hwId -Type String -Force
    Write-OK "Blacklisted: $hwId"
    $counter++
    $existingValues[$hwId] = $true
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Scheduled task: NahimicPolicyGuard
#     Re-applies the HW ID blacklist at every startup as SYSTEM.
#     Protects against Windows feature updates that can reset Group Policy
#     registry keys under HKLM\SOFTWARE\Policies\...
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Creating NahimicPolicyGuard scheduled task"

$guardTaskName = 'NahimicPolicyGuard'

# Remove stale version if present (idempotent re-run)
Unregister-ScheduledTask -TaskName $guardTaskName -Confirm:$false -ErrorAction SilentlyContinue

$guardScript = @'
$hwIdRegPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPath = "$hwIdRegPath\DenyDeviceIDs"
if (-not (Test-Path $hwIdRegPath)) { New-Item -Path $hwIdRegPath -Force | Out-Null }
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDs'            -Value 1 -Type DWord -Force
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force
if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force | Out-Null }
$ids = @(
    'SWC\VEN_103C&AID_NAHIMIC', 'SWC\VEN_1462&AID_NAHIMIC',
    'SWC\VEN_10DE&AID_NAHIMIC', 'SWC\VEN_1043&AID_NAHIMIC',
    'ROOT\NAHIMIC_MIRRORING',   'ROOT\NahimicBTLink',
    'ROOT\Nahimic_Mirroring',   'ROOT\NahimicXVAD',
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

$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guardScript))

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NonInteractive -NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                 -MultipleInstances IgnoreNew

try {
    Register-ScheduledTask -TaskName $guardTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Re-applies Nahimic HW ID blacklist at startup. Survives Windows feature updates.' `
        | Out-Null
    Write-OK "Task '$guardTaskName' created (runs at startup as SYSTEM)"
} catch {
    Write-Warn "Could not create scheduled task: $_"
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. Summary
# ─────────────────────────────────────────────────────────────────────────────
$line = "─" * 62
Write-Host "`n$line" -ForegroundColor DarkGray
Write-Host " Removal complete: Nahimic / A-Volute / Sonic Studio / A-Studio" -ForegroundColor Green
Write-Host " Actions performed:" -ForegroundColor White
Write-Host "   - Win32 apps uninstalled (UninstallString)" -ForegroundColor White
Write-Host "   - AppX / Store packages removed" -ForegroundColor White
Write-Host "   - Services stopped and removed" -ForegroundColor White
Write-Host "   - Processes terminated" -ForegroundColor White
Write-Host "   - Audio class registry backed up to Desktop" -ForegroundColor White
Write-Host "   - APO cleanup: SS3Config subkeys + FxProperties deleted directly" -ForegroundColor White
Write-Host "   - Drivers removed from Driver Store (pnputil)" -ForegroundColor White
Write-Host "   - PnP devices removed" -ForegroundColor White
Write-Host "   - Leftover files deleted (takeown + ACL deny fallback)" -ForegroundColor White
Write-Host "   - Scheduled tasks removed" -ForegroundColor White
Write-Host "   - Windows Update entries hidden (WUA COM API)" -ForegroundColor White
Write-Host "   - Hardware IDs blacklisted (permanent block)" -ForegroundColor White
Write-Host "   - NahimicPolicyGuard task created (survives feature updates)" -ForegroundColor White
Write-Host "$line" -ForegroundColor DarkGray

$restart = Read-Host "`nRestart now? (y/N)"
if ($restart -match '^[yY]$') { Restart-Computer -Force }
