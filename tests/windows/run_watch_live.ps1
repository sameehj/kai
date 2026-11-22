# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Live tests for Kai Watch (kaisvc.exe) on a real machine. Needs an elevated
# PowerShell (ETW's kernel providers and the Service Control Manager need an
# administrator); without one it says so and exits 77 (CTest: skipped).
#
#   powershell -ExecutionPolicy Bypass -File tests\windows\run_watch_live.ps1 `
#       -Bin build\Release [-CpuMinutes 10] [-SkipService] [-Report file]
#
# Part 1, ETW (kaisvc run, a throwaway home): a fake agent (a copy of cmd.exe
# named claude.exe under <tmp>\.local\bin, which matches Claude Code's install
# path) runs curl.exe: the connection must be recorded for "claude" with its
# hostname; the same curl run outside the agent must not be. With watch_files
# on, the agent opening a fake private key must be recorded as seen. Then the
# ETW session is stopped from outside: kai status --json must say "Internet
# watching stopped" until Kai Watch restarts it.
# Part 2, CPU: kaisvc run on this machine for -CpuMinutes, its CPU time measured.
# Part 3, the service: install, start, status over the pipe, stop, uninstall.
#
# Nothing from any file is printed. The fake key is made up here.
param(
    [string]$Bin = "build\Release",
    [int]$CpuMinutes = 10,
    [switch]$SkipService,
    [string]$Report = ""
)
$ErrorActionPreference = "Stop"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Output "skipped: needs an elevated PowerShell (ETW and the service manager)"; exit 77 }

$Bin = (Resolve-Path $Bin).Path
$checks = 0; $fails = 0
$log = New-Object System.Collections.Generic.List[string]
function Say($m) { Write-Output $m; $log.Add($m) }
function Check($ok, $what) {
    $script:checks++
    if (-not $ok) { $script:fails++; Say "  FAIL: $what" } else { Say "  ok: $what" }
}

$root = Join-Path $env:TEMP ("kai-watch-live-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$home2 = Join-Path $root "home"
$kh = Join-Path $root "kai-home"
$inst = Join-Path $root "Kai"
New-Item -ItemType Directory -Force $home2, $kh, $inst, "$home2\.ssh", "$home2\.local\bin", "$home2\proj" | Out-Null
Copy-Item "$Bin\kai.exe", "$Bin\kaisvc.exe" $inst
Set-Content "$home2\.ssh\id_ed25519" "KAI-FAKE-TEST-KEY-NOT-REAL" -Encoding ascii
Copy-Item "$env:SystemRoot\System32\cmd.exe" "$home2\.local\bin\claude.exe"
$fakeAgent = "$home2\.local\bin\claude.exe"
$curl = "$env:SystemRoot\System32\curl.exe"
$hb = Join-Path $env:ProgramData "Kai\network-health.json"
$procs = New-Object System.Collections.Generic.List[object]
# leftovers from an earlier run that stopped half way
Get-Process kaisvc -ErrorAction SilentlyContinue | Stop-Process -Force
cmd /c "logman stop Kai-Watch -ets >NUL 2>&1"
Remove-Item $hb -ErrorAction SilentlyContinue

function Kai([string]$args2) {
    return & cmd /c "set USERPROFILE=$home2&& set KAI_HOME=$kh&& `"$inst\kai.exe`" $args2"
}
function Start-Watch([string]$policy) {
    # Kai's default policy (kai init), then the switches this run needs
    Remove-Item "$kh\policy" -ErrorAction SilentlyContinue
    Kai "init" | Out-Null
    Add-Content "$kh\policy" $policy -Encoding ascii
    $save = @($env:USERPROFILE, $env:KAI_HOME, $env:KAI_POLICY)
    $env:USERPROFILE = $home2; $env:KAI_HOME = $kh; $env:KAI_POLICY = $null
    $script:svcLog = Join-Path $root ("kaisvc-" + (Get-Date -Format "HHmmss") + ".log")
    $p = Start-Process "$inst\kaisvc.exe" -ArgumentList "run" -PassThru -WindowStyle Hidden `
        -RedirectStandardError $script:svcLog
    $env:USERPROFILE = $save[0]; $env:KAI_HOME = $save[1]; $env:KAI_POLICY = $save[2]
    $script:procs.Add($p)
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $hb) {
            $j = Get-Content $hb -Raw | ConvertFrom-Json
            if ($j.etw.state -eq "running") { return $p }
        }
    }
    Say "  kaisvc didn't start watching; its log:"
    Get-Content $script:svcLog | ForEach-Object { Say "    $_" }
    throw "kaisvc run didn't start watching"
}
function Stop-Watch($p) {
    if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
    cmd /c "logman stop Kai-Watch -ets >NUL 2>&1"   # the killed process can't stop its session
}
# Every audit line is a JSON record; a line that isn't fails the run.
function Audit() {
    $f = "$kh\audit.log"
    if (-not (Test-Path $f)) { return @() }
    return @(Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json })
}

