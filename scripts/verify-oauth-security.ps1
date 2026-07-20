[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalPublicOrigin = $env:KLANATA_PUBLIC_ORIGIN
$env:KLANATA_PUBLIC_ORIGIN = 'https://workstation.example.test'
Add-Type -AssemblyName System.Net.Http

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

function Assert-SecretAbsent {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($secret in @(
        $script:MockAuthorizationCode,
        $script:MockRefreshToken,
        $script:MockAccessToken,
        $script:MockClientSecret
    )) {
        if (-not [string]::IsNullOrWhiteSpace($secret) -and $Value.Contains($secret)) {
            throw "$Context leaked a mocked authorization code or token."
        }
    }
}

function ConvertFrom-TestQuery {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    $values = @{}
    foreach ($pair in @($Uri.Query.TrimStart('?') -split '&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        $name = [Uri]::UnescapeDataString($parts[0].Replace('+', ' '))
        $value = if ($parts.Count -gt 1) {
            [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
        }
        else { '' }
        $values[$name] = $value
    }
    return $values
}

try {
    . (Join-Path $root 'server.ps1') -LibraryOnly

    $script:MockAuthorizationCode = 'mock-authorization-code-never-expose'
    $script:MockRefreshToken = 'Atzr|mock-refresh-token-never-expose'
    $script:MockAccessToken = 'mock-access-token-never-expose'
    $script:MockClientSecret = 'mock-client-secret-never-expose'
    $script:MockSellerId = 'AC7OMGZBRADKF'
    $script:MockStoreName = 'Carkee'
    $script:OAuthExchangeCalls = [Collections.Generic.List[object]]::new()
    $script:RefreshTokenExchangeCalls = [Collections.Generic.List[object]]::new()
    $script:MarketplaceDiscoveryCalls = [Collections.Generic.List[object]]::new()

    # OAuth routes require durable storage. Tests replace it with an in-memory
    # success result so no credential file is read or written.
    function Get-AuthorizationStoreKey {
        return [byte[]](1..32)
    }

    function Save-AuthorizationStore {
        return $true
    }

    # These are the only functions that can contact Amazon in the callback.
    # Replacing both makes an accidental real request impossible in this test.
    function Get-LwaAuthorizationCodeToken {
        param(
            [string]$ClientId,
            [string]$ClientSecret,
            [string]$AuthorizationCode,
            [string]$RedirectUri
        )

        [void]$script:OAuthExchangeCalls.Add([pscustomobject]@{
            clientId = $ClientId
            clientSecret = $ClientSecret
            authorizationCode = $AuthorizationCode
            redirectUri = $RedirectUri
        })
        return [pscustomobject]@{
            access_token = $script:MockAccessToken
            refresh_token = $script:MockRefreshToken
            expires_in = 3600
            token_type = 'bearer'
        }
    }

    function Get-LwaToken {
        param(
            [string]$ClientId,
            [string]$ClientSecret,
            [string]$RefreshToken
        )

        [void]$script:RefreshTokenExchangeCalls.Add([pscustomobject]@{
            clientId = $ClientId
            clientSecret = $ClientSecret
            refreshToken = $RefreshToken
        })
        return [pscustomobject]@{
            access_token = $script:MockAccessToken
            expires_in = 3600
            token_type = 'bearer'
        }
    }

    function Find-SpApiMarketplaceParticipations {
        param(
            [string]$AccessToken,
            [string]$PreferredRegion
        )

        [void]$script:MarketplaceDiscoveryCalls.Add([pscustomobject]@{
            accessToken = $AccessToken
            preferredRegion = $PreferredRegion
        })
        return [pscustomobject]@{
            region = 'eu'
            endpoint = 'https://sellingpartnerapi-eu.amazon.com'
            regionAutoDetected = $true
            response = [pscustomobject]@{
                payload = @(
                    [pscustomobject]@{
                        marketplace = [pscustomobject]@{
                            id = 'A13V1IB3VIYZZH'
                            name = 'Amazon.fr'
                            countryCode = 'FR'
                            domainName = 'amazon.fr'
                        }
                        storeName = $script:MockStoreName
                        participation = [pscustomobject]@{
                            isParticipating = $true
                            hasSuspendedListings = $false
                        }
                    },
                    [pscustomobject]@{
                        marketplace = [pscustomobject]@{
                            id = 'A1PA6795UKMFR9'
                            name = 'Amazon.de'
                            countryCode = 'DE'
                            domainName = 'amazon.de'
                        }
                        storeName = $script:MockStoreName
                        participation = [pscustomobject]@{
                            isParticipating = $true
                            hasSuspendedListings = $false
                        }
                    }
                )
            }
        }
    }

    $script:OAuthStates.Clear()
    $script:AuthSessions.Clear()
    $script:AuthorizationProfiles.Clear()
    $script:CurrentAuthSessionIds.Clear()
    $script:CurrentAuthSessionId = $null
    Set-DeveloperApplication `
        -ApplicationId 'amzn1.sellerapps.app.mock-operator' `
        -AuthorizationBaseUri 'https://sellercentral.amazon.com/apps/authorize/consent' `
        -ClientId 'amzn1.application-oa2-client.mock' `
        -ClientSecret $script:MockClientSecret

    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()

    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)

    function Invoke-LocalApiRequest {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [ValidateSet('GET', 'POST')][string]$Method = 'GET',
            [hashtable]$Headers = @{},
            [AllowEmptyString()][string]$Body = ''
        )

        $contextTask = $listener.GetContextAsync()
        $requestMessage = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::new($Method),
            "http://127.0.0.1:$port$Path"
        )
        foreach ($headerName in $Headers.Keys) {
            [void]$requestMessage.Headers.TryAddWithoutValidation($headerName, [string]$Headers[$headerName])
        }
        if (-not [string]::IsNullOrWhiteSpace($Body)) {
            $requestMessage.Content = [Net.Http.StringContent]::new(
                $Body,
                [Text.Encoding]::UTF8,
                'application/json'
            )
        }
        $responseTask = $client.SendAsync($requestMessage)
        $context = $contextTask.GetAwaiter().GetResult()
        Handle-ApiRequest -Context $context
        $response = $responseTask.GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $location = if ($null -ne $response.Headers.Location) {
            $response.Headers.Location.OriginalString
        }
        else { '' }
        $cacheControl = @($response.Headers.GetValues('Cache-Control')) -join ','
        $result = [pscustomobject]@{
            statusCode = [int]$response.StatusCode
            body = $body
            location = $location
            cacheControl = $cacheControl
        }
        $requestMessage.Dispose()
        $response.Dispose()
        return $result
    }

    try {
        $localStatus = Invoke-LocalApiRequest -Path '/api/status'
        $localStatusPayload = $localStatus.body | ConvertFrom-Json
        Assert-True ([bool]$localStatusPayload.adminConfigurationWritable) `
            'A direct loopback request was not recognized as an administrator request.'
        Assert-Equal $localStatusPayload.allowedAmazonStoreName 'Carkee' 'Status returned the wrong allowed Amazon store.'
        Assert-Equal (@($localStatusPayload.allowedAmazonSellerIds) -join ',') `
            'AC7OMGZBRADKF' `
            'Status returned the wrong allowed Amazon Seller set.'
        $proxiedStatus = Invoke-LocalApiRequest -Path '/api/status' -Headers @{
            'X-Forwarded-For' = '203.0.113.20'
            'X-Real-IP' = '203.0.113.20'
        }
        Assert-True (-not [bool](($proxiedStatus.body | ConvertFrom-Json).adminConfigurationWritable)) `
            'A proxied public request was incorrectly recognized as an administrator request.'
        foreach ($adminPath in @('/api/auth/application', '/api/auth/verify')) {
            $denied = Invoke-LocalApiRequest -Path $adminPath -Method POST -Headers @{
                'X-Forwarded-For' = '203.0.113.20'
                'X-Real-IP' = '203.0.113.20'
            }
            Assert-Equal $denied.statusCode 403 "Public access to $adminPath was not rejected."
            Assert-Equal (($denied.body | ConvertFrom-Json).error.code) 'ADMIN_LOCAL_ONLY' `
                "Public access to $adminPath returned the wrong error code."
            Assert-SecretAbsent -Value $denied.body -Context "Denied $adminPath response"
        }

        $script:MockStoreName = 'Another Store'
        $manualStoreDenied = Invoke-LocalApiRequest `
            -Path '/api/auth/verify' `
            -Method POST `
            -Body (@{
                refreshToken = $script:MockRefreshToken
                sellerId = $script:MockSellerId
            } | ConvertTo-Json -Compress)
        Assert-Equal $manualStoreDenied.statusCode 403 'Manual migration accepted a non-Carkee store.'
        Assert-Equal (($manualStoreDenied.body | ConvertFrom-Json).error.code) `
            'STORE_NOT_ALLOWED' `
            'Manual migration returned the wrong store-policy code.'
        Assert-Equal $script:AuthSessions.Count 0 'Rejected manual migration created an active session.'
        Assert-Equal $script:AuthorizationProfiles.Count 0 'Rejected manual migration created a persistent profile.'
        Assert-Equal $script:CurrentAuthSessionIds.Count 0 'Rejected manual migration changed the current session list.'
        Assert-Equal $script:RefreshTokenExchangeCalls.Count 1 'Manual migration did not perform exactly one mocked LWA exchange.'
        Assert-Equal $script:MarketplaceDiscoveryCalls.Count 1 'Manual migration did not perform exactly one mocked Marketplace discovery.'
        Assert-SecretAbsent -Value $manualStoreDenied.body -Context 'Rejected manual migration response'

        $script:MockStoreName = 'Carkee'
        $script:RefreshTokenExchangeCalls.Clear()
        $script:MarketplaceDiscoveryCalls.Clear()
        $manualSellerDenied = Invoke-LocalApiRequest `
            -Path '/api/auth/verify' `
            -Method POST `
            -Body (@{
                refreshToken = $script:MockRefreshToken
                sellerId = 'A238CU8SD85H9R'
            } | ConvertTo-Json -Compress)
        Assert-Equal $manualSellerDenied.statusCode 403 'Manual migration accepted a disallowed Seller.'
        Assert-Equal (($manualSellerDenied.body | ConvertFrom-Json).error.code) `
            'STORE_NOT_ALLOWED' `
            'Disallowed manual Seller returned the wrong policy code.'
        Assert-Equal $script:RefreshTokenExchangeCalls.Count 0 'A disallowed manual Seller reached LWA.'
        Assert-Equal $script:MarketplaceDiscoveryCalls.Count 0 'A disallowed manual Seller reached Marketplace discovery.'
        Assert-Equal $script:AuthSessions.Count 0 'A disallowed manual Seller created an active session.'
        Assert-Equal $script:AuthorizationProfiles.Count 0 'A disallowed manual Seller created a persistent profile.'
        Assert-SecretAbsent -Value $manualSellerDenied.body -Context 'Disallowed manual Seller response'

        $foreignJobId = '11111111111111111111111111111111'
        $foreignBatchId = '22222222222222222222222222222222'
        $foreignAnalysisId = '33333333333333333333333333333333'
        $script:Jobs[$foreignJobId] = [pscustomobject]@{ sellerId = 'A238CU8SD85H9R' }
        $script:PricingBatches[$foreignBatchId] = [pscustomobject]@{ sellerId = 'A238CU8SD85H9R' }
        $script:Analyses[$foreignAnalysisId] = [pscustomobject]@{ templateSellerId = 'A238CU8SD85H9R' }
        $script:CurrentAnalysisId = $foreignAnalysisId

        $filteredJobs = Invoke-LocalApiRequest -Path '/api/jobs'
        $filteredJobsPayload = $filteredJobs.body | ConvertFrom-Json
        Assert-Equal @($filteredJobsPayload.jobs).Count 0 'Foreign Seller jobs were exposed in the public list.'
        $foreignJob = Invoke-LocalApiRequest -Path "/api/jobs/$foreignJobId"
        Assert-Equal $foreignJob.statusCode 404 'A foreign Seller job was readable by ID.'
        $foreignReport = Invoke-LocalApiRequest -Path "/api/jobs/$foreignJobId/report"
        Assert-Equal $foreignReport.statusCode 404 'A foreign Seller report was readable by ID.'
        $foreignReconnect = Invoke-LocalApiRequest -Path "/api/jobs/$foreignJobId/reconnect" -Method POST
        Assert-Equal $foreignReconnect.statusCode 404 'A foreign Seller job reached reconnect handling.'

        $filteredBatches = Invoke-LocalApiRequest -Path '/api/pricing/batches'
        $filteredBatchesPayload = $filteredBatches.body | ConvertFrom-Json
        Assert-Equal @($filteredBatchesPayload.batches).Count 0 'Foreign Seller pricing batches were exposed in the public list.'
        $foreignBatch = Invoke-LocalApiRequest -Path "/api/pricing/batches/$foreignBatchId"
        Assert-Equal $foreignBatch.statusCode 404 'A foreign Seller pricing batch was readable by ID.'

        $filteredWorkflow = Invoke-LocalApiRequest -Path '/api/workflow/current'
        Assert-True ($null -eq ($filteredWorkflow.body | ConvertFrom-Json).analysis) `
            'A foreign Seller analysis was exposed through the current workflow.'

        $script:Jobs.Clear()
        $script:PricingBatches.Clear()
        $script:Analyses.Clear()
        $script:CurrentAnalysisId = $null

        $startResponse = Invoke-LocalApiRequest -Path '/api/auth/oauth/start'
        Assert-Equal $startResponse.statusCode 200 'OAuth start did not return HTTP 200.'
        $startPayload = $startResponse.body | ConvertFrom-Json
        $authorizationUri = [Uri]$startPayload.authorizationUrl
        $authorizationQuery = ConvertFrom-TestQuery -Uri $authorizationUri
        Assert-Equal $authorizationUri.GetLeftPart([UriPartial]::Path) `
            'https://sellercentral.amazon.com/apps/authorize/consent' `
            'OAuth start used the wrong Seller Central authorization endpoint.'
        Assert-Equal $authorizationQuery['application_id'] `
            'amzn1.sellerapps.app.mock-operator' `
            'OAuth start did not send the Amazon Application ID.'
        Assert-True ($authorizationQuery.ContainsKey('state')) 'OAuth start did not issue a state value.'
        Assert-True ($authorizationQuery['state'] -match '^[A-Za-z0-9_-]{43}$') `
            'OAuth state is not a 256-bit URL-safe value.'
        Assert-Equal $startPayload.callbackUrl `
            'https://workstation.example.test/api/auth/oauth/callback' `
            'OAuth start returned the wrong callback URL.'
        Assert-Equal ([int]$startPayload.expiresIn) 600 'OAuth state lifetime is not ten minutes.'
        Assert-SecretAbsent -Value $startResponse.body -Context 'OAuth start response'

        $invalidResponse = Invoke-LocalApiRequest -Path (
            '/api/auth/oauth/callback?state=invalid-state&selling_partner_id=' +
            $script:MockSellerId + '&spapi_oauth_code=' +
            [Uri]::EscapeDataString($script:MockAuthorizationCode)
        )
        Assert-Equal $invalidResponse.statusCode 302 'Invalid state did not redirect.'
        Assert-True ($invalidResponse.location.EndsWith('#settings?amazon=error&reason=invalid_state')) `
            'Invalid state did not return the safe UI error marker.'
        Assert-Equal $script:OAuthExchangeCalls.Count 0 'Invalid state reached the token exchange.'
        Assert-SecretAbsent -Value ($invalidResponse.location + $invalidResponse.body) -Context 'Invalid-state callback response'

        $expiredState = New-OAuthState -CallbackUrl ([string]$startPayload.callbackUrl)
        $script:OAuthStates[$expiredState].expiresAt = [DateTime]::UtcNow.AddSeconds(-1)
        $expiredResponse = Invoke-LocalApiRequest -Path (
            '/api/auth/oauth/callback?state=' + [Uri]::EscapeDataString($expiredState) +
            '&selling_partner_id=' + $script:MockSellerId +
            '&spapi_oauth_code=' + [Uri]::EscapeDataString($script:MockAuthorizationCode)
        )
        Assert-Equal $expiredResponse.statusCode 302 'Expired state did not redirect.'
        Assert-True ($expiredResponse.location.EndsWith('#settings?amazon=error&reason=expired_state')) `
            'Expired state did not return the safe UI error marker.'
        Assert-Equal $script:OAuthExchangeCalls.Count 0 'Expired state reached the token exchange.'
        Assert-SecretAbsent -Value ($expiredResponse.location + $expiredResponse.body) -Context 'Expired-state callback response'

        $validState = [string]$authorizationQuery['state']
        $successPath = '/api/auth/oauth/callback?state=' + [Uri]::EscapeDataString($validState) +
            '&selling_partner_id=' + $script:MockSellerId +
            '&spapi_oauth_code=' + [Uri]::EscapeDataString($script:MockAuthorizationCode)
        $successResponse = Invoke-LocalApiRequest -Path $successPath
        Assert-Equal $successResponse.statusCode 302 'Successful callback did not redirect.'
        Assert-Equal $successResponse.location `
            'https://workstation.example.test/#settings?amazon=connected' `
            'Successful callback did not return to Settings.'
        Assert-True ($successResponse.cacheControl -match 'no-store') `
            'OAuth callback response is cacheable.'
        Assert-SecretAbsent -Value ($successResponse.location + $successResponse.body) -Context 'Successful callback response'

        Assert-Equal $script:OAuthExchangeCalls.Count 1 'Successful callback did not exchange exactly one code.'
        Assert-Equal $script:OAuthExchangeCalls[0].authorizationCode `
            $script:MockAuthorizationCode `
            'The callback exchanged the wrong authorization code.'
        Assert-Equal $script:OAuthExchangeCalls[0].redirectUri `
            ([string]$startPayload.callbackUrl) `
            'The authorization-code exchange did not reuse the exact callback URL.'
        Assert-Equal $script:MarketplaceDiscoveryCalls.Count 1 `
            'Successful callback did not discover Marketplaces exactly once.'
        Assert-Equal $script:MarketplaceDiscoveryCalls[0].accessToken `
            $script:MockAccessToken `
            'Marketplace discovery did not use the exchanged Access Token.'
        Assert-Equal $script:MarketplaceDiscoveryCalls[0].preferredRegion 'auto' `
            'Marketplace discovery was not automatic.'

        Assert-Equal $script:AuthSessions.Count 1 'OAuth callback did not create one authorization session.'
        Assert-Equal $script:AuthorizationProfiles.Count 1 'OAuth callback did not create one persistent profile.'
        $session = @($script:AuthSessions.Values)[0]
        $profile = @($script:AuthorizationProfiles.Values)[0]
        Assert-Equal $session.sellerId $script:MockSellerId 'OAuth callback did not bind the callback Seller ID.'
        Assert-Equal $profile.sellerId $script:MockSellerId 'Persistent profile did not bind the callback Seller ID.'
        Assert-Equal @($session.marketplaces).Count 2 'Marketplace discovery did not populate both sites.'
        Assert-Equal ((@($session.marketplaces | ForEach-Object { $_.countryCode }) | Sort-Object) -join ',') `
            'DE,FR' `
            'Discovered Marketplace data was not registered.'

        $workflowResponse = Invoke-LocalApiRequest -Path '/api/workflow/current'
        Assert-Equal $workflowResponse.statusCode 200 'Public workflow response failed after OAuth binding.'
        $workflow = $workflowResponse.body | ConvertFrom-Json
        Assert-Equal $workflow.auth.sellerId $script:MockSellerId 'Public workflow lost the bound Seller ID.'
        Assert-True ([bool]$workflow.auth.storeAllowed) 'Public workflow did not mark the verified Carkee store as allowed.'
        Assert-True ([bool]$workflow.auth.sellerBound) 'Public workflow did not mark the OAuth Seller as bound.'
        Assert-Equal $workflow.auth.verifiedStoreName 'Carkee' 'Public workflow returned the wrong verified store name.'
        Assert-Equal @($workflow.auth.marketplaces).Count 2 'Public workflow lost the discovered Marketplaces.'
        Assert-SecretAbsent -Value $workflowResponse.body -Context 'Public workflow response'
        Assert-True (-not $workflowResponse.body.Contains('refreshToken')) `
            'Public workflow exposed a Refresh Token property.'
        Assert-True (-not $workflowResponse.body.Contains('accessToken')) `
            'Public workflow exposed an Access Token property.'
        Assert-True (-not $workflowResponse.body.Contains('clientSecret')) `
            'Public workflow exposed a Client Secret property.'

        $replayResponse = Invoke-LocalApiRequest -Path $successPath
        Assert-Equal $replayResponse.statusCode 302 'Replayed callback did not redirect.'
        Assert-True ($replayResponse.location.EndsWith('#settings?amazon=error&reason=invalid_state')) `
            'Replayed state was not rejected.'
        Assert-Equal $script:OAuthExchangeCalls.Count 1 'Replayed state caused a second token exchange.'
        Assert-Equal $script:MarketplaceDiscoveryCalls.Count 1 'Replayed state caused a second Marketplace discovery.'
        Assert-SecretAbsent -Value ($replayResponse.location + $replayResponse.body) -Context 'Replayed callback response'

        $otherStoreStart = Invoke-LocalApiRequest -Path '/api/auth/oauth/start'
        $otherStoreStartPayload = $otherStoreStart.body | ConvertFrom-Json
        $otherStoreState = (ConvertFrom-TestQuery -Uri ([Uri]$otherStoreStartPayload.authorizationUrl))['state']
        $script:MockStoreName = 'Another Store'
        $otherStoreResponse = Invoke-LocalApiRequest -Path (
            '/api/auth/oauth/callback?state=' + [Uri]::EscapeDataString($otherStoreState) +
            '&selling_partner_id=' + $script:MockSellerId +
            '&spapi_oauth_code=' + [Uri]::EscapeDataString($script:MockAuthorizationCode)
        )
        Assert-Equal $otherStoreResponse.statusCode 302 'A non-Carkee authorization did not redirect.'
        Assert-True ($otherStoreResponse.location.EndsWith('#settings?amazon=error&reason=store_not_allowed')) `
            'A non-Carkee Marketplace discovery did not return the store policy marker.'
        Assert-Equal $script:AuthSessions.Count 1 'A non-Carkee authorization created an active session.'
        Assert-Equal $script:AuthorizationProfiles.Count 1 'A non-Carkee authorization created a persistent profile.'
        Assert-Equal $script:OAuthExchangeCalls.Count 2 'The non-Carkee callback did not exchange exactly one authorization code.'
        Assert-Equal $script:MarketplaceDiscoveryCalls.Count 2 'The non-Carkee callback did not perform Marketplace discovery exactly once.'
        Assert-SecretAbsent -Value ($otherStoreResponse.location + $otherStoreResponse.body) -Context 'Non-Carkee callback response'

        $wrongSellerStart = Invoke-LocalApiRequest -Path '/api/auth/oauth/start'
        $wrongSellerStartPayload = $wrongSellerStart.body | ConvertFrom-Json
        $wrongSellerState = (ConvertFrom-TestQuery -Uri ([Uri]$wrongSellerStartPayload.authorizationUrl))['state']
        $wrongSellerResponse = Invoke-LocalApiRequest -Path (
            '/api/auth/oauth/callback?state=' + [Uri]::EscapeDataString($wrongSellerState) +
            '&selling_partner_id=A238CU8SD85H9R' +
            '&spapi_oauth_code=' + [Uri]::EscapeDataString($script:MockAuthorizationCode)
        )
        Assert-Equal $wrongSellerResponse.statusCode 302 'A disallowed Seller callback did not redirect.'
        Assert-True ($wrongSellerResponse.location.EndsWith('#settings?amazon=error&reason=store_not_allowed')) `
            'A disallowed Seller callback did not return the store policy marker.'
        Assert-Equal $script:OAuthExchangeCalls.Count 2 'A disallowed Seller reached the authorization-code exchange.'
        Assert-Equal $script:MarketplaceDiscoveryCalls.Count 2 'A disallowed Seller reached Marketplace discovery.'
        Assert-Equal $script:AuthSessions.Count 1 'A disallowed Seller created an active session.'
        Assert-Equal $script:AuthorizationProfiles.Count 1 'A disallowed Seller created a persistent profile.'
        Assert-SecretAbsent -Value ($wrongSellerResponse.location + $wrongSellerResponse.body) -Context 'Disallowed-Seller callback response'
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
        $listener.Stop()
        $listener.Close()
    }

    Write-Output 'OAuth security verification passed: state lifecycle, callback binding, Marketplace discovery, and response secrecy.'
}
finally {
    $env:KLANATA_PUBLIC_ORIGIN = $originalPublicOrigin
}
