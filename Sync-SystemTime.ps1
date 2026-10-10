<#
.SYNOPSIS
    Syncs the Windows clock, falling back gracefully when NTP is unavailable.

.DESCRIPTION
    1. Probes each candidate NTP server and keeps the ones that answer.
    2. Points the Windows Time service at those servers and resyncs.
    3. If no server answers (NTP blocked on the network) and -HttpFallback is
       given, sets the clock from the Date header of an HTTPS response
       (accurate to about a second).

    Everything except -CheckOnly needs an elevated PowerShell.

.PARAMETER Servers
    NTP servers to try, in order of preference.

.PARAMETER CheckOnly
    Only report the current clock offset per server. Changes nothing.

.PARAMETER HttpFallback
    Allow setting the clock from an HTTPS Date header when NTP is unreachable.

.PARAMETER HttpHosts
    HTTPS hosts used by -HttpFallback.

.PARAMETER Retries
    How many times to attempt the resync before giving up.

.PARAMETER TimeZone
    Optional time zone id to set first (see Get-TimeZone -ListAvailable).

.PARAMETER HardwareClock
    How Windows reads the motherboard clock. Linux keeps it in UTC by default,
    so a dual-boot machine needs UTC here too or the time shifts on every boot.
      Auto      - switch to UTC if Linux partitions are found (default)
      UTC       - always use UTC
      LocalTime - Windows default
      Keep      - never touch the setting
    A change needs a reboot to take effect.

.PARAMETER Force
    Reconfigure the time source even on a domain-joined machine.

.EXAMPLE
    .\Sync-SystemTime.ps1 -CheckOnly

.EXAMPLE
    .\Sync-SystemTime.ps1 -HttpFallback

.EXAMPLE
    .\Sync-SystemTime.ps1 -Servers time.cloudflare.com,time.google.com -TimeZone 'Pakistan Standard Time'
