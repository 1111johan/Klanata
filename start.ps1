[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4317,

    [string]$TemplatePath = $env:AMAZON_TEMPLATE_PATH,

    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })]
    [string]$AllowedAmazonStoreName = 'Carkee',

    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })]
    [string[]]$AllowedAmazonSellerIds = @('AC7OMGZBRADKF'),

    [switch]$NoBrowser,

    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverPath = Join-Path $appRoot 'server.ps1'
$runtimePath = Join-Path $appRoot 'runtime'
$serverInfoPath = Join-Path $runtimePath 'server.json'
$normalizedAllowedAmazonStoreName = $AllowedAmazonStoreName.Trim()
$normalizedAllowedAmazonSellerIds = @($AllowedAmazonSellerIds | ForEach-Object {
    @(([string]$_) -split ',')
} | ForEach-Object {
    ([string]$_).Trim().ToUpperInvariant()
} | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
} | Sort-Object -Unique)

if (-not (Test-Path -LiteralPath $runtimePath)) {
    New-Item -ItemType Directory -Path $runtimePath | Out-Null
}

if (Test-Path -LiteralPath $serverInfoPath) {
    try {
        $existing = Get-Content -LiteralPath $serverInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $process = Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $url = "http://127.0.0.1:$($existing.port)/"
            $status = Invoke-RestMethod -Uri "${url}api/status" -TimeoutSec 2
            $identityMatches = $status.ok -and (
                [string]::IsNullOrWhiteSpace([string]$existing.instanceId) -or
                [string]$status.instanceId -eq [string]$existing.instanceId
            ) -and
                [string]$status.allowedAmazonStoreName -eq $normalizedAllowedAmazonStoreName -and
                ((@($status.allowedAmazonSellerIds | Sort-Object) -join ',') -eq
                    ($normalizedAllowedAmazonSellerIds -join ','))
            if ($identityMatches) {
                if (-not $NoBrowser) {
                    Start-Process $url
                }
                Write-Host "Amazon SP-API Console is already running at $url"
                exit 0
            }
        }
    }
    catch {
        # Start a new server below when the saved state is stale.
    }
}

function Test-LocalPort {
    param([int]$Candidate)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect('127.0.0.1', $Candidate, $null, $null)
        $connected = $result.AsyncWaitHandle.WaitOne(150)
        if ($connected) {
            $client.EndConnect($result)
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

while (Test-LocalPort -Candidate $Port) {
    $Port++
    if ($Port -gt 65535) {
        throw 'No available local port was found.'
    }
}

$instanceId = [guid]::NewGuid().ToString('N')
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', "`"$serverPath`"",
    '-Port', $Port,
    '-InstanceId', $instanceId,
    '-AllowedAmazonStoreName', "`"$normalizedAllowedAmazonStoreName`"",
    '-AllowedAmazonSellerIds', "`"$($normalizedAllowedAmazonSellerIds -join ',')`""
)
if (-not [string]::IsNullOrWhiteSpace($TemplatePath)) {
    $arguments += @('-TemplatePath', "`"$TemplatePath`"")
}
if ($ReadOnly) {
    $arguments += '-ReadOnly'
}

$process = Start-Process `
    -FilePath 'powershell.exe' `
    -ArgumentList $arguments `
    -WindowStyle Hidden `
    -PassThru

$serverInfo = [ordered]@{
    pid = $process.Id
    port = $Port
    instanceId = $instanceId
    processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
    startedAt = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText(
    $serverInfoPath,
    ($serverInfo | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)

$url = "http://127.0.0.1:$Port/"
$ready = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 250
    try {
        $status = Invoke-RestMethod -Uri "${url}api/status" -TimeoutSec 2
        if ($status.ok -and [string]$status.instanceId -eq $instanceId) {
            $ready = $true
            break
        }
    }
    catch {
        # Continue waiting while the local server starts.
    }
}

if (-not $ready) {
    $runningProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    if ($null -ne $runningProcess -and
        $runningProcess.StartTime.ToUniversalTime().ToString('o') -eq $serverInfo.processStartTimeUtc) {
        Stop-Process -Id $runningProcess.Id -Force
    }
    Remove-Item -LiteralPath $serverInfoPath -Force -ErrorAction SilentlyContinue
    throw "The local server did not become ready at $url"
}

if (-not $NoBrowser) {
    Start-Process $url
}

Write-Host "Amazon SP-API Console started at $url"
