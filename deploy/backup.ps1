[CmdletBinding()]
param(
    [string]$DataRoot = 'C:\ProgramData\Klanata Inventory Workstation',
    [string]$BackupRoot = 'C:\ProgramData\Klanata Inventory Workstation\backups',
    [string]$ServiceName = 'KlanataInventoryWorkstation'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
    throw "Data directory was not found: $DataRoot"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$destination = Join-Path $BackupRoot $timestamp
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$restart = $null -ne $service -and $service.Status -eq 'Running'
if ($restart) {
    Stop-Service -Name $ServiceName
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
}

try {
    foreach ($folder in @('data', 'keys', 'config')) {
        $source = Join-Path $DataRoot $folder
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
        }
    }
    $hashes = Get-ChildItem -LiteralPath $destination -Recurse -File | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName.Substring($destination.Length + 1); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }
    $hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding UTF8
}
finally {
    if ($restart) {
        Start-Service -Name $ServiceName
    }
}

Write-Host "Backup created at $destination"
