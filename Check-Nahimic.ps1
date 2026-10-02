<#
    Check-Nahimic.ps1

    Pre-check / audit: detects Nahimic / A-Volute / Sonic Studio / A-Studio
    remnants, plus any device-install block left behind by the removal script.

    Author: https://github.com/Leproide
    Repo:   https://github.com/Leproide/Remove-Nahimic

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
    Read-only detection of Nahimic/Sonic remnants and of the HW-ID deny policy.

    .DESCRIPTION
    Run this BEFORE (or after) the removal script to see what is present.
    Read-only: it does NOT modify anything.

    Exit codes (STANDARD shell convention - inverted vs the old script):
        exit 0 = clean          (nothing found)        -> success/true
        exit 2 = remnants found  (run Remove-Nahimic.ps1)
        exit 3 = system is clean of Nahimic BUT a device-install block is
                 active (DenyDeviceIDs / NahimicPolicyGuard) - may be blocking
                 real hardware; see README "Recovery".

    .NOTES
    Driver Store detection uses Win32_PnPSignedDriver (CIM, locale-invariant),
    with a bilingual pnputil text fallback - the old 'Published Name' /
    'Provider Name' parse silently matched nothing on non-English Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
# Not SilentlyContinue globally: a failing probe must not read as "clean".
$ErrorActionPreference = 'Continue'

# Broad pattern for structured fields (DisplayName, service/key names, paths).
$TARGET = 'Nahimic|A[-_ ]Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite|NahimicAPO'

# Narrow pattern for free-text fields (FriendlyName, Copyright) where broad
# terms like "Studio" would cause false positives on third-party APOs
# (Conexant CVHT, Waves, SRS, etc.).
$APO_TARGET = 'Nahimic|A[-_ ]Volute|NahimicAPO|NhNotif'

$hits    = [System.Collections.Generic.List[string]]::new()
$blocks  = [System.Collections.Generic.List[string]]::new()

function Add-Hit   { param([string]$Text) if ($Text -and -not $hits.Contains($Text))   { $hits.Add($Text)   | Out-Null } }
function Add-Block { param([string]$Text) if ($Text -and -not $blocks.Contains($Text)) { $blocks.Add($Text) | Out-Null } }

# -- 1. Win32 uninstall entries ------------------------------------------------
foreach ($root in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    Get-ItemProperty $root -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $TARGET } |
        ForEach-Object { Add-Hit "Win32 app:        $($_.DisplayName)" }
}

# -- 2. AppX / Store packages --------------------------------------------------
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $TARGET -or $_.PackageFullName -match $TARGET } |
    ForEach-Object { Add-Hit "AppX package:     $($_.Name)" }

Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $TARGET -or $_.PackageName -match $TARGET } |
    ForEach-Object { Add-Hit "Provisioned AppX: $($_.DisplayName)" }

# -- 3. Services ---------------------------------------------------------------
foreach ($p in @('NahimicService','Nahimic_Mirroring','AVolute*','SonicSuite*','ASSonicStudio*','ASonicStudio*')) {
    Get-Service -Name $p -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Hit "Service:          $($_.Name) [$($_.Status)]" }
}

# -- 4. Running processes ------------------------------------------------------
foreach ($p in @('NahimicSvc*','NahimicService*','A-Volute*','AVS*','NhNotifSys*',
                 'MSICenter*','MSI*Dragon*','DragonCenter*','OneDragonCenter*',
                 'SonicStudio*','SonicSuite*','ASSonicStudio*','ASonicStudio*','A-Studio*','AStudio*')) {
    Get-Process -Name $p -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Hit "Process:          $($_.Name) (PID $($_.Id))" }
}

# -- 5. Known registry keys ----------------------------------------------------
foreach ($key in @(
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
    'HKLM:\SOFTWARE\ASUSTeK Computer Inc.\ASUS Sonic Studio')) {
    if (Test-Path $key) { Add-Hit "Registry key:     $key" }
}

# -- 6. APO: SS3Config subkeys (Sonic Studio 3 blobs) -------------------------
$audioClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
if (Test-Path $audioClassKey) {
    Get-ChildItem -Path $audioClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            $devIndex = $_.PSChildName
            $devPath  = $_.PSPath
            foreach ($ss3 in @('PlaybackSS3Config','RecordSS3Config')) {
                $ss3Path = Join-Path $devPath "InterfaceSetting\$ss3"
                if (Test-Path $ss3Path) {
                    Add-Hit "APO SS3Config:    $devIndex\InterfaceSetting\$ss3"
                }
            }
            # FxProperties: check by property NAME (values are binary PROPVARIANTs)
            $fxPath = Join-Path $devPath 'FxProperties'
            if (Test-Path $fxPath) {
                $knownGuids = '9B8844FE-1650-40E5-A5EA-11B8C83821A1|F363DF17-A750-4AC3-B7B5-2BBEFFA9085F|E0F2C10F-8244-476E-8EBE-B6EE73D8F2FB|D3465FC4-DB6D-4796-8FDE-0CB851BE2EC9'
                $props = Get-ItemProperty -Path $fxPath -ErrorAction SilentlyContinue
                if ($props) {
                    $props.PSObject.Properties |
                        Where-Object { $_.Name -notlike 'PS*' -and $_.Name -match "(?i)^\{($knownGuids)\}" } |
                        ForEach-Object { Add-Hit "APO FxProperty:   $devIndex \ $($_.Name)" }
                }
            }
        }
}

