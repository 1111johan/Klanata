[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'server.ps1') -LibraryOnly

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function Assert-ThrowsCode {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actualCode = ''
    try {
        & $Action
    }
    catch {
        $actualCode = [string]$_.Exception.Data['KlanataErrorCode']
    }
    if ($actualCode -ne $Code) {
        throw "$Message Expected error code '$Code', received '$actualCode'."
    }
}

function New-TestMarketplace {
    param(
        [string]$Id,
        [string]$Name,
        [string]$StoreName,
        [bool]$IsParticipating = $true,
        [bool]$HasSuspendedListings = $false
    )

    return [pscustomobject]@{
        id = $Id
        name = $Name
        countryCode = 'US'
        domainName = 'amazon.com'
        storeName = $StoreName
        isParticipating = $IsParticipating
        hasSuspendedListings = $HasSuspendedListings
    }
}

function New-RawParticipation {
    param([Parameter(Mandatory = $true)][object]$Marketplace)

    return [pscustomobject]@{
        marketplace = [pscustomobject]@{
            id = $Marketplace.id
            name = $Marketplace.name
            countryCode = $Marketplace.countryCode
            domainName = $Marketplace.domainName
        }
        storeName = $Marketplace.storeName
        participation = [pscustomobject]@{
            isParticipating = $Marketplace.isParticipating
            hasSuspendedListings = $Marketplace.hasSuspendedListings
        }
    }
}

function New-TestDiscovery {
    param([Parameter(Mandatory = $true)][object[]]$Marketplaces)

    return [pscustomobject]@{
        region = 'na'
        endpoint = 'https://sellingpartnerapi-na.amazon.com'
        regionAutoDetected = $false
        response = [pscustomobject]@{
            payload = @($Marketplaces | ForEach-Object { New-RawParticipation -Marketplace $_ })
        }
    }
}

$carkeeMarketplace = New-TestMarketplace `
    -Id 'ATVPDKIKX0DER' `
    -Name 'Amazon.com' `
    -StoreName 'Carkee'
$invoicingMarketplace = New-TestMarketplace `
    -Id 'INVOICING-INTERNAL' `
    -Name 'Amazon Invoicing' `
    -StoreName 'Invoicing_1367520_AC7OMGZBRADKF'

$identity = Assert-AllowedAmazonMarketplaces -Marketplaces @($carkeeMarketplace, $invoicingMarketplace)
Assert-Equal $identity.storeName 'Carkee' 'The verified store name is incorrect.'
Assert-Equal @($identity.marketplaceIds).Count 1 'An internal Invoicing participation became selectable.'
Assert-Equal $identity.marketplaceIds[0] 'ATVPDKIKX0DER' 'The wrong Marketplace was accepted.'

$otherStoreMarketplace = New-TestMarketplace `
    -Id 'ATVPDKIKX0DER' `
    -Name 'Amazon.com' `
    -StoreName 'Another Store'
Assert-ThrowsCode `
    -Action { Assert-AllowedAmazonMarketplaces -Marketplaces @($otherStoreMarketplace) | Out-Null } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'A selectable non-Carkee Marketplace was accepted.'

$blankStoreMarketplace = New-TestMarketplace `
    -Id 'ATVPDKIKX0DER' `
    -Name 'Amazon.com' `
    -StoreName ''
Assert-ThrowsCode `
    -Action { Assert-AllowedAmazonMarketplaces -Marketplaces @($blankStoreMarketplace) | Out-Null } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'A selectable Marketplace without a store name was accepted.'
