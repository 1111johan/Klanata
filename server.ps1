[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4317,

    [string]$TemplatePath = $env:AMAZON_TEMPLATE_PATH
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:PublicRoot = Join-Path $script:AppRoot 'public'
$script:RuntimeRoot = Join-Path $script:AppRoot 'runtime'
$script:JobsPath = Join-Path $script:RuntimeRoot 'jobs.json'
$script:DefaultSourceFile = $TemplatePath
$script:MaxBodyBytes = 8MB
$script:Analyses = @{}
$script:AuthSessions = @{}
$script:AccountValidations = @{}
$script:Jobs = @{}

if (-not (Test-Path -LiteralPath $script:RuntimeRoot)) {
    New-Item -ItemType Directory -Path $script:RuntimeRoot | Out-Null
}

function Write-Utf8WithoutBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-ErrorDetail {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
        return [string]$ErrorRecord.ErrorDetails.Message
    }

    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        try {
            $stream = $response.GetResponseStream()
            $reader = [IO.StreamReader]::new($stream)
            try {
                $body = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    return $body
                }
            }
            finally {
                $reader.Dispose()
                $stream.Dispose()
            }
        }
        catch {
            # Fall through to the exception message.
        }
    }

    return $ErrorRecord.Exception.Message
}

function ConvertTo-SafeAmazonMessage {
    param([Parameter(Mandatory = $true)][string]$Detail)

    try {
        $parsed = $Detail | ConvertFrom-Json
        if ($null -ne $parsed.errors) {
            return (@($parsed.errors | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace([string]$_.code)) {
                    [string]$_.message
                }
                else {
                    "$($_.code): $($_.message)"
                }
            }) -join ' | ')
        }
    }
    catch {
        # Use the original text when the response is not JSON.
    }

    return $Detail
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory = $true)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][object]$Value,
        [int]$StatusCode = 200
    )

    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Write-ApiError {
    param(
        [Parameter(Mandatory = $true)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$StatusCode = 400,
        [string]$Code = 'REQUEST_FAILED'
    )

    Write-JsonResponse -Context $Context -StatusCode $StatusCode -Value ([ordered]@{
        error = [ordered]@{
            code = $Code
            message = $Message
        }
    })
}

function Read-JsonBody {
    param([Parameter(Mandatory = $true)][Net.HttpListenerRequest]$Request)

    if ($Request.ContentLength64 -gt $script:MaxBodyBytes) {
        throw "Request body exceeds the $($script:MaxBodyBytes / 1MB) MB limit."
    }

    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{}
    }

    return $text | ConvertFrom-Json
}

function Parse-TsvLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

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

        if ($character -eq "`t" -and -not $insideQuotes) {
            [void]$fields.Add($builder.ToString())
            [void]$builder.Clear()
            continue
        }

        [void]$builder.Append($character)
    }

    if ($insideQuotes) {
        throw 'The template contains an unterminated quoted field.'
    }

    [void]$fields.Add($builder.ToString())
    return $fields.ToArray()
}

function ConvertTo-FulfillmentChannelCode {
    param([Parameter(Mandatory = $true)][string]$Value)

    switch -Regex ($Value.Trim()) {
        '^(DEFAULT|Fulfilment by Merchant \(Default\)|Fulfillment by Merchant \(Default\))$' {
            return 'DEFAULT'
        }
        '^AMAZON_NA$' {
            return 'AMAZON_NA'
        }
        default {
            throw "Unsupported fulfillment channel: $Value"
        }
    }
}

