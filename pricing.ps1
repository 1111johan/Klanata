Set-StrictMode -Version Latest

function Get-PricingPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Parse-PricingDelimitedLine {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory = $true)][char]$Delimiter
    )

    $fields = [Collections.Generic.List[string]]::new()
    $builder = [Text.StringBuilder]::new()
    $insideQuotes = $false
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($character -eq '"') {
            if ($insideQuotes -and $index + 1 -lt $Line.Length -and $Line[$index + 1] -eq '"') {
                [void]$builder.Append('"')
                $index++
            }
            else {
                $insideQuotes = -not $insideQuotes
            }
            continue
        }
        if ($character -eq $Delimiter -and -not $insideQuotes) {
            [void]$fields.Add($builder.ToString())
            [void]$builder.Clear()
            continue
        }
        [void]$builder.Append($character)
    }
    if ($insideQuotes) {
        throw 'The pricing file contains an unterminated quoted field.'
    }
    [void]$fields.Add($builder.ToString())
    return $fields.ToArray()
}

function Normalize-PricingColumnName {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '' }
    return [regex]::Replace($Value.Trim().ToLowerInvariant(), '[^\p{L}\p{Nd}]', '')
}

function Find-PricingColumnIndex {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Headers,
        [Parameter(Mandatory = $true)][string[]]$Aliases,
        [string[]]$Patterns = @()
    )

    $normalizedAliases = @($Aliases | ForEach-Object { Normalize-PricingColumnName -Value $_ })
    for ($index = 0; $index -lt $Headers.Count; $index++) {
        $normalized = Normalize-PricingColumnName -Value $Headers[$index]
        if ($normalized -in $normalizedAliases) { return $index }
    }
    for ($index = 0; $index -lt $Headers.Count; $index++) {
        $normalized = Normalize-PricingColumnName -Value $Headers[$index]
        foreach ($pattern in $Patterns) {
            if ($normalized -match $pattern) { return $index }
        }
    }
    return -1
}

function Get-PricingField {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Fields,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge $Fields.Count) { return '' }
    return $Fields[$Index].Trim()
}

