[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][AllowNull()]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

$root = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $root 'server.ps1'
$servicePath = Join-Path $root 'deploy/linux/legacy/klanata-amazon.service'

. $serverPath -LibraryOnly

$writeBlock = Get-LegacyPricingWriteBlock -IsLocalAdmin $true
Assert-Equal $writeBlock.statusCode 403 'Legacy pricing writes must be blocked by default.'
Assert-Equal $writeBlock.code 'V4_REQUIRED' 'Legacy pricing writes must require V4 by default.'

$EnableUnsafeLegacyPricingMigration = $true
$writeBlock = Get-LegacyPricingWriteBlock -IsLocalAdmin $false
Assert-Equal $writeBlock.code 'ADMIN_LOCAL_ONLY' 'The unsafe override must remain local-administrator only.'
$writeBlock = Get-LegacyPricingWriteBlock -IsLocalAdmin $true
Assert-Equal $writeBlock $null 'The explicit unsafe migration override should be the only write escape hatch.'
$EnableUnsafeLegacyPricingMigration = $false

$serverText = Get-Content -LiteralPath $serverPath -Raw -Encoding utf8
foreach ($routePattern in @(
    "`$path -eq '/api/pricing/batches'",
    "`$path -match '^/api/pricing/batches/([a-f0-9]{32})/approve`$'",
    "`$path -match '^/api/pricing/batches/([a-f0-9]{32})/submit`$'"
)) {
    $routeIndex = $serverText.IndexOf($routePattern, [StringComparison]::Ordinal)
    if ($routeIndex -lt 0) { throw "Legacy pricing route was not found: $routePattern" }
    $routeBlock = $serverText.Substring($routeIndex, [Math]::Min(700, $serverText.Length - $routeIndex))
    if ($routeBlock -notmatch 'Get-LegacyPricingWriteBlock') {
        throw "Legacy pricing route does not use the shared V4 gate: $routePattern"
    }
}

$inventoryRoute = "`$path -eq '/api/feeds/submit'"
$inventoryIndex = $serverText.IndexOf($inventoryRoute, [StringComparison]::Ordinal)
if ($inventoryIndex -lt 0) { throw 'Inventory submission route was not found.' }
$inventoryBlock = $serverText.Substring($inventoryIndex, [Math]::Min(500, $serverText.Length - $inventoryIndex))
if ($inventoryBlock -match 'Get-LegacyPricingWriteBlock|V4_REQUIRED') {
    throw 'Inventory upload was incorrectly captured by the legacy pricing lockdown.'
}

$serviceText = Get-Content -LiteralPath $servicePath -Raw -Encoding utf8
if ($serviceText -match 'EnablePricingProduction|EnableUnsafeLegacyPricingMigration') {
    throw 'The production legacy service must not enable any pricing write override.'
}

Write-Output 'Legacy pricing lockdown verification passed.'