function Analyze-TemplateText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $normalized = $Text.TrimStart([char]0xFEFF)
    $lines = @($normalized -split "`r?`n")
    while ($lines.Count -gt 0 -and [string]::IsNullOrEmpty($lines[-1])) {
        if ($lines.Count -eq 1) {
            $lines = @()
        }
        else {
            $lines = @($lines[0..($lines.Count - 2)])
        }
    }

    if ($lines.Count -lt 7) {
        throw 'The file does not contain a complete Amazon price and quantity template.'
    }

    $settingsFields = @(Parse-TsvLine -Line $lines[0])
    $settings = $settingsFields[0]
    $labelMatch = [regex]::Match($settings, '(?:^|&)labelRow=(\d+)')
    $attributeMatch = [regex]::Match($settings, '(?:^|&)attributeRow=(\d+)')
    $dataMatch = [regex]::Match($settings, '(?:^|&)dataRow=(\d+)')

    if (-not ($labelMatch.Success -and $attributeMatch.Success -and $dataMatch.Success)) {
        throw 'Template metadata is missing labelRow, attributeRow, or dataRow.'
    }

    $labelRow = [int]$labelMatch.Groups[1].Value
    $attributeRow = [int]$attributeMatch.Groups[1].Value
    $dataRow = [int]$dataMatch.Groups[1].Value

    if ($labelRow -gt $lines.Count -or $attributeRow -gt $lines.Count -or $dataRow -gt $lines.Count) {
        throw 'Template row metadata points outside the file.'
    }

    $labels = @(Parse-TsvLine -Line $lines[$labelRow - 1])
    $attributes = @(Parse-TsvLine -Line $lines[$attributeRow - 1])

    if ($labels.Count -ne $attributes.Count) {
        throw 'The label and attribute rows have different column counts.'
    }

    $skuAttribute = 'contribution_sku#1.value'
    $channelAttribute = 'fulfillment_availability#1.fulfillment_channel_code'
    $quantityAttribute = 'fulfillment_availability#1.quantity'
    $skuIndex = [Array]::IndexOf($attributes, $skuAttribute)
    $channelIndex = [Array]::IndexOf($attributes, $channelAttribute)
    $quantityIndex = [Array]::IndexOf($attributes, $quantityAttribute)

    if ($skuIndex -lt 0 -or $channelIndex -lt 0 -or $quantityIndex -lt 0) {
        throw 'The file is missing SKU, fulfillment channel, or quantity attributes.'
    }

    $records = [Collections.Generic.List[object]]::new()
    $seenSkus = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $nonEmptyCounts = New-Object int[] $attributes.Count
    $zeroCount = 0
    $positiveCount = 0
    $minimumQuantity = [int]::MaxValue
    $maximumQuantity = [int]::MinValue
    $quantityTotal = [long]0
    $bins = [ordered]@{
        zero = 0
        low = 0
        medium = 0
        high = 0
        bulk = 0
        veryHigh = 0
    }

    for ($lineIndex = $dataRow - 1; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ([string]::IsNullOrWhiteSpace($lines[$lineIndex])) {
            continue
        }

        $fields = @(Parse-TsvLine -Line $lines[$lineIndex])
        if ($fields.Count -ne $attributes.Count) {
            throw "Row $($lineIndex + 1) has $($fields.Count) columns; expected $($attributes.Count)."
        }

        for ($columnIndex = 0; $columnIndex -lt $fields.Count; $columnIndex++) {
            if (-not [string]::IsNullOrWhiteSpace($fields[$columnIndex])) {
                $nonEmptyCounts[$columnIndex]++
            }
        }

        $sku = $fields[$skuIndex].Trim()
        $channel = $fields[$channelIndex].Trim()
        $quantityText = $fields[$quantityIndex].Trim()

        if ([string]::IsNullOrWhiteSpace($sku)) {
            throw "Row $($lineIndex + 1) contains an empty SKU."
        }
        if (-not $seenSkus.Add($sku)) {
            throw "Duplicate SKU found: $sku"
        }

        $quantity = 0
        if (-not [int]::TryParse(
            $quantityText,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$quantity
        ) -or $quantity -lt 0) {
            throw "Invalid quantity for SKU ${sku}: $quantityText"
        }

        $channelCode = ConvertTo-FulfillmentChannelCode -Value $channel
        if ($channelCode -ne 'DEFAULT') {
            throw "SKU $sku uses $channelCode. This console only submits merchant-fulfilled inventory."
        }

        if ($quantity -eq 0) {
            $zeroCount++
            $bins.zero++
        }
        else {
            $positiveCount++
            if ($quantity -le 9) { $bins.low++ }
            elseif ($quantity -le 49) { $bins.medium++ }
            elseif ($quantity -le 99) { $bins.high++ }
            elseif ($quantity -le 499) { $bins.bulk++ }
            else { $bins.veryHigh++ }
        }

        $minimumQuantity = [Math]::Min($minimumQuantity, $quantity)
        $maximumQuantity = [Math]::Max($maximumQuantity, $quantity)
        $quantityTotal += $quantity

        [void]$records.Add([pscustomobject]@{
            sku = $sku
            fulfillmentChannelCode = $channelCode
            quantity = $quantity
            sourceRow = $lineIndex + 1
        })
    }

    if ($records.Count -eq 0) {
        throw 'No uploadable data rows were found.'
    }
    if ($records.Count -gt 25000) {
        throw "The file contains $($records.Count) rows; JSON_LISTINGS_FEED supports at most 25,000 messages per feed."
    }

    $nonEmptyColumns = [Collections.Generic.List[object]]::new()
    for ($columnIndex = 0; $columnIndex -lt $labels.Count; $columnIndex++) {
        if ($nonEmptyCounts[$columnIndex] -gt 0) {
            [void]$nonEmptyColumns.Add([pscustomobject]@{
                index = $columnIndex + 1
                label = $labels[$columnIndex]
                attribute = $attributes[$columnIndex]
                nonEmpty = $nonEmptyCounts[$columnIndex]
            })
        }
    }

    $preview = @($records | Select-Object -First 12 | ForEach-Object {
        [pscustomobject]@{
            sku = $_.sku
            channel = $_.fulfillmentChannelCode
            quantity = $_.quantity
            row = $_.sourceRow
        }
    })

    return [pscustomobject]@{
        fileName = $FileName
        records = $records
        summary = [pscustomobject]@{
            rows = $records.Count
            uniqueSkus = $seenSkus.Count
            zeroQuantity = $zeroCount
            positiveQuantity = $positiveCount
            minQuantity = $minimumQuantity
            maxQuantity = $maximumQuantity
            totalQuantity = $quantityTotal
            skippedExampleRows = $dataRow - $attributeRow - 1
            columnCount = $attributes.Count
        }
        distribution = @(
            [pscustomobject]@{ key = 'zero'; label = '0'; count = $bins.zero }
            [pscustomobject]@{ key = 'low'; label = '1-9'; count = $bins.low }
            [pscustomobject]@{ key = 'medium'; label = '10-49'; count = $bins.medium }
            [pscustomobject]@{ key = 'high'; label = '50-99'; count = $bins.high }
            [pscustomobject]@{ key = 'bulk'; label = '100-499'; count = $bins.bulk }
            [pscustomobject]@{ key = 'veryHigh'; label = '500+'; count = $bins.veryHigh }
        )
        preview = $preview
        nonEmptyColumns = $nonEmptyColumns
    }
}

