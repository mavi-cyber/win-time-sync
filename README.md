# win-time-sync

A PowerShell script that syncs the Windows clock. It copes with networks where the default time server is blocked, and it fixes the clock shift that appears on every boot when Windows is dual booted with Linux.

## What it does

1. Reports the current time, time zone, hardware clock mode, and whether Linux partitions were found.
2. Probes each candidate NTP server and keeps the ones that answer.
3. On a dual-boot machine, switches Windows to read the hardware clock as UTC so it agrees with Linux.
4. Points the Windows Time service (`w32time`) at the reachable servers and resyncs, with retries.
5. If no server answers and `-HttpFallback` is given, sets the clock from the `Date` header of an HTTPS response (accurate to about a second).

It fixes two common problems:

- The `w32tm /resync` error "The computer did not resync because no time data was available", which usually means `time.windows.com` is unreachable or NTP (UDP 123) is blocked.
- Windows showing the wrong time after every boot into Linux, off by your UTC offset. See "Dual booting with Linux".

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or later
- An elevated PowerShell (Run as administrator) for everything except `-CheckOnly`

## Usage

Check the current offset, clock mode, and Linux detection without changing anything (no admin needed):

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-SystemTime.ps1 -CheckOnly
```

Sync the clock (and apply the dual-boot fix if Linux is detected):

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-SystemTime.ps1
```

Sync without touching the hardware clock mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-SystemTime.ps1 -HardwareClock Keep
```

Sync, and fall back to HTTPS if NTP is blocked:

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-SystemTime.ps1 -HttpFallback
```

Use your own servers and set the time zone first:

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-SystemTime.ps1 -Servers time.cloudflare.com,time.google.com -TimeZone "Pakistan Standard Time"
```

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-Servers` | `time.windows.com`, `time.cloudflare.com`, `time.google.com`, `pool.ntp.org` | NTP servers to try, in order of preference. |
| `-CheckOnly` | off | Report the offset per server, the hardware clock mode, and Linux detection, then exit. Changes nothing. |
| `-HttpFallback` | off | Allow setting the clock from an HTTPS `Date` header when NTP fails. |
| `-HttpHosts` | `www.cloudflare.com`, `www.google.com`, `www.microsoft.com` | Hosts used by `-HttpFallback`. |
| `-Retries` | `3` | Resync attempts before giving up (1 to 10). |
| `-TimeZone` | none | Time zone id to set first. List ids with `Get-TimeZone -ListAvailable`. |
| `-HardwareClock` | `Auto` | How Windows reads the motherboard clock: `Auto` (UTC if Linux partitions are found), `UTC`, `LocalTime`, or `Keep` (never touch it). A change needs a reboot. See "Dual booting with Linux". |
| `-Force` | off | Reconfigure the time source even on a domain-joined machine. |

## Dual booting with Linux

Windows reads the motherboard clock as local time, while Linux reads it as UTC. Each system rewrites the clock in its own format, so after booting the other one the time is off by your UTC offset (5 hours in Pakistan) until the next sync.

The fix is to make both systems agree, and the script does this by default. It looks for Linux partitions on any disk, and if it finds one while Windows is still in local-time mode, it switches Windows to UTC:

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-SystemTime.ps1
```

Reboot afterwards, then run the script once more, because the first boot in the new mode can still show the old shifted time. `-CheckOnly` shows the current mode and whether Linux was detected, without changing anything.

The switch sets the `RealTimeIsUniversal` registry value under `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation`. Use `-HardwareClock LocalTime` to undo it, or `-HardwareClock Keep` to stop the script from touching it.

Detection is by partition type, so an external drive with a Linux filesystem also counts. Use `-HardwareClock Keep` in that case.

The alternative is to leave Windows alone and make Linux use local time instead, by running `timedatectl set-local-rtc 1 --adjust-system-clock` in Linux. If you do that, always pass `-HardwareClock Keep` here. Do one or the other, not both.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Clock synced, or `-CheckOnly` finished. |
| `1` | Sync failed, or the script was not run elevated. |

## Things to know

- A successful sync replaces the configured Windows Time source with the servers that answered the probe. To go back to the Windows default, run `w32tm /config /syncfromflags:manual /manualpeerlist:"time.windows.com,0x9" /update` in an elevated terminal.
- On a domain-joined machine the script leaves the domain time source alone unless `-Force` is given.
- If the `w32time` service is disabled, the script sets it to Manual so it can start.
- The HTTPS fallback is only accurate to about a second, and it can fail if the clock is wrong by days, because TLS certificate checks depend on the date. In that case set the time manually in Settings > Time & language > Date & time, then run the script again.
