# Fallback NDK installer - bypasses the crashing sdkmanager / android CLI.
# Downloads an NDK zip straight from Google, extracts it into the SDK, and
# prints the exact ndkVersion string to put in android/app/build.gradle.kts.
param(
  [string]$Release = "r28c",   # r28c == Pkg.Revision 28.2.13676358 (Flutter 3.47 default)
  [string]$Sdk = "C:\Users\User\AppData\Local\Android\Sdk"
)
$ErrorActionPreference = "Stop"
$url  = "https://dl.google.com/android/repository/android-ndk-$Release-windows.zip"
$zip  = "$env:TEMP\android-ndk-$Release-windows.zip"
$dest = "$env:TEMP\ndk-extract-$Release"

Write-Host "Downloading $url ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $zip

Write-Host "Extracting ..." -ForegroundColor Cyan
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $dest

$inner = Get-ChildItem $dest -Directory | Select-Object -First 1
$props = Join-Path $inner.FullName "source.properties"
$rev = (Select-String -Path $props -Pattern "Pkg.Revision\s*=\s*(.+)").Matches.Groups[1].Value.Trim()
Write-Host "NDK package revision: $rev" -ForegroundColor Green

$target = Join-Path $Sdk "ndk\$rev"
New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
Move-Item $inner.FullName $target

Write-Host ""
Write-Host "Installed to: $target" -ForegroundColor Green
Write-Host "Set this in android/app/build.gradle.kts inside android { }:" -ForegroundColor Yellow
Write-Host "    ndkVersion = `"$rev`"" -ForegroundColor Yellow
