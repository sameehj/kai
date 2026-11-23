# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
#
# Build Kai for Windows into one MSI: kai.exe + kaisvc.exe (C, MSVC, release
# build), the app (Kai.exe, self-contained .NET), signed, verified, with
# SHA256SUMS. Run from the repository root in a Developer PowerShell or any
# shell with CMake, the .NET SDK, WiX (dotnet tool) and the Windows SDK.
#
#   powershell -ExecutionPolicy Bypass -File scripts\release\build-windows-msi.ps1 [-SkipApp] [-RequireSigned]
#
# Signing (SHA-256 file digests, RFC 3161 timestamps) uses signtool with ONE
# of these, from the environment (never from a file in the repository):
#   KAI_SIGN_THUMBPRINT          a code-signing certificate in the Windows
#                                certificate store: how DigiCert KeyLocker
#                                (KSP), SSL.com eSigner (CKA) and Certum
#                                SimplySign (virtual card) present a cloud key
#   KAI_SIGN_DLIB, KAI_SIGN_DMDF a signtool /dlib plugin and its metadata file
#   KAI_SIGN_PFX, KAI_SIGN_PFX_PASSWORD   a .pfx file (test certificates only)
#   KAI_TIMESTAMP_URL            optional; default http://timestamp.digicert.com
# Without any of them the build is UNSIGNED, named so, for local testing only:
# the script says what the owner needs and stops there. -RequireSigned makes
# that an error (use it for a release). This script never publishes anything.
param(
    [switch]$SkipApp,
    [switch]$RequireSigned,
    [string]$OutDir = "dist\windows"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location $root

function Step($m) { Write-Host "==> $m" }
function Run([string]$exe, [string[]]$a) {
    & $exe @a
    if ($LASTEXITCODE -ne 0) { throw "$exe failed ($LASTEXITCODE): $($a -join ' ')" }
}

# ---------------------------------------------------------------- version
$hdr = Get-Content include\kai.h -Raw
if ($hdr -notmatch '#define KAI_VERSION "([0-9]+)\.([0-9]+)\.([0-9]+)(-preview\.([0-9]+))?"') { throw "KAI_VERSION not found" }
$version = $Matches[0] -replace '.*"(.*)"', '$1'
$maj = [int]$Matches[1]; $min = [int]$Matches[2]; $pat = [int]$Matches[3]
$pre = if ($Matches[5]) { [int]$Matches[5] } else { 999 }
# MSI compares the first three fields only, so x.y.z-preview.N becomes
# x.y.(z*1000+N) and the final x.y.z becomes x.y.(z*1000+999).
$msiVersion = "$maj.$min.$($pat * 1000 + $pre)"
$commit = (git rev-parse --short=12 HEAD).Trim()
if (git status --porcelain) { $commit += "-dirty" }
Step "Kai $version (MSI $msiVersion), commit $commit"

# ---------------------------------------------------------------- signing
$tsUrl = if ($env:KAI_TIMESTAMP_URL) { $env:KAI_TIMESTAMP_URL } else { "http://timestamp.digicert.com" }
$signArgs = $null
if ($env:KAI_SIGN_THUMBPRINT) { $signArgs = @("/sha1", $env:KAI_SIGN_THUMBPRINT) }
elseif ($env:KAI_SIGN_DLIB -and $env:KAI_SIGN_DMDF) { $signArgs = @("/dlib", $env:KAI_SIGN_DLIB, "/dmdf", $env:KAI_SIGN_DMDF) }
elseif ($env:KAI_SIGN_PFX) { $signArgs = @("/f", $env:KAI_SIGN_PFX, "/p", $env:KAI_SIGN_PFX_PASSWORD) }
$signed = $null -ne $signArgs
if (-not $signed -and $RequireSigned) { throw "-RequireSigned: no signing credentials in the environment (see the top of this script)" }

$signtool = $null
if ($signed) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\" } | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
    if (-not $signtool) { throw "signtool.exe not found: install the Windows SDK" }
}
function Sign([string[]]$files) {
    if (-not $signed -or -not $files) { return }
    foreach ($f in $files) {
        Run $signtool (@("sign") + $signArgs + @("/fd", "SHA256", "/tr", $tsUrl, "/td", "SHA256", "/d", "Kai", $f))
    }
}
function Verify([string[]]$files) {
    foreach ($f in $files) { Run $signtool @("verify", "/pa", "/v", $f) | Out-Null }
}