# -- 7. HKCR AudioProcessingObjects (narrow $APO_TARGET to avoid false pos.) ---
foreach ($ar in @('HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects',
                  'HKLM:\SOFTWARE\Classes\WOW6432Node\AudioEngine\AudioProcessingObjects')) {
    if (-not (Test-Path $ar)) { continue }
    Get-ChildItem -Path $ar -ErrorAction SilentlyContinue | ForEach-Object {
        $friendly  = (Get-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -ErrorAction SilentlyContinue).FriendlyName
        $copyright = (Get-ItemProperty -Path $_.PSPath -Name 'Copyright'    -ErrorAction SilentlyContinue).Copyright
        if (($friendly -and $friendly -match $APO_TARGET) -or ($copyright -and $copyright -match $APO_TARGET)) {
            Add-Hit "APO registration: $($_.PSChildName) ($friendly)"
        }
    }
}

# -- 8. Driver Store (CIM primary, bilingual pnputil fallback) -----------------
# OLD BUG: parsed localized pnputil output ('Published Name'/'Provider Name'),
# so nothing matched on non-English Windows. CIM property names are invariant.
$infSeen = New-Object System.Collections.Generic.HashSet[string]

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
                if ($infSeen.Add($Matches[1])) { Add-Hit "Driver Store:     $($Matches[1])" }
            }
        }
} catch {
    Add-Hit "Driver Store:     (CIM query failed: $_)"
}

# Fallback: pnputil, matching both EN and IT field labels.
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
            if ($infSeen.Add($currentInf)) { Add-Hit "Driver Store:     $currentInf" }
            $currentInf = $null
        }
    }
}

# -- 9. PnP devices ------------------------------------------------------------
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET -or $_.InstanceId -match $TARGET } |
    ForEach-Object { Add-Hit "PnP device:       $($_.FriendlyName) [$($_.InstanceId)]" }

# -- 10. Residual files / folders ----------------------------------------------
foreach ($p in @(
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
    "$env:ProgramData\ASUS\SonicStudio")) {
    if (Test-Path $p) { Add-Hit "File/Folder:      $p" }
}

# -- 11. Scheduled tasks (Nahimic's own; guard task handled in section 12) ------
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { ($_.TaskName -match $TARGET -or $_.TaskPath -match $TARGET) -and
                   $_.TaskName -ne 'NahimicPolicyGuard' } |
    ForEach-Object { Add-Hit "Scheduled task:   $($_.TaskPath)$($_.TaskName)" }

# -- 12. Device-install block left by the removal script -----------------------
# Not a Nahimic remnant: it's OUR deny policy. Report it separately because a
# contaminated deny list (older bug) could be blocking real audio hardware.
$restrictionsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPath     = "$restrictionsPath\DenyDeviceIDs"

if (Test-Path $restrictionsPath) {
    $deny     = (Get-ItemProperty -Path $restrictionsPath -Name 'DenyDeviceIDs'            -ErrorAction SilentlyContinue).DenyDeviceIDs
    $denyRetro = (Get-ItemProperty -Path $restrictionsPath -Name 'DenyDeviceIDsRetroactive' -ErrorAction SilentlyContinue).DenyDeviceIDsRetroactive
    if ($deny -eq 1) {
        Add-Block "Device-install deny policy is ACTIVE (DenyDeviceIDs=1, Retroactive=$denyRetro)"
    }
    if (Test-Path $denyListPath) {
        (Get-Item -Path $denyListPath -ErrorAction SilentlyContinue).Property | ForEach-Object {
            $v = Get-ItemPropertyValue -Path $denyListPath -Name $_ -ErrorAction SilentlyContinue
            if ($v) {
                # Flag any entry that is NOT a Nahimic/Sonic software component -
                # i.e. a real-hardware enumerator that must never be blocked.
                if ($v -match '(?i)^(HDAUDIO|PCI|ACPI|USB|HID|SWD)\\') {
                    Add-Block "DANGER: deny list contains a REAL-HARDWARE id: $v"
                } else {
                    Add-Block "Deny list entry: $v"
                }
            }
        }
    }
}

$guard = Get-ScheduledTask -TaskName 'NahimicPolicyGuard' -ErrorAction SilentlyContinue
if ($guard) {
    Add-Block "NahimicPolicyGuard task present (re-applies the deny list at startup)"
}

# -- Result --------------------------------------------------------------------
$logFile = Join-Path $env:SystemRoot 'Temp\Check-Nahimic.log'
$lines   = @()

if ($hits.Count -gt 0) {
    $lines += ""
    $lines += "WARNING: Nahimic / A-Volute / Sonic Studio detected ($($hits.Count) item(s)):"
    $lines += ""
    $hits | Sort-Object | ForEach-Object { $lines += "  - $_" }
    $lines += ""
    $lines += "Run Remove-Nahimic.ps1 as Administrator to clean up."
    $exit = 2
} elseif ($blocks.Count -gt 0) {
    $lines += ""
    $lines += "Nahimic not present, BUT a device-install block is active ($($blocks.Count) item(s)):"
    $lines += ""
    $blocks | Sort-Object | ForEach-Object { $lines += "  - $_" }
    $lines += ""
    $lines += "If real audio hardware is being blocked, see the README 'Recovery' section."
    $exit = 3
} else {
    $lines += ""
    $lines += "Nahimic not present - system is clean."
    $exit = 0
}

# Always append the block report when remnants were found too, so the deny
# policy is visible even in the "remnants" case.
if ($hits.Count -gt 0 -and $blocks.Count -gt 0) {
    $lines += ""
    $lines += "Device-install block also active:"
    $blocks | Sort-Object | ForEach-Object { $lines += "  - $_" }
}

$lines | ForEach-Object { Write-Output $_ }
try {
    $header = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - exit $exit"
    @($header) + $lines | Out-File -FilePath $logFile -Encoding UTF8 -Force
} catch {
    Write-Warning "Could not write log to $logFile : $_"
}

exit $exit
