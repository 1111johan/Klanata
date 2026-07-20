[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'pricing.ps1')

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

$scope = [pscustomobject]@{
    authSessionId = 'test-auth'
    marketplaceId = 'ATVPDKIKX0DER'
    region = 'na'
    storeName = 'Test Store'
    countryCode = 'US'
    currency = 'USD'
}
$rule = [pscustomobject]@{
    direction = 'UP'
    threshold = 100
    lowerMode = 'FIXED_AMOUNT'
    lowerValue = 0.50
    upperMode = 'PERCENTAGE'
    upperValue = 0.50
    maxAbsoluteChange = 0.90
    businessPriceMode = 'PRESERVE_DISCOUNT_RATIO'
}
$csv = @'
Seller SKU,ASIN,Quantity,Fulfillment Channel,Status,Price,Business Price,Currency
SAME-FBM,B000000001,5,MFN,Active,99.99,89.99,USD
SAME-FBA,B000000001,5,FBA,Active,99.99,,USD
BOUNDARY-100,B000000002,10,DEFAULT,Open,100.00,90.00,USD
BOUNDARY-OVER,B000000003,10,Fulfillment by Merchant (Default),Buyable,100.01,,USD
INACTIVE,B000000004,10,MFN,Inactive,80.00,,USD
ZERO,B000000005,0,MFN,Active,80.00,,USD
UNKNOWN,B000000006,10,Unmapped Channel,Active,80.00,,USD
DUPLICATE,B000000007,10,MFN,Active,80.00,,USD
DUPLICATE,B000000008,10,MFN,Active,80.00,,USD
'@

$result = Invoke-PricingSimulation -Text $csv -FileName 'pricing-test.csv' -Rule $rule -Scope $scope
Assert-Equal $result.summary.totalRows 9 'Total row count mismatch.'
Assert-Equal $result.summary.eligible 2 'Eligible row count mismatch.'
Assert-Equal $result.summary.excluded 7 'Excluded row count mismatch.'
Assert-Equal $result.summary.submissionLocked $true 'Submission gate must remain locked.'

$boundary = @($result.eligibleItems | Where-Object { $_.sku -eq 'BOUNDARY-100' })[0]
Assert-Equal $boundary.newPrice ([decimal]100.50) 'The <=100 fixed amount rule is incorrect.'
Assert-Equal $boundary.newBusinessPrice ([decimal]90.45) 'Business discount preservation is incorrect.'
$over = @($result.eligibleItems | Where-Object { $_.sku -eq 'BOUNDARY-OVER' })[0]
Assert-Equal $over.newPrice ([decimal]100.51) 'The >100 percentage rule is incorrect.'
Assert-Equal $over.newBusinessPrice $null 'A missing business price must not be created.'

$downRule = [pscustomobject]@{
    direction = 'DOWN'
    threshold = 100
    lowerMode = 'FIXED_AMOUNT'
    lowerValue = 0.50
    upperMode = 'PERCENTAGE'
    upperValue = 5
    maxAbsoluteChange = 0.90
}
$downCsv = @'
SKU,ASIN,Quantity,Fulfillment,Status,Price,Business Price,Currency
CAP-090,B000000009,10,MFN,Active,1000.00,900.00,USD
'@
$downResult = Invoke-PricingSimulation -Text $downCsv -FileName 'pricing-down.csv' -Rule $downRule -Scope $scope
Assert-Equal $downResult.summary.eligible 1 'The capped decrease row should be eligible.'
Assert-Equal $downResult.eligibleItems[0].newPrice ([decimal]999.10) 'The 0.90 maximum change cap is incorrect.'
Assert-Equal $downResult.eligibleItems[0].delta ([decimal]-0.90) 'The decrease direction is incorrect.'
Assert-Equal $downResult.rule.businessPriceMode 'DO_NOT_CHANGE' 'Business price must default to DO_NOT_CHANGE.'
Assert-Equal $downResult.eligibleItems[0].newBusinessPrice ([decimal]900.00) 'The simulation must show an unchanged business price.'
Assert-Equal $downResult.gate.code 'V4_REQUIRED' 'Legacy simulation must point production writes to V4.'

$productionResult = Invoke-PricingSimulation `
    -Text $downCsv `
    -FileName 'pricing-production.csv' `
    -Rule $downRule `
    -Scope $scope `
    -ProductionEnabled $true
Assert-Equal $productionResult.summary.submissionLocked $false 'A valid simulation must open the controlled production approval gate.'
Assert-Equal $productionResult.gate.code 'READY_FOR_APPROVAL' 'Production gate code mismatch.'

$fingerprint = Get-PricingBatchFingerprint -Simulation $productionResult -SellerId 'A1TESTSELLER'
Assert-Equal $fingerprint.Length 64 'Pricing fingerprint must be a SHA-256 value.'
Assert-Equal (Get-PricingApprovalPhrase -SellerId 'A1TESTSELLER' -CountryCode 'US' -Rows 1 -Direction 'DOWN' -Risk 'LOW') 'APPROVE LLER US 1 DOWN' 'Approval phrase mismatch.'
Assert-Equal (Get-PricingSubmissionPhrase -SellerId 'A1TESTSELLER' -CountryCode 'US' -Rows 1 -Direction 'DOWN') 'SUBMIT LLER US 1 DOWN' 'Submission phrase mismatch.'

$batch = [pscustomobject]@{
    marketplaceId = 'ATVPDKIKX0DER'
    currency = 'USD'
    items = $productionResult.eligibleItems
}
$feed = New-PricingFeedJson -Batch $batch -SellerId 'A1TESTSELLER' | ConvertFrom-Json
Assert-Equal $feed.messages.Count 1 'Pricing feed message count mismatch.'
Assert-Equal $feed.messages[0].operationType 'PATCH' 'Pricing feed must use PATCH.'
Assert-Equal $feed.messages[0].patches[0].path '/attributes/purchasable_offer' 'Pricing feed patch path mismatch.'
Assert-Equal ([decimal]$feed.messages[0].patches[0].value[0].our_price[0].schedule[0].value_with_tax) ([decimal]999.10) 'Pricing feed target value mismatch.'
Assert-Equal $feed.messages[0].patches[0].value.Count 1 'DO_NOT_CHANGE must emit only the consumer offer.'
Assert-Equal $feed.messages[0].patches[0].value[0].audience 'ALL' 'DO_NOT_CHANGE must not emit a B2B audience.'

Write-Output 'Pricing simulation verification passed.'
