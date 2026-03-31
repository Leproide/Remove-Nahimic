#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Rimozione completa di Nahimic / A-Volute / Sonic Studio / A-Studio e blocco
    reinstallazione tramite Windows Update.
.DESCRIPTION
    - Disinstalla app Win32 e Store (AppX) correlate
    - Arresta e rimuove servizi
    - Termina processi
    - Elimina chiavi di registro e APO registrati
    - Rimuove driver dal Driver Store (pnputil)
    - Rimuove dispositivi PnP
    - Elimina file e cartelle residue
    - Rimuove task schedulati
    - Nasconde aggiornamenti Windows Update pendenti (WUA COM API)
    - Blacklista gli Hardware ID per bloccare reinstallazioni future
.NOTES
    Richiede privilegi di amministratore.
    Al termine viene proposto un riavvio.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
# Pattern centralizzato — aggiungere qui per estendere la pulizia
# ─────────────────────────────────────────────────────────────────────────────
$TARGET = 'Nahimic|A[-_ ]Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite|NahimicAPO'

function Write-Step    { param([string]$T); Write-Host "`n[*] $T" -ForegroundColor Cyan }
function Write-OK      { param([string]$T); Write-Host "    [+] $T" -ForegroundColor Green }
function Write-Warn    { param([string]$T); Write-Host "    [!] $T" -ForegroundColor Yellow }
function Write-Skipped { param([string]$T); Write-Host "    [-] $T (non trovato, skip)" -ForegroundColor DarkGray }

# ─────────────────────────────────────────────────────────────────────────────
# 0. Disinstallazione app Win32 tramite UninstallString di registro
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Disinstallazione applicazioni Win32"

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

            Write-Host "    Trovato: $name" -ForegroundColor Yellow

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
                Write-OK "Disinstallato: $name"
            } catch {
                Write-Warn "Impossibile disinstallare '$name': $_"
            }
        }
}

# ─────────────────────────────────────────────────────────────────────────────
# 0b. Rimozione pacchetti AppX / Store
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rimozione pacchetti AppX / Store"

Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $TARGET -or $_.PackageFullName -match $TARGET } |
    ForEach-Object {
        Write-Host "    Rimozione AppX: $($_.Name)" -ForegroundColor Yellow
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        Write-OK "AppX rimosso: $($_.Name)"
    }

Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $TARGET -or $_.PackageName -match $TARGET } |
    ForEach-Object {
        Write-Host "    Rimozione provisioned AppX: $($_.DisplayName)" -ForegroundColor Yellow
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        Write-OK "Provisioned AppX rimosso: $($_.DisplayName)"
    }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Servizi: stop + disabilitazione + rimozione
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Arresto e rimozione servizi"

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
        Write-OK "Servizio '$svc' fermato e rimosso"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Processi: kill
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Terminazione processi correlati"

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
        Write-OK "Processo '$pattern' terminato"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Registro: eliminazione chiavi + scan APO
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rimozione chiavi di registro"

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
        Write-OK "Chiave rimossa: $key"
    } else {
        Write-Skipped $key
    }
}

# Scansione APO (Audio Processing Objects) registrati nelle classi driver audio
Write-Host "    Scansione APO nei driver audio..." -ForegroundColor DarkGray

$apoScanRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
)

foreach ($apoRoot in $apoScanRoots) {
    if (-not (Test-Path $apoRoot)) { continue }
    Get-ChildItem -Path $apoRoot -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            $props.PSObject.Properties | Where-Object { $_.Value -match $TARGET } | ForEach-Object {
                $propName = $_.Name
                $propPath = $_.PSPath
                Write-Warn "APO trovato: $propPath → $propName"
                Remove-ItemProperty -Path $propPath -Name $propName -Force -ErrorAction SilentlyContinue
                Write-OK "Proprietà APO rimossa: $propName"
            }
        } catch {}
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Driver Store: rimozione via pnputil
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rimozione driver da Driver Store (pnputil)"

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
    Write-Skipped "Nessun driver corrispondente nel Driver Store"
} else {
    foreach ($inf in $infFiles) {
        Write-Host "    Rimozione: $inf" -ForegroundColor Yellow
        pnputil /delete-driver $inf /uninstall /force 2>&1 |
            ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        Write-OK "Driver $inf rimosso"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Dispositivi PnP
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Disinstallazione dispositivi PnP"

Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET } |
    ForEach-Object {
        Write-Host "    Rimozione: $($_.FriendlyName) [$($_.InstanceId)]" -ForegroundColor Yellow
        pnputil /remove-device "$($_.InstanceId)" 2>&1 | Out-Null
        Write-OK "Dispositivo rimosso: $($_.FriendlyName)"
    }

# ─────────────────────────────────────────────────────────────────────────────
# 6. File system
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Eliminazione file e cartelle"

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

foreach ($p in $paths) {
    if (Test-Path $p) {
        Remove-Item -Path $p -Recurse -Force
        Write-OK "Rimosso: $p"
    } else {
        Write-Skipped $p
    }
}

Write-Host "    Scansione residui in System32 / SysWOW64..." -ForegroundColor DarkGray
foreach ($dir in @("$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64")) {
    Get-ChildItem -Path $dir -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $TARGET } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.FullName -Force -Recurse
                Write-OK "Residuo rimosso: $($_.FullName)"
            } catch {
                Write-Warn "Non rimovibile (in uso?): $($_.FullName)"
            }
        }
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Task Scheduler
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rimozione task schedulati"