function New-ListingsFeedJson {
    param(
        [Parameter(Mandatory = $true)][object]$Analysis,
        [Parameter(Mandatory = $true)][string]$SellerId
    )

    $messages = [Collections.Generic.List[object]]::new()
    $messageId = 0
    foreach ($record in $Analysis.records) {
        $messageId++
        [void]$messages.Add([ordered]@{
            messageId = $messageId
            sku = $record.sku
            operationType = 'PARTIAL_UPDATE'
            productType = 'PRODUCT'
            attributes = [ordered]@{
                fulfillment_availability = @(
                    [ordered]@{
                        fulfillment_channel_code = $record.fulfillmentChannelCode
                        quantity = $record.quantity
                    }
                )
            }
        })
    }

    $feed = [ordered]@{
        header = [ordered]@{
            sellerId = $SellerId
            version = '2.0'
            issueLocale = 'en_CA'
        }
        messages = $messages
    }

    return $feed | ConvertTo-Json -Depth 20 -Compress
}

function Get-RegionEndpoint {
    param([Parameter(Mandatory = $true)][string]$Region)

    switch ($Region.ToLowerInvariant()) {
        'na' { return 'https://sellingpartnerapi-na.amazon.com' }
        'eu' { return 'https://sellingpartnerapi-eu.amazon.com' }
        'fe' { return 'https://sellingpartnerapi-fe.amazon.com' }
        default { throw "Unsupported SP-API region: $Region" }
    }
}

