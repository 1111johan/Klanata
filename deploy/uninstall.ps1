[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\Klanata Inventory Workstation\app',
    [string]$DataRoot = 'C:\ProgramData\Klanata Inventory Workstation',
    [string]$ServiceName = 'KlanataInventoryWorkstation',
    [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run uninstall.ps1 from an elevated PowerShell session.'
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    & sc.exe delete $ServiceName | Out-Null
}

if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}
if ($PurgeData -and (Test-Path -LiteralPath $DataRoot -PathType Container)) {
    Remove-Item -LiteralPath $DataRoot -Recurse -Force
}

Write-Host 'Klanata Inventory Workstation was uninstalled. Data was preserved unless -PurgeData was specified.'
