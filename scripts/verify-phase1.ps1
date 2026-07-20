[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
$npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

if ([string]::IsNullOrWhiteSpace($dotnet)) {
    $dotnet = 'C:\Program Files\dotnet\dotnet.exe'
}
if ([string]::IsNullOrWhiteSpace($npm)) {
    $npm = 'C:\Program Files\nodejs\npm.cmd'
}
if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
    throw '.NET 10 SDK was not found.'
}
if (-not (Test-Path -LiteralPath $npm -PathType Leaf)) {
    throw 'Node.js LTS was not found.'
}

$nodeDirectory = Split-Path -Parent $npm
if (($env:PATH -split ';') -notcontains $nodeDirectory) {
    $env:PATH = "$nodeDirectory;$env:PATH"
}

Push-Location $root
try {
    Invoke-CheckedCommand $dotnet restore Klanata.slnx
    Invoke-CheckedCommand $dotnet build Klanata.slnx --configuration Release --no-restore
    Invoke-CheckedCommand $dotnet test Klanata.slnx --configuration Release --no-build --no-restore

    Push-Location (Join-Path $root 'src\Klanata.Web')
    try {
        Invoke-CheckedCommand $npm ci
        Invoke-CheckedCommand $npm run typecheck
        Invoke-CheckedCommand $npm run lint
        Invoke-CheckedCommand $npm run build
        Invoke-CheckedCommand $npm audit --audit-level=high
    }
    finally {
        Pop-Location
    }

    $vulnerabilityJson = & $dotnet package list --project Klanata.slnx --vulnerable --include-transitive --format json --no-restore
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet vulnerability scan failed.`n$($vulnerabilityJson | Out-String)"
    }

    $vulnerabilityReport = ($vulnerabilityJson | Out-String) | ConvertFrom-Json
    $vulnerablePackages = @(
        $vulnerabilityReport.projects.frameworks.topLevelPackages
        $vulnerabilityReport.projects.frameworks.transitivePackages
    ) | Where-Object { $_.vulnerabilities.Count -gt 0 }

    if ($vulnerablePackages.Count -gt 0) {
        $packageNames = $vulnerablePackages | ForEach-Object { $_.id } | Sort-Object -Unique
        throw "NuGet vulnerability scan found vulnerable packages: $($packageNames -join ', ')"
    }

    Write-Host 'Phase 1 verification passed.'
}
finally {
    Pop-Location
}
