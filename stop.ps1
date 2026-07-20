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
$identityMatches = $false
if ($null -ne $process -and $process.ProcessName -match '^powershell$') {
    if (-not [string]::IsNullOrWhiteSpace([string]$serverInfo.processStartTimeUtc)) {
        $identityMatches = $process.StartTime.ToUniversalTime().ToString('o') -eq [string]$serverInfo.processStartTimeUtc
    }
    else {
        try {
            $status = Invoke-RestMethod -Uri "http://127.0.0.1:$($serverInfo.port)/api/status" -TimeoutSec 2
            $identityMatches = $status.ok -and (
                [string]::IsNullOrWhiteSpace([string]$serverInfo.instanceId) -or
                [string]$status.instanceId -eq [string]$serverInfo.instanceId
            )
        }
        catch {
            $identityMatches = $false
        }
    }
}

if ($identityMatches) {
    Stop-Process -Id $process.Id
}

Remove-Item -LiteralPath $serverInfoPath -Force
if ($identityMatches) {
    Write-Host 'Amazon SP-API Console stopped.'
}
else {
    Write-Host 'Removed stale server state; no matching console process was stopped.'
}
