# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Install the Kai MSI, check what it put in place, uninstall it, check that
# nothing is left: no service, no program folder, no PATH entry, no Start
# menu shortcut, no Kai hooks. Needs an elevated PowerShell (exit 77 without).
# The app isn't started, so no agent gets connected.
#
#   powershell -ExecutionPolicy Bypass -File tests\windows\run_msi_roundtrip.ps1 -Msi dist\windows\Kai-...msi
param([Parameter(Mandatory = $true)][string]$Msi, [string]$Report = "")
$ErrorActionPreference = "Stop"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Output "skipped: needs an elevated PowerShell"; exit 77 }
$Msi = (Resolve-Path $Msi).Path
$checks = 0; $fails = 0
$log = New-Object System.Collections.Generic.List[string]
function Say($m) { Write-Output $m; $log.Add($m) }
function Check($ok, $what) { $script:checks++; if ($ok) { Say "  ok: $what" } else { $script:fails++; Say "  FAIL: $what" } }
$dir = Join-Path $env:ProgramFiles "Kai"
$lnk = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Kai.lnk"
function MachinePath { [Environment]::GetEnvironmentVariable("PATH", "Machine") }

Say "== Kai MSI round trip =="
$t0 = Get-Date
$p = Start-Process msiexec.exe -ArgumentList "/i", "`"$Msi`"", "/qn", "/norestart", "/l*v", "`"$env:TEMP\kai-msi-install.log`"" -Wait -PassThru
Check ($p.ExitCode -eq 0) "install: msiexec exit $($p.ExitCode)"
Check (Test-Path "$dir\Kai.exe") "Kai.exe in Program Files\Kai"
Check (Test-Path "$dir\bin\kai.exe") "kai.exe in Program Files\Kai\bin"
Check (Test-Path "$dir\bin\kaisvc.exe") "kaisvc.exe in Program Files\Kai\bin"
Check (Test-Path "$dir\kaicore.dll") "kaicore.dll beside Kai.exe"
Check ((MachinePath) -like "*$dir\bin*") "bin on the system PATH"
Check (Test-Path $lnk) "Start menu shortcut"
$s = Get-Service KaiWatch -ErrorAction SilentlyContinue
Check ($s -and $s.Status -eq "Running" -and $s.StartType -eq "Automatic") "Kai Watch service running, starts with Windows"
Check ((Get-CimInstance Win32_Service -Filter "Name='KaiWatch'").StartName -eq "LocalSystem") "Kai Watch runs as LocalSystem"
$v = & "$dir\bin\kai.exe" version
Check ($v -match "commit [0-9a-f]{7,}") "kai version prints the commit: $v"
Check ($v -notmatch "dev build") "kai.exe is a release build"
$snap = Join-Path $env:TEMP ("kai-msi-snap-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$sp = Start-Process "$dir\Kai.exe" -ArgumentList "--snapshot", $snap -PassThru   # renders the pages, connects nothing
$started = $sp.WaitForExit(120000) -and $sp.ExitCode -eq 0 -and (Test-Path "$snap\window-now.png")
if (-not $sp.HasExited) { $sp.Kill() }
Check $started ("the installed app starts and draws its window (exit 0x{0:X8})" -f $sp.ExitCode)
Remove-Item -Recurse -Force $snap -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
$hb = Join-Path $env:ProgramData "Kai\network-health.json"
Check (Test-Path $hb) "Kai Watch wrote its heartbeat"

$p = Start-Process msiexec.exe -ArgumentList "/x", "`"$Msi`"", "/qn", "/norestart", "/l*v", "`"$env:TEMP\kai-msi-uninstall.log`"" -Wait -PassThru
Check ($p.ExitCode -eq 0) "uninstall: msiexec exit $($p.ExitCode)"
Check ($null -eq (Get-Service KaiWatch -ErrorAction SilentlyContinue)) "no Kai Watch service left"
Check (-not (Test-Path $dir)) "no Program Files\Kai left"
Check ((MachinePath) -notlike "*$dir\bin*") "PATH entry removed"
Check (-not (Test-Path $lnk)) "Start menu shortcut removed"
$hooks = @("$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.codex\hooks.json", "$env:USERPROFILE\.cursor\hooks.json") |
    Where-Object { (Test-Path $_) -and ((Get-Content $_ -Raw) -match "kai(\.exe)?[`"' ]+.*hook|hook (claude|codex|cursor)") }
Check ($hooks.Count -eq 0) "no Kai hooks in the user's agent settings"
Say ("took {0:N0} s" -f ((Get-Date) - $t0).TotalSeconds)
Say ""
Say "$checks checks, $fails failures"
if ($Report) { $log | Set-Content $Report -Encoding utf8 }
if ($fails) { exit 1 } else { exit 0 }