function ConvertTo-PricingDecimal {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $number = [decimal]0
    $styles = [Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowCurrencySymbol
    if ([decimal]::TryParse($Value, $styles, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    if ([decimal]::TryParse($Value, $styles, [Globalization.CultureInfo]::CurrentCulture, [ref]$number)) {
        return $number
    }
    return $null
}

function ConvertTo-PricingInteger {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $number = 0
    if ([int]::TryParse($Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return $null
}

function ConvertTo-PricingFulfillment {
    param([AllowEmptyString()][string]$Value)

    $normalized = Normalize-PricingColumnName -Value $Value
    if ($normalized -match '^(default|mfn|fbm|merchant|merchantfulfilled|卖家配送|自配送|卖家自配送)$' -or
        $normalized -match 'fulfil(l)?mentbymerchant') { return 'MFN' }
    if ($normalized -match '^(afn|fba)$' -or $normalized -match 'amazon|亚马逊配送') { return 'FBA' }
    return 'UNKNOWN'
}

function ConvertTo-PricingStatus {
    param([AllowEmptyString()][string]$Value)

    $normalized = Normalize-PricingColumnName -Value $Value
    if ($normalized -match '^(active|open|buyable|online|enabled|在线|可售|在售|启用)$') { return 'ACTIVE' }
    if ($normalized -match 'suppress|抑制') { return 'SUPPRESSED' }
    if ($normalized -match 'incomplete|未完成') { return 'INCOMPLETE' }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return 'UNKNOWN' }
    return 'INACTIVE'
}

function Get-PricingMarketplaceCurrency {
    param([AllowEmptyString()][string]$CountryCode)

    switch ($CountryCode.ToUpperInvariant()) {
        'US' { return 'USD' }
        'CA' { return 'CAD' }
        'MX' { return 'MXN' }
        'BR' { return 'BRL' }
        'UK' { return 'GBP' }
        'GB' { return 'GBP' }
        'SE' { return 'SEK' }
        'PL' { return 'PLN' }
        'TR' { return 'TRY' }
        'JP' { return 'JPY' }
        'AU' { return 'AUD' }
        'SG' { return 'SGD' }
        'IN' { return 'INR' }
        'SA' { return 'SAR' }
        'AE' { return 'AED' }
        'EG' { return 'EGP' }
        default { return 'EUR' }
    }
}

function Get-PricingRule {
    param([Parameter(Mandatory = $true)][object]$Rule)

    $direction = ([string](Get-PricingPropertyValue -Object $Rule -Name 'direction' -DefaultValue 'UP')).ToUpperInvariant()
    $lowerMode = ([string](Get-PricingPropertyValue -Object $Rule -Name 'lowerMode' -DefaultValue 'FIXED_AMOUNT')).ToUpperInvariant()
    $upperMode = ([string](Get-PricingPropertyValue -Object $Rule -Name 'upperMode' -DefaultValue 'PERCENTAGE')).ToUpperInvariant()
    $businessPriceMode = ([string](Get-PricingPropertyValue -Object $Rule -Name 'businessPriceMode' -DefaultValue 'DO_NOT_CHANGE')).ToUpperInvariant()
    if ($businessPriceMode -eq 'UNCHANGED') { $businessPriceMode = 'DO_NOT_CHANGE' }
    if ($direction -notin @('UP', 'DOWN')) { throw 'Pricing direction must be UP or DOWN.' }
    if ($lowerMode -notin @('FIXED_AMOUNT', 'PERCENTAGE') -or $upperMode -notin @('FIXED_AMOUNT', 'PERCENTAGE')) {
        throw 'Pricing modes must be FIXED_AMOUNT or PERCENTAGE.'
    }
    if ($businessPriceMode -notin @('PRESERVE_DISCOUNT_RATIO', 'SAME_ABSOLUTE_DELTA', 'SAME_PERCENTAGE', 'DO_NOT_CHANGE')) {
        throw 'Unsupported business price strategy.'
    }

    $threshold = [decimal](Get-PricingPropertyValue -Object $Rule -Name 'threshold' -DefaultValue 100)
    $lowerValue = [decimal](Get-PricingPropertyValue -Object $Rule -Name 'lowerValue' -DefaultValue 0.5)
    $upperValue = [decimal](Get-PricingPropertyValue -Object $Rule -Name 'upperValue' -DefaultValue 0.5)
    $maxAbsoluteChange = [decimal](Get-PricingPropertyValue -Object $Rule -Name 'maxAbsoluteChange' -DefaultValue 0.9)
    if ($threshold -le 0 -or $lowerValue -le 0 -or $upperValue -le 0 -or $maxAbsoluteChange -le 0) {
        throw 'Pricing rule values must be greater than zero.'
    }
    if ($lowerValue -gt 100 -or $upperValue -gt 100 -or $maxAbsoluteChange -gt 1000) {
        throw 'Pricing rule values exceed the simulation safety limits.'
    }

    return [pscustomobject]@{
        direction = $direction
        threshold = $threshold
        lowerMode = $lowerMode
        lowerValue = $lowerValue
        upperMode = $upperMode
        upperValue = $upperValue
        maxAbsoluteChange = $maxAbsoluteChange
        businessPriceMode = $businessPriceMode
    }
}

function Get-PricingChange {
    param(
        [Parameter(Mandatory = $true)][decimal]$CurrentPrice,
        [Parameter(Mandatory = $true)][object]$Rule
    )

    $mode = if ($CurrentPrice -le $Rule.threshold) { $Rule.lowerMode } else { $Rule.upperMode }
    $value = if ($CurrentPrice -le $Rule.threshold) { $Rule.lowerValue } else { $Rule.upperValue }
    $absoluteChange = if ($mode -eq 'PERCENTAGE') { $CurrentPrice * $value / 100 } else { $value }
    $absoluteChange = [Math]::Min($absoluteChange, $Rule.maxAbsoluteChange)
    if ($Rule.direction -eq 'DOWN') { $absoluteChange = -$absoluteChange }
    $newPrice = [Math]::Round($CurrentPrice + $absoluteChange, 2, [MidpointRounding]::AwayFromZero)
    return [pscustomobject]@{
        mode = $mode
        delta = [Math]::Round($newPrice - $CurrentPrice, 2, [MidpointRounding]::AwayFromZero)
        newPrice = $newPrice
    }
}

function Get-NewBusinessPrice {
    param(
        [Parameter(Mandatory = $true)][decimal]$CurrentPrice,
        $BusinessPrice,
        [Parameter(Mandatory = $true)][decimal]$NewPrice,
        [Parameter(Mandatory = $true)][decimal]$Delta,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    if ($null -eq $BusinessPrice) { return $null }
    $currentBusinessPrice = [decimal]$BusinessPrice
    switch ($Mode) {
        'DO_NOT_CHANGE' { return $currentBusinessPrice }
        'SAME_ABSOLUTE_DELTA' { $value = $currentBusinessPrice + $Delta }
        'SAME_PERCENTAGE' { $value = $currentBusinessPrice * ($NewPrice / $CurrentPrice) }
        default { $value = $NewPrice * ($currentBusinessPrice / $CurrentPrice) }
    }
    return [Math]::Round($value, 2, [MidpointRounding]::AwayFromZero)
}

function Invoke-PricingSimulation {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][object]$Rule,
        [Parameter(Mandatory = $true)][object]$Scope,
        [bool]$ProductionEnabled = $false
    )

    $normalizedText = $Text.TrimStart([char]0xFEFF)
    $lines = @($normalizedText -split "`r?`n")
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[-1])) {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    if ($lines.Count -lt 2) { throw 'The pricing file must contain a header and at least one data row.' }
    if ($lines.Count -gt 25010) { throw 'The pricing file contains more than 25,000 data rows.' }

    $delimiter = if ([IO.Path]::GetExtension($FileName).ToLowerInvariant() -eq '.csv') { [char]',' } else { [char]"`t" }
    $headerLineIndex = 0
    $dataLineIndex = 1
    if ($lines[0].StartsWith('settings=', [StringComparison]::OrdinalIgnoreCase)) {
        $settings = @(Parse-PricingDelimitedLine -Line $lines[0] -Delimiter $delimiter)[0]
        $attributeMatch = [regex]::Match($settings, '(?:^|&)attributeRow=(\d+)')
        $dataMatch = [regex]::Match($settings, '(?:^|&)dataRow=(\d+)')
        if (-not $attributeMatch.Success -or -not $dataMatch.Success) {
            throw 'Amazon template metadata is missing attributeRow or dataRow.'
        }
        $headerLineIndex = [int]$attributeMatch.Groups[1].Value - 1
        $dataLineIndex = [int]$dataMatch.Groups[1].Value - 1
    }
    if ($headerLineIndex -ge $lines.Count -or $dataLineIndex -ge $lines.Count) {
        throw 'Pricing file metadata points outside the file.'
    }

    $headers = @(Parse-PricingDelimitedLine -Line $lines[$headerLineIndex] -Delimiter $delimiter)
    $columns = [ordered]@{
        sku = Find-PricingColumnIndex -Headers $headers -Aliases @('sku', 'seller sku', 'seller-sku', 'msku', '商家sku', '卖家sku') -Patterns @('^contributionsku.*value$')
        asin = Find-PricingColumnIndex -Headers $headers -Aliases @('asin', 'asin1', '商品asin')
        quantity = Find-PricingColumnIndex -Headers $headers -Aliases @('quantity', 'qty', 'available quantity', '可售库存', '库存数量', '库存') -Patterns @('fulfillmentavailability.*quantity$')
        fulfillment = Find-PricingColumnIndex -Headers $headers -Aliases @('fulfillment', 'fulfillment channel', 'fulfillment-channel', 'fulfillment type', '配送渠道', '配送方式', '发货方式') -Patterns @('fulfillmentavailability.*fulfillmentchannelcode$')
        status = Find-PricingColumnIndex -Headers $headers -Aliases @('status', 'item status', 'item-status', 'listing status', '商品状态', 'listing状态', '状态')
        price = Find-PricingColumnIndex -Headers $headers -Aliases @('price', 'current price', 'your price', 'standard price', '当前售价', '普通售价', '售价') -Patterns @('purchasableoffer.*audienceall.*ourprice.*valuewithtax$')
        businessPrice = Find-PricingColumnIndex -Headers $headers -Aliases @('business price', 'b2b price', 'business-price', '企业价', '企业售价') -Patterns @('purchasableoffer.*audienceb2b.*ourprice.*valuewithtax$')
        currency = Find-PricingColumnIndex -Headers $headers -Aliases @('currency', 'currency code', '币种') -Patterns @('purchasableoffer.*audienceall.*currency$')
        minimumPrice = Find-PricingColumnIndex -Headers $headers -Aliases @('minimum price', 'min price', 'minimum seller allowed price', '最低价', '最低允许价') -Patterns @('purchasableoffer.*audienceall.*minimumsellerallowedprice.*valuewithtax$')
        maximumPrice = Find-PricingColumnIndex -Headers $headers -Aliases @('maximum price', 'max price', 'maximum seller allowed price', '最高价', '最高允许价') -Patterns @('purchasableoffer.*audienceall.*maximumsellerallowedprice.*valuewithtax$')
        cost = Find-PricingColumnIndex -Headers $headers -Aliases @('cost', 'unit cost', 'product cost', '成本', '成本价')
    }
    if ($columns.sku -lt 0) { throw 'The pricing file is missing a Seller SKU/MSKU column.' }

    $parsedRule = Get-PricingRule -Rule $Rule
    $records = [Collections.Generic.List[object]]::new()
    $skuCounts = @{}
    for ($lineIndex = $dataLineIndex; $lineIndex -lt $lines.Count; $lineIndex++) {
        $fields = @(Parse-PricingDelimitedLine -Line $lines[$lineIndex] -Delimiter $delimiter)
        $sku = Get-PricingField -Fields $fields -Index $columns.sku
        if ([string]::IsNullOrWhiteSpace($sku) -and (@($fields | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)) { continue }
        $key = $sku.ToUpperInvariant()
        if (-not $skuCounts.ContainsKey($key)) { $skuCounts[$key] = 0 }
        $skuCounts[$key]++
        [void]$records.Add([pscustomobject]@{
            sourceRow = $lineIndex + 1
            sku = $sku
            asin = Get-PricingField -Fields $fields -Index $columns.asin
            quantity = ConvertTo-PricingInteger -Value (Get-PricingField -Fields $fields -Index $columns.quantity)
            fulfillment = ConvertTo-PricingFulfillment -Value (Get-PricingField -Fields $fields -Index $columns.fulfillment)
            status = ConvertTo-PricingStatus -Value (Get-PricingField -Fields $fields -Index $columns.status)
            price = ConvertTo-PricingDecimal -Value (Get-PricingField -Fields $fields -Index $columns.price)
            businessPrice = ConvertTo-PricingDecimal -Value (Get-PricingField -Fields $fields -Index $columns.businessPrice)
            currency = (Get-PricingField -Fields $fields -Index $columns.currency).ToUpperInvariant()
            minimumPrice = ConvertTo-PricingDecimal -Value (Get-PricingField -Fields $fields -Index $columns.minimumPrice)
            maximumPrice = ConvertTo-PricingDecimal -Value (Get-PricingField -Fields $fields -Index $columns.maximumPrice)
            cost = ConvertTo-PricingDecimal -Value (Get-PricingField -Fields $fields -Index $columns.cost)
        })
    }
    if ($records.Count -eq 0) { throw 'The pricing file contains no data rows.' }

    $fbaAsins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records) {
        if ($record.fulfillment -eq 'FBA' -and -not [string]::IsNullOrWhiteSpace($record.asin)) {
            [void]$fbaAsins.Add($record.asin)
        }
    }

    $eligible = [Collections.Generic.List[object]]::new()
    $excluded = [Collections.Generic.List[object]]::new()
    $reasonCounts = @{}
    $scopeCurrency = ([string](Get-PricingPropertyValue -Object $Scope -Name 'currency' -DefaultValue '')).ToUpperInvariant()
    foreach ($record in $records) {
        $reason = ''
        if ([string]::IsNullOrWhiteSpace($record.sku) -or [string]::IsNullOrWhiteSpace($record.asin) -or
            $columns.quantity -lt 0 -or $columns.fulfillment -lt 0 -or $columns.status -lt 0 -or $columns.price -lt 0) {
            $reason = 'EXCLUDED_INCOMPLETE'
        }
        elseif ($skuCounts[$record.sku.ToUpperInvariant()] -gt 1) { $reason = 'EXCLUDED_DATA_CONFLICT' }
        elseif ($record.fulfillment -eq 'FBA') { $reason = 'EXCLUDED_FBA' }
        elseif ($record.fulfillment -eq 'UNKNOWN') { $reason = 'EXCLUDED_UNKNOWN_FULFILLMENT' }
        elseif ($fbaAsins.Contains($record.asin)) { $reason = 'EXCLUDED_FBM_WITH_SAME_ASIN_FBA' }
        elseif ($record.status -eq 'SUPPRESSED') { $reason = 'EXCLUDED_SUPPRESSED' }
        elseif ($record.status -eq 'INCOMPLETE') { $reason = 'EXCLUDED_INCOMPLETE' }
        elseif ($record.status -ne 'ACTIVE') { $reason = 'EXCLUDED_INACTIVE' }
        elseif ($null -eq $record.quantity -or $record.quantity -le 0) { $reason = 'EXCLUDED_ZERO_QUANTITY' }
        elseif ($null -eq $record.price -or $record.price -le 0) { $reason = 'EXCLUDED_INVALID_PRICE' }
        elseif (-not [string]::IsNullOrWhiteSpace($record.currency) -and
            -not [string]::IsNullOrWhiteSpace($scopeCurrency) -and $record.currency -ne $scopeCurrency) { $reason = 'EXCLUDED_INVALID_PRICE' }
        elseif ($null -ne $record.businessPrice -and ($record.businessPrice -le 0 -or $record.businessPrice -gt $record.price)) { $reason = 'EXCLUDED_INVALID_PRICE' }

        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            if (-not $reasonCounts.ContainsKey($reason)) { $reasonCounts[$reason] = 0 }
            $reasonCounts[$reason]++
            [void]$excluded.Add([pscustomobject]@{
                row = $record.sourceRow; sku = $record.sku; asin = $record.asin; reason = $reason
            })
            continue
        }

        $change = Get-PricingChange -CurrentPrice $record.price -Rule $parsedRule
        $newBusinessPrice = Get-NewBusinessPrice -CurrentPrice $record.price -BusinessPrice $record.businessPrice -NewPrice $change.newPrice -Delta $change.delta -Mode $parsedRule.businessPriceMode
        if ($change.newPrice -le 0 -or
            ($null -ne $record.minimumPrice -and $change.newPrice -lt $record.minimumPrice) -or
            ($null -ne $record.maximumPrice -and $change.newPrice -gt $record.maximumPrice) -or
            ($null -ne $record.cost -and $change.newPrice -lt $record.cost) -or
            ($null -ne $newBusinessPrice -and $newBusinessPrice -gt $change.newPrice)) {
            $reason = 'EXCLUDED_INVALID_PRICE'
            if (-not $reasonCounts.ContainsKey($reason)) { $reasonCounts[$reason] = 0 }
            $reasonCounts[$reason]++
            [void]$excluded.Add([pscustomobject]@{
                row = $record.sourceRow; sku = $record.sku; asin = $record.asin; reason = $reason
            })
            continue
        }

        $deltaPercent = [Math]::Round([Math]::Abs($change.delta / $record.price * 100), 2)
        $risk = if ($null -ne $record.businessPrice -or $deltaPercent -ge 1) { 'MEDIUM' } else { 'LOW' }
        [void]$eligible.Add([pscustomobject]@{
            row = $record.sourceRow
            sku = $record.sku
            asin = $record.asin
            quantity = $record.quantity
            fulfillment = $record.fulfillment
            currency = $record.currency
            currentPrice = $record.price
            newPrice = $change.newPrice
            delta = $change.delta
            deltaPercent = $deltaPercent
            currentBusinessPrice = $record.businessPrice
            newBusinessPrice = $newBusinessPrice
            businessPriceMode = $parsedRule.businessPriceMode
            calculationMode = $change.mode
            risk = $risk
        })
    }

    $overallRisk = if ($eligible.Count -gt 500) { 'HIGH' } elseif ($eligible.Count -ge 20 -or @($eligible | Where-Object { $_.risk -eq 'MEDIUM' }).Count -gt 0) { 'MEDIUM' } else { 'LOW' }
    $reasonLabels = [ordered]@{
        EXCLUDED_FBA = 'FBA SKU'
        EXCLUDED_FBM_WITH_SAME_ASIN_FBA = '同 ASIN 存在 FBA'
        EXCLUDED_INACTIVE = '非活动 Listing'
        EXCLUDED_ZERO_QUANTITY = '零库存或不可售'
        EXCLUDED_INCOMPLETE = '数据不完整'
        EXCLUDED_SUPPRESSED = 'Listing 被抑制'
        EXCLUDED_INVALID_PRICE = '价格或保护规则异常'
        EXCLUDED_UNKNOWN_FULFILLMENT = '配送渠道未知'
        EXCLUDED_DATA_CONFLICT = '重复 SKU 或数据冲突'
    }
    $reasonSummary = @($reasonLabels.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ code = $_.Key; label = $_.Value; count = if ($reasonCounts.ContainsKey($_.Key)) { $reasonCounts[$_.Key] } else { 0 } }
    })
    $missingColumns = [Collections.Generic.List[string]]::new()
    foreach ($required in @('asin', 'quantity', 'fulfillment', 'status', 'price')) {
        if ($columns[$required] -lt 0) { [void]$missingColumns.Add($required) }
    }

    $submissionLocked = -not $ProductionEnabled -or $missingColumns.Count -gt 0 -or $eligible.Count -eq 0 -or $eligible.Count -gt 20000
    $gateCode = if (-not $ProductionEnabled) {
        'V4_REQUIRED'
    }
    elseif ($missingColumns.Count -gt 0) {
        'REQUIRED_COLUMNS_MISSING'
    }
    elseif ($eligible.Count -eq 0) {
        'NO_ELIGIBLE_ITEMS'
    }
    elseif ($eligible.Count -gt 20000) {
        'BATCH_LIMIT_EXCEEDED'
    }
    else {
        'READY_FOR_APPROVAL'
    }
    $gateMessage = switch ($gateCode) {
        'V4_REQUIRED' { '旧版文件调价仅供管理员应急模拟；生产写入请使用 V4 API 原生调价流程。' }
        'REQUIRED_COLUMNS_MISSING' { '数据缺少生产提交所需列，必须修正后重新模拟。' }
        'NO_ELIGIBLE_ITEMS' { '当前批次没有可提交的调价候选。' }
        'BATCH_LIMIT_EXCEEDED' { '单个生产调价批次最多允许 20,000 个 SKU。' }
        default { '规则模拟已通过，可以创建受控审批批次。' }
    }

    return [pscustomobject]@{
        fileName = $FileName
        generatedAt = [DateTime]::UtcNow.ToString('o')
        scope = $Scope
        rule = $parsedRule
        summary = [pscustomobject]@{
            totalRows = $records.Count
            eligible = $eligible.Count
            excluded = $excluded.Count
            withBusinessPrice = @($eligible | Where-Object { $null -ne $_.currentBusinessPrice }).Count
            direction = $parsedRule.direction
            overallRisk = $overallRisk
            missingColumns = $missingColumns.ToArray()
            submissionLocked = $submissionLocked
        }
        exclusions = $reasonSummary
        eligibleItems = $eligible.ToArray()
        excludedItems = @($excluded | Select-Object -First 250)
        previewTruncated = $eligible.Count -gt 1000 -or $excluded.Count -gt 250
        gate = [pscustomobject]@{
            locked = $submissionLocked
            code = $gateCode
            message = $gateMessage
        }
    }
}