Assert-ThrowsCode `
    -Action { Assert-AllowedAmazonMarketplaces -Marketplaces @($invoicingMarketplace) | Out-Null } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'An authorization without a selectable Marketplace was accepted.'

Assert-True (Test-IsAllowedAmazonSellerId -SellerId 'AC7OMGZBRADKF') 'The production Carkee Seller was not allowed.'
Assert-True (-not (Test-IsAllowedAmazonSellerId -SellerId 'A238CU8SD85H9R')) 'The foreign template Seller was allowed.'
Assert-True (-not (Test-IsAllowedAmazonSellerId -SellerId 'A31XDG4RA4GIQ1')) 'A non-production Seller was allowed.'

$script:RestoreLwaCalls = 0
function Get-LwaToken {
    $script:RestoreLwaCalls++
    throw 'The offline restore test must not reach LWA.'
}
$script:DeveloperApplication = [pscustomobject]@{
    clientId = 'offline-client-id'
    clientSecret = 'offline-client-secret'
}
Assert-ThrowsCode `
    -Action {
        Restore-AuthorizationProfile -Profile ([pscustomobject]@{
            id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            sellerId = 'A238CU8SD85H9R'
            refreshToken = 'offline-foreign-refresh-token'
            requestedRegion = 'auto'
        })
    } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'A foreign stored profile reached restore.'
Assert-Equal $script:RestoreLwaCalls 0 'A foreign stored profile reached LWA during restore.'

$script:AuthSessions.Clear()
$script:AuthorizationProfiles.Clear()
$script:CurrentAuthSessionIds.Clear()
$script:CurrentAuthSessionId = $null
$token = [pscustomobject]@{
    access_token = 'offline-access-token'
    expires_in = 3600
}
$discovery = New-TestDiscovery -Marketplaces @($carkeeMarketplace, $invoicingMarketplace)

$boundSession = Register-AuthorizationSession `
    -Token $token `
    -ClientId 'offline-client-id' `
    -ClientSecret 'offline-client-secret' `
    -RefreshToken 'offline-bound-refresh-token' `
    -SellerId 'AC7OMGZBRADKF' `
    -MarketplaceDiscovery $discovery
Assert-Equal $boundSession.verifiedStoreName 'Carkee' 'The session did not record its verified store.'
Assert-Equal $boundSession.storeIdentitySource 'sellers-v1/getMarketplaceParticipations' 'The session store identity source is incorrect.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$boundSession.storeIdentityVerifiedAt)) `
    'The session store verification time is missing.'
[void](Test-AuthSession -AuthSessionId $boundSession.id)
$publicSession = ConvertTo-PublicAuthSession -Session $boundSession
Assert-True ([bool]$publicSession.storeAllowed) 'The public session was not marked as store-allowed.'
Assert-True ([bool]$publicSession.sellerBound) 'The public session was not marked as Seller-bound.'
Assert-Equal @($publicSession.storeNames).Count 1 'The internal Invoicing store name was exposed as an operator store.'
Assert-Equal @($publicSession.marketplaces).Count 1 'The internal Invoicing Marketplace was exposed as an operator target.'

$sessionCountBeforeReject = $script:AuthSessions.Count
$profileCountBeforeReject = $script:AuthorizationProfiles.Count
Assert-ThrowsCode `
    -Action {
        Register-AuthorizationSession `
            -Token $token `
            -ClientId 'offline-client-id' `
            -ClientSecret 'offline-client-secret' `
            -RefreshToken 'offline-foreign-refresh-token' `
            -SellerId 'A238CU8SD85H9R' `
            -MarketplaceDiscovery $discovery | Out-Null
    } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'A non-allowlisted Seller was registered.'
Assert-Equal $script:AuthSessions.Count $sessionCountBeforeReject 'Rejected Seller registration mutated active sessions.'
Assert-Equal $script:AuthorizationProfiles.Count $profileCountBeforeReject 'Rejected Seller registration mutated profiles.'

$unboundSession = Register-AuthorizationSession `
    -Token $token `
    -ClientId 'offline-client-id' `
    -ClientSecret 'offline-client-secret' `
    -RefreshToken 'offline-unbound-refresh-token' `
    -MarketplaceDiscovery $discovery
$unboundPublicSession = ConvertTo-PublicAuthSession -Session $unboundSession
Assert-True ([bool]$unboundPublicSession.storeAllowed) 'An allowed discovery session was hidden.'
Assert-True (-not [bool]$unboundPublicSession.sellerBound) 'An unbound discovery session was marked as bound.'

$script:MockAuthorizationStoreSaveResult = $true
function Save-AuthorizationStore {
    return [bool]$script:MockAuthorizationStoreSaveResult
}