function Get-LwaToken {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [Parameter(Mandatory = $true)][string]$RefreshToken
    )

    try {
        return Invoke-RestMethod `
            -Method Post `
            -Uri 'https://api.amazon.com/auth/o2/token' `
            -ContentType 'application/x-www-form-urlencoded;charset=UTF-8' `
            -Body @{
                grant_type = 'refresh_token'
                refresh_token = $RefreshToken
                client_id = $ClientId
                client_secret = $ClientSecret
            }
    }
    catch {
        $detail = ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_)
        throw "LWA authorization failed. $detail"
    }
}

function New-SpApiHeaders {
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    return @{
        'x-amz-access-token' = $AccessToken
        'x-amz-date' = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        'user-agent' = 'AmazonInventoryConsole/1.0 (Language=PowerShell)'
    }
}

function Invoke-SpApiJson {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $false)][object]$Body
    )

    $arguments = @{
        Method = $Method
        Uri = $Uri
        Headers = New-SpApiHeaders -AccessToken $AccessToken
        ContentType = 'application/json; charset=UTF-8'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $arguments.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        return Invoke-RestMethod @arguments
    }
    catch {
        $detail = ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_)
        throw $detail
    }
}

function Test-AuthSession {
    param([Parameter(Mandatory = $true)][string]$AuthSessionId)

    if (-not $script:AuthSessions.ContainsKey($AuthSessionId)) {
        throw 'Authorization session was not found. Verify credentials again.'
    }

    $session = $script:AuthSessions[$AuthSessionId]
    if ([DateTime]::UtcNow -ge $session.expiresAt) {
        $script:AuthSessions.Remove($AuthSessionId)
        throw 'Authorization session has expired. Verify credentials again.'
    }

    return $session
}

function ConvertTo-PublicJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    $reportAvailable = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$Job.reportFileName)) {
        $reportAvailable = Test-Path -LiteralPath (Join-Path $script:RuntimeRoot $Job.reportFileName)
    }

    return [ordered]@{
        id = $Job.id
        feedId = $Job.feedId
        status = $Job.status
        createdAt = $Job.createdAt
        updatedAt = $Job.updatedAt
        sellerId = $Job.sellerId
        marketplaceId = $Job.marketplaceId
        region = $Job.region
        fileName = $Job.fileName
        rows = $Job.rows
        zeroQuantity = $Job.zeroQuantity
        positiveQuantity = $Job.positiveQuantity
        reportAvailable = $reportAvailable
        reportSummary = $Job.reportSummary
        error = $Job.error
    }
}

function Save-JobStore {
    $persisted = @($script:Jobs.Values | ForEach-Object {
        ConvertTo-PublicJob -Job $_
    })
    Write-Utf8WithoutBom -Path $script:JobsPath -Content ($persisted | ConvertTo-Json -Depth 20)
}

function Load-JobStore {
    if (-not (Test-Path -LiteralPath $script:JobsPath)) {
        return
    }

    try {
        $items = @(Get-Content -LiteralPath $script:JobsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$item.id)) {
                continue
            }
            $status = [string]$item.status
            if ($status -in @('IN_QUEUE', 'IN_PROGRESS')) {
                $status = 'RECONNECT_REQUIRED'
            }
            $script:Jobs[[string]$item.id] = [pscustomobject]@{
                id = [string]$item.id
                feedId = [string]$item.feedId
                status = $status
                createdAt = [string]$item.createdAt
                updatedAt = [string]$item.updatedAt
                sellerId = [string]$item.sellerId
                marketplaceId = [string]$item.marketplaceId
                region = [string]$item.region
                fileName = [string]$item.fileName
                rows = [int]$item.rows
                zeroQuantity = [int]$item.zeroQuantity
                positiveQuantity = [int]$item.positiveQuantity
                reportFileName = if ($item.reportAvailable) { "feed-processing-report-$($item.feedId).json" } else { $null }
                reportSummary = $item.reportSummary
                error = [string]$item.error
                authSessionId = $null
                resultDocumentId = $null
            }
        }
    }
    catch {
        $backupPath = "$($script:JobsPath).invalid-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item -LiteralPath $script:JobsPath -Destination $backupPath
    }
}