function ConvertTo-PublicPricingSimulation {
    param([Parameter(Mandatory = $true)][object]$Simulation)

    return [ordered]@{
        simulationId = [string](Get-PricingPropertyValue -Object $Simulation -Name 'simulationId' -DefaultValue '')
        fileName = $Simulation.fileName
        generatedAt = $Simulation.generatedAt
        scope = $Simulation.scope
        rule = $Simulation.rule
        summary = $Simulation.summary
        exclusions = $Simulation.exclusions
        eligibleItems = @($Simulation.eligibleItems | Select-Object -First 1000)
        excludedItems = @($Simulation.excludedItems | Select-Object -First 250)
        previewTruncated = [bool]$Simulation.previewTruncated
        gate = $Simulation.gate
    }
}

function Get-PricingBatchFingerprint {
    param(
        [Parameter(Mandatory = $true)][object]$Simulation,
        [Parameter(Mandatory = $true)][string]$SellerId
    )

    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add($SellerId.Trim().ToUpperInvariant())
    [void]$lines.Add(([string]$Simulation.scope.marketplaceId).Trim().ToUpperInvariant())
    [void]$lines.Add(([string]$Simulation.rule.direction).Trim().ToUpperInvariant())
    foreach ($item in @($Simulation.eligibleItems | Sort-Object sku)) {
        [void]$lines.Add((
            '{0}|{1}|{2}|{3}|{4}' -f
            ([string]$item.sku).Trim().ToUpperInvariant(),
            ([decimal]$item.currentPrice).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture),
            ([decimal]$item.newPrice).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture),
            $(if ($null -eq $item.currentBusinessPrice) { '' } else { ([decimal]$item.currentBusinessPrice).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) }),
            $(if ($null -eq $item.newBusinessPrice) { '' } else { ([decimal]$item.newBusinessPrice).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) })
        ))
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PricingApprovalPhrase {
    param(
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$CountryCode,
        [Parameter(Mandatory = $true)][int]$Rows,
        [Parameter(Mandatory = $true)][string]$Direction,
        [Parameter(Mandatory = $true)][string]$Risk
    )

    $sellerSuffix = if ($SellerId.Length -le 4) { $SellerId.ToUpperInvariant() } else { $SellerId.Substring($SellerId.Length - 4).ToUpperInvariant() }
    $prefix = if ($Risk.ToUpperInvariant() -eq 'HIGH') { 'APPROVE HIGH' } else { 'APPROVE' }
    return "$prefix $sellerSuffix $($CountryCode.ToUpperInvariant()) $Rows $($Direction.ToUpperInvariant())"
}