[void](Set-ValidatedAuthorizationSellerBindings `
    -AuthSessionIds @($unboundSession.id) `
    -SellerId 'AC7OMGZBRADKF')
Assert-Equal $unboundSession.sellerId 'AC7OMGZBRADKF' 'The validated session Seller was not bound.'
Assert-Equal $script:AuthorizationProfiles[$unboundSession.id].sellerId `
    'AC7OMGZBRADKF' `
    'The validated profile Seller was not bound.'

$rollbackSession = Register-AuthorizationSession `
    -Token $token `
    -ClientId 'offline-client-id' `
    -ClientSecret 'offline-client-secret' `
    -RefreshToken 'offline-rollback-refresh-token' `
    -MarketplaceDiscovery $discovery
$script:MockAuthorizationStoreSaveResult = $false
$saveFailureRejected = $false
try {
    Set-ValidatedAuthorizationSellerBindings `
        -AuthSessionIds @($rollbackSession.id) `
        -SellerId 'AC7OMGZBRADKF' | Out-Null
}
catch {
    $saveFailureRejected = $_.Exception.Message -match 'could not be securely persisted'
}
Assert-True $saveFailureRejected 'A Seller binding with failed secure persistence was accepted.'
Assert-Equal $rollbackSession.sellerId '' 'Failed Seller persistence left the session bound in memory.'
Assert-Equal $script:AuthorizationProfiles[$rollbackSession.id].sellerId `
    '' `
    'Failed Seller persistence left the profile bound in memory.'
$script:MockAuthorizationStoreSaveResult = $true

$missingContextRejected = $false
try {
    Assert-AllowedAmazonProductionContext `
        -Session $unboundSession `
        -SellerId 'AC7OMGZBRADKF' `
        -MarketplaceId 'ATVPDKIKX0DER' `
        -RequireValidatedContext
}
catch {
    $missingContextRejected = $_.Exception.Message -match 'not validated'
}
Assert-True $missingContextRejected 'A production context without validation was accepted.'
Add-SessionValidatedContext `
    -Session $unboundSession `
    -SellerId 'AC7OMGZBRADKF' `
    -MarketplaceId 'ATVPDKIKX0DER'
Assert-AllowedAmazonProductionContext `
    -Session $unboundSession `
    -SellerId 'AC7OMGZBRADKF' `
    -MarketplaceId 'ATVPDKIKX0DER' `
    -RequireValidatedContext

$script:Analyses.Clear()
$script:Analyses['existing-analysis'] = [pscustomobject]@{ templateSellerId = 'AC7OMGZBRADKF' }
$script:CurrentAnalysisId = 'existing-analysis'
$script:CurrentAccountValidationId = 'existing-validation'
$foreignAnalysis = [pscustomobject]@{
    templateSellerId = 'A238CU8SD85H9R'
    templateMarketplaceId = 'ATVPDKIKX0DER'
}
Assert-ThrowsCode `
    -Action { Register-TemplateAnalysis -Analysis $foreignAnalysis | Out-Null } `
    -Code 'ACCOUNT_NOT_ALLOWED' `
    -Message 'The foreign template analysis entered workstation state.'
Assert-Equal $script:Analyses.Count 1 'Rejected template analysis changed the analysis store.'
Assert-Equal $script:CurrentAnalysisId 'existing-analysis' 'Rejected template analysis replaced the current analysis.'
Assert-Equal $script:CurrentAccountValidationId 'existing-validation' 'Rejected template analysis cleared account validation.'

Assert-ThrowsCode `
    -Action { ConvertTo-PublicJob -Job ([pscustomobject]@{ sellerId = 'A238CU8SD85H9R' }) | Out-Null } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'A foreign Seller job passed the public conversion guard.'