#>
[CmdletBinding()]
param(
    [string[]]$Servers = @('time.windows.com', 'time.cloudflare.com', 'time.google.com', 'pool.ntp.org'),
    [switch]$CheckOnly,
    [switch]$HttpFallback,
    [string[]]$HttpHosts = @('www.cloudflare.com', 'www.google.com', 'www.microsoft.com'),
    [ValidateRange(1, 10)][int]$Retries = 3,
    [string]$TimeZone,
    [ValidateSet('Auto', 'UTC', 'LocalTime', 'Keep')][string]$HardwareClock = 'Auto',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns the clock offset in seconds against $Server, or $null if unreachable.
function Get-NtpOffset([string]$Server) {
    $out = & w32tm /stripchart /computer:$Server /samples:1 /dataonly
    foreach ($line in $out) {
        if ($line -match ',\s*([+-]\d+\.\d+)s') {
            return [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    return $null
}

function Get-HttpTime([string]$HostName) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -Uri "https://$HostName" -Method Head -UseBasicParsing -TimeoutSec 10
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    [DateTime]::ParseExact([string]$r.Headers['Date'], 'R', [Globalization.CultureInfo]::InvariantCulture, $styles)
}

$tzKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'

function Get-HardwareClockMode {
    $p = Get-ItemProperty -Path $tzKey -Name RealTimeIsUniversal -ErrorAction SilentlyContinue
    if ($p -and $p.RealTimeIsUniversal -eq 1) { 'UTC' } else { 'LocalTime' }
}

# True if any disk has a Linux partition (filesystem, swap, LVM, root, home).
function Test-LinuxInstalled {
    $gpt = '{0fc63daf-8483-4772-8e79-3d69d8477de4}', '{0657fd6d-a4ab-43c4-84e5-0933c84b4f4f}',
           '{e6d6d379-f507-44c2-a23c-238f2a3df928}', '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}',
           '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}'
    $mbr = 0x82, 0x83, 0x8e
    try {
        foreach ($p in Get-Partition) {
            if ($p.GptType -and $gpt -contains $p.GptType.ToLower()) { return $true }
            if ($p.MbrType -and $mbr -contains $p.MbrType) { return $true }
        }
    } catch { }
    return $false
}

# --- probe -------------------------------------------------------------------

$clockMode = Get-HardwareClockMode
$hasLinux = Test-LinuxInstalled

Write-Host "Local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ($((Get-TimeZone).Id))"
Write-Host "Hardware clock is read as: $clockMode"
if ($hasLinux -and $clockMode -eq 'LocalTime') {
    Write-Host 'Linux partitions found: Linux keeps the hardware clock in UTC, so the time will shift on every boot until Windows uses UTC too.' -ForegroundColor DarkYellow
}
Write-Host 'Probing NTP servers...'

$reachable = @()
foreach ($s in $Servers) {
    $offset = Get-NtpOffset $s
    if ($null -eq $offset) {
        Write-Host ("  {0,-22} unreachable" -f $s) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  {0,-22} offset {1:+0.000;-0.000}s" -f $s, $offset) -ForegroundColor Green
        $reachable += $s
    }
}

if ($CheckOnly) {
    if (-not $reachable) { Write-Host 'No NTP server reachable (UDP 123 is probably blocked on this network).' }
    exit 0
}

if (-not (Test-Admin)) {
    Write-Error 'Run this from an elevated PowerShell (Run as administrator), or use -CheckOnly.'
}

if ($TimeZone) {
    Set-TimeZone -Id $TimeZone
    Write-Host "Time zone set to $TimeZone"
}

$targetMode = $HardwareClock
if ($targetMode -eq 'Auto') {
    if ($hasLinux) { $targetMode = 'UTC' } else { $targetMode = 'Keep' }
}
if ($targetMode -ne 'Keep' -and $targetMode -ne $clockMode) {
    if ($targetMode -eq 'UTC') {
        Set-ItemProperty -Path $tzKey -Name RealTimeIsUniversal -Value 1 -Type DWord
    } else {
        Remove-ItemProperty -Path $tzKey -Name RealTimeIsUniversal
    }
    Write-Host "Hardware clock mode set to $targetMode. Reboot, then run this script once more." -ForegroundColor Green
}

# --- NTP sync ----------------------------------------------------------------

if ($reachable) {
    $domainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
    if ($domainJoined -and -not $Force) {
        Write-Host 'Domain-joined machine: keeping the domain time source (use -Force to override).'
    } else {
        $peers = ($reachable | ForEach-Object { "$_,0x9" }) -join ' '
        & w32tm /config /manualpeerlist:"$peers" /syncfromflags:manual /update | Out-Null
    }

    $svc = Get-Service w32time
    if ($svc.StartType -eq 'Disabled') { Set-Service w32time -StartupType Manual }
    Restart-Service w32time -Force

    for ($i = 1; $i -le $Retries; $i++) {
        Start-Sleep -Seconds 2
        $out = & w32tm /resync /force
        if ($LASTEXITCODE -eq 0) {
            $after = Get-NtpOffset $reachable[0]
            Write-Host "Synced. Local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
            if ($null -ne $after) { Write-Host ("Remaining offset: {0:+0.000;-0.000}s" -f $after) }
            exit 0
        }
        Write-Host "  attempt $i/$Retries failed: $($out | Select-Object -Last 1)" -ForegroundColor DarkYellow
    }
    Write-Host 'NTP resync did not succeed.' -ForegroundColor DarkYellow
} else {
    Write-Host 'No NTP server reachable (UDP 123 is probably blocked on this network).' -ForegroundColor DarkYellow
}

# --- HTTPS fallback ----------------------------------------------------------

if (-not $HttpFallback) {
    Write-Host 'Re-run with -HttpFallback to set the clock from an HTTPS Date header instead.'
    exit 1
}

# Note: if the clock is wrong by days, TLS certificate checks can fail here too.
foreach ($h in $HttpHosts) {
    try {
        $utc = Get-HttpTime $h
        Set-Date -Date $utc.ToLocalTime() | Out-Null
        Write-Host "Clock set from $h. Local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "  $h failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Write-Host 'Could not get the time over HTTPS either. Set it manually in Settings > Time & language.' -ForegroundColor Red
exit 1
