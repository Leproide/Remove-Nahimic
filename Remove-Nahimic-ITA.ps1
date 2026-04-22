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
    - Rimozione APO diretta (SS3Config + FxProperties) senza dipendere dal tipo dei valori
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

# Pattern centralizzato
$TARGET = 'Nahimic|A[-_ ]Volute|NhNotif|\bA[-_ ]?Studio\b|Sonic[-_ ]?Studio|SonicSuite|NahimicAPO'

function Write-Step    { param([string]$T); Write-Host "`n[*] $T" -ForegroundColor Cyan }
function Write-OK      { param([string]$T); Write-Host "    [+] $T" -ForegroundColor Green }
function Write-Warn    { param([string]$T); Write-Host "    [!] $T" -ForegroundColor Yellow }
function Write-Skipped { param([string]$T); Write-Host "    [-] $T (non trovato, skip)" -ForegroundColor DarkGray }

# ─────────────────────────────────────────────────────────────────────────────
# 0. Disinstallazione app Win32
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
                if ($cmdLine -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] }
                elseif ($cmdLine -match '^(\S+)\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] }
                else { $exe = $cmdLine; $arg = '' }
                Start-Process -FilePath $exe -ArgumentList $arg -Wait -NoNewWindow
                Write-OK "Disinstallato: $name"
            } catch { Write-Warn "Impossibile disinstallare '$name': $_" }
        }
}

# ─────────────────────────────────────────────────────────────────────────────
# 0b. Pacchetti AppX / Store
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
# 1. Servizi
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Arresto e rimozione servizi"