# ---------------------------------------------------------------- C: kai.exe, kaisvc.exe
$bld = "build-release"
Step "C build (release: ignores KAI_HOME / KAI_POLICY)"
Run cmake @("-S", ".", "-B", $bld, "-G", "Visual Studio 17 2022", "-A", "x64", "-DKAI_RELEASE=ON")
Run cmake @("--build", $bld, "--config", "Release", "--target", "kai", "kaisvc", "kaicore")

$stage = Join-Path $root "build-release\stage"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force "$stage\bin", "$stage\app" | Out-Null
Copy-Item "$bld\Release\kai.exe", "$bld\Release\kaisvc.exe" "$stage\bin"

# ---------------------------------------------------------------- the app
$appProj = "app\windows\Kai\Kai.csproj"
$haveApp = -not $SkipApp -and (Test-Path $appProj)
if ($haveApp) {
    Step "app (self-contained .NET, win-x64)"
    Run dotnet @("publish", $appProj, "-c", "Release", "-r", "win-x64", "--self-contained", "true",
                 "-p:WindowsAppSDKSelfContained=true", "-p:Version=$msiVersion", "-p:InformationalVersion=$version+$commit",
                 "-o", "$stage\app")
    # libkai for the app's in-process calls (pause, daily counts), as Kai.app links it
    Copy-Item "$bld\Release\kaicore.dll" "$stage\app"
    if (Test-Path "$stage\app\bin") { throw "the app publish brought its own bin\ folder: a developer kai.exe must never ship" }
} elseif (-not $SkipApp) {
    throw "$appProj not found (use -SkipApp for a CLI-and-service MSI)"
}
# The shipped kai.exe must be this commit's release build.
$kv = & "$stage\bin\kai.exe" version
if ($kv -match "dev build" -or $kv -notmatch [regex]::Escape($commit.Split("-")[0])) { throw "staged kai.exe is not this commit's release build: $kv" }

# ---------------------------------------------------------------- sign the binaries
# Ours, and anything that isn't signed yet; files Microsoft already signed
# (the .NET runtime, the Windows App SDK) keep their own signature.
$bins = Get-ChildItem $stage -Recurse -Include *.exe, *.dll | Where-Object {
    $_.Directory.FullName -like "$stage\bin*" -or $_.Name -eq "Kai.exe" -or $_.Name -eq "Kai.dll" -or
    (Get-AuthenticodeSignature $_.FullName).Status -ne "Valid" } | Select-Object -ExpandProperty FullName
if ($signed) { Step "signing $($bins.Count) files"; Sign $bins; Verify $bins }

# ---------------------------------------------------------------- MSI
Step "MSI"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$name = "Kai-$version-x64" + $(if ($signed) { "" } else { "-UNSIGNED" }) + ".msi"
$msi = Join-Path (Resolve-Path $OutDir).Path $name
$wixArgs = @("build", "-arch", "x64", "-ext", "WixToolset.Util.wixext", "-d", "ProductVersion=$msiVersion",
             "-d", "BinDir=$stage\bin", "-d", "IconFile=installer\windows\Kai.ico")
if ($haveApp) { $wixArgs += @("-d", "AppDir=$stage\app") }
$wixArgs += @("-o", $msi, "installer\windows\Kai.wxs")
Run wix $wixArgs
if ($signed) { Sign @($msi); Verify @($msi) }

$hash = (Get-FileHash $msi -Algorithm SHA256).Hash.ToLower()
"$hash  $name" | Set-Content (Join-Path $OutDir "SHA256SUMS") -Encoding ascii
Step "$msi"
Write-Host "    SHA-256 $hash"

if (-not $signed) {
    Write-Host ""
    Write-Host "UNSIGNED BUILD: for testing on this machine only. Do not publish it." -ForegroundColor Yellow
    Write-Host "To sign a release, the owner needs an OV (or EV) code-signing certificate with cloud signing,"
    Write-Host "set up so signtool can reach it, then runs, in a fresh PowerShell:"
    Write-Host ""
    Write-Host '  # DigiCert KeyLocker / SSL.com eSigner (CKA) / Certum SimplySign: the certificate shows up'
    Write-Host '  # in "certmgr.msc" > Personal > Certificates once the vendor tool is signed in.'
    Write-Host '  Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Format-List Subject, Thumbprint'
    Write-Host '  $env:KAI_SIGN_THUMBPRINT = "<that thumbprint>"'
    Write-Host '  powershell -ExecutionPolicy Bypass -File scripts\release\build-windows-msi.ps1 -RequireSigned'
    Write-Host ""
    Write-Host "It signs kai.exe, kaisvc.exe, Kai.exe and every unsigned DLL, then the MSI (SHA-256, RFC 3161"
    Write-Host "timestamp from $tsUrl), checks each with signtool verify /pa /v, and writes SHA256SUMS."
}
