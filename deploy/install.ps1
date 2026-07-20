[CmdletBinding()]
param(
    [string]$PublishPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'publish\win-x64'),
    [string]$InstallRoot = 'C:\Program Files\Klanata Inventory Workstation\app',
    [string]$DataRoot = 'C:\ProgramData\Klanata Inventory Workstation',
    [string]$ServiceName = 'KlanataInventoryWorkstation'
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run install.ps1 from an elevated PowerShell session.'
}
if (-not (Test-Path -LiteralPath $PublishPath -PathType Container)) {
    throw "Publish directory was not found: $PublishPath"
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
Copy-Item -Path (Join-Path $PublishPath '*') -Destination $InstallRoot -Recurse -Force

& icacls.exe $DataRoot /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'LOCAL SERVICE:(OI)(CI)M' | Out-Null
$executable = Join-Path $InstallRoot 'Klanata.Api.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Service executable was not found: $executable"
}

$binaryPath = "`"$executable`""
& sc.exe create $ServiceName binPath= $binaryPath start= auto obj= 'NT AUTHORITY\LocalService' DisplayName= 'Klanata Inventory Workstation' | Out-Null
& sc.exe description $ServiceName 'Local Amazon MFN inventory change control workstation.' | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/30000/restart/120000 | Out-Null
Start-Service -Name $ServiceName

$ready = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Seconds 1
    try {
        $health = Invoke-RestMethod 'http://127.0.0.1:4317/api/v2/system/health' -TimeoutSec 3
        if ($health.overallStatus -in @('healthy', 'degraded')) {
            $ready = $true
            break
        }
    }
    catch {
    }
}
if (-not $ready) {
    throw 'The Windows Service started but did not pass its health check.'
}

Write-Host 'Klanata Inventory Workstation was installed successfully.'
