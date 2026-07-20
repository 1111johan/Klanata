[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4318
)

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

Push-Location (Join-Path $root 'src\Klanata.Web')
try {
    Invoke-CheckedCommand $npm ci
    Invoke-CheckedCommand $npm run build
}
finally {
    Pop-Location
}

$env:ASPNETCORE_ENVIRONMENT = 'Development'
$runArguments = @(
    'run'
    '--project'
    (Join-Path $root 'src\Klanata.Api\Klanata.Api.csproj')
    '--no-launch-profile'
    '--'
    '--urls'
    "http://127.0.0.1:$Port"
)
Invoke-CheckedCommand -FilePath $dotnet -ArgumentList $runArguments