function Save-FeedReport {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$FeedId
    )

    $reportFileName = "feed-processing-report-$FeedId.json"
    $reportPath = Join-Path $script:RuntimeRoot $reportFileName
    $temporaryPath = "$reportPath.download"
    Invoke-WebRequest -Method Get -Uri $Document.url -OutFile $temporaryPath -UseBasicParsing

    try {
        if ([string]$Document.compressionAlgorithm -eq 'GZIP') {
            $inputStream = [IO.File]::OpenRead($temporaryPath)
            $gzipStream = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
            $outputStream = [IO.File]::Create($reportPath)
            try {
                $gzipStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
                $gzipStream.Dispose()
                $inputStream.Dispose()
            }
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $reportPath -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return $reportFileName
}

function Update-FeedJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    if ($Job.status -notin @('IN_QUEUE', 'IN_PROGRESS')) {
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$Job.authSessionId)) {
        $Job.status = 'RECONNECT_REQUIRED'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-JobStore
        return
    }

    try {
        $session = Test-AuthSession -AuthSessionId $Job.authSessionId
        $feed = Invoke-SpApiJson `
            -Method GET `
            -Uri "$($session.endpoint)/feeds/2021-06-30/feeds/$($Job.feedId)" `
            -AccessToken $session.accessToken

        $Job.status = [string]$feed.processingStatus
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        $Job.resultDocumentId = [string]$feed.resultFeedDocumentId

        if ($Job.status -in @('DONE', 'CANCELLED', 'FATAL') -and
            -not [string]::IsNullOrWhiteSpace([string]$Job.resultDocumentId) -and
            [string]::IsNullOrWhiteSpace([string]$Job.reportFileName)) {

            $document = Invoke-SpApiJson `
                -Method GET `
                -Uri "$($session.endpoint)/feeds/2021-06-30/documents/$($Job.resultDocumentId)" `
                -AccessToken $session.accessToken

            $Job.reportFileName = Save-FeedReport -Document $document -FeedId $Job.feedId
            $reportPath = Join-Path $script:RuntimeRoot $Job.reportFileName
            try {
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $Job.reportSummary = $report.summary
            }
            catch {
                $Job.reportSummary = $null
            }
        }

        Save-JobStore
    }
    catch {
        $Job.error = $_.Exception.Message
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-JobStore
    }
}

