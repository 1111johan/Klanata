[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'server.ps1') -LibraryOnly

$validation = [pscustomobject]@{
    authSessionId = 'primary-session'
    authSessionIds = @('primary-session', 'backup-session')
    sellerId = 'SELLER-TEST'
    marketplaceId = 'MARKETPLACE-TEST'
}

$defaultSelection = Get-ValidatedSubmissionAuthSessionId -Validation $validation
if ($defaultSelection -ne 'primary-session') {
    throw "Expected primary-session, received $defaultSelection."
}

$backupSelection = Get-ValidatedSubmissionAuthSessionId `
    -Validation $validation `
    -RequestedAuthSessionId 'backup-session'
if ($backupSelection -ne 'backup-session') {
    throw "Expected backup-session, received $backupSelection."
}

$rejected = $false
try {
    Get-ValidatedSubmissionAuthSessionId `
        -Validation $validation `
        -RequestedAuthSessionId 'unvalidated-session' | Out-Null
}
catch {
    $rejected = $_.Exception.Message -match 'not validated'
}
if (-not $rejected) {
    throw 'An unvalidated authorization session was not rejected.'
}

$session = [pscustomobject]@{}
Add-SessionValidatedContext `
    -Session $session `
    -SellerId $validation.sellerId `
    -MarketplaceId $validation.marketplaceId
if (-not (Test-SessionValidatedContext `
        -Session $session `
        -SellerId $validation.sellerId `
        -MarketplaceId $validation.marketplaceId)) {
    throw 'Validated Seller/Marketplace context was not recorded on the session.'
}
if (Test-SessionValidatedContext `
        -Session $session `
        -SellerId 'OTHER-SELLER' `
        -MarketplaceId $validation.marketplaceId) {
    throw 'Authorization context validation leaked across Sellers.'
}

$script:RegionProbeCalls = [Collections.Generic.List[string]]::new()
function Invoke-SpApiJson {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$AccessToken,
        [object]$Body
    )

    [void]$script:RegionProbeCalls.Add($Uri)
    if ($Uri -match 'sellingpartnerapi-na') {
        throw 'Unauthorized: Access to requested resource is denied.'
    }
    return [pscustomobject]@{ payload = @() }
}

$regionProbe = Find-SpApiMarketplaceParticipations `
    -AccessToken 'temporary-access-token' `
    -PreferredRegion 'na'
if ($regionProbe.region -ne 'eu' -or -not $regionProbe.regionAutoDetected) {
    throw 'SP-API region auto-detection did not switch from North America to Europe.'
}
if ($script:RegionProbeCalls.Count -ne 2) {
    throw "Expected two region probes, received $($script:RegionProbeCalls.Count)."
}

Write-Host 'Authorization policy verification passed: multi-token selection, context isolation, and region auto-detection.'
