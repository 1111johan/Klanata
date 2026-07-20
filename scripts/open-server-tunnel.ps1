[CmdletBinding()]
param(
    [string]$Server = '144.225.124.172',
    [string]$User = 'user_cyh',
    [ValidateRange(1024, 65535)]
    [int]$LocalPort = 4320,
    [ValidateRange(1024, 65535)]
    [int]$RemotePort = 4318,
    [switch]$Background
)

$ErrorActionPreference = 'Stop'
$ssh = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($ssh)) {
    throw 'OpenSSH client was not found.'
}

$occupied = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
if ($null -ne $occupied) {
    throw "Local port $LocalPort is already in use."
}

$arguments = @(
    '-N',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3',
    '-L', "127.0.0.1:${LocalPort}:127.0.0.1:${RemotePort}",
    "${User}@${Server}"
)

if (-not $Background) {
    Write-Host "Tunnel active at http://127.0.0.1:$LocalPort/. Press Ctrl+C to close it."
    & $ssh @arguments
    exit $LASTEXITCODE
}

$process = Start-Process -FilePath $ssh -ArgumentList $arguments -WindowStyle Hidden -PassThru
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 250
    if ($process.HasExited) {
        throw "SSH tunnel exited with code $($process.ExitCode)."
    }
    if ($null -ne (Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)) {
        Write-Host "Tunnel active at http://127.0.0.1:$LocalPort/ (PID $($process.Id))."
        return
    }
}

Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
throw 'SSH tunnel did not become ready.'
