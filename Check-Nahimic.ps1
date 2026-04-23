<#
Author: Leprechaun
Repo: https://github.com/Leproide/Remove-Nahimic

.SYNOPSIS
    Pre-check: detects Nahimic / A-Volute / Sonic Studio / A-Studio remnants.
.DESCRIPTION
    Run this BEFORE the removal script to see exactly what will be cleaned.
    exit 0 = something found  (removal script needed)
    exit 1 = nothing found    (system is clean)
.NOTES
    Read-only — does not modify anything.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$TARGET = 'Nahimic|A[-_ ]Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite|NahimicAPO'

# Narrow pattern for free-text fields (FriendlyName, Copyright) where broad
# terms like "Studio" would cause false positives on third-party APOs.
$APO_TARGET = 'Nahimic|A[-_ ]Volute|NahimicAPO|NhNotif'

$hits = [System.Collections.Generic.List[string]]::new()
function Add-Hit { param([string]$Text) if ($Text -and -not $hits.Contains($Text)) { $hits.Add($Text) | Out-Null } }

# ── 1. Win32 uninstall entries ────────────────────────────────────────────────
foreach ($root in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    Get-ItemProperty $root -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $TARGET } |
        ForEach-Object { Add-Hit "Win32 app:       $($_.DisplayName)" }
}

# ── 2. AppX / Store packages ──────────────────────────────────────────────────
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $TARGET -or $_.PackageFullName -match $TARGET } |
    ForEach-Object { Add-Hit "AppX package:    $($_.Name)" }

Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $TARGET -or $_.PackageName -match $TARGET } |
    ForEach-Object { Add-Hit "Provisioned AppX: $($_.DisplayName)" }

# ── 3. Services ───────────────────────────────────────────────────────────────
foreach ($p in @('NahimicService','Nahimic_Mirroring','AVolute*','SonicSuite*','ASSonicStudio*','ASonicStudio*')) {
    Get-Service -Name $p -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Hit "Service:         $($_.Name) [$($_.Status)]" }
}

# ── 4. Running processes ──────────────────────────────────────────────────────
foreach ($p in @('NahimicSvc*','NahimicService*','A-Volute*','AVS*','NhNotifSys*',
                 'MSICenter*','MSI*Dragon*','DragonCenter*','OneDragonCenter*',
                 'SonicStudio*','SonicSuite*','ASSonicStudio*','ASonicStudio*','A-Studio*','AStudio*')) {
    Get-Process -Name $p -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Hit "Process:         $($_.Name) (PID $($_.Id))" }
}

# ── 5. Known registry keys ────────────────────────────────────────────────────
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
    if (Test-Path $key) { Add-Hit "Registry key:    $key" }
}

# ── 6. APO: SS3Config subkeys (Sonic Studio 3 blobs) ─────────────────────────
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
                    Add-Hit "APO SS3Config:   $devIndex\InterfaceSetting\$ss3"
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
                        ForEach-Object { Add-Hit "APO FxProperty:  $devIndex \ $($_.Name)" }
                }
            }
        }
}

# ── 7. HKCR AudioProcessingObjects ───────────────────────────────────────────
# Uses $APO_TARGET (narrow) instead of $TARGET to avoid false positives on
# third-party APOs (Conexant CVHT, Waves, SRS, etc.) whose FriendlyName or
# Copyright may contain generic words like "Studio" matched by $TARGET.
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

# ── 8. Driver Store ───────────────────────────────────────────────────────────
$driverList = pnputil /enum-drivers 2>&1
$currentInf = $null
foreach ($line in $driverList) {
    if ($line -match 'Published Name\s*:\s*(oem\d+\.inf)') { $currentInf = $Matches[1] }
    if ($currentInf -and ($line -match "Provider Name\s*:\s*($TARGET)" -or
                          $line -match "Original Name\s*:\s*\S*($TARGET)\S*")) {
        Add-Hit "Driver Store:    $currentInf"
        $currentInf = $null
    }
}

# ── 9. PnP devices ────────────────────────────────────────────────────────────
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET -or $_.InstanceId -match $TARGET } |
    ForEach-Object { Add-Hit "PnP device:      $($_.FriendlyName) [$($_.InstanceId)]" }

# ── 10. Residual files / folders ──────────────────────────────────────────────
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
    if (Test-Path $p) { Add-Hit "File/Folder:     $p" }
}

# ── 11. Scheduled tasks ───────────────────────────────────────────────────────
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match $TARGET -or $_.TaskPath -match $TARGET } |
    ForEach-Object { Add-Hit "Scheduled task:  $($_.TaskPath)$($_.TaskName)" }

# ── Result ────────────────────────────────────────────────────────────────────
$logFile = "C:\Windows\Temp\Check-Nahimic.log"

if ($hits.Count -gt 0) {
    $lines = @()
    $lines += ""
    $lines += "WARNING: Nahimic / A-Volute / Sonic Studio detected ($($hits.Count) item(s)):"
    $lines += ""
    $hits | Sort-Object | ForEach-Object { $lines += "  - $_" }
    $lines += ""
    $lines += "Run Remove-Nahimic.ps1 as Administrator to clean up."

    $lines | ForEach-Object { Write-Output $_ }
    $lines | Out-File -FilePath $logFile -Encoding UTF8 -Force

    exit 0
} else {
    Write-Output ""
    Write-Output "Nahimic not present — system is clean."
    Write-Output ""
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Clean" | Out-File -FilePath $logFile -Encoding UTF8 -Force
    exit 1
}