$found = $false
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match $TARGET -or $_.TaskPath -match $TARGET } |
    ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false
        Write-OK "Task rimosso: $($_.TaskPath)$($_.TaskName)"
        $found = $true
    }
if (-not $found) { Write-Skipped "Nessun task corrispondente" }

# ─────────────────────────────────────────────────────────────────────────────
# 8. Windows Update: nascondi driver pendenti tramite WUA COM API
#    Equivalente al tasto "Hide" di Windows Update Mini Tool, completamente
#    automatico e senza GUI.
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Nascondere aggiornamenti driver pendenti (Windows Update)"

$wuSearcher = $null
try {
    $wuSession  = New-Object -ComObject Microsoft.Update.Session
    $wuSearcher = $wuSession.CreateUpdateSearcher()

    Write-Host "    Ricerca in corso..." -ForegroundColor DarkGray
    $wuResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=0")

    if ($wuResult.Updates.Count -eq 0) {
        Write-Skipped "Nessun aggiornamento driver pendente"
    } else {
        $hiddenCount = 0
        foreach ($upd in $wuResult.Updates) {
            if ($upd.Title -match $TARGET -or $upd.Description -match $TARGET) {
                $upd.IsHidden = $true
                Write-OK "Nascosto: $($upd.Title)"
                $hiddenCount++
            }
        }
        if ($hiddenCount -eq 0) {
            Write-Skipped "Nessun driver corrispondente tra i $($wuResult.Updates.Count) pendenti"
        }
    }
} catch {
    Write-Warn "WUA COM API non disponibile: $_"
    Write-Host "    Nascondi manualmente i driver da Windows Update o usa Windows Update Mini Tool." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Blacklist Hardware ID — blocco permanente via Group Policy
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Blacklist Hardware ID (blocco permanente)"

$hwIdRegPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPath = "$hwIdRegPath\DenyDeviceIDs"

if (-not (Test-Path $hwIdRegPath)) { New-Item -Path $hwIdRegPath -Force | Out-Null }
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDs'            -Value 1 -Type DWord -Force
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force
if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force | Out-Null }

$knownHwIds = @(
    # Nahimic / A-Volute (vari vendor: HP, MSI, NVIDIA, ASUS)
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

# HW ID dai device PnP ancora presenti
$liveIds = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET } |
    ForEach-Object { $_.HardwareID } |
    Where-Object { $_ }

# HW ID dagli aggiornamenti WU appena nascosti
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

# Legge valori già presenti per evitare duplicati
$existingValues = @{}
(Get-Item -Path $denyListPath -ErrorAction SilentlyContinue).Property | ForEach-Object {
    $v = Get-ItemPropertyValue -Path $denyListPath -Name $_ -ErrorAction SilentlyContinue
    if ($v) { $existingValues[$v] = $true }
}

$counter = if ($existingValues.Count -gt 0) { $existingValues.Count + 1 } else { 1 }

foreach ($hwId in $allHwIds) {
    if ($existingValues.ContainsKey($hwId)) {
        Write-Host "    [=] Già presente: $hwId" -ForegroundColor DarkGray
        continue
    }
    Set-ItemProperty -Path $denyListPath -Name $counter.ToString() -Value $hwId -Type String -Force
    Write-OK "Blacklistato: $hwId"
    $counter++
    $existingValues[$hwId] = $true
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Riepilogo
# ─────────────────────────────────────────────────────────────────────────────
$line = "─" * 62
Write-Host "`n$line" -ForegroundColor DarkGray
Write-Host " Rimozione completata: Nahimic / A-Volute / Sonic Studio / A-Studio" -ForegroundColor Green
Write-Host " Azioni eseguite:" -ForegroundColor White
Write-Host "   - App Win32 disinstallate (UninstallString)" -ForegroundColor White
Write-Host "   - Pacchetti AppX / Store rimossi" -ForegroundColor White
Write-Host "   - Servizi fermati e rimossi" -ForegroundColor White
Write-Host "   - Processi terminati" -ForegroundColor White
Write-Host "   - Chiavi registro + APO eliminati" -ForegroundColor White
Write-Host "   - Driver rimossi dal Driver Store (pnputil)" -ForegroundColor White
Write-Host "   - Dispositivi PnP rimossi" -ForegroundColor White
Write-Host "   - File e cartelle residue eliminate" -ForegroundColor White
Write-Host "   - Task schedulati rimossi" -ForegroundColor White
Write-Host "   - Aggiornamenti WU driver nascosti (WUA COM API)" -ForegroundColor White
Write-Host "   - Hardware ID blacklistati (blocco permanente)" -ForegroundColor White
Write-Host "$line" -ForegroundColor DarkGray

$restart = Read-Host "`nRiavviare ora? (s/N)"
if ($restart -match '^[sS]$') { Restart-Computer -Force }