function Get-PricingSubmissionPhrase {
    param(
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$CountryCode,
        [Parameter(Mandatory = $true)][int]$Rows,
        [Parameter(Mandatory = $true)][string]$Direction
    )

    $sellerSuffix = if ($SellerId.Length -le 4) { $SellerId.ToUpperInvariant() } else { $SellerId.Substring($SellerId.Length - 4).ToUpperInvariant() }
    return "SUBMIT $sellerSuffix $($CountryCode.ToUpperInvariant()) $Rows $($Direction.ToUpperInvariant())"
}

function New-PricingOfferPatchValue {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$MarketplaceId,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $offers = [Collections.Generic.List[object]]::new()
    [void]$offers.Add([ordered]@{
        marketplace_id = $MarketplaceId
        currency = $Currency
        audience = 'ALL'
        our_price = @(
            [ordered]@{
                schedule = @(
                    [ordered]@{ value_with_tax = [decimal]$Item.newPrice }
                )
            }
        )
    })
    $businessPriceMode = ([string](Get-PricingPropertyValue -Object $Item -Name 'businessPriceMode' -DefaultValue 'DO_NOT_CHANGE')).ToUpperInvariant()
    if ($businessPriceMode -eq 'UNCHANGED') { $businessPriceMode = 'DO_NOT_CHANGE' }
    if ($businessPriceMode -ne 'DO_NOT_CHANGE' -and $null -ne $Item.newBusinessPrice) {
        [void]$offers.Add([ordered]@{
            marketplace_id = $MarketplaceId
            currency = $Currency
            audience = 'B2B'
            our_price = @(
                [ordered]@{
                    schedule = @(
                        [ordered]@{ value_with_tax = [decimal]$Item.newBusinessPrice }
                    )
                }
            )
        })
    }
    return $offers.ToArray()
}

