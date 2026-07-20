[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4317,

    [string]$TemplatePath = $env:AMAZON_TEMPLATE_PATH,

    [string]$InstanceId = '',

    [ValidateRange(5, 600)]
    [int]$RequestTimeoutSec = 60,

    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })]
    [string]$AllowedAmazonStoreName = 'Carkee',

    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })]
    [string[]]$AllowedAmazonSellerIds = @('AC7OMGZBRADKF'),

    [switch]$ReadOnly,

    [switch]$EnableUnsafeLegacyPricingMigration,

    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:PublicRoot = Join-Path $script:AppRoot 'public'
$script:RuntimeRoot = Join-Path $script:AppRoot 'runtime'
$script:JobsPath = Join-Path $script:RuntimeRoot 'jobs.json'
$script:PricingBatchesPath = Join-Path $script:RuntimeRoot 'pricing-batches.json'
$script:AuthorizationStorePath = Join-Path $script:RuntimeRoot 'authorization-store.json'
$script:CredentialKeyPath = if ([string]::IsNullOrWhiteSpace($env:KLANATA_CREDENTIAL_KEY_PATH)) {
    '/run/secrets/workstation-store.key'
}
else {
    $env:KLANATA_CREDENTIAL_KEY_PATH
}
$script:DefaultAmazonAuthorizationBaseUri = 'https://sellercentral.amazon.com/apps/authorize/consent'
$script:DefaultSourceFile = $TemplatePath
$script:InstanceId = if ([string]::IsNullOrWhiteSpace($InstanceId)) { [guid]::NewGuid().ToString('N') } else { $InstanceId }
$script:RequestTimeoutSec = $RequestTimeoutSec
$script:AllowedAmazonStoreName = $AllowedAmazonStoreName.Trim()
$configuredAllowedAmazonSellerIds = @($AllowedAmazonSellerIds)
$script:AllowedAmazonSellerIdSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($allowedSellerIdValue in $configuredAllowedAmazonSellerIds) {
    foreach ($allowedSellerId in @(([string]$allowedSellerIdValue) -split ',')) {
        $normalizedAllowedSellerId = ([string]$allowedSellerId).Trim().ToUpperInvariant()
        if ($normalizedAllowedSellerId -notmatch '^A[A-Z0-9]{9,19}$') {
            throw "Invalid allowed Amazon Seller ID: $allowedSellerId"
        }
        [void]$script:AllowedAmazonSellerIdSet.Add($normalizedAllowedSellerId)
    }
}
if ($script:AllowedAmazonSellerIdSet.Count -eq 0) {
    throw 'At least one allowed Amazon Seller ID is required.'
}
$script:MaxBodyBytes = 10MB
$script:AmazonRequestMaxAttempts = 4
$script:Analyses = @{}
$script:PricingSimulations = @{}
$script:PricingBatches = @{}
$script:AuthSessions = @{}
$script:AuthorizationProfiles = @{}
$script:OAuthStates = @{}
$script:AccountValidations = @{}
$script:Jobs = @{}
$script:DeveloperApplication = $null
$script:CurrentAnalysisId = $null
$script:CurrentAuthSessionId = $null
$script:CurrentAuthSessionIds = [Collections.Generic.List[string]]::new()
$script:CurrentAccountValidationId = $null

. (Join-Path $script:AppRoot 'pricing.ps1')

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

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
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

function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    if ($null -eq $response) {
        return 0
    }

    try {
        return [int]$response.StatusCode
    }
    catch {
        return 0
    }
}

function Test-IsTransientAmazonFailure {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $statusCode = Get-HttpStatusCode -ErrorRecord $ErrorRecord
    if ($statusCode -in @(408, 425, 429, 500, 502, 503, 504)) {
        return $true
    }

    $statusProperty = $ErrorRecord.Exception.PSObject.Properties['Status']
    $networkStatus = if ($null -ne $statusProperty) { [string]$statusProperty.Value } else { '' }
    return $networkStatus -in @(
        'Timeout',
        'ConnectFailure',
        'ConnectionClosed',
        'KeepAliveFailure',
        'ReceiveFailure',
        'SendFailure',
        'NameResolutionFailure'
    )
}