foreach ($pattern in @('NahimicService','Nahimic_Mirroring','AVolute*','SonicSuite*','ASSonicStudio*','ASonicStudio*')) {
    Get-Service -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Service -Name $_.Name -Force
        Set-Service  -Name $_.Name -StartupType Disabled
        sc.exe delete $_.Name | Out-Null
        Write-OK "Servizio '$($_.Name)' fermato e rimosso"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Processi
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Terminazione processi correlati"

foreach ($pattern in @('NahimicSvc*','NahimicService*','A-Volute*','AVS*','NhNotifSys*',
                       'MSICenter*','MSI*Dragon*','DragonCenter*','OneDragonCenter*',
                       'SonicStudio*','SonicSuite*','ASSonicStudio*','ASonicStudio*','A-Studio*','AStudio*')) {
    $procs = Get-Process -Name $pattern -ErrorAction SilentlyContinue
    if ($procs) { $procs | Stop-Process -Force; Write-OK "Processo '$pattern' terminato" }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Registro: chiavi note
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rimozione chiavi di registro"

# Backup preventivo della classe audio
$audioClassKeyRaw = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$backupFile = Join-Path "$env:USERPROFILE\Desktop" ("AudioClass_backup_{0}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
& reg.exe export $audioClassKeyRaw $backupFile /y 2>&1 | Out-Null
if (Test-Path $backupFile) { Write-OK "Backup classe audio: $backupFile" }
else { Write-Warn "Backup classe audio fallito (non bloccante)" }

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

foreach ($key in $regKeys) {
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force; Write-OK "Chiave rimossa: $key" }
    else { Write-Skipped $key }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3b. Pulizia APO diretta — SS3Config / FxProperties
#
#     I valori sotto PlaybackSS3Config / RecordSS3Config sono PROPVARIANT
#     binari: .ToString() restituisce "System.Byte[]", quindi il pattern
#     matching sui valori non funziona. Si elimina l'intera sottochiave.
#     FxProperties viene ripulita confrontando il NOME della proprietà con
#     i GUID APO noti di Nahimic/Sonic (i nomi sono stringhe leggibili).
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Pulizia APO diretta (SS3Config + FxProperties)"

$audioClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'

$ss3Subkeys = @('PlaybackSS3Config', 'RecordSS3Config')

$knownApoPropertyGuids = @(
    '9B8844FE-1650-40E5-A5EA-11B8C83821A1',
    'F363DF17-A750-4AC3-B7B5-2BBEFFA9085F',
    'E0F2C10F-8244-476E-8EBE-B6EE73D8F2FB',
    'D3465FC4-DB6D-4796-8FDE-0CB851BE2EC9'
)
$apoGuidPattern = '(?i)^\{(' + ($knownApoPropertyGuids -join '|') + ')\}'

Write-Host "    Arresto servizi audio..." -ForegroundColor DarkGray
Stop-Service 'AudioEndpointBuilder', 'audiosrv' -Force -ErrorAction SilentlyContinue

if (Test-Path $audioClassKey) {
    Get-ChildItem -Path $audioClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            $devIndex = $_.PSChildName
            $devPath  = $_.PSPath

            # Elimina le intere sottochiavi SS3Config
            foreach ($ss3 in $ss3Subkeys) {
                $ss3Path    = Join-Path $devPath "InterfaceSetting\$ss3"
                $ss3PathRaw = "$audioClassKeyRaw\$devIndex\InterfaceSetting\$ss3"
                if (Test-Path $ss3Path) {
                    Remove-Item -Path $ss3Path -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path $ss3Path) { & reg.exe delete $ss3PathRaw /f 2>&1 | Out-Null }
                    if (Test-Path $ss3Path) { Write-Warn "Non rimovibile (ACL?): $ss3PathRaw" }
                    else { Write-OK "Eliminato: $devIndex\InterfaceSetting\$ss3" }
                }
            }

            # Rimuove da FxProperties le proprietà il cui nome e' un GUID APO noto
            $fxPath = Join-Path $devPath 'FxProperties'
            if (Test-Path $fxPath) {
                $props = Get-ItemProperty -Path $fxPath -ErrorAction SilentlyContinue
                if ($props) {
                    foreach ($prop in $props.PSObject.Properties) {
                        if ($prop.Name -like 'PS*') { continue }
                        if ($prop.Name -match $apoGuidPattern) {
                            Remove-ItemProperty -Path $fxPath -Name $prop.Name -Force -ErrorAction SilentlyContinue
                            Write-OK "FxProperties rimossa: $devIndex \ $($prop.Name)"
                        }
                    }
                }
            }
        }
} else {
    Write-Skipped "Chiave classe audio non trovata"
}

# Pulizia HKCR\AudioEngine\AudioProcessingObjects
foreach ($ar in @('HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects',
                  'HKLM:\SOFTWARE\Classes\WOW6432Node\AudioEngine\AudioProcessingObjects')) {
    if (-not (Test-Path $ar)) { continue }
    Get-ChildItem -Path $ar -ErrorAction SilentlyContinue | ForEach-Object {
        $friendly  = (Get-ItemProperty -Path $_.PSPath -Name 'FriendlyName' -ErrorAction SilentlyContinue).FriendlyName
        $copyright = (Get-ItemProperty -Path $_.PSPath -Name 'Copyright'    -ErrorAction SilentlyContinue).Copyright
        if (($friendly -and $friendly -match $TARGET) -or ($copyright -and $copyright -match $TARGET)) {
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Registrazione APO rimossa: $($_.PSChildName) ($friendly)"
        }
    }
}

Write-Host "    Riavvio servizi audio..." -ForegroundColor DarkGray
Start-Service 'AudioEndpointBuilder' -ErrorAction SilentlyContinue
Start-Service 'audiosrv'             -ErrorAction SilentlyContinue
Write-OK "Servizi audio riavviati"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Driver Store
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rimozione driver da Driver Store (pnputil)"

$driverList = pnputil /enum-drivers 2>&1
$infFiles   = @()
$currentInf = $null

foreach ($line in $driverList) {
    if ($line -match 'Published Name\s*:\s*(oem\d+\.inf)') { $currentInf = $Matches[1] }
    if ($currentInf) {
        if ($line -match "Provider Name\s*:\s*($TARGET)" -or
            $line -match "Original Name\s*:\s*\S*($TARGET)\S*") {
            if ($infFiles -notcontains $currentInf) { $infFiles += $currentInf }
            $currentInf = $null
        }
    }
}

if ($infFiles.Count -eq 0) { Write-Skipped "Nessun driver corrispondente nel Driver Store" }
else {
    foreach ($inf in $infFiles) {
        Write-Host "    Rimozione: $inf" -ForegroundColor Yellow
        pnputil /delete-driver $inf /uninstall /force 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
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

foreach ($p in $paths) {
    if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force; Write-OK "Rimosso: $p" }
    else { Write-Skipped $p }
}

Write-Host "    Scansione residui in System32 / SysWOW64..." -ForegroundColor DarkGray
foreach ($dir in @("$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64")) {
    Get-ChildItem -Path $dir -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $TARGET } |
        ForEach-Object {
            try { Remove-Item -Path $_.FullName -Force -Recurse; Write-OK "Residuo rimosso: $($_.FullName)" }
            catch { Write-Warn "Non rimovibile (in uso?): $($_.FullName)" }
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
# 8. Windows Update: nascondi driver pendenti (WUA COM API)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Nascondere aggiornamenti driver pendenti (Windows Update)"

$wuSearcher = $null
try {
    $wuSession  = New-Object -ComObject Microsoft.Update.Session
    $wuSearcher = $wuSession.CreateUpdateSearcher()
    Write-Host "    Ricerca in corso..." -ForegroundColor DarkGray
    $wuResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=0")
    if ($wuResult.Updates.Count -eq 0) { Write-Skipped "Nessun aggiornamento driver pendente" }
    else {
        $hiddenCount = 0
        foreach ($upd in $wuResult.Updates) {
            if ($upd.Title -match $TARGET -or $upd.Description -match $TARGET) {
                $upd.IsHidden = $true; Write-OK "Nascosto: $($upd.Title)"; $hiddenCount++
            }
        }
        if ($hiddenCount -eq 0) { Write-Skipped "Nessun driver corrispondente tra i $($wuResult.Updates.Count) pendenti" }
    }
} catch {
    Write-Warn "WUA COM API non disponibile: $_"
    Write-Host "    Nascondi manualmente da Windows Update o usa Windows Update Mini Tool." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Blacklist Hardware ID
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Blacklist Hardware ID (blocco permanente)"

$hwIdRegPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$denyListPath = "$hwIdRegPath\DenyDeviceIDs"

if (-not (Test-Path $hwIdRegPath)) { New-Item -Path $hwIdRegPath -Force | Out-Null }
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDs'            -Value 1 -Type DWord -Force
Set-ItemProperty -Path $hwIdRegPath -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force
if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force | Out-Null }

$knownHwIds = @(
    'SWC\VEN_103C&AID_NAHIMIC', 'SWC\VEN_1462&AID_NAHIMIC',
    'SWC\VEN_10DE&AID_NAHIMIC', 'SWC\VEN_1043&AID_NAHIMIC',
    'ROOT\NAHIMIC_MIRRORING',
    'SWC\VEN_1043&AID_SONICSTUDIO', 'ROOT\SONICSTUDIO', 'ROOT\ASTUDIO'
)

$liveIds = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $TARGET } |
    ForEach-Object { $_.HardwareID } | Where-Object { $_ }

$wuIds = @()
if ($wuSearcher) {
    try {
        $hiddenResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=1")
        foreach ($u in $hiddenResult.Updates) {
            if ($u.Title -match $TARGET) { $u.DriverHardwareID | Where-Object { $_ } | ForEach-Object { $wuIds += $_ } }
        }
    } catch {}
}

$allHwIds = ($knownHwIds + $liveIds + $wuIds) | Sort-Object -Unique

$existingValues = @{}
(Get-Item -Path $denyListPath -ErrorAction SilentlyContinue).Property | ForEach-Object {
    $v = Get-ItemPropertyValue -Path $denyListPath -Name $_ -ErrorAction SilentlyContinue
    if ($v) { $existingValues[$v] = $true }
}

$counter = if ($existingValues.Count -gt 0) { $existingValues.Count + 1 } else { 1 }
foreach ($hwId in $allHwIds) {
    if ($existingValues.ContainsKey($hwId)) { Write-Host "    [=] Gia' presente: $hwId" -ForegroundColor DarkGray; continue }
    Set-ItemProperty -Path $denyListPath -Name $counter.ToString() -Value $hwId -Type String -Force
    Write-OK "Blacklistato: $hwId"
    $counter++; $existingValues[$hwId] = $true
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
Write-Host "   - Chiavi registro eliminate" -ForegroundColor White
Write-Host "   - Backup classe audio salvato sul Desktop" -ForegroundColor White
Write-Host "   - APO puliti: SS3Config eliminato + FxProperties ripulita" -ForegroundColor White
Write-Host "   - Driver rimossi dal Driver Store (pnputil)" -ForegroundColor White
Write-Host "   - Dispositivi PnP rimossi" -ForegroundColor White
Write-Host "   - File e cartelle residue eliminate" -ForegroundColor White
Write-Host "   - Task schedulati rimossi" -ForegroundColor White
Write-Host "   - Aggiornamenti WU driver nascosti (WUA COM API)" -ForegroundColor White
Write-Host "   - Hardware ID blacklistati (blocco permanente)" -ForegroundColor White
Write-Host "$line" -ForegroundColor DarkGray

$restart = Read-Host "`nRiavviare ora? (s/N)"
if ($restart -match '^[sS]$') { Restart-Computer -Force }