Assert-ThrowsCode `
    -Action { ConvertTo-PublicPricingBatch -Batch ([pscustomobject]@{ sellerId = 'A238CU8SD85H9R' }) | Out-Null } `
    -Code 'STORE_NOT_ALLOWED' `
    -Message 'A foreign Seller pricing batch passed the public conversion guard.'

$pricingBatch = [pscustomobject]@{
    id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    status = 'SUBMITTED'
    createdAt = '2026-07-17T00:00:00Z'
    updatedAt = '2026-07-17T00:00:00Z'
    approvedAt = '2026-07-17T00:00:00Z'
    submittedAt = '2026-07-17T00:00:00Z'
    accountValidationId = 'validation-id'
    sellerId = 'AC7OMGZBRADKF'
    marketplaceId = 'ATVPDKIKX0DER'
    countryCode = 'US'
    currency = 'USD'
    region = 'na'
    storeName = 'Carkee'
    fileName = 'pricing.csv'
    rows = 1
    direction = 'UP'
    risk = 'LOW'
    rule = [pscustomobject]@{}
    fingerprint = 'fingerprint'
    approvalConfirmation = 'APPROVE'
    submissionConfirmation = 'SUBMIT'
    validationPreview = [pscustomobject]@{}
    items = @()
    submissionJobId = 'cccccccccccccccccccccccccccccccc'
    reportSummary = $null
    error = ''
}
$foreignLinkedJob = [pscustomobject]@{
    id = $pricingBatch.submissionJobId
    kind = 'PRICING'
    pricingBatchId = $pricingBatch.id
    sellerId = 'A238CU8SD85H9R'
    marketplaceId = $pricingBatch.marketplaceId
    feedId = 'FOREIGN-FEED'
    status = 'DONE'
    updatedAt = '2026-07-17T01:00:00Z'
    reportSummary = [pscustomobject]@{ messagesInvalid = 0; errors = 0; warnings = 0 }
    reportFileName = 'foreign-report.json'
    error = ''
}
$script:PricingBatches[$pricingBatch.id] = $pricingBatch
$script:Jobs[$foreignLinkedJob.id] = $foreignLinkedJob
Assert-True (-not (Test-IsValidPricingJobBatchLink -Job $foreignLinkedJob -Batch $pricingBatch)) `
    'A cross-Seller pricing Job/Batch link was accepted.'
$publicBatchWithForeignJob = ConvertTo-PublicPricingBatch -Batch $pricingBatch
Assert-Equal $publicBatchWithForeignJob.feedId '' 'A foreign Job Feed ID leaked through a Carkee pricing batch.'
$statusBeforeForeignUpdate = $pricingBatch.status
Update-PricingBatchFromJob -Job $foreignLinkedJob
Assert-Equal $pricingBatch.status $statusBeforeForeignUpdate 'A foreign Job updated a Carkee pricing batch.'

$matchingJob = $foreignLinkedJob.PSObject.Copy()
$matchingJob.sellerId = 'AC7OMGZBRADKF'
$matchingJob.feedId = 'CARKEE-FEED'
$script:Jobs[$matchingJob.id] = $matchingJob
Assert-True (Test-IsValidPricingJobBatchLink -Job $matchingJob -Batch $pricingBatch) `
    'A matching Carkee pricing Job/Batch link was rejected.'
$publicBatchWithMatchingJob = ConvertTo-PublicPricingBatch -Batch $pricingBatch
Assert-Equal $publicBatchWithMatchingJob.feedId 'CARKEE-FEED' 'A valid Carkee Feed ID was not exposed.'

$wrongMarketplaceJob = $matchingJob.PSObject.Copy()
$wrongMarketplaceJob.marketplaceId = 'A2EUQ1WTGCTBG2'
Assert-True (-not (Test-IsValidPricingJobBatchLink -Job $wrongMarketplaceJob -Batch $pricingBatch)) `
    'A cross-Marketplace pricing Job/Batch link was accepted.'

$unownedAnalysis = [pscustomobject]@{
    templateSellerId = ''
    templateMarketplaceId = ''
}
$unownedAnalysisId = Register-TemplateAnalysis -Analysis $unownedAnalysis
Assert-Equal $script:CurrentAnalysisId $unownedAnalysisId 'A template without Seller metadata was not admitted for preview.'

Write-Output 'Carkee authorization policy verification passed: store identity, Seller allowlist, delayed binding, production context, and foreign-template isolation.'