Say "== Kai Watch live tests =="
try {

# ---------------------------------------------------------------- part 1
Say "ETW: an agent's connections, attributed and filtered"
$p = Start-Watch "egress log`nwatch_files on`n"
$j = Get-Content $hb -Raw | ConvertFrom-Json
Check ($j.etw.state -eq "running" -and $j.running) "heartbeat says watching (etw $($j.etw.state))"

& $fakeAgent /c "`"$curl`" -s -o NUL --noproxy * --max-time 15 https://api.github.com/" | Out-Null
& $curl -s -o NUL --noproxy "*" --max-time 15 https://registry.npmjs.org/ | Out-Null
& $fakeAgent /c "type `"$home2\.ssh\id_ed25519`" > NUL" | Out-Null
Start-Sleep -Seconds 6
$j = Get-Content $hb -Raw | ConvertFrom-Json
Say ("  ETW delivered: process {0}, network {1}, dns {2}, file {3}; parsed: {4}, {5}, {6}, {7}; agent processes now {8}" -f `
    $j.etw.delivered.process, $j.etw.delivered.network, $j.etw.delivered.dns, $j.etw.delivered.file,
    $j.etw.parsed.process, $j.etw.parsed.network, $j.etw.parsed.dns, $j.etw.parsed.file, $j.agent_processes)
Say ("  DNS skipped: " + ($j.etw.dns_skipped | ConvertTo-Json -Compress))
Get-Content $script:svcLog | Where-Object { $_ -notlike "*ChatGPT*" } | Select-Object -First 40 | ForEach-Object { Say "  kaisvc: $_" }

$a = Audit
$net = @($a | Where-Object { $_.source -eq "network" })
$ex = @($net | Where-Object { $_.target -eq "api.github.com" })
Check ($ex.Count -ge 1) "the agent's curl to api.github.com is recorded with its hostname"
if ($ex.Count -ge 1) {
    Check ($ex[0].event -eq "claude" -and $ex[0].decision -eq "log") "recorded as Claude Code, Watch (log), not blocked"
    Check ($ex[0].detail -like "*seen by Kai Watch*") "the record says Kai Watch saw it"
}
Check (@($net | Where-Object { $_.target -like "registry.npmjs.org*" }).Count -eq 0) "curl outside the agent is not recorded"
$seen = @($a | Where-Object { $_.source -eq "storage" -and $_.target -like "*id_ed25519" })
Check ($seen.Count -ge 1) "the agent opening a protected file is recorded as seen"
if ($seen.Count -ge 1) { Check ($seen[0].decision -eq "log" -and $seen[0].detail -like "seen:*") "seen, Watch only" }
$raw = if (Test-Path "$kh\audit.log") { Get-Content "$kh\audit.log" -Raw } else { "" }
Check (-not $raw.Contains("KAI-FAKE-TEST-KEY")) "no file content in any record"
if (Test-Path "$kh\audit.log") {
    Kai "log verify" | Out-Null
    Check ($LASTEXITCODE -eq 0) "kai log verify: the audit chain is intact"
}

Say "ETW: the session dies, status says so, Kai Watch restarts it"
cmd /c "logman stop Kai-Watch -ets >NUL 2>&1"
Start-Sleep -Seconds 6
$j = Get-Content $hb -Raw | ConvertFrom-Json
$st = (Kai "status --json") -join "`n" | ConvertFrom-Json
$noticed = ($j.running -eq $false) -or ($j.etw.restarts -ge 1)
Check $noticed "heartbeat noticed the dead session (running $($j.running), restarts $($j.etw.restarts))"
if ($j.running -eq $false) {
    Check (@($st.degraded | Where-Object { $_ -like "Internet watching stopped*" }).Count -eq 1) "kai status --json: Internet watching stopped"
}
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $j = Get-Content $hb -Raw | ConvertFrom-Json
    if ($j.running -and $j.etw.state -eq "running") { break }
}
Check ($j.running -and $j.etw.restarts -ge 1) "Kai Watch restarted the session by itself (restarts $($j.etw.restarts))"
$st = (Kai "status --json") -join "`n" | ConvertFrom-Json
Check (@($st.degraded | Where-Object { $_ -like "Internet watching*" }).Count -eq 0) "kai status --json is fine again"

Say "pipe: status works; a request from inside an agent is refused"
$ps = (& "$inst\kaisvc.exe" status) -join "" | ConvertFrom-Json
Check ($ps.wall -eq "network") "kaisvc status answers over the pipe"
$r = (& $fakeAgent /c "`"$inst\kaisvc.exe`" pipe stop") -join "" | ConvertFrom-Json
Check ($r.ok -eq $false -and $r.error -like "refused*") "stop from the agent's tree is refused"
$r = (& "$inst\kaisvc.exe" pipe stop) -join "" | ConvertFrom-Json
Check ($r.ok) "stop from outside the agent works"
$j = Get-Content $hb -Raw | ConvertFrom-Json
Check ($j.paused -and $j.mode -eq "off") "heartbeat: paused, mode off"
$r = (& "$inst\kaisvc.exe" pipe start) -join "" | ConvertFrom-Json
Check ($r.ok) "start again"
Stop-Watch $p

Say "status: a heartbeat that says ETW stopped is never shown as healthy"
# written here by an administrator, so it is trusted like the service's own
$now = [int][double]::Parse((Get-Date -UFormat %s))
Set-Content $hb ('{"wall":"network","mode":"log","running":false,"problem":"the ETW session ended (test)","ts":' + $now + '}') -Encoding ascii
$st = (Kai "status --json") -join "`n" | ConvertFrom-Json
Check ($st.state -eq "degraded" -and @($st.degraded | Where-Object { $_ -eq "Internet watching stopped: the ETW session ended (test)" }).Count -eq 1) "kai status --json: Internet watching stopped, with the reason"
Check ($st.walls.observed.network.running -eq $false -and $st.walls.observed.network.verified -eq $false) "observed: not running, not verified"
Remove-Item $hb

# ---------------------------------------------------------------- part 2
if ($CpuMinutes -gt 0) {
    Say "CPU: kaisvc run for $CpuMinutes minute(s), files watch off (the default)"
    $p = Start-Watch "egress log`n"
    Start-Sleep -Seconds 5
    # the service reports its own CPU time (GetProcessTimes) in its heartbeat
    $c0 = (Get-Content $hb -Raw | ConvertFrom-Json).cpu_ms; $t0 = Get-Date
    Start-Sleep -Seconds ($CpuMinutes * 60)
    Start-Sleep -Seconds 5
    $j = Get-Content $hb -Raw | ConvertFrom-Json
    $c1 = $j.cpu_ms; $t1 = Get-Date
    $wall = ($t1 - $t0).TotalMilliseconds
    $cores = [Environment]::ProcessorCount
    $pctCore = 100.0 * ($c1 - $c0) / $wall
    $pctTotal = $pctCore / $cores
    Say ("  CPU: {0:N0} ms over {1:N0} s = {2:N3}% of one core, {3:N4}% of the machine ({4} logical CPUs); {5} events, {6} lost, {7} processes known" -f ($c1 - $c0), ($wall / 1000), $pctCore, $pctTotal, $cores, $j.etw.events, $j.etw.events_lost, $j.processes)
    Check ($pctCore -lt 1.0) "under 1% CPU on average (of one core)"
    Stop-Watch $p
}

# ---------------------------------------------------------------- part 3
if (-not $SkipService) {
    Say "service lifecycle: install, start, status, stop, uninstall"
    & "$inst\kaisvc.exe" install | Out-Null
    $s = Get-Service KaiWatch -ErrorAction SilentlyContinue
    Check ($s -and $s.StartType -eq "Automatic") "installed, starts with Windows"
    $wmi = Get-CimInstance Win32_Service -Filter "Name='KaiWatch'"
    Check ($wmi.StartName -eq "LocalSystem") "runs as LocalSystem"
    & "$inst\kaisvc.exe" start | Out-Null
    Start-Sleep -Seconds 4
    Check ((Get-Service KaiWatch).Status -eq "Running") "running"
    # The service works for whoever is signed in at the console: with nobody
    # there (a CI runner) it waits, and its pipe opens when someone signs in.
    if ((Get-CimInstance Win32_ComputerSystem).UserName) {
        $ps = (& "$inst\kaisvc.exe" status) -join "" | ConvertFrom-Json
        Check ($ps.wall -eq "network" -and $ps.ts -gt 0) "answers over the pipe"
    } else {
        Say "  (nobody signed in at the console: the pipe check is skipped)"
    }
    $acl = (Get-Acl (Split-Path $hb)).Access | Where-Object { $_.FileSystemRights -match "Write|FullControl|Modify" }
    Check (@($acl | Where-Object { $_.IdentityReference -notmatch "SYSTEM|Administrators" }).Count -eq 0) "only SYSTEM and Administrators can write %ProgramData%\Kai"
    & "$inst\kaisvc.exe" stop | Out-Null
    Check ((Get-Service KaiWatch).Status -eq "Stopped") "stopped"
    & "$inst\kaisvc.exe" uninstall | Out-Null
    Start-Sleep -Seconds 1
    Check ($null -eq (Get-Service KaiWatch -ErrorAction SilentlyContinue)) "uninstalled: no service left"
    Check (-not (Test-Path $hb)) "uninstalled: no heartbeat left"
}

} finally {
    foreach ($q in $procs) { if (-not $q.HasExited) { $q.Kill() } }
    cmd /c "logman stop Kai-Watch -ets >NUL 2>&1"
}
Say ""
Say "$checks checks, $fails failures"
if ($Report) { $log | Set-Content $Report -Encoding utf8 }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
if ($fails) { exit 1 } else { exit 0 }