function New-PricingPatchBody {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$MarketplaceId,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    return [ordered]@{
        productType = 'PRODUCT'
        patches = @(
            [ordered]@{
                op = 'replace'
                path = '/attributes/purchasable_offer'
                value = @(New-PricingOfferPatchValue -Item $Item -MarketplaceId $MarketplaceId -Currency $Currency)
            }
        )
    }
}

function New-PricingFeedJson {
    param(
        [Parameter(Mandatory = $true)][object]$Batch,
        [Parameter(Mandatory = $true)][string]$SellerId
    )

    $messages = [Collections.Generic.List[object]]::new()
    $messageId = 0
    foreach ($item in @($Batch.items)) {
        $messageId++
        $patchBody = New-PricingPatchBody `
            -Item $item `
            -MarketplaceId ([string]$Batch.marketplaceId) `
            -Currency ([string]$Batch.currency)
        [void]$messages.Add([ordered]@{
            messageId = $messageId
            sku = [string]$item.sku
            operationType = 'PATCH'
            productType = $patchBody.productType
            patches = $patchBody.patches
        })
    }

    $feed = [ordered]@{
        header = [ordered]@{
            sellerId = $SellerId
            version = '2.0'
            issueLocale = 'en_US'
        }
        messages = $messages
    }
    return $feed | ConvertTo-Json -Depth 30 -Compress
}
