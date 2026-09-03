# run_demo.ps1 - one-shot demo launcher.
#   .\run_demo.ps1            # start backend, print phone command
#   .\run_demo.ps1 -Run       # also launch the app on the connected phone
param([switch]$Run, [int]$Port = 8080)

$ErrorActionPreference = "Stop"
$flutterBin = "C:\Users\User\Downloads\flutter_windows_3.47.2-stable\flutter\bin"
if (Test-Path $flutterBin) { $env:Path = "$flutterBin;$env:Path" }

$lan = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1).IPAddress
if (-not $lan) {
  $lan = (Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } |
          Select-Object -First 1).IPAddress
}

$apiBase = "http://${lan}:${Port}"
Write-Host ""
Write-Host "  Dashboard : http://localhost:${Port}/"  -ForegroundColor Green
Write-Host "  API base  : $apiBase"                    -ForegroundColor Green
Write-Host ""
Write-Host "  On a second terminal (or with -Run), launch the app:" -ForegroundColor Yellow
Write-Host "    flutter run --release --dart-define=API_BASE_URL=$apiBase" -ForegroundColor Yellow
Write-Host ""

if ($Run) {
  Start-Process python -ArgumentList "`"$PSScriptRoot\mock_backend\server.py`"", "--port", "$Port"
  Start-Sleep -Seconds 2
  Start-Process "http://localhost:$Port/"
  Push-Location $PSScriptRoot
  flutter run --release --dart-define=API_BASE_URL=$apiBase
  Pop-Location
} else {
  python "$PSScriptRoot\mock_backend\server.py" --port $Port
}