function Get-AmazonRetryDelayMilliseconds {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    if ($null -ne $response) {
        try {
            $retryAfter = [string]$response.Headers['Retry-After']
            $retryAfterSeconds = 0
            if ([int]::TryParse($retryAfter, [ref]$retryAfterSeconds) -and $retryAfterSeconds -gt 0) {
                return [Math]::Min(30000, $retryAfterSeconds * 1000)
            }
        }
        catch {
            # Fall back to exponential backoff.
        }
    }

    $backoffSeconds = [Math]::Min(8, [Math]::Pow(2, $Attempt - 1))
    return [int]($backoffSeconds * 1000) + (Get-Random -Minimum 0 -Maximum 500)
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

function Read-ZipXmlDocument {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $entry = $Archive.GetEntry($EntryName)
    if ($null -eq $entry) {
        throw "Spreadsheet entry was not found: $EntryName"
    }
    if ($entry.Length -gt 16MB) {
        throw "Spreadsheet entry is too large: $EntryName"
    }

    $stream = $entry.Open()
    try {
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.Load($reader)
            return ,$document
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertFrom-ExcelColumnLetters {
    param([Parameter(Mandatory = $true)][string]$Letters)

    $column = 0
    foreach ($character in $Letters.ToUpperInvariant().ToCharArray()) {
        $value = [int]$character - [int][char]'A' + 1
        if ($value -lt 1 -or $value -gt 26) {
            throw "Invalid spreadsheet cell reference: $Letters"
        }
        $column = ($column * 26) + $value
        if ($column -gt 512) {
            throw 'The spreadsheet contains more than 512 columns.'
        }
    }
    return $column
}

function ConvertTo-TsvField {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }
    $normalized = $Value.Replace("`r`n", ' ').Replace("`r", ' ').Replace("`n", ' ')
    if ($normalized.Contains("`t") -or $normalized.Contains('"')) {
        return '"' + $normalized.Replace('"', '""') + '"'
    }
    return $normalized
}

function ConvertFrom-SpreadsheetToTsv {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$PreferredSheetName = 'Template',
        [switch]$AllowFirstWorksheet
    )

    if ($Bytes.Length -eq 0) {
        throw 'The spreadsheet is empty.'
    }
    if ($Bytes.Length -gt 6MB) {
        throw 'The spreadsheet exceeds the 6 MB upload limit.'
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    $memory = [IO.MemoryStream]::new($Bytes, $false)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $memory,
            [IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        try {
            $workbook = Read-ZipXmlDocument -Archive $archive -EntryName 'xl/workbook.xml'
            $workbookNamespaces = [Xml.XmlNamespaceManager]::new($workbook.NameTable)
            $workbookNamespaces.AddNamespace('main', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
            $workbookNamespaces.AddNamespace('rel', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
            $worksheetNodes = @($workbook.SelectNodes('/main:workbook/main:sheets/main:sheet', $workbookNamespaces))
            $templateSheet = @($worksheetNodes | Where-Object {
                [string]$_.GetAttribute('name') -eq $PreferredSheetName
            } | Select-Object -First 1)
            if ($templateSheet.Count -eq 0 -and $AllowFirstWorksheet -and $worksheetNodes.Count -gt 0) {
                $templateSheet = @($worksheetNodes[0])
            }
            if ($templateSheet.Count -eq 0) {
                throw "Spreadsheet $FileName does not contain the required worksheet $PreferredSheetName."
            }
            $worksheetName = [string]$templateSheet[0].GetAttribute('name')

            $relationshipId = $templateSheet[0].GetAttribute(
                'id',
                'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
            )
            if ([string]::IsNullOrWhiteSpace($relationshipId)) {
                throw "The $worksheetName worksheet relationship is missing."
            }

            $relationships = Read-ZipXmlDocument -Archive $archive -EntryName 'xl/_rels/workbook.xml.rels'
            $relationshipNamespaces = [Xml.XmlNamespaceManager]::new($relationships.NameTable)
            $relationshipNamespaces.AddNamespace('pkg', 'http://schemas.openxmlformats.org/package/2006/relationships')
            $sheetRelationship = @($relationships.SelectNodes('/pkg:Relationships/pkg:Relationship', $relationshipNamespaces) | Where-Object {
                [string]$_.GetAttribute('Id') -eq $relationshipId
            } | Select-Object -First 1)
            if ($sheetRelationship.Count -eq 0) {
                throw "The $worksheetName worksheet target is missing."
            }

            $target = [Uri]::UnescapeDataString([string]$sheetRelationship[0].GetAttribute('Target')).Replace('\', '/')
            if ($target.StartsWith('/')) {
                $sheetEntryName = $target.TrimStart('/')
            }
            else {
                $sheetEntryName = "xl/$target"
            }
            if ($sheetEntryName.Contains('../')) {
                throw 'The Template worksheet target is invalid.'
            }

            $sharedStrings = [Collections.Generic.List[string]]::new()
            if ($null -ne $archive.GetEntry('xl/sharedStrings.xml')) {
                $sharedStringDocument = Read-ZipXmlDocument -Archive $archive -EntryName 'xl/sharedStrings.xml'
                $sharedStringNamespaces = [Xml.XmlNamespaceManager]::new($sharedStringDocument.NameTable)
                $sharedStringNamespaces.AddNamespace('main', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
                foreach ($item in $sharedStringDocument.SelectNodes('/main:sst/main:si', $sharedStringNamespaces)) {
                    $parts = @($item.SelectNodes('.//main:t', $sharedStringNamespaces) | ForEach-Object { [string]$_.InnerText })
                    [void]$sharedStrings.Add(($parts -join ''))
                }
            }

            $worksheet = Read-ZipXmlDocument -Archive $archive -EntryName $sheetEntryName
            $worksheetNamespaces = [Xml.XmlNamespaceManager]::new($worksheet.NameTable)
            $worksheetNamespaces.AddNamespace('main', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
            $rows = @{}
            $maximumRow = 0
            $maximumColumn = 0
            foreach ($rowNode in $worksheet.SelectNodes('/main:worksheet/main:sheetData/main:row', $worksheetNamespaces)) {
                $rowNumber = 0
                if (-not [int]::TryParse([string]$rowNode.GetAttribute('r'), [ref]$rowNumber) -or $rowNumber -lt 1) {
                    throw "The $worksheetName worksheet contains an invalid row number."
                }
                if ($rowNumber -gt 25007) {
                    throw "The $worksheetName worksheet contains more than 25,000 data rows."
                }

                $values = @{}
                foreach ($cell in $rowNode.SelectNodes('./main:c', $worksheetNamespaces)) {
                    $reference = [string]$cell.GetAttribute('r')
                    $referenceMatch = [regex]::Match($reference, '^([A-Za-z]+)(\d+)$')
                    if (-not $referenceMatch.Success) {
                        throw "Invalid spreadsheet cell reference: $reference"
                    }
                    $column = ConvertFrom-ExcelColumnLetters -Letters $referenceMatch.Groups[1].Value
                    $type = [string]$cell.GetAttribute('t')
                    if ($type -eq 'inlineStr') {
                        $value = @($cell.SelectNodes('./main:is//main:t', $worksheetNamespaces) | ForEach-Object { [string]$_.InnerText }) -join ''
                    }
                    else {
                        $valueNode = $cell.SelectSingleNode('./main:v', $worksheetNamespaces)
                        $value = if ($null -eq $valueNode) { '' } else { [string]$valueNode.InnerText }
                        if ($type -eq 's' -and -not [string]::IsNullOrWhiteSpace($value)) {
                            $sharedStringIndex = 0
                            if (-not [int]::TryParse($value, [ref]$sharedStringIndex) -or
                                $sharedStringIndex -lt 0 -or
                                $sharedStringIndex -ge $sharedStrings.Count) {
                                throw "Invalid shared string index in cell $reference."
                            }
                            $value = $sharedStrings[$sharedStringIndex]
                        }
                    }
                    $values[$column] = $value
                    $maximumColumn = [Math]::Max($maximumColumn, $column)
                }
                $rows[$rowNumber] = $values
                $maximumRow = [Math]::Max($maximumRow, $rowNumber)
            }

            $maximumRow = [Math]::Max($maximumRow, 7)
            if ($maximumColumn -eq 0) {
                throw "The $worksheetName worksheet is empty."
            }
            $lines = [Collections.Generic.List[string]]::new()
            for ($rowNumber = 1; $rowNumber -le $maximumRow; $rowNumber++) {
                $fields = [Collections.Generic.List[string]]::new()
                $rowValues = if ($rows.ContainsKey($rowNumber)) { $rows[$rowNumber] } else { @{} }
                for ($column = 1; $column -le $maximumColumn; $column++) {
                    $value = if ($rowValues.ContainsKey($column)) { [string]$rowValues[$column] } else { '' }
                    [void]$fields.Add((ConvertTo-TsvField -Value $value))
                }
                [void]$lines.Add(($fields -join "`t"))
            }
            return $lines -join "`n"
        }
        finally {
            $archive.Dispose()
        }
    }
    catch [IO.InvalidDataException] {
        throw "Spreadsheet $FileName is not a valid XLSX/XLSM file."
    }
    finally {
        $memory.Dispose()
    }
}

function ConvertFrom-AmazonSpreadsheetTemplate {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    return ConvertFrom-SpreadsheetToTsv `
        -Bytes $Bytes `
        -FileName $FileName `
        -PreferredSheetName 'Template'
}

function Read-AmazonTemplateFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.xlsx', '.xlsm')) {
        return ConvertFrom-AmazonSpreadsheetTemplate `
            -Bytes ([IO.File]::ReadAllBytes($Path)) `
            -FileName ([IO.Path]::GetFileName($Path))
    }
    if ($extension -notin @('.txt', '.tsv')) {
        throw 'Supported template formats are TXT, TSV, XLSX, and XLSM.'
    }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
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
    $sellerMatch = [regex]::Match($settings, '(?:^|&)contributorId=amzn1\.cr\.o\.([^&]+)')
    $marketplaceMatch = [regex]::Match($settings, '(?:^|&)primaryMarketplaceId=amzn1\.mp\.o\.([^&]+)')
    $templateSellerId = if ($sellerMatch.Success) { [Uri]::UnescapeDataString($sellerMatch.Groups[1].Value) } else { '' }
    $templateMarketplaceId = if ($marketplaceMatch.Success) { [Uri]::UnescapeDataString($marketplaceMatch.Groups[1].Value) } else { '' }

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
        templateSellerId = $templateSellerId
        templateMarketplaceId = $templateMarketplaceId
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

function Register-TemplateAnalysis {
    param([Parameter(Mandatory = $true)][object]$Analysis)

    $templateSellerId = [string](Get-PricingPropertyValue `
        -Object $Analysis `
        -Name 'templateSellerId' `
        -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($templateSellerId) -and
        -not (Test-IsAllowedAmazonSellerId -SellerId $templateSellerId)) {
        $exception = [InvalidOperationException]::new(
            'This Amazon template belongs to a Seller account that is not allowed on this workstation.'
        )
        $exception.Data['KlanataErrorCode'] = 'ACCOUNT_NOT_ALLOWED'
        throw $exception
    }

    $analysisId = [guid]::NewGuid().ToString('N')
    $script:Analyses[$analysisId] = $Analysis
    $script:CurrentAnalysisId = $analysisId
    $script:CurrentAccountValidationId = $null
    return $analysisId
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

function Get-SubmissionConfirmationPhrase {
    param([Parameter(Mandatory = $true)][object]$Analysis)

    $rows = [int]$Analysis.summary.rows
    $zeroQuantity = [int]$Analysis.summary.zeroQuantity
    $zeroRate = if ($rows -gt 0) { $zeroQuantity / $rows } else { 0 }
    if ($rows -ge 1000 -or $zeroRate -ge 0.5) {
        return "SUBMIT $rows"
    }

    return 'SUBMIT'
}

function Test-IsSelectableMarketplace {
    param([Parameter(Mandatory = $true)][object]$Marketplace)

    if (-not [bool]$Marketplace.isParticipating -or [bool]$Marketplace.hasSuspendedListings) {
        return $false
    }

    $name = [string]$Marketplace.name
    $storeName = ([string]$Marketplace.storeName).Trim()
    return $name -notmatch '(?i)^Non-Amazon\b' -and
        $name -notmatch '(?i)Shadow Marketplace' -and
        $storeName -notmatch '(?i)^Invoicing_'
}

function Throw-AmazonStoreNotAllowed {
    $exception = [InvalidOperationException]::new(
        "Only the $($script:AllowedAmazonStoreName) Amazon store can be authorized on this workstation."
    )
    $exception.Data['KlanataErrorCode'] = 'STORE_NOT_ALLOWED'
    throw $exception
}

function Test-IsAmazonStoreNotAllowedError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    return [string]$ErrorRecord.Exception.Data['KlanataErrorCode'] -eq 'STORE_NOT_ALLOWED'
}

function Test-IsAllowedAmazonSellerId {
    param([AllowEmptyString()][string]$SellerId)

    if ([string]::IsNullOrWhiteSpace($SellerId)) {
        return $false
    }
    try {
        $normalizedSellerId = Normalize-AmazonSellerId -SellerId $SellerId
    }
    catch {
        return $false
    }
    return $script:AllowedAmazonSellerIdSet.Contains($normalizedSellerId)
}

function Assert-AllowedAmazonSellerId {
    param(
        [AllowEmptyString()][string]$SellerId,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($SellerId) -and $AllowEmpty) {
        return
    }
    if (-not (Test-IsAllowedAmazonSellerId -SellerId $SellerId)) {
        Throw-AmazonStoreNotAllowed
    }
}

function Assert-AllowedAmazonMarketplaces {
    param([Parameter(Mandatory = $true)][object[]]$Marketplaces)

    $selectable = @($Marketplaces | Where-Object { Test-IsSelectableMarketplace -Marketplace $_ })
    $observedStoreNames = @($selectable | ForEach-Object {
        ([string]$_.storeName).Trim()
    } | Sort-Object -Unique)
    $unexpectedMarketplaces = @($selectable | Where-Object {
        -not [string]::Equals(
            ([string]$_.storeName).Trim(),
            $script:AllowedAmazonStoreName,
            [StringComparison]::OrdinalIgnoreCase
        )
    })

    if ($selectable.Count -eq 0 -or $unexpectedMarketplaces.Count -gt 0) {
        Throw-AmazonStoreNotAllowed
    }

    return [pscustomobject]@{
        storeName = $script:AllowedAmazonStoreName
        source = 'sellers-v1/getMarketplaceParticipations'
        verifiedAt = [DateTime]::UtcNow.ToString('o')
        marketplaceIds = @($selectable | ForEach-Object { [string]$_.id })
    }
}

function Assert-AllowedAmazonMarketplaceDiscovery {
    param([Parameter(Mandatory = $true)][object]$MarketplaceDiscovery)

    $marketplaces = @(ConvertTo-SpApiMarketplaces -MarketplaceResponse $MarketplaceDiscovery.response)
    $identity = Assert-AllowedAmazonMarketplaces -Marketplaces $marketplaces
    return [pscustomobject]@{
        identity = $identity
        marketplaces = $marketplaces
    }
}

function Assert-AllowedAmazonSession {
    param([Parameter(Mandatory = $true)][object]$Session)

    [void](Assert-AllowedAmazonMarketplaces -Marketplaces @($Session.marketplaces))
    $verifiedStoreName = [string](Get-PricingPropertyValue `
        -Object $Session `
        -Name 'verifiedStoreName' `
        -DefaultValue '')
    $identitySource = [string](Get-PricingPropertyValue `
        -Object $Session `
        -Name 'storeIdentitySource' `
        -DefaultValue '')
    $verifiedAt = [string](Get-PricingPropertyValue `
        -Object $Session `
        -Name 'storeIdentityVerifiedAt' `
        -DefaultValue '')
    if (-not [string]::Equals(
            $verifiedStoreName,
            $script:AllowedAmazonStoreName,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $identitySource -ne 'sellers-v1/getMarketplaceParticipations' -or
        [string]::IsNullOrWhiteSpace($verifiedAt)) {
        Throw-AmazonStoreNotAllowed
    }
    Assert-AllowedAmazonSellerId `
        -SellerId ([string](Get-PricingPropertyValue -Object $Session -Name 'sellerId' -DefaultValue '')) `
        -AllowEmpty
}

function Assert-AllowedAmazonProductionContext {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$MarketplaceId,
        [switch]$RequireValidatedContext
    )

    Assert-AllowedAmazonSession -Session $Session
    $normalizedSellerId = Normalize-AmazonSellerId -SellerId $SellerId
    Assert-AllowedAmazonSellerId -SellerId $normalizedSellerId
    $sessionSellerId = Normalize-AmazonSellerId `
        -SellerId ([string](Get-PricingPropertyValue -Object $Session -Name 'sellerId' -DefaultValue ''))
    if ($sessionSellerId -cne $normalizedSellerId) {
        throw 'The authorization session Seller ID does not match the requested production context.'
    }

    $marketplaceMatches = @($Session.marketplaces | Where-Object {
        [string]$_.id -eq $MarketplaceId -and
        (Test-IsSelectableMarketplace -Marketplace $_) -and
        [string]::Equals(
            ([string]$_.storeName).Trim(),
            $script:AllowedAmazonStoreName,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($marketplaceMatches.Count -eq 0) {
        throw 'The authorization session does not include the requested production Marketplace.'
    }
    if ($RequireValidatedContext -and
        -not (Test-SessionValidatedContext `
            -Session $Session `
            -SellerId $normalizedSellerId `
            -MarketplaceId $MarketplaceId)) {
        throw 'The authorization session is not validated for this Seller and Marketplace.'
    }
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

function Get-RegionDisplayName {
    param([Parameter(Mandatory = $true)][string]$Region)

    switch ($Region.ToLowerInvariant()) {
        'na' { return 'North America' }
        'eu' { return 'Europe' }
        'fe' { return 'Far East' }
        default { return $Region.ToUpperInvariant() }
    }
}

function Get-MaskedClientId {
    param([string]$ClientId)

    if ([string]::IsNullOrWhiteSpace($ClientId)) { return '' }
    if ($ClientId.Length -le 12) { return $ClientId }
    return "$($ClientId.Substring(0, [Math]::Min(32, $ClientId.Length)))..."
}

function Normalize-AmazonSellerId {
    param(
        [AllowEmptyString()][string]$SellerId,
        [switch]$AllowEmpty
    )

    $normalized = $SellerId.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        if ($AllowEmpty) { return '' }
        throw 'Seller ID is required.'
    }
    if ($normalized -notmatch '^A[A-Z0-9]{9,19}$') {
        throw 'Seller ID must be an Amazon Selling Partner ID (10-20 uppercase letters or digits, beginning with A).'
    }
    return $normalized
}

function Set-DeveloperApplication {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [AllowEmptyString()][string]$ApplicationId = '',
        [AllowEmptyString()][string]$AuthorizationBaseUri = '',
        [AllowEmptyString()][string]$ConfiguredAt = ''
    )

    $resolvedApplicationId = if ($PSBoundParameters.ContainsKey('ApplicationId')) {
        $ApplicationId.Trim()
    }
    elseif ($null -ne $script:DeveloperApplication) {
        [string](Get-PricingPropertyValue -Object $script:DeveloperApplication -Name 'applicationId' -DefaultValue '')
    }
    else {
        ''
    }
    $resolvedAuthorizationBaseUri = if ($PSBoundParameters.ContainsKey('AuthorizationBaseUri') -and
        -not [string]::IsNullOrWhiteSpace($AuthorizationBaseUri)) {
        $AuthorizationBaseUri.Trim()
    }
    elseif ($null -ne $script:DeveloperApplication) {
        [string](Get-PricingPropertyValue `
            -Object $script:DeveloperApplication `
            -Name 'authorizationBaseUri' `
            -DefaultValue $script:DefaultAmazonAuthorizationBaseUri)
    }
    else {
        $script:DefaultAmazonAuthorizationBaseUri
    }

    $authorizationUri = $null
    $allowedSellerCentralHosts = @(
        'sellercentral.amazon.com',
        'sellercentral-europe.amazon.com',
        'sellercentral.amazon.ca',
        'sellercentral.amazon.com.mx',
        'sellercentral.amazon.com.br',
        'sellercentral.amazon.co.uk',
        'sellercentral.amazon.de',
        'sellercentral.amazon.fr',
        'sellercentral.amazon.it',
        'sellercentral.amazon.es',
        'sellercentral.amazon.nl',
        'sellercentral.amazon.se',
        'sellercentral.amazon.pl',
        'sellercentral.amazon.com.be',
        'sellercentral.amazon.ie',
        'sellercentral.amazon.co.jp',
        'sellercentral.amazon.com.au',
        'sellercentral.amazon.sg',
        'sellercentral.amazon.in',
        'sellercentral.amazon.ae',
        'sellercentral.amazon.sa',
        'sellercentral.amazon.com.tr'
    )
    if (-not [Uri]::TryCreate($resolvedAuthorizationBaseUri, [UriKind]::Absolute, [ref]$authorizationUri) -or
        $authorizationUri.Scheme -ne 'https' -or
        -not [string]::IsNullOrWhiteSpace($authorizationUri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($authorizationUri.Fragment) -or
        $authorizationUri.Query -notin @('', '?version=beta') -or
        $authorizationUri.AbsolutePath.TrimEnd('/') -ne '/apps/authorize/consent' -or
        $authorizationUri.DnsSafeHost.ToLowerInvariant() -notin $allowedSellerCentralHosts) {
        throw 'Amazon authorization base URI must use an approved Amazon Seller Central HTTPS consent endpoint.'
    }

    $script:DeveloperApplication = [pscustomobject]@{
        applicationId = $resolvedApplicationId
        authorizationBaseUri = $authorizationUri.AbsoluteUri.TrimEnd('/')
        clientId = $ClientId.Trim()
        clientSecret = $ClientSecret.Trim()
        configuredAt = if ([string]::IsNullOrWhiteSpace($ConfiguredAt)) {
            [DateTime]::UtcNow.ToString('o')
        }
        else {
            $ConfiguredAt
        }
    }
}

function Get-AuthorizationStoreKey {
    if ([string]::IsNullOrWhiteSpace($script:CredentialKeyPath) -or
        -not (Test-Path -LiteralPath $script:CredentialKeyPath -PathType Leaf)) {
        return $null
    }

    $rawBytes = [IO.File]::ReadAllBytes($script:CredentialKeyPath)
    if ($rawBytes.Length -eq 32) {
        return ,$rawBytes
    }

    $text = [Text.Encoding]::UTF8.GetString($rawBytes).Trim()
    if ($text -match '^[0-9a-fA-F]{64}$') {
        $key = [byte[]]::new(32)
        for ($index = 0; $index -lt 32; $index++) {
            $key[$index] = [Convert]::ToByte($text.Substring($index * 2, 2), 16)
        }
        return ,$key
    }

    try {
        $decoded = [Convert]::FromBase64String($text)
        if ($decoded.Length -eq 32) {
            return ,$decoded
        }
    }
    catch {
        # The validation error below covers malformed Base64 and incorrect key sizes.
    }

    throw 'Credential key file must contain exactly 32 raw bytes, 64 hexadecimal characters, or a Base64-encoded 32-byte key.'
}

function Protect-AuthorizationStorePayload {
    param(
        [Parameter(Mandatory = $true)][string]$PlainText,
        [Parameter(Mandatory = $true)][byte[]]$Key
    )

    $nonce = [byte[]]::new(12)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($nonce) } finally { $rng.Dispose() }
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipherBytes = [byte[]]::new($plainBytes.Length)
    $tag = [byte[]]::new(16)
    $associatedData = [Text.Encoding]::UTF8.GetBytes('klanata.authorization-store.v1')
    $aes = [Security.Cryptography.AesGcm]::new($Key)
    try {
        $aes.Encrypt($nonce, $plainBytes, $cipherBytes, $tag, $associatedData)
    }
    finally {
        $aes.Dispose()
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }

    return [ordered]@{
        version = 1
        algorithm = 'AES-256-GCM'
        nonce = [Convert]::ToBase64String($nonce)
        ciphertext = [Convert]::ToBase64String($cipherBytes)
        tag = [Convert]::ToBase64String($tag)
    }
}

function Unprotect-AuthorizationStorePayload {
    param(
        [Parameter(Mandatory = $true)][object]$Envelope,
        [Parameter(Mandatory = $true)][byte[]]$Key
    )

    if ([int](Get-PricingPropertyValue -Object $Envelope -Name 'version' -DefaultValue 0) -ne 1 -or
        [string](Get-PricingPropertyValue -Object $Envelope -Name 'algorithm' -DefaultValue '') -ne 'AES-256-GCM') {
        throw 'Unsupported authorization store format.'
    }

    $nonce = [Convert]::FromBase64String([string]$Envelope.nonce)
    $cipherBytes = [Convert]::FromBase64String([string]$Envelope.ciphertext)
    $tag = [Convert]::FromBase64String([string]$Envelope.tag)
    if ($nonce.Length -ne 12 -or $tag.Length -ne 16) {
        throw 'Authorization store encryption metadata is invalid.'
    }
    $plainBytes = [byte[]]::new($cipherBytes.Length)
    $associatedData = [Text.Encoding]::UTF8.GetBytes('klanata.authorization-store.v1')
    $aes = [Security.Cryptography.AesGcm]::new($Key)
    try {
        $aes.Decrypt($nonce, $cipherBytes, $tag, $plainBytes, $associatedData)
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    }
    finally {
        $aes.Dispose()
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-CredentialStorageStatus {
    $key = $null
    try {
        $key = Get-AuthorizationStoreKey
    }
    catch {
        return 'aes-gcm-key-invalid'
    }
    if ($null -ne $key) {
        [Array]::Clear($key, 0, $key.Length)
        return 'aes-256-gcm-file'
    }
    return 'memory-only-key-unavailable'
}

function Get-DeveloperApplicationPublicStatus {
    $configured = $null -ne $script:DeveloperApplication -and
        -not [string]::IsNullOrWhiteSpace([string]$script:DeveloperApplication.clientId) -and
        -not [string]::IsNullOrWhiteSpace([string]$script:DeveloperApplication.clientSecret)

    $applicationId = if ($null -ne $script:DeveloperApplication) {
        [string](Get-PricingPropertyValue -Object $script:DeveloperApplication -Name 'applicationId' -DefaultValue '')
    }
    else { '' }
    $authorizationBaseUri = if ($null -ne $script:DeveloperApplication) {
        [string](Get-PricingPropertyValue `
            -Object $script:DeveloperApplication `
            -Name 'authorizationBaseUri' `
            -DefaultValue $script:DefaultAmazonAuthorizationBaseUri)
    }
    else { $script:DefaultAmazonAuthorizationBaseUri }

    return [ordered]@{
        configured = [bool]$configured
        oauthReady = [bool]($configured -and -not [string]::IsNullOrWhiteSpace($applicationId))
        applicationId = $applicationId
        authorizationBaseUri = $authorizationBaseUri
        clientId = if ($configured) { Get-MaskedClientId -ClientId ([string]$script:DeveloperApplication.clientId) } else { '' }
        clientSecret = if ($configured) { 'encrypted' } else { 'not-configured' }
        configuredAt = if ($configured) { [string]$script:DeveloperApplication.configuredAt } else { '' }
        credentialStorage = Get-CredentialStorageStatus
    }
}

function Save-AuthorizationStore {
    $key = Get-AuthorizationStoreKey
    if ($null -eq $key) {
        return $false
    }

    try {
        $application = if ($null -eq $script:DeveloperApplication) {
            $null
        }
        else {
            [ordered]@{
                applicationId = [string](Get-PricingPropertyValue -Object $script:DeveloperApplication -Name 'applicationId' -DefaultValue '')
                authorizationBaseUri = [string](Get-PricingPropertyValue `
                    -Object $script:DeveloperApplication `
                    -Name 'authorizationBaseUri' `
                    -DefaultValue $script:DefaultAmazonAuthorizationBaseUri)
                clientId = [string]$script:DeveloperApplication.clientId
                clientSecret = [string]$script:DeveloperApplication.clientSecret
                configuredAt = [string]$script:DeveloperApplication.configuredAt
            }
        }
        $profiles = @($script:AuthorizationProfiles.Values | Sort-Object id | ForEach-Object {
            [ordered]@{
                id = [string]$_.id
                sellerId = [string]$_.sellerId
                refreshToken = [string]$_.refreshToken
                requestedRegion = [string]$_.requestedRegion
                createdAt = [string]$_.createdAt
                updatedAt = [string]$_.updatedAt
            }
        })
        $payload = [ordered]@{
            application = $application
            profiles = $profiles
            savedAt = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 10 -Compress
        $envelope = Protect-AuthorizationStorePayload -PlainText $payload -Key $key
        $temporaryPath = "$($script:AuthorizationStorePath).tmp"
        Write-Utf8WithoutBom -Path $temporaryPath -Content ($envelope | ConvertTo-Json -Depth 5)
        Move-Item -LiteralPath $temporaryPath -Destination $script:AuthorizationStorePath -Force
        return $true
    }
    finally {
        [Array]::Clear($key, 0, $key.Length)
    }
}

function Load-AuthorizationStore {
    if (-not (Test-Path -LiteralPath $script:AuthorizationStorePath -PathType Leaf)) {
        return
    }

    $key = Get-AuthorizationStoreKey
    if ($null -eq $key) {
        Write-Warning 'Encrypted Amazon authorization data exists, but the credential key file is unavailable.'
        return
    }

    try {
        $envelope = Get-Content -LiteralPath $script:AuthorizationStorePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $plainText = Unprotect-AuthorizationStorePayload -Envelope $envelope -Key $key
        $payload = $plainText | ConvertFrom-Json
        $applicationProperty = $payload.PSObject.Properties['application']
        if ($null -ne $applicationProperty -and $null -ne $applicationProperty.Value) {
            $application = $applicationProperty.Value
            Set-DeveloperApplication `
                -ApplicationId ([string](Get-PricingPropertyValue -Object $application -Name 'applicationId' -DefaultValue '')) `
                -AuthorizationBaseUri ([string](Get-PricingPropertyValue `
                    -Object $application `
                    -Name 'authorizationBaseUri' `
                    -DefaultValue $script:DefaultAmazonAuthorizationBaseUri)) `
                -ClientId ([string]$application.clientId) `
                -ClientSecret ([string]$application.clientSecret) `
                -ConfiguredAt ([string](Get-PricingPropertyValue -Object $application -Name 'configuredAt' -DefaultValue ''))
        }

        $script:AuthorizationProfiles.Clear()
        foreach ($storedProfile in @($payload.profiles)) {
            $profileId = [string](Get-PricingPropertyValue -Object $storedProfile -Name 'id' -DefaultValue '')
            $refreshToken = [string](Get-PricingPropertyValue -Object $storedProfile -Name 'refreshToken' -DefaultValue '')
            if ($profileId -notmatch '^[a-f0-9]{32}$' -or [string]::IsNullOrWhiteSpace($refreshToken)) {
                continue
            }
            $script:AuthorizationProfiles[$profileId] = [pscustomobject]@{
                id = $profileId
                sellerId = [string](Get-PricingPropertyValue -Object $storedProfile -Name 'sellerId' -DefaultValue '')
                refreshToken = $refreshToken
                requestedRegion = [string](Get-PricingPropertyValue -Object $storedProfile -Name 'requestedRegion' -DefaultValue 'auto')
                createdAt = [string](Get-PricingPropertyValue -Object $storedProfile -Name 'createdAt' -DefaultValue '')
                updatedAt = [string](Get-PricingPropertyValue -Object $storedProfile -Name 'updatedAt' -DefaultValue '')
            }
        }
    }
    catch {
        throw 'Encrypted Amazon authorization data could not be loaded. Verify the credential key and store integrity.'
    }
    finally {
        [Array]::Clear($key, 0, $key.Length)
    }

    if ($null -eq $script:DeveloperApplication) {
        return
    }
    foreach ($profile in @($script:AuthorizationProfiles.Values)) {
        try {
            Restore-AuthorizationProfile -Profile $profile
        }
        catch {
            Write-Warning "Amazon authorization profile $($profile.id) could not be restored and remains encrypted for a later retry."
        }
    }
}

function Find-SpApiMarketplaceParticipations {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$PreferredRegion = ''
    )

    $normalizedPreferredRegion = $PreferredRegion.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedPreferredRegion) -or $normalizedPreferredRegion -eq 'auto') {
        $normalizedPreferredRegion = ''
        $candidateRegions = @('na', 'eu', 'fe')
    }
    elseif ($normalizedPreferredRegion -in @('na', 'eu', 'fe')) {
        $candidateRegions = @($normalizedPreferredRegion) + @('na', 'eu', 'fe') | Select-Object -Unique
    }
    else {
        throw "Unsupported SP-API region: $PreferredRegion"
    }

    $failures = [Collections.Generic.List[string]]::new()
    foreach ($candidateRegion in $candidateRegions) {
        $endpoint = Get-RegionEndpoint -Region $candidateRegion
        try {
            $response = Invoke-SpApiJson `
                -Method GET `
                -Uri "$endpoint/sellers/v1/marketplaceParticipations" `
                -AccessToken $AccessToken
            return [pscustomobject]@{
                region = $candidateRegion
                endpoint = $endpoint
                response = $response
                regionAutoDetected = [string]::IsNullOrWhiteSpace($normalizedPreferredRegion) -or $candidateRegion -ne $normalizedPreferredRegion
            }
        }
        catch {
            $safeMessage = ConvertTo-SafeAmazonMessage -Detail $_.Exception.Message
            [void]$failures.Add("$(Get-RegionDisplayName -Region $candidateRegion): $safeMessage")
        }
    }

    throw (
        'LWA issued an Access Token, but the Sellers API denied access in North America, Europe, and Far East. ' +
        'Confirm that the Refresh Token was authorized for the SP-API application matching this Client ID, ' +
        'and that the application roles and Seller Central authorization are still active. Region results: ' +
        ($failures -join ' | ')
    )
}

function Get-LwaToken {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [Parameter(Mandatory = $true)][string]$RefreshToken
    )

    for ($attempt = 1; $attempt -le $script:AmazonRequestMaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Post `
                -Uri 'https://api.amazon.com/auth/o2/token' `
                -ContentType 'application/x-www-form-urlencoded;charset=UTF-8' `
                -TimeoutSec $script:RequestTimeoutSec `
                -Body @{
                    grant_type = 'refresh_token'
                    refresh_token = $RefreshToken
                    client_id = $ClientId
                    client_secret = $ClientSecret
                }
        }
        catch {
            if ($attempt -lt $script:AmazonRequestMaxAttempts -and (Test-IsTransientAmazonFailure -ErrorRecord $_)) {
                Start-Sleep -Milliseconds (Get-AmazonRetryDelayMilliseconds -ErrorRecord $_ -Attempt $attempt)
                continue
            }

            $detail = ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_)
            throw "LWA authorization failed. $detail"
        }
    }
}

function Get-LwaAuthorizationCodeToken {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [Parameter(Mandatory = $true)][string]$AuthorizationCode,
        [Parameter(Mandatory = $true)][string]$RedirectUri
    )

    for ($attempt = 1; $attempt -le $script:AmazonRequestMaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Post `
                -Uri 'https://api.amazon.com/auth/o2/token' `
                -ContentType 'application/x-www-form-urlencoded;charset=UTF-8' `
                -TimeoutSec $script:RequestTimeoutSec `
                -Body @{
                    grant_type = 'authorization_code'
                    code = $AuthorizationCode
                    client_id = $ClientId
                    client_secret = $ClientSecret
                    redirect_uri = $RedirectUri
                }
        }
        catch {
            if ($attempt -lt $script:AmazonRequestMaxAttempts -and (Test-IsTransientAmazonFailure -ErrorRecord $_)) {
                Start-Sleep -Milliseconds (Get-AmazonRetryDelayMilliseconds -ErrorRecord $_ -Attempt $attempt)
                continue
            }

            $detail = ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_)
            throw "LWA authorization-code exchange failed. $detail"
        }
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
        [Parameter(Mandatory = $false)][object]$Body,
        [bool]$AllowRetry = $true
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

    $maximumAttempts = if ($AllowRetry) { $script:AmazonRequestMaxAttempts } else { 1 }
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @arguments -TimeoutSec $script:RequestTimeoutSec
        }
        catch {
            if ($attempt -lt $maximumAttempts -and (Test-IsTransientAmazonFailure -ErrorRecord $_)) {
                Start-Sleep -Milliseconds (Get-AmazonRetryDelayMilliseconds -ErrorRecord $_ -Attempt $attempt)
                continue
            }

            $detail = ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_)
            throw $detail
        }
    }
}

function ConvertTo-SpApiMarketplaces {
    param([Parameter(Mandatory = $true)][object]$MarketplaceResponse)

    return @($MarketplaceResponse.payload | ForEach-Object {
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
}

function Register-AuthorizationSession {
    param(
        [Parameter(Mandatory = $true)][object]$Token,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [Parameter(Mandatory = $true)][string]$RefreshToken,
        [AllowEmptyString()][string]$SellerId = '',
        [Parameter(Mandatory = $true)][object]$MarketplaceDiscovery,
        [string]$RequestedRegion = 'auto',
        [AllowEmptyString()][string]$ProfileId = ''
    )

    $verifiedDiscovery = Assert-AllowedAmazonMarketplaceDiscovery -MarketplaceDiscovery $MarketplaceDiscovery
    $marketplaces = @($verifiedDiscovery.marketplaces)
    $storeIdentity = $verifiedDiscovery.identity
    $normalizedSellerId = if ([string]::IsNullOrWhiteSpace($SellerId)) {
        ''
    }
    else {
        Normalize-AmazonSellerId -SellerId $SellerId
    }
    Assert-AllowedAmazonSellerId -SellerId $normalizedSellerId -AllowEmpty

    if ([string]::IsNullOrWhiteSpace($ProfileId)) {
        foreach ($existingProfile in @($script:AuthorizationProfiles.Values)) {
            if ([string]$existingProfile.refreshToken -eq $RefreshToken) {
                $ProfileId = [string]$existingProfile.id
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($ProfileId)) {
        $ProfileId = [guid]::NewGuid().ToString('N')
    }

    $now = [DateTime]::UtcNow.ToString('o')
    $existingCreatedAt = if ($script:AuthorizationProfiles.ContainsKey($ProfileId)) {
        [string](Get-PricingPropertyValue `
            -Object $script:AuthorizationProfiles[$ProfileId] `
            -Name 'createdAt' `
            -DefaultValue $now)
    }
    else { $now }
    $normalizedRequestedRegion = if ([string]::IsNullOrWhiteSpace($RequestedRegion)) {
        'auto'
    }
    else {
        $RequestedRegion.Trim().ToLowerInvariant()
    }
    $script:AuthorizationProfiles[$ProfileId] = [pscustomobject]@{
        id = $ProfileId
        sellerId = $normalizedSellerId
        refreshToken = $RefreshToken
        requestedRegion = $normalizedRequestedRegion
        createdAt = $existingCreatedAt
        updatedAt = $now
    }

    foreach ($existingSessionId in @($script:CurrentAuthSessionIds.ToArray())) {
        if (-not $script:AuthSessions.ContainsKey($existingSessionId)) {
            [void]$script:CurrentAuthSessionIds.Remove($existingSessionId)
            continue
        }
        $existingSession = $script:AuthSessions[$existingSessionId]
        if ($existingSessionId -eq $ProfileId -or
            ($existingSession.clientId -eq $ClientId -and $existingSession.refreshToken -eq $RefreshToken)) {
            [void]$script:CurrentAuthSessionIds.Remove($existingSessionId)
            [void]$script:AuthSessions.Remove($existingSessionId)
            if ($script:CurrentAuthSessionId -eq $existingSessionId) {
                $script:CurrentAuthSessionId = $null
            }
        }
    }

    $expiresIn = if ($null -ne $Token.expires_in) { [int]$Token.expires_in } else { 3600 }
    $script:AuthSessions[$ProfileId] = [pscustomobject]@{
        id = $ProfileId
        accessToken = [string]$Token.access_token
        expiresAt = [DateTime]::UtcNow.AddSeconds([Math]::Max(60, $expiresIn - 60))
        clientId = $ClientId
        clientSecret = $ClientSecret
        refreshToken = $RefreshToken
        sellerId = $normalizedSellerId
        endpoint = [string]$MarketplaceDiscovery.endpoint
        region = [string]$MarketplaceDiscovery.region
        requestedRegion = $normalizedRequestedRegion
        regionAutoDetected = [bool]$MarketplaceDiscovery.regionAutoDetected
        marketplaces = $marketplaces
        verifiedStoreName = [string]$storeIdentity.storeName
        storeIdentitySource = [string]$storeIdentity.source
        storeIdentityVerifiedAt = [string]$storeIdentity.verifiedAt
        validatedContexts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        lastUsedAt = [DateTime]::UtcNow
    }
    [void]$script:CurrentAuthSessionIds.Add($ProfileId)
    $script:CurrentAuthSessionId = $ProfileId
    return $script:AuthSessions[$ProfileId]
}

function Restore-AuthorizationProfile {
    param([Parameter(Mandatory = $true)][object]$Profile)

    Assert-AllowedAmazonSellerId `
        -SellerId ([string](Get-PricingPropertyValue -Object $Profile -Name 'sellerId' -DefaultValue '')) `
        -AllowEmpty
    if ($null -eq $script:DeveloperApplication) {
        throw 'Amazon developer application is not configured.'
    }
    $token = Get-LwaToken `
        -ClientId ([string]$script:DeveloperApplication.clientId) `
        -ClientSecret ([string]$script:DeveloperApplication.clientSecret) `
        -RefreshToken ([string]$Profile.refreshToken)
    $marketplaceDiscovery = Find-SpApiMarketplaceParticipations `
        -AccessToken ([string]$token.access_token) `
        -PreferredRegion ([string]$Profile.requestedRegion)
    [void](Register-AuthorizationSession `
        -Token $token `
        -ClientId ([string]$script:DeveloperApplication.clientId) `
        -ClientSecret ([string]$script:DeveloperApplication.clientSecret) `
        -RefreshToken ([string]$Profile.refreshToken) `
        -SellerId ([string]$Profile.sellerId) `
        -MarketplaceDiscovery $marketplaceDiscovery `
        -RequestedRegion ([string]$Profile.requestedRegion) `
        -ProfileId ([string]$Profile.id))
}

function Test-AuthSession {
    param([Parameter(Mandatory = $true)][string]$AuthSessionId)

    if (-not $script:AuthSessions.ContainsKey($AuthSessionId)) {
        throw 'Authorization session was not found. Verify credentials again.'
    }

    $session = $script:AuthSessions[$AuthSessionId]
    Assert-AllowedAmazonSession -Session $session
    if ([DateTime]::UtcNow -ge $session.expiresAt) {
        try {
            $token = Get-LwaToken `
                -ClientId $session.clientId `
                -ClientSecret $session.clientSecret `
                -RefreshToken $session.refreshToken
            $expiresIn = if ($null -ne $token.expires_in) { [int]$token.expires_in } else { 3600 }
            $session.accessToken = [string]$token.access_token
            $session.expiresAt = [DateTime]::UtcNow.AddSeconds([Math]::Max(60, $expiresIn - 60))
        }
        catch {
            $script:AuthSessions.Remove($AuthSessionId)
            throw 'Authorization session could not be refreshed. Verify credentials again.'
        }
    }

    $session.lastUsedAt = [DateTime]::UtcNow
    return $session
}

function Test-IsAuthorizationFailure {
    param([Parameter(Mandatory = $true)][string]$Message)

    return $Message -match '(?i)authorization session|LWA authorization|access token|unauthorized|not authorized|HTTP 401|only the .+ Amazon store'
}

function Set-ValidatedAuthorizationSellerBindings {
    param(
        [Parameter(Mandatory = $true)][string[]]$AuthSessionIds,
        [Parameter(Mandatory = $true)][string]$SellerId
    )

    $normalizedSellerId = Normalize-AmazonSellerId -SellerId $SellerId
    Assert-AllowedAmazonSellerId -SellerId $normalizedSellerId
    $snapshots = [Collections.Generic.List[object]]::new()
    foreach ($authSessionId in @($AuthSessionIds | Select-Object -Unique)) {
        if (-not $script:AuthSessions.ContainsKey($authSessionId)) {
            throw 'Authorization session was not found while binding the Seller account.'
        }
        $session = $script:AuthSessions[$authSessionId]
        Assert-AllowedAmazonSession -Session $session
        $sessionSellerId = [string](Get-PricingPropertyValue `
            -Object $session `
            -Name 'sellerId' `
            -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($sessionSellerId)) {
            if ((Normalize-AmazonSellerId -SellerId $sessionSellerId) -cne $normalizedSellerId) {
                throw 'The authorization session is already bound to another Seller account.'
            }
            continue
        }
        if (-not $script:AuthorizationProfiles.ContainsKey($authSessionId)) {
            throw 'The authorization profile was not found while binding the Seller account.'
        }
        $profile = $script:AuthorizationProfiles[$authSessionId]
        $profileSellerId = [string](Get-PricingPropertyValue `
            -Object $profile `
            -Name 'sellerId' `
            -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($profileSellerId) -and
            (Normalize-AmazonSellerId -SellerId $profileSellerId) -cne $normalizedSellerId) {
            throw 'The authorization profile is already bound to another Seller account.'
        }
        [void]$snapshots.Add([pscustomobject]@{
            session = $session
            profile = $profile
            sessionSellerId = $sessionSellerId
            profileSellerId = $profileSellerId
            profileUpdatedAt = [string](Get-PricingPropertyValue `
                -Object $profile `
                -Name 'updatedAt' `
                -DefaultValue '')
        })
    }

    if ($snapshots.Count -eq 0) {
        return $false
    }

    try {
        $updatedAt = [DateTime]::UtcNow.ToString('o')
        foreach ($snapshot in $snapshots) {
            $snapshot.session.sellerId = $normalizedSellerId
            $snapshot.profile.sellerId = $normalizedSellerId
            $snapshot.profile.updatedAt = $updatedAt
        }
        if (-not (Save-AuthorizationStore)) {
            throw 'Secure credential persistence is unavailable.'
        }
    }
    catch {
        foreach ($snapshot in $snapshots) {
            $snapshot.session.sellerId = $snapshot.sessionSellerId
            $snapshot.profile.sellerId = $snapshot.profileSellerId
            $snapshot.profile.updatedAt = $snapshot.profileUpdatedAt
        }
        throw 'The verified Seller binding could not be securely persisted.'
    }

    return $true
}

function Get-AuthorizationContextKey {
    param(
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$MarketplaceId
    )

    return "$($SellerId.Trim())::$($MarketplaceId.Trim())"
}

function Add-SessionValidatedContext {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$MarketplaceId
    )

    if ($null -eq $Session.PSObject.Properties['validatedContexts']) {
        $Session | Add-Member -NotePropertyName validatedContexts -NotePropertyValue (
            [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        )
    }
    [void]$Session.validatedContexts.Add((Get-AuthorizationContextKey -SellerId $SellerId -MarketplaceId $MarketplaceId))
}

function Test-SessionValidatedContext {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$MarketplaceId
    )

    if ($null -eq $Session.PSObject.Properties['validatedContexts']) {
        return $false
    }
    return $Session.validatedContexts.Contains(
        (Get-AuthorizationContextKey -SellerId $SellerId -MarketplaceId $MarketplaceId)
    )
}

function Invoke-AccountValidationPreview {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][object]$Analysis,
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$MarketplaceId
    )

    $marketplaceMatches = @($Session.marketplaces | Where-Object {
        $_.id -eq $MarketplaceId -and (Test-IsSelectableMarketplace -Marketplace $_)
    })
    if ($marketplaceMatches.Count -eq 0) {
        throw 'The selected marketplace is unavailable, suspended, or not part of this authorization.'
    }

    $sample = $Analysis.records[0]
    $encodedSku = [Uri]::EscapeDataString([string]$sample.sku)
    $uri = "$($Session.endpoint)/listings/2021-08-01/items/$SellerId/$encodedSku" +
        "?marketplaceIds=$MarketplaceId&mode=VALIDATION_PREVIEW&issueLocale=en_CA"
    $validationResponse = Invoke-SpApiJson `
        -Method PATCH `
        -Uri $uri `
        -AccessToken $Session.accessToken `
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

    $validationStatus = [string]$validationResponse.status
    $validationIssues = @($validationResponse.issues)
    $errorIssues = @($validationIssues | Where-Object { [string]$_.severity -eq 'ERROR' })
    if ($validationStatus -notin @('ACCEPTED', 'VALID') -or $errorIssues.Count -gt 0) {
        $issueText = @($errorIssues | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace([string]$_.code)) {
                [string]$_.message
            }
            else {
                "$($_.code): $($_.message)"
            }
        }) -join ' | '
        if ([string]::IsNullOrWhiteSpace($issueText)) {
            $issueText = "Amazon returned validation status $validationStatus."
        }
        throw "Validation preview was not accepted. $issueText"
    }

    return [pscustomobject]@{
        status = $validationStatus
        sku = [string]$validationResponse.sku
        issues = $validationIssues
    }
}

function Invoke-PricingValidationPreview {
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$SellerId,
        [Parameter(Mandatory = $true)][string]$MarketplaceId,
        [Parameter(Mandatory = $true)][string]$Currency,
        [Parameter(Mandatory = $true)][object]$Item
    )

    $encodedSku = [Uri]::EscapeDataString([string]$Item.sku)
    $uri = "$($Session.endpoint)/listings/2021-08-01/items/$SellerId/$encodedSku" +
        "?marketplaceIds=$MarketplaceId&mode=VALIDATION_PREVIEW&issueLocale=en_US"
    $validationResponse = Invoke-SpApiJson `
        -Method PATCH `
        -Uri $uri `
        -AccessToken $Session.accessToken `
        -Body (New-PricingPatchBody -Item $Item -MarketplaceId $MarketplaceId -Currency $Currency)

    $validationStatus = [string]$validationResponse.status
    $validationIssues = @($validationResponse.issues)
    $errorIssues = @($validationIssues | Where-Object { [string]$_.severity -eq 'ERROR' })
    if ($validationStatus -notin @('ACCEPTED', 'VALID') -or $errorIssues.Count -gt 0) {
        $issueText = @($errorIssues | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace([string]$_.code)) { [string]$_.message }
            else { "$($_.code): $($_.message)" }
        }) -join ' | '
        if ([string]::IsNullOrWhiteSpace($issueText)) {
            $issueText = "Amazon returned validation status $validationStatus."
        }
        throw "Price validation preview was not accepted for SKU $($Item.sku). $issueText"
    }

    return [pscustomobject]@{
        status = $validationStatus
        sku = [string]$Item.sku
        issueCount = $validationIssues.Count
    }
}

function Get-ValidatedSubmissionAuthSessionId {
    param(
        [Parameter(Mandatory = $true)][object]$Validation,
        [string]$RequestedAuthSessionId
    )

    $allowedSessionIds = if ($null -ne $Validation.PSObject.Properties['authSessionIds']) {
        @($Validation.authSessionIds)
    }
    else {
        @($Validation.authSessionId)
    }
    $selectedSessionId = ([string]$RequestedAuthSessionId).Trim()
    if ([string]::IsNullOrWhiteSpace($selectedSessionId)) {
        $selectedSessionId = [string]$Validation.authSessionId
    }
    if ($selectedSessionId -notin $allowedSessionIds) {
        throw 'The selected authorization was not validated for this Seller and Marketplace.'
    }
    return $selectedSessionId
}

function Test-IsValidPricingJobBatchLink {
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][object]$Batch
    )

    $jobSellerId = [string](Get-PricingPropertyValue -Object $Job -Name 'sellerId' -DefaultValue '')
    $batchSellerId = [string](Get-PricingPropertyValue -Object $Batch -Name 'sellerId' -DefaultValue '')
    if (-not (Test-IsAllowedAmazonSellerId -SellerId $jobSellerId) -or
        -not (Test-IsAllowedAmazonSellerId -SellerId $batchSellerId)) {
        return $false
    }

    return [string](Get-PricingPropertyValue -Object $Job -Name 'kind' -DefaultValue 'INVENTORY') -eq 'PRICING' -and
        [string](Get-PricingPropertyValue -Object $Job -Name 'pricingBatchId' -DefaultValue '') -eq
            [string](Get-PricingPropertyValue -Object $Batch -Name 'id' -DefaultValue '') -and
        [string](Get-PricingPropertyValue -Object $Batch -Name 'submissionJobId' -DefaultValue '') -eq
            [string](Get-PricingPropertyValue -Object $Job -Name 'id' -DefaultValue '') -and
        $jobSellerId -ceq $batchSellerId -and
        [string](Get-PricingPropertyValue -Object $Job -Name 'marketplaceId' -DefaultValue '') -ceq
            [string](Get-PricingPropertyValue -Object $Batch -Name 'marketplaceId' -DefaultValue '')
}

function ConvertTo-PublicJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    Assert-AllowedAmazonSellerId -SellerId ([string]$Job.sellerId)
    $publicPricingBatchId = ''
    $pricingBatchId = [string](Get-PricingPropertyValue -Object $Job -Name 'pricingBatchId' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($pricingBatchId) -and
        $script:PricingBatches.ContainsKey($pricingBatchId) -and
        (Test-IsValidPricingJobBatchLink -Job $Job -Batch $script:PricingBatches[$pricingBatchId])) {
        $publicPricingBatchId = $pricingBatchId
    }
    $reportAvailable = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$Job.reportFileName)) {
        $reportAvailable = Test-Path -LiteralPath (Join-Path $script:RuntimeRoot $Job.reportFileName)
    }

    return [ordered]@{
        id = $Job.id
        kind = [string](Get-PricingPropertyValue -Object $Job -Name 'kind' -DefaultValue 'INVENTORY')
        pricingBatchId = $publicPricingBatchId
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
        direction = [string](Get-PricingPropertyValue -Object $Job -Name 'direction' -DefaultValue '')
        currency = [string](Get-PricingPropertyValue -Object $Job -Name 'currency' -DefaultValue '')
        reportAvailable = $reportAvailable
        reportSummary = $Job.reportSummary
        error = $Job.error
    }
}

function ConvertTo-PersistedJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    return [ordered]@{
        id = $Job.id
        kind = [string](Get-PricingPropertyValue -Object $Job -Name 'kind' -DefaultValue 'INVENTORY')
        pricingBatchId = [string](Get-PricingPropertyValue -Object $Job -Name 'pricingBatchId' -DefaultValue '')
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
        direction = [string](Get-PricingPropertyValue -Object $Job -Name 'direction' -DefaultValue '')
        currency = [string](Get-PricingPropertyValue -Object $Job -Name 'currency' -DefaultValue '')
        reportFileName = $Job.reportFileName
        reportSummary = $Job.reportSummary
        resultDocumentId = $Job.resultDocumentId
        error = $Job.error
    }
}

function ConvertTo-PublicAuthSession {
    param([Parameter(Mandatory = $true)][object]$Session)

    Assert-AllowedAmazonSession -Session $Session
    $sellerId = [string](Get-PricingPropertyValue -Object $Session -Name 'sellerId' -DefaultValue '')
    $selectableMarketplaces = @($Session.marketplaces | Where-Object {
        Test-IsSelectableMarketplace -Marketplace $_
    })
    $expiresIn = [Math]::Max(0, [int][Math]::Floor(($Session.expiresAt - [DateTime]::UtcNow).TotalSeconds))
    return [ordered]@{
        authSessionId = $Session.id
        sellerId = $sellerId
        sellerBound = -not [string]::IsNullOrWhiteSpace($sellerId)
        storeAllowed = $true
        verifiedStoreName = [string]$Session.verifiedStoreName
        storeIdentitySource = [string]$Session.storeIdentitySource
        storeIdentityVerifiedAt = [string]$Session.storeIdentityVerifiedAt
        expiresIn = $expiresIn
        region = $Session.region
        requestedRegion = $Session.requestedRegion
        regionAutoDetected = $Session.regionAutoDetected
        endpoint = $Session.endpoint
        storeNames = @($selectableMarketplaces.storeName | Sort-Object -Unique)
        marketplaces = $selectableMarketplaces
    }
}

function Save-JobStore {
    $persisted = @($script:Jobs.Values | ForEach-Object {
        ConvertTo-PersistedJob -Job $_
    })
    $temporaryPath = "$($script:JobsPath).tmp"
    Write-Utf8WithoutBom -Path $temporaryPath -Content ($persisted | ConvertTo-Json -Depth 20)
    Move-Item -LiteralPath $temporaryPath -Destination $script:JobsPath -Force
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
            elseif ($status -in @('PREPARING_SUBMISSION', 'SUBMITTING')) {
                $status = 'SUBMISSION_UNKNOWN'
            }
            $reportFileNameProperty = $item.PSObject.Properties['reportFileName']
            $reportAvailableProperty = $item.PSObject.Properties['reportAvailable']
            $resultDocumentProperty = $item.PSObject.Properties['resultDocumentId']
            $reportFileName = if ($null -ne $reportFileNameProperty) {
                [string]$reportFileNameProperty.Value
            }
            elseif ($null -ne $reportAvailableProperty -and [bool]$reportAvailableProperty.Value) {
                "feed-processing-report-$($item.feedId).json"
            }
            else {
                $null
            }

            if ($status -in @('DONE', 'FATAL', 'CANCELLED') -and
                [string]::IsNullOrWhiteSpace($reportFileName) -and
                $null -ne $resultDocumentProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$resultDocumentProperty.Value)) {
                $status = 'RECONNECT_REQUIRED'
            }

            $script:Jobs[[string]$item.id] = [pscustomobject]@{
                id = [string]$item.id
                kind = [string](Get-PricingPropertyValue -Object $item -Name 'kind' -DefaultValue 'INVENTORY')
                pricingBatchId = [string](Get-PricingPropertyValue -Object $item -Name 'pricingBatchId' -DefaultValue '')
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
                direction = [string](Get-PricingPropertyValue -Object $item -Name 'direction' -DefaultValue '')
                currency = [string](Get-PricingPropertyValue -Object $item -Name 'currency' -DefaultValue '')
                reportFileName = $reportFileName
                reportSummary = $item.reportSummary
                error = [string]$item.error
                authSessionId = $null
                resultDocumentId = if ($null -ne $resultDocumentProperty) { [string]$resultDocumentProperty.Value } else { $null }
            }
        }
    }
    catch {
        $backupPath = "$($script:JobsPath).invalid-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item -LiteralPath $script:JobsPath -Destination $backupPath
    }
}

function ConvertTo-PersistedPricingBatch {
    param([Parameter(Mandatory = $true)][object]$Batch)

    return [ordered]@{
        id = $Batch.id
        simulationId = $Batch.simulationId
        fingerprint = $Batch.fingerprint
        status = $Batch.status
        createdAt = $Batch.createdAt
        updatedAt = $Batch.updatedAt
        approvedAt = $Batch.approvedAt
        submittedAt = $Batch.submittedAt
        accountValidationId = $Batch.accountValidationId
        sellerId = $Batch.sellerId
        marketplaceId = $Batch.marketplaceId
        countryCode = $Batch.countryCode
        currency = $Batch.currency
        region = $Batch.region
        storeName = $Batch.storeName
        fileName = $Batch.fileName
        rows = $Batch.rows
        direction = $Batch.direction
        risk = $Batch.risk
        rule = $Batch.rule
        items = $Batch.items
        approvalConfirmation = $Batch.approvalConfirmation
        submissionConfirmation = $Batch.submissionConfirmation
        validationPreview = $Batch.validationPreview
        submissionJobId = $Batch.submissionJobId
        reportSummary = $Batch.reportSummary
        error = $Batch.error
    }
}

function ConvertTo-PublicPricingBatch {
    param([Parameter(Mandatory = $true)][object]$Batch)

    Assert-AllowedAmazonSellerId -SellerId ([string]$Batch.sellerId)
    $feedId = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Batch.submissionJobId) -and
        $script:Jobs.ContainsKey([string]$Batch.submissionJobId) -and
        (Test-IsValidPricingJobBatchLink `
            -Job $script:Jobs[[string]$Batch.submissionJobId] `
            -Batch $Batch)) {
        $feedId = [string]$script:Jobs[[string]$Batch.submissionJobId].feedId
    }
    $requiredConfirmation = switch ([string]$Batch.status) {
        'APPROVAL_PENDING' { [string]$Batch.approvalConfirmation }
        'APPROVED' { [string]$Batch.submissionConfirmation }
        default { '' }
    }

    return [ordered]@{
        id = $Batch.id
        status = $Batch.status
        createdAt = $Batch.createdAt
        updatedAt = $Batch.updatedAt
        approvedAt = $Batch.approvedAt
        submittedAt = $Batch.submittedAt
        accountValidationId = $Batch.accountValidationId
        sellerId = $Batch.sellerId
        marketplaceId = $Batch.marketplaceId
        countryCode = $Batch.countryCode
        currency = $Batch.currency
        region = $Batch.region
        storeName = $Batch.storeName
        fileName = $Batch.fileName
        rows = $Batch.rows
        direction = $Batch.direction
        risk = $Batch.risk
        rule = $Batch.rule
        fingerprint = $Batch.fingerprint
        requiredConfirmation = $requiredConfirmation
        validationPreview = $Batch.validationPreview
        submissionJobId = $Batch.submissionJobId
        feedId = $feedId
        reportSummary = $Batch.reportSummary
        error = $Batch.error
        items = @($Batch.items | Select-Object -First 250)
        itemsTruncated = $Batch.rows -gt 250
    }
}

function Save-PricingBatchStore {
    $persisted = @($script:PricingBatches.Values | ForEach-Object {
        ConvertTo-PersistedPricingBatch -Batch $_
    })
    $temporaryPath = "$($script:PricingBatchesPath).tmp"
    Write-Utf8WithoutBom -Path $temporaryPath -Content ($persisted | ConvertTo-Json -Depth 30)
    Move-Item -LiteralPath $temporaryPath -Destination $script:PricingBatchesPath -Force
}

function Load-PricingBatchStore {
    if (-not (Test-Path -LiteralPath $script:PricingBatchesPath)) { return }

    try {
        $items = @(Get-Content -LiteralPath $script:PricingBatchesPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$item.id)) { continue }
            $status = [string]$item.status
            if ($status -in @('SUBMITTING', 'SUBMISSION_PREPARING')) { $status = 'SUBMISSION_UNKNOWN' }
            $script:PricingBatches[[string]$item.id] = [pscustomobject]@{
                id = [string]$item.id
                simulationId = [string]$item.simulationId
                fingerprint = [string]$item.fingerprint
                status = $status
                createdAt = [string]$item.createdAt
                updatedAt = [string]$item.updatedAt
                approvedAt = [string](Get-PricingPropertyValue -Object $item -Name 'approvedAt' -DefaultValue '')
                submittedAt = [string](Get-PricingPropertyValue -Object $item -Name 'submittedAt' -DefaultValue '')
                accountValidationId = [string](Get-PricingPropertyValue -Object $item -Name 'accountValidationId' -DefaultValue '')
                sellerId = [string]$item.sellerId
                marketplaceId = [string]$item.marketplaceId
                countryCode = [string]$item.countryCode
                currency = [string]$item.currency
                region = [string]$item.region
                storeName = [string]$item.storeName
                fileName = [string]$item.fileName
                rows = [int]$item.rows
                direction = [string]$item.direction
                risk = [string]$item.risk
                rule = $item.rule
                items = @($item.items)
                approvalConfirmation = [string]$item.approvalConfirmation
                submissionConfirmation = [string]$item.submissionConfirmation
                validationPreview = Get-PricingPropertyValue -Object $item -Name 'validationPreview' -DefaultValue $null
                submissionJobId = [string](Get-PricingPropertyValue -Object $item -Name 'submissionJobId' -DefaultValue '')
                reportSummary = Get-PricingPropertyValue -Object $item -Name 'reportSummary' -DefaultValue $null
                error = [string](Get-PricingPropertyValue -Object $item -Name 'error' -DefaultValue '')
            }
        }
    }
    catch {
        $backupPath = "$($script:PricingBatchesPath).invalid-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item -LiteralPath $script:PricingBatchesPath -Destination $backupPath
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
    for ($attempt = 1; $attempt -le $script:AmazonRequestMaxAttempts; $attempt++) {
        try {
            Invoke-WebRequest `
                -Method Get `
                -Uri $Document.url `
                -OutFile $temporaryPath `
                -TimeoutSec $script:RequestTimeoutSec `
                -UseBasicParsing
            break
        }
        catch {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt $script:AmazonRequestMaxAttempts -and (Test-IsTransientAmazonFailure -ErrorRecord $_)) {
                Start-Sleep -Milliseconds (Get-AmazonRetryDelayMilliseconds -ErrorRecord $_ -Attempt $attempt)
                continue
            }
            throw
        }
    }

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

function Send-FeedDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Path
    )

    for ($attempt = 1; $attempt -le $script:AmazonRequestMaxAttempts; $attempt++) {
        try {
            Invoke-WebRequest `
                -Method Put `
                -Uri $Uri `
                -ContentType 'application/json; charset=UTF-8' `
                -InFile $Path `
                -TimeoutSec $script:RequestTimeoutSec `
                -UseBasicParsing | Out-Null
            return
        }
        catch {
            if ($attempt -lt $script:AmazonRequestMaxAttempts -and (Test-IsTransientAmazonFailure -ErrorRecord $_)) {
                Start-Sleep -Milliseconds (Get-AmazonRetryDelayMilliseconds -ErrorRecord $_ -Attempt $attempt)
                continue
            }

            throw "Feed document upload failed. $(ConvertTo-SafeAmazonMessage -Detail (Get-ErrorDetail -ErrorRecord $_))"
        }
    }
}

function Update-PricingBatchFromJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    if ([string](Get-PricingPropertyValue -Object $Job -Name 'kind' -DefaultValue 'INVENTORY') -ne 'PRICING') { return }
    $batchId = [string](Get-PricingPropertyValue -Object $Job -Name 'pricingBatchId' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($batchId) -or -not $script:PricingBatches.ContainsKey($batchId)) { return }

    $batch = $script:PricingBatches[$batchId]
    if (-not (Test-IsValidPricingJobBatchLink -Job $Job -Batch $batch)) { return }
    $batch.updatedAt = [string]$Job.updatedAt
    $batch.reportSummary = $Job.reportSummary
    $batch.error = [string]$Job.error
    switch ([string]$Job.status) {
        'IN_QUEUE' { $batch.status = 'SUBMITTED' }
        'IN_PROGRESS' { $batch.status = 'PROCESSING' }
        'RECONNECT_REQUIRED' { $batch.status = 'RECONNECT_REQUIRED' }
        'SUBMISSION_UNKNOWN' { $batch.status = 'SUBMISSION_UNKNOWN' }
        'SUBMISSION_FAILED' { $batch.status = 'SUBMISSION_FAILED' }
        'FATAL' { $batch.status = 'FAILED' }
        'CANCELLED' { $batch.status = 'CANCELLED' }
        'DONE' {
            if ([string]::IsNullOrWhiteSpace([string]$Job.reportFileName)) {
                $batch.status = 'PROCESSING_REPORT_PENDING'
            }
            else {
                $summary = $Job.reportSummary
                $invalid = if ($null -eq $summary) { 0 } else { [int](Get-PricingPropertyValue -Object $summary -Name 'messagesInvalid' -DefaultValue 0) }
                $errors = if ($null -eq $summary) { 0 } else { [int](Get-PricingPropertyValue -Object $summary -Name 'errors' -DefaultValue 0) }
                $warnings = if ($null -eq $summary) { 0 } else { [int](Get-PricingPropertyValue -Object $summary -Name 'warnings' -DefaultValue 0) }
                if ($invalid -gt 0 -or $errors -gt 0) { $batch.status = 'PARTIALLY_FAILED' }
                elseif ($warnings -gt 0) { $batch.status = 'COMPLETED_WITH_WARNINGS' }
                else { $batch.status = 'COMPLETED' }
            }
        }
    }
    Save-PricingBatchStore
}

function Update-FeedJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    Assert-AllowedAmazonSellerId -SellerId ([string]$Job.sellerId)
    $shouldRefreshStatus = $Job.status -in @('IN_QUEUE', 'IN_PROGRESS')
    $shouldFetchReport = $Job.status -in @('DONE', 'CANCELLED', 'FATAL') -and
        -not [string]::IsNullOrWhiteSpace([string]$Job.resultDocumentId) -and
        [string]::IsNullOrWhiteSpace([string]$Job.reportFileName)
    if (-not $shouldRefreshStatus -and -not $shouldFetchReport) {
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$Job.authSessionId)) {
        $Job.status = 'RECONNECT_REQUIRED'
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-JobStore
        Update-PricingBatchFromJob -Job $Job
        return
    }

    try {
        $session = Test-AuthSession -AuthSessionId $Job.authSessionId
        Assert-AllowedAmazonProductionContext `
            -Session $session `
            -SellerId ([string]$Job.sellerId) `
            -MarketplaceId ([string]$Job.marketplaceId) `
            -RequireValidatedContext
        if ($shouldRefreshStatus) {
            $feed = Invoke-SpApiJson `
                -Method GET `
                -Uri "$($session.endpoint)/feeds/2021-06-30/feeds/$($Job.feedId)" `
                -AccessToken $session.accessToken

            $Job.status = [string]$feed.processingStatus
            $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $resultDocumentProperty = $feed.PSObject.Properties['resultFeedDocumentId']
            $Job.resultDocumentId = if ($null -ne $resultDocumentProperty) {
                [string]$resultDocumentProperty.Value
            }
            else {
                $null
            }
        }
        $Job.error = $null

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
        if (Test-IsAuthorizationFailure -Message $Job.error) {
            $Job.status = 'RECONNECT_REQUIRED'
            $Job.authSessionId = $null
        }
        $Job.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-JobStore
        Update-PricingBatchFromJob -Job $Job
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

function Get-RequestPublicOrigin {
    param([Parameter(Mandatory = $true)][Net.HttpListenerRequest]$Request)

    $configuredOrigin = ([string]$env:KLANATA_PUBLIC_ORIGIN).Trim().TrimEnd('/')
    $candidateOrigin = if (-not [string]::IsNullOrWhiteSpace($configuredOrigin)) {
        $configuredOrigin
    }
    else {
        $Request.Url.GetLeftPart([UriPartial]::Authority)
    }
    $originUri = $null
    if (-not [Uri]::TryCreate($candidateOrigin, [UriKind]::Absolute, [ref]$originUri) -or
        $originUri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrWhiteSpace($originUri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($originUri.Query) -or
        -not [string]::IsNullOrWhiteSpace($originUri.Fragment) -or
        $originUri.AbsolutePath -ne '/') {
        throw 'The public callback origin is invalid.'
    }
    return $originUri.GetLeftPart([UriPartial]::Authority)
}

function Get-OAuthUiRedirectLocation {
    param(
        [Parameter(Mandatory = $true)][Net.HttpListenerRequest]$Request,
        [AllowEmptyString()][string]$CallbackUrl,
        [Parameter(Mandatory = $true)][string]$Fragment
    )

    $origin = if ([string]::IsNullOrWhiteSpace($CallbackUrl)) {
        Get-RequestPublicOrigin -Request $Request
    }
    else {
        ([Uri]$CallbackUrl).GetLeftPart([UriPartial]::Authority)
    }
    return "$origin/#$Fragment"
}

function New-OAuthState {
    param([Parameter(Mandatory = $true)][string]$CallbackUrl)

    $now = [DateTime]::UtcNow
    foreach ($existingState in @($script:OAuthStates.Keys)) {
        if ([DateTime]$script:OAuthStates[$existingState].expiresAt -le $now) {
            [void]$script:OAuthStates.Remove($existingState)
        }
    }
    if ($script:OAuthStates.Count -ge 100) {
        $statesToRemove = @($script:OAuthStates.GetEnumerator() |
            Sort-Object { [DateTime]$_.Value.createdAt } |
            Select-Object -First ($script:OAuthStates.Count - 99))
        foreach ($stateToRemove in $statesToRemove) {
            [void]$script:OAuthStates.Remove([string]$stateToRemove.Key)
        }
    }

    $randomBytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
    $state = [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $script:OAuthStates[$state] = [pscustomobject]@{
        callbackUrl = $CallbackUrl
        createdAt = $now
        expiresAt = $now.AddMinutes(10)
    }
    return $state
}

function Take-OAuthState {
    param([AllowEmptyString()][string]$State)

    if ([string]::IsNullOrWhiteSpace($State)) {
        return [pscustomobject]@{ ok = $false; reason = 'missing_state'; value = $null }
    }
    if (-not $script:OAuthStates.ContainsKey($State)) {
        return [pscustomobject]@{ ok = $false; reason = 'invalid_state'; value = $null }
    }

    $value = $script:OAuthStates[$State]
    [void]$script:OAuthStates.Remove($State)
    if ([DateTime]::UtcNow -ge [DateTime]$value.expiresAt) {
        return [pscustomobject]@{ ok = $false; reason = 'expired_state'; value = $null }
    }
    return [pscustomobject]@{ ok = $true; reason = ''; value = $value }
}

function Write-OAuthRedirect {
    param(
        [Parameter(Mandatory = $true)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$Location
    )

    $Context.Response.StatusCode = 302
    $Context.Response.RedirectLocation = $Location
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.ContentLength64 = 0
    $Context.Response.OutputStream.Close()
}

function Test-IsLocalAdminRequest {
    param([Parameter(Mandatory = $true)][Net.HttpListenerRequest]$Request)

    $remoteEndpoint = $Request.RemoteEndPoint
    if ($null -eq $remoteEndpoint -or -not [Net.IPAddress]::IsLoopback($remoteEndpoint.Address)) {
        return $false
    }
    foreach ($headerName in @('Forwarded', 'X-Forwarded-For', 'X-Real-IP')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Request.Headers[$headerName])) {
            return $false
        }
    }
    return $true
}

function Get-LegacyPricingWriteBlock {
    param([Parameter(Mandatory = $true)][bool]$IsLocalAdmin)

    if (-not $EnableUnsafeLegacyPricingMigration) {
        return [pscustomobject]@{
            statusCode = 403
            code = 'V4_REQUIRED'
            message = 'Legacy pricing writes are retired. Use the V4 API-native pricing workflow.'
        }
    }
    if ($ReadOnly) {
        return [pscustomobject]@{
            statusCode = 403
            code = 'READ_ONLY'
            message = 'The legacy workstation is running in read-only fallback mode.'
        }
    }
    if (-not $IsLocalAdmin) {
        return [pscustomobject]@{
            statusCode = 403
            code = 'ADMIN_LOCAL_ONLY'
            message = 'The unsafe legacy pricing migration override is restricted to a local server administrator.'
        }
    }
    return $null
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
            instanceId = $script:InstanceId
            defaultFileAvailable = (-not [string]::IsNullOrWhiteSpace($script:DefaultSourceFile)) -and (Test-Path -LiteralPath $script:DefaultSourceFile -PathType Leaf)
            defaultFileName = if ([string]::IsNullOrWhiteSpace($script:DefaultSourceFile)) { '' } else { [IO.Path]::GetFileName($script:DefaultSourceFile) }
            credentialStorage = Get-CredentialStorageStatus
            apiVersion = '1.5'
            amazonRequestMaxAttempts = $script:AmazonRequestMaxAttempts
            submissionConfirmation = 'risk-based-row-count'
            pricingMode = 'administrator-emergency-simulation'
            pricingProductionEnabled = $false
            legacyPricingSimulationAvailable = Test-IsLocalAdminRequest -Request $request
            legacyPricingMigrationUnsafeOverrideEnabled = [bool]$EnableUnsafeLegacyPricingMigration
            allowedAmazonStoreName = $script:AllowedAmazonStoreName
            allowedAmazonSellerIds = @($script:AllowedAmazonSellerIdSet | Sort-Object)
            developerApplication = Get-DeveloperApplicationPublicStatus
            adminConfigurationWritable = Test-IsLocalAdminRequest -Request $request
            readOnly = [bool]$ReadOnly
        })
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/auth/application') {
        if (-not (Test-IsLocalAdminRequest -Request $request)) {
            Write-ApiError -Context $Context -StatusCode 403 -Message 'Amazon application configuration is restricted to the server administrator.' -Code 'ADMIN_LOCAL_ONLY'
            return
        }
        $previousApplication = $script:DeveloperApplication
        $configurationSaved = $false
        try {
            $body = Read-JsonBody -Request $request
            $existingApplication = $script:DeveloperApplication
            $applicationId = [string](Get-PricingPropertyValue -Object $body -Name 'applicationId' -DefaultValue '')
            $authorizationBaseUri = [string](Get-PricingPropertyValue -Object $body -Name 'authorizationBaseUri' -DefaultValue '')
            $clientId = [string](Get-PricingPropertyValue -Object $body -Name 'clientId' -DefaultValue '')
            $clientSecret = [string](Get-PricingPropertyValue -Object $body -Name 'clientSecret' -DefaultValue '')

            if ($null -ne $existingApplication) {
                if ([string]::IsNullOrWhiteSpace($applicationId)) {
                    $applicationId = [string](Get-PricingPropertyValue -Object $existingApplication -Name 'applicationId' -DefaultValue '')
                }
                if ([string]::IsNullOrWhiteSpace($authorizationBaseUri)) {
                    $authorizationBaseUri = [string](Get-PricingPropertyValue `
                        -Object $existingApplication `
                        -Name 'authorizationBaseUri' `
                        -DefaultValue $script:DefaultAmazonAuthorizationBaseUri)
                }
                if ([string]::IsNullOrWhiteSpace($clientId)) {
                    $clientId = [string]$existingApplication.clientId
                }
                if ([string]::IsNullOrWhiteSpace($clientSecret)) {
                    $clientSecret = [string]$existingApplication.clientSecret
                }
            }
            elseif ([string]::IsNullOrWhiteSpace($authorizationBaseUri)) {
                $authorizationBaseUri = $script:DefaultAmazonAuthorizationBaseUri
            }

            if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
                throw 'Client ID and Client Secret are required for the initial Amazon developer application configuration.'
            }
            Set-DeveloperApplication `
                -ApplicationId $applicationId `
                -AuthorizationBaseUri $authorizationBaseUri `
                -ClientId $clientId `
                -ClientSecret $clientSecret
            $persisted = Save-AuthorizationStore
            if (-not $persisted) {
                throw 'Secure credential persistence is unavailable. Configure the workstation credential key before saving the Amazon developer application.'
            }
            $configurationSaved = $true
            Write-JsonResponse -Context $Context -Value ([ordered]@{
                developerApplication = Get-DeveloperApplicationPublicStatus
                persisted = $true
            })
        }
        catch {
            if (-not $configurationSaved) {
                $script:DeveloperApplication = $previousApplication
            }
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'APPLICATION_CONFIGURATION_FAILED'
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/auth/oauth/start') {
        try {
            $application = $script:DeveloperApplication
            if ($null -eq $application -or
                [string]::IsNullOrWhiteSpace([string]$application.clientId) -or
                [string]::IsNullOrWhiteSpace([string]$application.clientSecret) -or
                [string]::IsNullOrWhiteSpace([string](Get-PricingPropertyValue -Object $application -Name 'applicationId' -DefaultValue ''))) {
                throw 'Amazon OAuth is not ready. Configure the Application ID, Client ID, and Client Secret first.'
            }
            $storeKey = Get-AuthorizationStoreKey
            if ($null -eq $storeKey) {
                throw 'Secure credential persistence is unavailable. Configure the workstation credential key before authorizing a store.'
            }
            [Array]::Clear($storeKey, 0, $storeKey.Length)

            $callbackUrl = "$(Get-RequestPublicOrigin -Request $request)/api/auth/oauth/callback"
            $state = New-OAuthState -CallbackUrl $callbackUrl
            $authorizationBaseUri = [string](Get-PricingPropertyValue `
                -Object $application `
                -Name 'authorizationBaseUri' `
                -DefaultValue $script:DefaultAmazonAuthorizationBaseUri)
            $separator = if ($authorizationBaseUri.Contains('?')) { '&' } else { '?' }
            $authorizationUrl = $authorizationBaseUri + $separator +
                'application_id=' + [Uri]::EscapeDataString([string]$application.applicationId) +
                '&state=' + [Uri]::EscapeDataString($state)
            Write-JsonResponse -Context $Context -Value ([ordered]@{
                authorizationUrl = $authorizationUrl
                callbackUrl = $callbackUrl
                expiresIn = 600
            })
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'OAUTH_START_FAILED'
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/auth/oauth/callback') {
        $stateResult = Take-OAuthState -State ([string]$request.QueryString['state'])
        if (-not [bool]$stateResult.ok) {
            $redirectLocation = Get-OAuthUiRedirectLocation `
                -Request $request `
                -CallbackUrl '' `
                -Fragment "settings?amazon=error&reason=$($stateResult.reason)"
            Write-OAuthRedirect -Context $Context -Location $redirectLocation
            return
        }
        $callbackUrl = [string]$stateResult.value.callbackUrl

        if (-not [string]::IsNullOrWhiteSpace([string]$request.QueryString['error'])) {
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=authorization_denied')
            return
        }
        $sellerIdValue = [string]$request.QueryString['selling_partner_id']
        $authorizationCode = [string]$request.QueryString['spapi_oauth_code']
        try {
            $sellerIdValue = Normalize-AmazonSellerId -SellerId $sellerIdValue
        }
        catch {
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=authorization_response_invalid')
            return
        }
        if (-not (Test-IsAllowedAmazonSellerId -SellerId $sellerIdValue)) {
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=store_not_allowed')
            return
        }
        if ([string]::IsNullOrWhiteSpace($authorizationCode)) {
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=authorization_response_invalid')
            return
        }
        if ($null -eq $script:DeveloperApplication) {
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=server_configuration')
            return
        }

        try {
            $token = Get-LwaAuthorizationCodeToken `
                -ClientId ([string]$script:DeveloperApplication.clientId) `
                -ClientSecret ([string]$script:DeveloperApplication.clientSecret) `
                -AuthorizationCode $authorizationCode `
                -RedirectUri $callbackUrl
            $refreshToken = [string](Get-PricingPropertyValue -Object $token -Name 'refresh_token' -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($refreshToken)) {
                throw 'The authorization-code response did not include a Refresh Token.'
            }
        }
        catch {
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=token_exchange_failed')
            return
        }

        try {
            $marketplaceDiscovery = Find-SpApiMarketplaceParticipations `
                -AccessToken ([string]$token.access_token) `
                -PreferredRegion 'auto'
            [void](Assert-AllowedAmazonMarketplaceDiscovery -MarketplaceDiscovery $marketplaceDiscovery)
        }
        catch {
            $reason = if (Test-IsAmazonStoreNotAllowedError -ErrorRecord $_) {
                'store_not_allowed'
            }
            else {
                'marketplace_discovery_failed'
            }
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment "settings?amazon=error&reason=$reason")
            return
        }

        $previousAuthSessions = $script:AuthSessions.Clone()
        $previousAuthorizationProfiles = $script:AuthorizationProfiles.Clone()
        $previousCurrentAuthSessionIds = @($script:CurrentAuthSessionIds.ToArray())
        $previousCurrentAuthSessionId = $script:CurrentAuthSessionId
        try {
            $session = Register-AuthorizationSession `
                -Token $token `
                -ClientId ([string]$script:DeveloperApplication.clientId) `
                -ClientSecret ([string]$script:DeveloperApplication.clientSecret) `
                -RefreshToken $refreshToken `
                -SellerId $sellerIdValue `
                -MarketplaceDiscovery $marketplaceDiscovery `
                -RequestedRegion 'auto'
        }
        catch {
            $reason = if (Test-IsAmazonStoreNotAllowedError -ErrorRecord $_) {
                'store_not_allowed'
            }
            else {
                'authorization_binding_failed'
            }
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment "settings?amazon=error&reason=$reason")
            return
        }
        try {
            $persisted = Save-AuthorizationStore
        }
        catch {
            $persisted = $false
        }
        if (-not $persisted) {
            $script:AuthSessions = $previousAuthSessions
            $script:AuthorizationProfiles = $previousAuthorizationProfiles
            $script:CurrentAuthSessionIds = [Collections.Generic.List[string]]::new()
            foreach ($previousSessionId in $previousCurrentAuthSessionIds) {
                [void]$script:CurrentAuthSessionIds.Add($previousSessionId)
            }
            $script:CurrentAuthSessionId = $previousCurrentAuthSessionId
            Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
                -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=error&reason=storage_unavailable')
            return
        }

        Write-OAuthRedirect -Context $Context -Location (Get-OAuthUiRedirectLocation `
            -Request $request -CallbackUrl $callbackUrl -Fragment 'settings?amazon=connected')
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/analyze') {
        try {
            $body = Read-JsonBody -Request $request
            $useDefaultProperty = $body.PSObject.Properties['useDefault']
            $useDefault = $null -ne $useDefaultProperty -and [bool]$useDefaultProperty.Value
            if ($useDefault) {
                if ([string]::IsNullOrWhiteSpace($script:DefaultSourceFile) -or -not (Test-Path -LiteralPath $script:DefaultSourceFile -PathType Leaf)) {
                    throw 'No default template path is configured. Choose a file from the browser.'
                }
                $fileName = [IO.Path]::GetFileName($script:DefaultSourceFile)
                $content = Read-AmazonTemplateFile -Path $script:DefaultSourceFile
            }
            else {
                $fileName = [string]$body.fileName
                if ([string]::IsNullOrWhiteSpace($fileName)) {
                    throw 'fileName is required.'
                }
                $extension = [IO.Path]::GetExtension($fileName).ToLowerInvariant()
                if ($extension -in @('.xlsx', '.xlsm')) {
                    $contentBase64Property = $body.PSObject.Properties['contentBase64']
                    $contentBase64 = if ($null -eq $contentBase64Property) { '' } else { [string]$contentBase64Property.Value }
                    if ([string]::IsNullOrWhiteSpace($contentBase64)) {
                        throw 'contentBase64 is required for XLSX and XLSM files.'
                    }
                    try {
                        $spreadsheetBytes = [Convert]::FromBase64String($contentBase64)
                    }
                    catch {
                        throw 'The spreadsheet upload is not valid Base64 data.'
                    }
                    $content = ConvertFrom-AmazonSpreadsheetTemplate -Bytes $spreadsheetBytes -FileName $fileName
                }
                elseif ($extension -in @('.txt', '.tsv')) {
                    $content = [string]$body.content
                    if ([string]::IsNullOrWhiteSpace($content)) {
                        throw 'content is required for TXT and TSV files.'
                    }
                }
                else {
                    throw 'Supported template formats are TXT, TSV, XLSX, and XLSM.'
                }
            }

            $analysis = Analyze-TemplateText -Text $content -FileName $fileName
            $analysisId = Register-TemplateAnalysis -Analysis $analysis

            Write-JsonResponse -Context $Context -Value ([ordered]@{
                analysisId = $analysisId
                fileName = $analysis.fileName
                templateSellerId = $analysis.templateSellerId
                templateMarketplaceId = $analysis.templateMarketplaceId
                summary = $analysis.summary
                distribution = $analysis.distribution
                preview = $analysis.preview
                nonEmptyColumns = $analysis.nonEmptyColumns
            })
        }
        catch {
            $errorCode = [string]$_.Exception.Data['KlanataErrorCode']
            $accountNotAllowed = $errorCode -eq 'ACCOUNT_NOT_ALLOWED'
            Write-ApiError `
                -Context $Context `
                -StatusCode $(if ($accountNotAllowed) { 403 } else { 400 }) `
                -Message $_.Exception.Message `
                -Code $(if ($accountNotAllowed) { 'ACCOUNT_NOT_ALLOWED' } else { 'ANALYSIS_FAILED' })
        }
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/pricing/simulate') {
        if (-not (Test-IsLocalAdminRequest -Request $request)) {
            Write-ApiError -Context $Context -StatusCode 403 -Code 'ADMIN_LOCAL_ONLY' -Message 'Legacy file pricing is restricted to local administrator emergency simulation.'
            return
        }
        try {
            $body = Read-JsonBody -Request $request
            $fileName = [string]$body.fileName
            $authSessionId = [string](Get-PricingPropertyValue -Object $body -Name 'authSessionId' -DefaultValue '')
            $marketplaceId = [string]$body.marketplaceId
            $ruleProperty = $body.PSObject.Properties['rule']
            if ([string]::IsNullOrWhiteSpace($fileName)) { throw 'fileName is required.' }
            if ([string]::IsNullOrWhiteSpace($authSessionId) -or [string]::IsNullOrWhiteSpace($marketplaceId)) {
                throw 'An authorized Seller and Marketplace are required for pricing simulation.'
            }
            if ($null -eq $ruleProperty -or $null -eq $ruleProperty.Value) { throw 'A pricing rule is required.' }

            $session = Test-AuthSession -AuthSessionId $authSessionId
            $sellerId = [string](Get-PricingPropertyValue -Object $session -Name 'sellerId' -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($sellerId)) {
                throw 'The selected authorization has no Seller ID. Add or reconnect it in Settings before pricing.'
            }
            Assert-AllowedAmazonProductionContext `
                -Session $session `
                -SellerId $sellerId `
                -MarketplaceId $marketplaceId
            $marketplaceMatches = @($session.marketplaces | Where-Object {
                $_.id -eq $marketplaceId -and (Test-IsSelectableMarketplace -Marketplace $_)
            })
            if ($marketplaceMatches.Count -eq 0) {
                throw 'The selected Marketplace is unavailable or not part of the verified authorization.'
            }
            $marketplace = $marketplaceMatches[0]

            $extension = [IO.Path]::GetExtension($fileName).ToLowerInvariant()
            if ($extension -in @('.xlsx', '.xlsm')) {
                $contentBase64 = [string](Get-PricingPropertyValue -Object $body -Name 'contentBase64' -DefaultValue '')
                if ([string]::IsNullOrWhiteSpace($contentBase64)) { throw 'contentBase64 is required for XLSX and XLSM files.' }
                try { $spreadsheetBytes = [Convert]::FromBase64String($contentBase64) }
                catch { throw 'The spreadsheet upload is not valid Base64 data.' }
                $content = ConvertFrom-SpreadsheetToTsv `
                    -Bytes $spreadsheetBytes `
                    -FileName $fileName `
                    -PreferredSheetName 'Template' `
                    -AllowFirstWorksheet
            }
            elseif ($extension -in @('.csv', '.txt', '.tsv')) {
                $content = [string](Get-PricingPropertyValue -Object $body -Name 'content' -DefaultValue '')
                if ([string]::IsNullOrWhiteSpace($content)) { throw 'content is required for CSV, TXT, and TSV files.' }
            }
            else {
                throw 'Supported pricing snapshot formats are CSV, TXT, TSV, XLSX, and XLSM.'
            }

            $scope = [pscustomobject]@{
                authSessionId = $authSessionId
                sellerId = $sellerId
                marketplaceId = $marketplaceId
                region = [string]$session.region
                storeName = [string]$marketplace.storeName
                countryCode = [string]$marketplace.countryCode
                currency = Get-PricingMarketplaceCurrency -CountryCode ([string]$marketplace.countryCode)
            }
            $simulation = Invoke-PricingSimulation `
                -Text $content `
                -FileName $fileName `
                -Rule $ruleProperty.Value `
                -Scope $scope `
                -ProductionEnabled ([bool]$EnableUnsafeLegacyPricingMigration)
            $simulationId = [guid]::NewGuid().ToString('N')
            $simulation | Add-Member -NotePropertyName simulationId -NotePropertyValue $simulationId
            $script:PricingSimulations[$simulationId] = $simulation
            Write-JsonResponse -Context $Context -Value (ConvertTo-PublicPricingSimulation -Simulation $simulation)
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'PRICING_SIMULATION_FAILED'
        }
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/pricing/batches') {
        $writeBlock = Get-LegacyPricingWriteBlock -IsLocalAdmin (Test-IsLocalAdminRequest -Request $request)
        if ($null -ne $writeBlock) {
            Write-ApiError -Context $Context -StatusCode $writeBlock.statusCode -Code $writeBlock.code -Message $writeBlock.message
            return
        }

        try {
            $body = Read-JsonBody -Request $request
            $simulationId = [string]$body.simulationId
            $requestedAuthSessionId = [string]$body.authSessionId
            if (-not $script:PricingSimulations.ContainsKey($simulationId)) {
                throw 'The pricing simulation was not found. Run the simulation again.'
            }
            if ([string]::IsNullOrWhiteSpace($requestedAuthSessionId)) {
                throw 'An authorized Seller is required to create a pricing batch.'
            }

            $simulation = $script:PricingSimulations[$simulationId]
            if ([bool]$simulation.gate.locked -or [int]$simulation.summary.eligible -le 0) {
                throw "The simulation is not eligible for production approval. $($simulation.gate.message)"
            }

            $authSessionId = $requestedAuthSessionId.Trim()
            $session = Test-AuthSession -AuthSessionId $authSessionId
            $sellerId = [string](Get-PricingPropertyValue -Object $session -Name 'sellerId' -DefaultValue '')
            $marketplaceId = [string]$simulation.scope.marketplaceId
            if ([string]::IsNullOrWhiteSpace($sellerId)) {
                throw 'The selected authorization has no Seller ID. Add or reconnect it in Settings before pricing.'
            }
            Assert-AllowedAmazonProductionContext `
                -Session $session `
                -SellerId $sellerId `
                -MarketplaceId $marketplaceId
            if ($sellerId -ne [string]$simulation.scope.sellerId) {
                throw 'The selected authorization Seller ID does not match the pricing simulation.'
            }
            $marketplaceMatches = @($session.marketplaces | Where-Object {
                $_.id -eq $marketplaceId -and (Test-IsSelectableMarketplace -Marketplace $_)
            })
            if ($marketplaceMatches.Count -eq 0) {
                throw 'The selected authorization does not include the pricing simulation Marketplace.'
            }

            $fingerprint = Get-PricingBatchFingerprint `
                -Simulation $simulation `
                -SellerId $sellerId
            $existing = @($script:PricingBatches.Values | Where-Object {
                $_.fingerprint -eq $fingerprint -and $_.status -notin @('FAILED', 'CANCELLED')
            } | Select-Object -First 1)

            $previewResults = [Collections.Generic.List[object]]::new()
            foreach ($item in @($simulation.eligibleItems | Select-Object -First 3)) {
                [void]$previewResults.Add((Invoke-PricingValidationPreview `
                    -Session $session `
                    -SellerId $sellerId `
                    -MarketplaceId $marketplaceId `
                    -Currency ([string]$simulation.scope.currency) `
                    -Item $item))
            }

            $now = [DateTime]::UtcNow.ToString('o')
            $accountValidationId = [guid]::NewGuid().ToString('N')
            $script:AccountValidations[$accountValidationId] = [pscustomobject]@{
                id = $accountValidationId
                kind = 'PRICING'
                authSessionId = $authSessionId
                authSessionIds = @($authSessionId)
                analysisId = ''
                sellerId = $sellerId
                marketplaceId = $marketplaceId
                createdAt = [DateTime]::UtcNow
                submissionJobId = $null
                status = if ($previewResults.Count -gt 0) { [string]$previewResults[0].status } else { 'VALID' }
                sku = if ($previewResults.Count -gt 0) { [string]$previewResults[0].sku } else { '' }
                issues = @()
                rejectedAuthorizationProfileCount = 0
            }
            Add-SessionValidatedContext `
                -Session $session `
                -SellerId $sellerId `
                -MarketplaceId $marketplaceId

            if ($existing.Count -gt 0) {
                $existing[0].accountValidationId = $accountValidationId
                $existing[0].updatedAt = $now
                Save-PricingBatchStore
                Write-JsonResponse -Context $Context -Value (ConvertTo-PublicPricingBatch -Batch $existing[0])
                return
            }

            $batchId = [guid]::NewGuid().ToString('N')
            $rows = [int]$simulation.summary.eligible
            $batch = [pscustomobject]@{
                id = $batchId
                simulationId = $simulationId
                fingerprint = $fingerprint
                status = 'APPROVAL_PENDING'
                createdAt = $now
                updatedAt = $now
                approvedAt = ''
                submittedAt = ''
                accountValidationId = $accountValidationId
                sellerId = $sellerId
                marketplaceId = $marketplaceId
                countryCode = [string]$simulation.scope.countryCode
                currency = [string]$simulation.scope.currency
                region = [string]$simulation.scope.region
                storeName = [string]$simulation.scope.storeName
                fileName = [string]$simulation.fileName
                rows = $rows
                direction = [string]$simulation.rule.direction
                risk = [string]$simulation.summary.overallRisk
                rule = $simulation.rule
                items = @($simulation.eligibleItems)
                approvalConfirmation = Get-PricingApprovalPhrase `
                    -SellerId $sellerId `
                    -CountryCode ([string]$simulation.scope.countryCode) `
                    -Rows $rows `
                    -Direction ([string]$simulation.rule.direction) `
                    -Risk ([string]$simulation.summary.overallRisk)
                submissionConfirmation = Get-PricingSubmissionPhrase `
                    -SellerId $sellerId `
                    -CountryCode ([string]$simulation.scope.countryCode) `
                    -Rows $rows `
                    -Direction ([string]$simulation.rule.direction)
                validationPreview = [pscustomobject]@{
                    checked = $previewResults.Count
                    accepted = @($previewResults | Where-Object { $_.status -in @('ACCEPTED', 'VALID') }).Count
                    items = $previewResults.ToArray()
                }
                submissionJobId = ''
                reportSummary = $null
                error = ''
            }
            $script:PricingBatches[$batchId] = $batch
            Save-PricingBatchStore
            Write-JsonResponse -Context $Context -StatusCode 201 -Value (ConvertTo-PublicPricingBatch -Batch $batch)
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'PRICING_BATCH_FAILED'
        }
        return
    }

    if ($method -eq 'POST' -and $path -match '^/api/pricing/batches/([a-f0-9]{32})/approve$') {
        $writeBlock = Get-LegacyPricingWriteBlock -IsLocalAdmin (Test-IsLocalAdminRequest -Request $request)
        if ($null -ne $writeBlock) {
            Write-ApiError -Context $Context -StatusCode $writeBlock.statusCode -Code $writeBlock.code -Message $writeBlock.message
            return
        }
        try {
            $batchId = $Matches[1]
            if (-not $script:PricingBatches.ContainsKey($batchId)) { throw 'The pricing batch was not found.' }
            $batch = $script:PricingBatches[$batchId]
            Assert-AllowedAmazonSellerId -SellerId ([string]$batch.sellerId)
            $accountValidationId = [string](Get-PricingPropertyValue `
                -Object $batch `
                -Name 'accountValidationId' `
                -DefaultValue '')
            if (-not $script:AccountValidations.ContainsKey($accountValidationId)) {
                throw 'The pricing batch no longer has a valid Seller account validation.'
            }
            $validation = $script:AccountValidations[$accountValidationId]
            $session = Test-AuthSession -AuthSessionId ([string]$validation.authSessionId)
            Assert-AllowedAmazonProductionContext `
                -Session $session `
                -SellerId ([string]$batch.sellerId) `
                -MarketplaceId ([string]$batch.marketplaceId) `
                -RequireValidatedContext
            if ($batch.status -eq 'APPROVED') {
                Write-JsonResponse -Context $Context -Value (ConvertTo-PublicPricingBatch -Batch $batch)
                return
            }
            if ($batch.status -ne 'APPROVAL_PENDING') { throw "Pricing batch status $($batch.status) cannot be approved." }
            $body = Read-JsonBody -Request $request
            $confirmation = ([string]$body.confirmation).Trim()
            if ($confirmation -cne [string]$batch.approvalConfirmation) {
                throw "Approval confirmation is invalid. Enter $($batch.approvalConfirmation)."
            }
            $now = [DateTime]::UtcNow.ToString('o')
            $batch.status = 'APPROVED'
            $batch.approvedAt = $now
            $batch.updatedAt = $now
            $batch.error = ''
            Save-PricingBatchStore
            Write-JsonResponse -Context $Context -Value (ConvertTo-PublicPricingBatch -Batch $batch)
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'PRICING_APPROVAL_FAILED'
        }
        return
    }

    if ($method -eq 'POST' -and $path -match '^/api/pricing/batches/([a-f0-9]{32})/submit$') {
        $writeBlock = Get-LegacyPricingWriteBlock -IsLocalAdmin (Test-IsLocalAdminRequest -Request $request)
        if ($null -ne $writeBlock) {
            Write-ApiError -Context $Context -StatusCode $writeBlock.statusCode -Code $writeBlock.code -Message $writeBlock.message
            return
        }

        $batch = $null
        $job = $null
        $feedInputPath = $null
        try {
            $batchId = $Matches[1]
            if (-not $script:PricingBatches.ContainsKey($batchId)) { throw 'The pricing batch was not found.' }
            $batch = $script:PricingBatches[$batchId]
            Assert-AllowedAmazonSellerId -SellerId ([string]$batch.sellerId)
            if ($batch.status -notin @('APPROVED', 'SUBMITTED', 'PROCESSING', 'COMPLETED', 'COMPLETED_WITH_WARNINGS', 'PARTIALLY_FAILED')) {
                throw "Pricing batch status $($batch.status) cannot be submitted."
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$batch.submissionJobId)) {
                if (-not $script:Jobs.ContainsKey([string]$batch.submissionJobId)) {
                    throw 'The pricing submission record is missing. Do not create another submission.'
                }
                $existingSubmissionJob = $script:Jobs[[string]$batch.submissionJobId]
                if (-not (Test-IsValidPricingJobBatchLink -Job $existingSubmissionJob -Batch $batch)) {
                    throw 'The pricing submission record does not match this Seller and Marketplace.'
                }
                Write-JsonResponse -Context $Context -Value (ConvertTo-PublicJob -Job $existingSubmissionJob)
                return
            }

            $body = Read-JsonBody -Request $request
            $confirmation = ([string]$body.confirmation).Trim()
            if ($confirmation -cne [string]$batch.submissionConfirmation) {
                throw "Submission confirmation is invalid. Enter $($batch.submissionConfirmation)."
            }
            $accountValidationId = [string]$body.accountValidationId
            if (-not $script:AccountValidations.ContainsKey($accountValidationId)) {
                throw 'The Seller account validation was not found. Validate the account again before submitting.'
            }
            $validation = $script:AccountValidations[$accountValidationId]
            if ([string]$validation.sellerId -ne [string]$batch.sellerId -or
                [string]$validation.marketplaceId -ne [string]$batch.marketplaceId) {
                throw 'The current Seller validation does not match this pricing batch.'
            }
            $authSessionId = Get-ValidatedSubmissionAuthSessionId `
                -Validation $validation `
                -RequestedAuthSessionId ([string]$body.authSessionId)
            $session = Test-AuthSession -AuthSessionId $authSessionId
            Assert-AllowedAmazonProductionContext `
                -Session $session `
                -SellerId ([string]$batch.sellerId) `
                -MarketplaceId ([string]$batch.marketplaceId) `
                -RequireValidatedContext

            $activeBatchJobs = @($script:Jobs.Values | Where-Object {
                [string](Get-PricingPropertyValue -Object $_ -Name 'kind' -DefaultValue 'INVENTORY') -eq 'PRICING' -and
                $_.sellerId -eq $batch.sellerId -and $_.marketplaceId -eq $batch.marketplaceId -and
                $_.status -in @('PREPARING_SUBMISSION', 'SUBMITTING', 'SUBMISSION_UNKNOWN', 'IN_QUEUE', 'IN_PROGRESS')
            })
            if ($activeBatchJobs.Count -gt 0) {
                throw 'Another pricing batch for this Seller and Marketplace is still active.'
            }

            $feedJson = New-PricingFeedJson -Batch $batch -SellerId ([string]$batch.sellerId)
            $jobId = [guid]::NewGuid().ToString('N')
            $feedInputPath = Join-Path $script:RuntimeRoot "pricing-feed-input-$jobId.json"
            Write-Utf8WithoutBom -Path $feedInputPath -Content $feedJson

            $now = [DateTime]::UtcNow.ToString('o')
            $job = [pscustomobject]@{
                id = $jobId
                kind = 'PRICING'
                pricingBatchId = $batch.id
                feedId = ''
                status = 'PREPARING_SUBMISSION'
                createdAt = $now
                updatedAt = $now
                sellerId = [string]$batch.sellerId
                marketplaceId = [string]$batch.marketplaceId
                region = [string]$batch.region
                fileName = [string]$batch.fileName
                rows = [int]$batch.rows
                zeroQuantity = 0
                positiveQuantity = 0
                direction = [string]$batch.direction
                currency = [string]$batch.currency
                reportFileName = $null
                reportSummary = $null
                error = $null
                authSessionId = $authSessionId
                resultDocumentId = $null
            }
            $batch.status = 'SUBMISSION_PREPARING'
            $batch.submissionJobId = $jobId
            $batch.accountValidationId = $accountValidationId
            $batch.updatedAt = $now
            $script:Jobs[$jobId] = $job
            Save-JobStore
            Save-PricingBatchStore

            $document = Invoke-SpApiJson `
                -Method POST `
                -Uri "$($session.endpoint)/feeds/2021-06-30/documents" `
                -AccessToken $session.accessToken `
                -Body @{ contentType = 'application/json; charset=UTF-8' }
            Send-FeedDocument -Uri $document.url -Path $feedInputPath

            $job.status = 'SUBMITTING'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            $batch.status = 'SUBMITTING'
            $batch.updatedAt = $job.updatedAt
            Save-JobStore
            Save-PricingBatchStore

            $feedSubmission = Invoke-SpApiJson `
                -Method POST `
                -Uri "$($session.endpoint)/feeds/2021-06-30/feeds" `
                -AccessToken $session.accessToken `
                -AllowRetry $false `
                -Body ([ordered]@{
                    feedType = 'JSON_LISTINGS_FEED'
                    marketplaceIds = @([string]$batch.marketplaceId)
                    inputFeedDocumentId = $document.feedDocumentId
                })

            $submittedAt = [DateTime]::UtcNow.ToString('o')
            $job.feedId = [string]$feedSubmission.feedId
            $job.status = 'IN_QUEUE'
            $job.updatedAt = $submittedAt
            $batch.status = 'SUBMITTED'
            $batch.submittedAt = $submittedAt
            $batch.updatedAt = $submittedAt
            Save-JobStore
            Save-PricingBatchStore
            Write-JsonResponse -Context $Context -StatusCode 201 -Value (ConvertTo-PublicJob -Job $job)
        }
        catch {
            $submissionError = $_.Exception.Message
            if ($null -ne $job -and $job.status -in @('PREPARING_SUBMISSION', 'SUBMITTING')) {
                $job.status = if ($job.status -eq 'SUBMITTING') { 'SUBMISSION_UNKNOWN' } else { 'SUBMISSION_FAILED' }
                $job.error = $submissionError
                $job.updatedAt = [DateTime]::UtcNow.ToString('o')
                $batch.status = $job.status
                $batch.error = $submissionError
                $batch.updatedAt = $job.updatedAt
                try { Save-JobStore; Save-PricingBatchStore } catch { }
            }
            Write-ApiError -Context $Context -Message $submissionError -Code 'PRICING_SUBMIT_FAILED'
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace([string]$feedInputPath) -and
                (Test-Path -LiteralPath $feedInputPath -PathType Leaf)) {
                Remove-Item -LiteralPath $feedInputPath -Force -ErrorAction SilentlyContinue
            }
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/pricing/batches') {
        $batches = @($script:PricingBatches.Values | Where-Object {
            Test-IsAllowedAmazonSellerId -SellerId ([string]$_.sellerId)
        } | Sort-Object createdAt -Descending | ForEach-Object {
            ConvertTo-PublicPricingBatch -Batch $_
        })
        Write-JsonResponse -Context $Context -Value @{ batches = $batches }
        return
    }

    if ($method -eq 'GET' -and $path -match '^/api/pricing/batches/([a-f0-9]{32})$') {
        $batchId = $Matches[1]
        if (-not $script:PricingBatches.ContainsKey($batchId) -or
            -not (Test-IsAllowedAmazonSellerId -SellerId ([string]$script:PricingBatches[$batchId].sellerId))) {
            Write-ApiError -Context $Context -StatusCode 404 -Message 'Pricing batch was not found.' -Code 'NOT_FOUND'
            return
        }
        Write-JsonResponse -Context $Context -Value (ConvertTo-PublicPricingBatch -Batch $script:PricingBatches[$batchId])
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/auth/verify') {
        if (-not (Test-IsLocalAdminRequest -Request $request)) {
            Write-ApiError -Context $Context -StatusCode 403 -Message 'Legacy authorization migration is restricted to the server administrator.' -Code 'ADMIN_LOCAL_ONLY'
            return
        }
        $previousDeveloperApplication = $script:DeveloperApplication
        $previousAuthSessions = $script:AuthSessions.Clone()
        $previousAuthorizationProfiles = $script:AuthorizationProfiles.Clone()
        $previousCurrentAuthSessionIds = @($script:CurrentAuthSessionIds.ToArray())
        $previousCurrentAuthSessionId = $script:CurrentAuthSessionId
        $mutationStarted = $false
        $storageFailure = $false
        $session = $null
        try {
            $body = Read-JsonBody -Request $request
            $clientId = [string](Get-PricingPropertyValue -Object $body -Name 'clientId' -DefaultValue '')
            $clientSecret = [string](Get-PricingPropertyValue -Object $body -Name 'clientSecret' -DefaultValue '')
            $refreshToken = ([string]$body.refreshToken).Replace('\_', '_')
            $region = [string](Get-PricingPropertyValue -Object $body -Name 'region' -DefaultValue 'auto')
            $sellerIdProperty = $body.PSObject.Properties['sellerId']
            $sellerId = Normalize-AmazonSellerId `
                -SellerId $(if ($null -eq $sellerIdProperty) { '' } else { [string]$sellerIdProperty.Value }) `
                -AllowEmpty:($null -eq $sellerIdProperty)
            Assert-AllowedAmazonSellerId -SellerId $sellerId -AllowEmpty

            if ([string]::IsNullOrWhiteSpace($refreshToken)) {
                throw 'Refresh token is required.'
            }
            if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
                if ($null -eq $script:DeveloperApplication -or
                    [string]::IsNullOrWhiteSpace([string]$script:DeveloperApplication.clientId) -or
                    [string]::IsNullOrWhiteSpace([string]$script:DeveloperApplication.clientSecret)) {
                    throw 'Amazon developer application is not configured. Ask an administrator to configure Client ID and Client Secret once.'
                }
                $clientId = [string]$script:DeveloperApplication.clientId
                $clientSecret = [string]$script:DeveloperApplication.clientSecret
            }

            try {
                $storeKey = Get-AuthorizationStoreKey
                if ($null -eq $storeKey) {
                    throw 'Secure credential persistence is unavailable.'
                }
                [Array]::Clear($storeKey, 0, $storeKey.Length)
            }
            catch {
                $storageFailure = $true
                throw
            }

            $token = Get-LwaToken -ClientId $clientId -ClientSecret $clientSecret -RefreshToken $refreshToken
            $marketplaceDiscovery = Find-SpApiMarketplaceParticipations `
                -AccessToken $token.access_token `
                -PreferredRegion $region
            [void](Assert-AllowedAmazonMarketplaceDiscovery -MarketplaceDiscovery $marketplaceDiscovery)

            if ([string]::IsNullOrWhiteSpace($sellerId)) {
                foreach ($existingProfile in @($script:AuthorizationProfiles.Values)) {
                    if ([string]$existingProfile.refreshToken -eq $refreshToken -and
                        -not [string]::IsNullOrWhiteSpace([string]$existingProfile.sellerId)) {
                        $sellerId = [string]$existingProfile.sellerId
                        break
                    }
                }
                foreach ($existingSessionId in @($script:CurrentAuthSessionIds.ToArray())) {
                    if (-not $script:AuthSessions.ContainsKey($existingSessionId)) { continue }
                    $existingSession = $script:AuthSessions[$existingSessionId]
                    if ($existingSession.clientId -eq $clientId -and
                        $existingSession.refreshToken -eq $refreshToken) {
                        $existingSellerId = [string](Get-PricingPropertyValue `
                            -Object $existingSession `
                            -Name 'sellerId' `
                            -DefaultValue '')
                        if (-not [string]::IsNullOrWhiteSpace($existingSellerId)) {
                            $sellerId = $existingSellerId
                            break
                        }
                    }
                }
            }
            Assert-AllowedAmazonSellerId -SellerId $sellerId -AllowEmpty

            $mutationStarted = $true
            Set-DeveloperApplication -ClientId $clientId -ClientSecret $clientSecret

            $session = Register-AuthorizationSession `
                -Token $token `
                -ClientId $clientId `
                -ClientSecret $clientSecret `
                -RefreshToken $refreshToken `
                -SellerId $sellerId `
                -MarketplaceDiscovery $marketplaceDiscovery `
                -RequestedRegion $region
            try {
                if (-not (Save-AuthorizationStore)) {
                    throw 'Secure credential persistence is unavailable.'
                }
            }
            catch {
                $storageFailure = $true
                throw
            }
        }
        catch {
            if ($mutationStarted) {
                $script:DeveloperApplication = $previousDeveloperApplication
                $script:AuthSessions = $previousAuthSessions
                $script:AuthorizationProfiles = $previousAuthorizationProfiles
                $script:CurrentAuthSessionIds = [Collections.Generic.List[string]]::new()
                foreach ($previousSessionId in $previousCurrentAuthSessionIds) {
                    [void]$script:CurrentAuthSessionIds.Add($previousSessionId)
                }
                $script:CurrentAuthSessionId = $previousCurrentAuthSessionId
            }
            $storeNotAllowed = Test-IsAmazonStoreNotAllowedError -ErrorRecord $_
            $errorCode = if ($storeNotAllowed) {
                'STORE_NOT_ALLOWED'
            }
            elseif ($storageFailure) {
                'AUTH_STORAGE_FAILED'
            }
            else {
                'AUTH_FAILED'
            }
            $statusCode = if ($storeNotAllowed) { 403 } else { 400 }
            Write-ApiError -Context $Context -StatusCode $statusCode -Message $_.Exception.Message -Code $errorCode
            return
        }
        Write-JsonResponse -Context $Context -Value (ConvertTo-PublicAuthSession -Session $session)
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/account/validate') {
        try {
            $body = Read-JsonBody -Request $request
            $authSessionId = [string](Get-PricingPropertyValue -Object $body -Name 'authSessionId' -DefaultValue '')
            $analysisId = [string]$body.analysisId
            $sellerId = [string]$body.sellerId
            $marketplaceId = [string]$body.marketplaceId

            if (-not $script:Analyses.ContainsKey($analysisId)) {
                throw 'Analysis session was not found. Analyze the file again.'
            }
            if ([string]::IsNullOrWhiteSpace($sellerId) -or [string]::IsNullOrWhiteSpace($marketplaceId)) {
                throw 'Seller ID and marketplace are required.'
            }
            $sellerId = Normalize-AmazonSellerId -SellerId $sellerId
            Assert-AllowedAmazonSellerId -SellerId $sellerId

            $analysis = $script:Analyses[$analysisId]
            if (-not [string]::IsNullOrWhiteSpace([string]$analysis.templateSellerId) -and
                [string]$analysis.templateSellerId -ne $sellerId) {
                throw "Template Seller ID $($analysis.templateSellerId) does not match selected Seller ID $sellerId."
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$analysis.templateMarketplaceId) -and
                [string]$analysis.templateMarketplaceId -ne $marketplaceId) {
                throw "Template marketplace $($analysis.templateMarketplaceId) does not match selected marketplace $marketplaceId."
            }
            $candidateSessionIds = [Collections.Generic.List[string]]::new()
            $seenSessionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if (-not [string]::IsNullOrWhiteSpace($authSessionId) -and $seenSessionIds.Add($authSessionId)) {
                [void]$candidateSessionIds.Add($authSessionId)
            }
            if ($null -ne $body.PSObject.Properties['authSessionIds']) {
                foreach ($candidateSessionId in @($body.authSessionIds)) {
                    $normalizedSessionId = ([string]$candidateSessionId).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($normalizedSessionId) -and
                        $seenSessionIds.Add($normalizedSessionId)) {
                        [void]$candidateSessionIds.Add($normalizedSessionId)
                    }
                }
            }
            if ($candidateSessionIds.Count -eq 0) {
                throw 'At least one authorization session is required.'
            }

            $validatedSessionIds = [Collections.Generic.List[string]]::new()
            $validationFailures = [Collections.Generic.List[string]]::new()
            $primaryValidation = $null
            $candidateIndex = 0
            foreach ($candidateSessionId in $candidateSessionIds) {
                $candidateIndex++
                try {
                    $candidateSession = Test-AuthSession -AuthSessionId $candidateSessionId
                    $candidateSellerId = [string](Get-PricingPropertyValue `
                        -Object $candidateSession `
                        -Name 'sellerId' `
                        -DefaultValue '')
                    if (-not [string]::IsNullOrWhiteSpace($candidateSellerId) -and
                        (Normalize-AmazonSellerId -SellerId $candidateSellerId) -cne $sellerId) {
                        throw 'The authorization session is bound to a different Seller account.'
                    }
                    $candidateValidation = Invoke-AccountValidationPreview `
                        -Session $candidateSession `
                        -Analysis $analysis `
                        -SellerId $sellerId `
                        -MarketplaceId $marketplaceId
                    [void]$validatedSessionIds.Add($candidateSessionId)
                    if ($null -eq $primaryValidation) {
                        $primaryValidation = $candidateValidation
                    }
                }
                catch {
                    $safeFailure = ConvertTo-SafeAmazonMessage -Detail $_.Exception.Message
                    [void]$validationFailures.Add("Authorization $candidateIndex`: $safeFailure")
                }
            }
            if ($validatedSessionIds.Count -eq 0) {
                throw "No authorization matched this Seller and Marketplace. $($validationFailures -join ' | ')"
            }

            [void](Set-ValidatedAuthorizationSellerBindings `
                -AuthSessionIds $validatedSessionIds.ToArray() `
                -SellerId $sellerId)
            foreach ($validatedSessionId in $validatedSessionIds) {
                Add-SessionValidatedContext `
                    -Session $script:AuthSessions[$validatedSessionId] `
                    -SellerId $sellerId `
                    -MarketplaceId $marketplaceId
            }

            $selectedAuthSessionId = if ($validatedSessionIds.Contains($authSessionId)) {
                $authSessionId
            }
            else {
                $validatedSessionIds[0]
            }

            $validationId = [guid]::NewGuid().ToString('N')
            $script:AccountValidations[$validationId] = [pscustomobject]@{
                id = $validationId
                authSessionId = $selectedAuthSessionId
                authSessionIds = $validatedSessionIds.ToArray()
                analysisId = $analysisId
                sellerId = $sellerId
                marketplaceId = $marketplaceId
                createdAt = [DateTime]::UtcNow
                submissionJobId = $null
                status = [string]$primaryValidation.status
                sku = [string]$primaryValidation.sku
                issues = @($primaryValidation.issues)
                rejectedAuthorizationProfileCount = $validationFailures.Count
            }
            $script:CurrentAccountValidationId = $validationId

            Write-JsonResponse -Context $Context -Value ([ordered]@{
                accountValidationId = $validationId
                authSessionId = $selectedAuthSessionId
                authSessionIds = $validatedSessionIds.ToArray()
                authorizationProfileCount = $validatedSessionIds.Count
                rejectedAuthorizationProfileCount = $validationFailures.Count
                status = [string]$primaryValidation.status
                sku = [string]$primaryValidation.sku
                issues = @($primaryValidation.issues)
                sellerId = $sellerId
                marketplaceId = $marketplaceId
            })
        }
        catch {
            $accountNotAllowed = Test-IsAmazonStoreNotAllowedError -ErrorRecord $_
            Write-ApiError `
                -Context $Context `
                -StatusCode $(if ($accountNotAllowed) { 403 } else { 400 }) `
                -Message $_.Exception.Message `
                -Code $(if ($accountNotAllowed) { 'ACCOUNT_NOT_ALLOWED' } else { 'ACCOUNT_MISMATCH' })
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/workflow/current') {
        $analysisValue = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$script:CurrentAnalysisId) -and
            $script:Analyses.ContainsKey($script:CurrentAnalysisId)) {
            $analysis = $script:Analyses[$script:CurrentAnalysisId]
            $templateSellerId = [string](Get-PricingPropertyValue `
                -Object $analysis `
                -Name 'templateSellerId' `
                -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($templateSellerId) -or
                (Test-IsAllowedAmazonSellerId -SellerId $templateSellerId)) {
                $analysisValue = [ordered]@{
                    analysisId = $script:CurrentAnalysisId
                    fileName = $analysis.fileName
                    templateSellerId = $templateSellerId
                    templateMarketplaceId = $analysis.templateMarketplaceId
                    summary = $analysis.summary
                    distribution = $analysis.distribution
                    preview = $analysis.preview
                    nonEmptyColumns = $analysis.nonEmptyColumns
                }
            }
        }

        $authValues = [Collections.Generic.List[object]]::new()
        foreach ($authSessionId in @($script:CurrentAuthSessionIds.ToArray())) {
            try {
                $session = Test-AuthSession -AuthSessionId $authSessionId
                [void]$authValues.Add((ConvertTo-PublicAuthSession -Session $session))
            }
            catch {
                [void]$script:CurrentAuthSessionIds.Remove($authSessionId)
                if ($script:CurrentAuthSessionId -eq $authSessionId) {
                    $script:CurrentAuthSessionId = $null
                }
            }
        }

        $authValue = $null
        if ($authValues.Count -gt 0) {
            $authValue = @($authValues | Where-Object {
                $_.authSessionId -eq $script:CurrentAuthSessionId
            } | Select-Object -First 1)
            $authValue = if ($authValue.Count -gt 0) { $authValue[0] } else { $authValues[$authValues.Count - 1] }
        }

        $accountValue = $null
        if ($authValues.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$script:CurrentAccountValidationId) -and
            $script:AccountValidations.ContainsKey($script:CurrentAccountValidationId)) {
            $validation = $script:AccountValidations[$script:CurrentAccountValidationId]
            $validationSessionIds = if ($null -ne $validation.PSObject.Properties['authSessionIds']) {
                @($validation.authSessionIds)
            }
            else {
                @($validation.authSessionId)
            }
            $availableValidationSessionIds = @($authValues | Where-Object {
                $_.authSessionId -in $validationSessionIds
            } | ForEach-Object { [string]$_.authSessionId })
            if ($availableValidationSessionIds.Count -gt 0 -and
                (Test-IsAllowedAmazonSellerId -SellerId ([string]$validation.sellerId))) {
                if ($validation.authSessionId -notin $availableValidationSessionIds) {
                    $validation.authSessionId = $availableValidationSessionIds[0]
                }
                $accountValue = [ordered]@{
                    accountValidationId = $validation.id
                    authSessionId = $validation.authSessionId
                    authSessionIds = $availableValidationSessionIds
                    authorizationProfileCount = $availableValidationSessionIds.Count
                    rejectedAuthorizationProfileCount = if ($null -ne $validation.PSObject.Properties['rejectedAuthorizationProfileCount']) {
                        [int]$validation.rejectedAuthorizationProfileCount
                    }
                    else {
                        0
                    }
                    status = $validation.status
                    sku = $validation.sku
                    issues = $validation.issues
                    sellerId = $validation.sellerId
                    marketplaceId = $validation.marketplaceId
                }
            }
        }

        Write-JsonResponse -Context $Context -Value ([ordered]@{
            analysis = $analysisValue
            auth = $authValue
            authSessions = $authValues.ToArray()
            account = $accountValue
        })
        return
    }

    if ($method -eq 'POST' -and $path -eq '/api/feeds/submit') {
        if ($ReadOnly) {
            Write-ApiError -Context $Context -StatusCode 403 -Code 'READ_ONLY' -Message 'The legacy workstation is running in read-only fallback mode.'
            return
        }

        $job = $null
        $validation = $null
        $feedInputPath = $null
        try {
            $body = Read-JsonBody -Request $request
            $validationId = [string]$body.accountValidationId
            $requestedAuthSessionId = ([string]$body.authSessionId).Trim()
            $confirmation = ([string]$body.confirmation).Trim()

            if (-not $script:AccountValidations.ContainsKey($validationId)) {
                throw 'Account validation was not found. Validate the seller account again.'
            }

            $validation = $script:AccountValidations[$validationId]
            Assert-AllowedAmazonSellerId -SellerId ([string]$validation.sellerId)
            if (-not $script:Analyses.ContainsKey($validation.analysisId)) {
                throw 'Analysis session was not found. Analyze the file again.'
            }
            $analysis = $script:Analyses[$validation.analysisId]
            $expectedConfirmation = Get-SubmissionConfirmationPhrase -Analysis $analysis
            if ($confirmation -cne $expectedConfirmation) {
                throw "Submission confirmation is invalid. Enter $expectedConfirmation."
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$validation.submissionJobId)) {
                $existingJobId = [string]$validation.submissionJobId
                if (-not $script:Jobs.ContainsKey($existingJobId)) {
                    throw 'The previous submission record is missing. Validate the seller account again before retrying.'
                }

                $existingJob = $script:Jobs[$existingJobId]
                if ($existingJob.status -in @('PREPARING_SUBMISSION', 'SUBMITTING', 'SUBMISSION_UNKNOWN')) {
                    throw 'This validation already has a submission with an uncertain result. Check the task record before retrying.'
                }
                if ($existingJob.status -eq 'SUBMISSION_FAILED') {
                    throw 'This validation already has a failed submission. Validate the seller account again before retrying.'
                }

                Write-JsonResponse -Context $Context -Value (ConvertTo-PublicJob -Job $existingJob)
                return
            }

            $requestedAuthSessionId = Get-ValidatedSubmissionAuthSessionId `
                -Validation $validation `
                -RequestedAuthSessionId $requestedAuthSessionId

            $session = Test-AuthSession -AuthSessionId $requestedAuthSessionId
            Assert-AllowedAmazonProductionContext `
                -Session $session `
                -SellerId ([string]$validation.sellerId) `
                -MarketplaceId ([string]$validation.marketplaceId) `
                -RequireValidatedContext
            $feedJson = New-ListingsFeedJson -Analysis $analysis -SellerId $validation.sellerId
            $jobId = [guid]::NewGuid().ToString('N')
            $feedInputPath = Join-Path $script:RuntimeRoot "feed-input-$jobId.json"
            Write-Utf8WithoutBom -Path $feedInputPath -Content $feedJson

            $now = [DateTime]::UtcNow.ToString('o')
            $job = [pscustomobject]@{
                id = $jobId
                kind = 'INVENTORY'
                pricingBatchId = ''
                feedId = ''
                status = 'PREPARING_SUBMISSION'
                createdAt = $now
                updatedAt = $now
                sellerId = [string]$validation.sellerId
                marketplaceId = [string]$validation.marketplaceId
                region = [string]$session.region
                fileName = [string]$analysis.fileName
                rows = [int]$analysis.summary.rows
                zeroQuantity = [int]$analysis.summary.zeroQuantity
                positiveQuantity = [int]$analysis.summary.positiveQuantity
                direction = ''
                currency = ''
                reportFileName = $null
                reportSummary = $null
                error = $null
                authSessionId = $requestedAuthSessionId
                resultDocumentId = $null
            }
            $validation.submissionJobId = $jobId
            $script:Jobs[$jobId] = $job
            Save-JobStore

            $document = Invoke-SpApiJson `
                -Method POST `
                -Uri "$($session.endpoint)/feeds/2021-06-30/documents" `
                -AccessToken $session.accessToken `
                -Body @{ contentType = 'application/json; charset=UTF-8' }

            Send-FeedDocument -Uri $document.url -Path $feedInputPath

            $job.status = 'SUBMITTING'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-JobStore

            $feedSubmission = Invoke-SpApiJson `
                -Method POST `
                -Uri "$($session.endpoint)/feeds/2021-06-30/feeds" `
                -AccessToken $session.accessToken `
                -AllowRetry $false `
                -Body ([ordered]@{
                    feedType = 'JSON_LISTINGS_FEED'
                    marketplaceIds = @($validation.marketplaceId)
                    inputFeedDocumentId = $document.feedDocumentId
                })

            $job.feedId = [string]$feedSubmission.feedId
            $job.status = 'IN_QUEUE'
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-JobStore

            Write-JsonResponse -Context $Context -StatusCode 201 -Value (ConvertTo-PublicJob -Job $job)
        }
        catch {
            $submissionError = $_.Exception.Message
            if ($null -ne $job -and $job.status -in @('PREPARING_SUBMISSION', 'SUBMITTING')) {
                $job.status = if ($job.status -eq 'SUBMITTING') { 'SUBMISSION_UNKNOWN' } else { 'SUBMISSION_FAILED' }
                $job.error = $submissionError
                $job.updatedAt = [DateTime]::UtcNow.ToString('o')
                try {
                    Save-JobStore
                }
                catch {
                    # Preserve the original submission error returned below.
                }
            }
            Write-ApiError -Context $Context -Message $submissionError -Code 'SUBMIT_FAILED'
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace([string]$feedInputPath) -and
                (Test-Path -LiteralPath $feedInputPath -PathType Leaf)) {
                Remove-Item -LiteralPath $feedInputPath -Force -ErrorAction SilentlyContinue
            }
        }
        return
    }

    if ($method -eq 'POST' -and $path -match '^/api/jobs/([a-f0-9]{32})/reconnect$') {
        try {
            $jobId = $Matches[1]
            if (-not $script:Jobs.ContainsKey($jobId) -or
                -not (Test-IsAllowedAmazonSellerId -SellerId ([string]$script:Jobs[$jobId].sellerId))) {
                Write-ApiError -Context $Context -StatusCode 404 -Message 'Job was not found.' -Code 'NOT_FOUND'
                return
            }

            $body = Read-JsonBody -Request $request
            $authSessionId = [string]$body.authSessionId
            $job = $script:Jobs[$jobId]
            if ($job.status -ne 'RECONNECT_REQUIRED') {
                throw 'Only jobs waiting for authorization can be reconnected.'
            }

            $session = Test-AuthSession -AuthSessionId $authSessionId
            if ($session.region -ne $job.region) {
                throw 'The authorization region does not match this job.'
            }
            Assert-AllowedAmazonProductionContext `
                -Session $session `
                -SellerId ([string]$job.sellerId) `
                -MarketplaceId ([string]$job.marketplaceId) `
                -RequireValidatedContext

            $job.authSessionId = $authSessionId
            $job.status = 'IN_QUEUE'
            $job.error = $null
            $job.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-JobStore
            Update-FeedJob -Job $job
            Write-JsonResponse -Context $Context -Value (ConvertTo-PublicJob -Job $job)
        }
        catch {
            Write-ApiError -Context $Context -Message $_.Exception.Message -Code 'RECONNECT_FAILED'
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/jobs') {
        $jobs = @($script:Jobs.Values | Where-Object {
            Test-IsAllowedAmazonSellerId -SellerId ([string]$_.sellerId)
        } | Sort-Object createdAt -Descending | ForEach-Object {
            ConvertTo-PublicJob -Job $_
        })
        Write-JsonResponse -Context $Context -Value @{ jobs = $jobs }
        return
    }

    if ($method -eq 'GET' -and $path -match '^/api/jobs/([a-f0-9]{32})/report$') {
        $jobId = $Matches[1]
        if (-not $script:Jobs.ContainsKey($jobId) -or
            -not (Test-IsAllowedAmazonSellerId -SellerId ([string]$script:Jobs[$jobId].sellerId))) {
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
        if (-not $script:Jobs.ContainsKey($jobId) -or
            -not (Test-IsAllowedAmazonSellerId -SellerId ([string]$script:Jobs[$jobId].sellerId))) {
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

if ($LibraryOnly) {
    return
}

Load-JobStore
Load-PricingBatchStore
Load-AuthorizationStore

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
