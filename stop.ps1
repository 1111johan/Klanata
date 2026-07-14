[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverInfoPath = Join-Path $appRoot 'runtime\server.json'

if (-not (Test-Path -LiteralPath $serverInfoPath)) {
    Write-Host 'Amazon SP-API Console is not running.'
    exit 0
}

$serverInfo = Get-Content -LiteralPath $serverInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
$process = Get-Process -Id ([int]$serverInfo.pid) -ErrorAction SilentlyContinue
if ($null -ne $process -and $process.ProcessName -match '^powershell$') {
    Stop-Process -Id $process.Id
}

Remove-Item -LiteralPath $serverInfoPath -Force
Write-Host 'Amazon SP-API Console stopped.'