function Get-ContentType {
    param([Parameter(Mandatory = $true)][string]$Path)

    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        '.ico' { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

function Write-StaticFile {
    param(
        [Parameter(Mandatory = $true)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $cleanPath = $RelativePath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($cleanPath)) {
        $cleanPath = 'index.html'
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $script:PublicRoot $cleanPath))
    $publicFullPath = [IO.Path]::GetFullPath($script:PublicRoot)
    if (-not $candidate.StartsWith($publicFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $Context.Response.StatusCode = 404
        $Context.Response.OutputStream.Close()
        return
    }

    $bytes = [IO.File]::ReadAllBytes($candidate)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = Get-ContentType -Path $candidate
    $Context.Response.Headers['Cache-Control'] = 'no-cache'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Handle-ApiRequest {
    param([Parameter(Mandatory = $true)][Net.HttpListenerContext]$Context)

    $request = $Context.Request
    $method = $request.HttpMethod.ToUpperInvariant()
    $path = $request.Url.AbsolutePath

    if ($method -eq 'GET' -and $path -eq '/api/status') {
        Write-JsonResponse -Context $Context -Value ([ordered]@{
            ok = $true
            serverTime = [DateTime]::UtcNow.ToString('o')
            bind = "127.0.0.1:$Port"
            defaultFileAvailable = (-not [string]::IsNullOrWhiteSpace($script:DefaultSourceFile)) -and (Test-Path -LiteralPath $script:DefaultSourceFile -PathType Leaf)
            defaultFileName = if ([string]::IsNullOrWhiteSpace($script:DefaultSourceFile)) { '' } else { [IO.Path]::GetFileName($script:DefaultSourceFile) }
            credentialStorage = 'memory-only'
            apiVersion = '1.0'
        })
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/analyze') {
        try {
            $body = Read-JsonBody -Request $request
            if ($body.useDefault) {
                if ([string]::IsNullOrWhiteSpace($script:DefaultSourceFile) -or -not (Test-Path -LiteralPath $script:DefaultSourceFile -PathType Leaf)) {
                    throw 'No default template path is configured. Choose a file from the browser.'
                }
                $fileName = [IO.Path]::GetFileName($script:DefaultSourceFile)
                $content = [IO.File]::ReadAllText($script:DefaultSourceFile, [Text.Encoding]::UTF8)
            }
            else {
                $fileName = [string]$body.fileName
                $content = [string]$body.content
                if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($content)) {
                    throw 'fileName and content are required.'
                }
            }

            $analysis = Analyze-TemplateText -Text $content -FileName $fileName
            $analysisId = [guid]::NewGuid().ToString('N')
            $script:Analyses[$analysisId] = $analysis

            Write-JsonResponse -Context $Context -Value ([ordered]@{
                analysisId = $analysisId
                fileName = $analysis.fileName
                summary = $analysis.summary
                distribution = $analysis.distribution
                preview = $analysis.preview
                nonEmptyColumns = $analysis.nonEmptyColumns
            })
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'ANALYSIS_FAILED'
        }
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/auth/verify') {
        try {
            $body = Read-JsonBody -Request $request
            $clientId = [string]$body.clientId
            $clientSecret = [string]$body.clientSecret
            $refreshToken = ([string]$body.refreshToken).Replace('\_', '_')
            $region = [string]$body.region

            if ([string]::IsNullOrWhiteSpace($clientId) -or
                [string]::IsNullOrWhiteSpace($clientSecret) -or
                [string]::IsNullOrWhiteSpace($refreshToken)) {
                throw 'Client ID, client secret, and refresh token are required.'
            }

            $endpoint = Get-RegionEndpoint -Region $region
            $token = Get-LwaToken -ClientId $clientId -ClientSecret $clientSecret -RefreshToken $refreshToken
            $marketplaceResponse = Invoke-SpApiJson `
                -Method GET `
                -Uri "$endpoint/sellers/v1/marketplaceParticipations" `
                -AccessToken $token.access_token

            $marketplaces = @($marketplaceResponse.payload | ForEach-Object {
                [pscustomobject]@{
                    id = [string]$_.marketplace.id
                    name = [string]$_.marketplace.name
                    countryCode = [string]$_.marketplace.countryCode
                    domainName = [string]$_.marketplace.domainName
                    storeName = [string]$_.storeName
                    isParticipating = [bool]$_.participation.isParticipating
                    hasSuspendedListings = [bool]$_.participation.hasSuspendedListings
                }
            })

            $sessionId = [guid]::NewGuid().ToString('N')
            $expiresIn = if ($null -ne $token.expires_in) { [int]$token.expires_in } else { 3600 }
            $script:AuthSessions[$sessionId] = [pscustomobject]@{
                id = $sessionId
                accessToken = [string]$token.access_token
                expiresAt = [DateTime]::UtcNow.AddSeconds([Math]::Max(60, $expiresIn - 60))
                endpoint = $endpoint
                region = $region.ToLowerInvariant()
                marketplaces = $marketplaces
            }

            Write-JsonResponse -Context $Context -Value ([ordered]@{
                authSessionId = $sessionId
                expiresIn = $expiresIn
                region = $region.ToLowerInvariant()
                endpoint = $endpoint
                storeNames = @($marketplaces.storeName | Sort-Object -Unique)
                marketplaces = $marketplaces
            })
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'AUTH_FAILED'
        }
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/account/validate') {
        try {
            $body = Read-JsonBody -Request $request
            $authSessionId = [string]$body.authSessionId
            $analysisId = [string]$body.analysisId
            $sellerId = [string]$body.sellerId
            $marketplaceId = [string]$body.marketplaceId

            if (-not $script:Analyses.ContainsKey($analysisId)) {
                throw 'Analysis session was not found. Analyze the file again.'
            }
            if ([string]::IsNullOrWhiteSpace($sellerId) -or [string]::IsNullOrWhiteSpace($marketplaceId)) {
                throw 'Seller ID and marketplace are required.'
            }

            $session = Test-AuthSession -AuthSessionId $authSessionId
            $analysis = $script:Analyses[$analysisId]
            $sample = $analysis.records[0]
            $encodedSku = [Uri]::EscapeDataString([string]$sample.sku)
            $uri = "$($session.endpoint)/listings/2021-08-01/items/$sellerId/$encodedSku" +
                "?marketplaceIds=$marketplaceId&mode=VALIDATION_PREVIEW&issueLocale=en_CA"

            $validationResponse = Invoke-SpApiJson `
                -Method PATCH `
                -Uri $uri `
                -AccessToken $session.accessToken `
                -Body ([ordered]@{
                    productType = 'PRODUCT'
                    patches = @(
                        [ordered]@{
                            op = 'replace'
                            path = '/attributes/fulfillment_availability'
                            value = @(
                                [ordered]@{
                                    fulfillment_channel_code = 'DEFAULT'
                                    quantity = $sample.quantity
                                }
                            )
                        }
                    )
                })

            $validationId = [guid]::NewGuid().ToString('N')
            $script:AccountValidations[$validationId] = [pscustomobject]@{
                id = $validationId
                authSessionId = $authSessionId
                analysisId = $analysisId
                sellerId = $sellerId
                marketplaceId = $marketplaceId
                createdAt = [DateTime]::UtcNow
            }

            Write-JsonResponse -Context $Context -Value ([ordered]@{
                accountValidationId = $validationId
                status = [string]$validationResponse.status
                sku = [string]$validationResponse.sku
                issues = @($validationResponse.issues)
                sellerId = $sellerId
                marketplaceId = $marketplaceId
            })
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'ACCOUNT_MISMATCH'
        }
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/feeds/submit') {
        try {
            $body = Read-JsonBody -Request $request
            $validationId = [string]$body.accountValidationId
            $confirmation = [string]$body.confirmation

            if ($confirmation -ne 'SUBMIT') {
                throw 'Submission confirmation is invalid.'
            }
            if (-not $script:AccountValidations.ContainsKey($validationId)) {
                throw 'Account validation was not found. Validate the seller account again.'
            }

            $validation = $script:AccountValidations[$validationId]
            $session = Test-AuthSession -AuthSessionId $validation.authSessionId
            if (-not $script:Analyses.ContainsKey($validation.analysisId)) {
                throw 'Analysis session was not found. Analyze the file again.'
            }
            $analysis = $script:Analyses[$validation.analysisId]
            $feedJson = New-ListingsFeedJson -Analysis $analysis -SellerId $validation.sellerId
            $jobId = [guid]::NewGuid().ToString('N')
            $feedInputPath = Join-Path $script:RuntimeRoot "feed-input-$jobId.json"
            Write-Utf8WithoutBom -Path $feedInputPath -Content $feedJson

            $document = Invoke-SpApiJson `
                -Method POST `
                -Uri "$($session.endpoint)/feeds/2021-06-30/documents" `
                -AccessToken $session.accessToken `
                -Body @{ contentType = 'application/json; charset=UTF-8' }

            try {
                Invoke-WebRequest `
                    -Method Put `
                    -Uri $document.url `
                    -ContentType 'application/json; charset=UTF-8' `
                    -InFile $feedInputPath `
                    -UseBasicParsing | Out-Null
            }
            catch {
                throw "Feed document upload failed. $(ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_))"
            }

            $feedSubmission = Invoke-SpApiJson `
                -Method POST `
                -Uri "$($session.endpoint)/feeds/2021-06-30/feeds" `
                -AccessToken $session.accessToken `
                -Body ([ordered]@{
                    feedType = 'JSON_LISTINGS_FEED'
                    marketplaceIds = @($validation.marketplaceId)
                    inputFeedDocumentId = $document.feedDocumentId
                })

            $now = [DateTime]::UtcNow.ToString('o')
            $job = [pscustomobject]@{
                id = $jobId
                feedId = [string]$feedSubmission.feedId
                status = 'IN_QUEUE'
                createdAt = $now
                updatedAt = $now
                sellerId = [string]$validation.sellerId
                marketplaceId = [string]$validation.marketplaceId
                region = [string]$session.region
                fileName = [string]$analysis.fileName
                rows = [int]$analysis.summary.rows
                zeroQuantity = [int]$analysis.summary.zeroQuantity
                positiveQuantity = [int]$analysis.summary.positiveQuantity
                reportFileName = $null
                reportSummary = $null
                error = $null
                authSessionId = [string]$validation.authSessionId
                resultDocumentId = $null
            }
            $script:Jobs[$jobId] = $job
            Save-JobStore

            Write-JsonResponse -Context $Context -StatusCode 201 -Value (ConvertTo-PublicJob -Job $job)
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'SUBMIT_FAILED'
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/jobs') {
        $jobs = @($script:Jobs.Values | Sort-Object createdAt -Descending | ForEach-Object {
            ConvertTo-PublicJob -Job $_
        })
        Write-JsonResponse -Context $Context -Value @{ jobs = $jobs }
        return
    }

    if ($method -eq 'GET' -and $path -match '^/api/jobs/([a-f0-9]{32})/report$') {
        $jobId = $Matches[1]
        if (-not $script:Jobs.ContainsKey($jobId)) {
            Write-ApiError -Context $Context -StatusCode 404 -Message 'Job was not found.' -Code 'NOT_FOUND'
            return
        }
        $job = $script:Jobs[$jobId]
        if ([string]::IsNullOrWhiteSpace([string]$job.reportFileName)) {
            Write-ApiError -Context $Context -StatusCode 404 -Message 'Processing report is not available.' -Code 'REPORT_NOT_READY'
            return
        }
        $reportPath = Join-Path $script:RuntimeRoot $job.reportFileName
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
            Write-ApiError -Context $Context -StatusCode 404 -Message 'Processing report file is missing.' -Code 'REPORT_MISSING'
            return
        }
        $bytes = [IO.File]::ReadAllBytes($reportPath)
        $Context.Response.StatusCode = 200
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.Headers['Content-Disposition'] = "attachment; filename=$($job.reportFileName)"
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Context.Response.OutputStream.Close()
        return
    }

    if ($method -eq 'GET' -and $path -match '^/api/jobs/([a-f0-9]{32})$') {
        $jobId = $Matches[1]
        if (-not $script:Jobs.ContainsKey($jobId)) {
            Write-ApiError -Context $Context -StatusCode 404 -Message 'Job was not found.' -Code 'NOT_FOUND'
            return
        }
        $job = $script:Jobs[$jobId]
        Update-FeedJob -Job $job
        Write-JsonResponse -Context $Context -Value (ConvertTo-PublicJob -Job $job)
        return
    }

    Write-ApiError -Context $Context -StatusCode 404 -Message 'API route was not found.' -Code 'NOT_FOUND'
}

Load-JobStore

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

Write-Host "Amazon SP-API Console listening on http://127.0.0.1:$Port/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            if ($context.Request.Url.AbsolutePath.StartsWith('/api/', [StringComparison]::OrdinalIgnoreCase)) {
                Handle-ApiRequest -Context $context
            }
            elseif ($context.Request.HttpMethod -eq 'GET') {
                Write-StaticFile -Context $context -RelativePath $context.Request.Url.AbsolutePath
            }
            else {
                $context.Response.StatusCode = 405
                $context.Response.OutputStream.Close()
            }
        }
        catch {
            try {
                Write-ApiError -Context $context -StatusCode 500 -Message 'Unexpected server error.' -Code 'SERVER_ERROR'
            }
            catch {
                $context.Response.Abort()
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
