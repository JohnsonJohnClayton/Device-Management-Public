<#
.SYNOPSIS
    Exports a Microsoft 365 user, license, usage, and registered device audit.

.DESCRIPTION
    Uses direct Microsoft Graph REST calls with OAuth device-code authentication.
    This avoids loading Microsoft Graph, Exchange Online, and SharePoint Online
    PowerShell modules into the same session, which can cause recent MSAL/WAM
    authentication conflicts.

    The script exports all member, non-external Entra ID users with account
    status, assigned licenses, registered device names, mailbox usage, and
    OneDrive usage. Registered devices are grouped into one comma-separated CSV
    cell per user.

    Mailbox and OneDrive size are pulled from Microsoft Graph usage report
    endpoints. The report parser handles Graph report redirects, metadata rows,
    and anonymized report identifiers by resolving them against the user list.
    Storage reports use the D7 report window internally to get the freshest
    available report snapshot.

.PARAMETER OutputDir
    Directory where the CSV export will be written.
    Default: C:\Temp

.PARAMETER OutputFileName
    Name of the CSV export file.
    Default: 365UserDeviceAudit_<yyyyMMdd_HHmmss>.csv

.PARAMETER GraphClientId
    Application ID of your public-client app registration configured for device-code authentication.

.PARAMETER TenantIdOrDomain
    Tenant ID or domain used for device-code authentication.
    Required: supply your tenant ID or verified domain.

.PARAMETER AdminUPN
    Optional admin UPN shown in the sign-in prompt.

.PARAMETER DeviceActivityTimeFrame
    Optional number of days back from today to use when selecting registered
    devices. If set to 30, only registered devices with activity in the last
    30 days are included. If omitted or 0, all registered devices are included.
    Devices without an approximate last sign-in date are excluded when this
    filter is used.

.NOTES
    Requires an admin account with permission to consent/use these Graph scopes:
    - User.Read.All
    - Directory.Read.All
    - Device.Read.All
    - Reports.Read.All
    - Organization.Read.All

    This script intentionally avoids Connect-MgGraph, Connect-ExchangeOnline,
    and Connect-SPOService.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $OutputDir = "C:\Temp",

    [Parameter()]
    [string]
    $OutputFileName = "365UserDeviceAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [Parameter(Mandatory)]
    [string]
    $TenantIdOrDomain,

    [Parameter(Mandatory)]
    [string]$GraphClientId,

    [Parameter()]
    [string]
    $AdminUPN,

    [Parameter()]
    [ValidateRange(0, 3650)]
    [int]
    $DeviceActivityTimeFrame = 0
)

$ErrorActionPreference = "Stop"
$graphBaseUri = "https://graph.microsoft.com/v1.0"
$usageReportPeriod = "D7"
$graphScopes = @(
    "https://graph.microsoft.com/User.Read.All",
    "https://graph.microsoft.com/Directory.Read.All",
    "https://graph.microsoft.com/Device.Read.All",
    "https://graph.microsoft.com/Reports.Read.All",
    "https://graph.microsoft.com/Organization.Read.All",
    "offline_access"
) -join " "

Add-Type -AssemblyName System.Net.Http

function Get-GraphAccessToken {
    param (
        [Parameter(Mandatory)]
        [string]
        $Tenant,

        [Parameter(Mandatory)]
        [string]
        $ClientId,

        [Parameter(Mandatory)]
        [string]
        $Scopes,

        [Parameter()]
        [string]
        $PromptUPN
    )

    $deviceCodeUri = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode"
    $tokenUri = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    $deviceCodeBody = "client_id=$ClientId&scope=$([System.Uri]::EscapeDataString($Scopes))"

    Write-Host "Requesting Microsoft Graph device code..." -ForegroundColor Yellow
    $deviceCodeResponse = Invoke-RestMethod -Method POST -Uri $deviceCodeUri -Body $deviceCodeBody -ContentType "application/x-www-form-urlencoded"

    Write-Host ""
    Write-Host "Open a browser and go to: $($deviceCodeResponse.verification_uri)" -ForegroundColor Cyan
    Write-Host "Enter code: $($deviceCodeResponse.user_code)" -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($PromptUPN)) {
        Write-Host "Sign in as: $PromptUPN" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Waiting for sign-in..." -ForegroundColor Gray

    $expiresAt = (Get-Date).AddSeconds($deviceCodeResponse.expires_in)

    while ((Get-Date) -lt $expiresAt) {
        Start-Sleep -Seconds $deviceCodeResponse.interval

        try {
            $tokenBody = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$ClientId&device_code=$($deviceCodeResponse.device_code)"
            $tokenResponse = Invoke-RestMethod -Method POST -Uri $tokenUri -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
            return $tokenResponse.access_token
        } catch {
            $errorResponse = Get-OAuthErrorResponse -ErrorRecord $_

            if ($errorResponse.error -eq "authorization_pending") {
                continue
            }

            if ($errorResponse.error -eq "authorization_declined") {
                throw "Device-code sign-in was declined."
            }

            if ($errorResponse.error -eq "expired_token") {
                throw "Device code expired. Rerun the script."
            }

            throw
        }
    }

    throw "Timed out waiting for device-code sign-in."
}

function Get-OAuthErrorResponse {
    param (
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        try {
            return ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json)
        } catch {}
    }

    if ($ErrorRecord.Exception.Response) {
        try {
            $responseStream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($responseStream)
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } catch {}
    }

    if ($ErrorRecord.Exception.InnerException -and $ErrorRecord.Exception.InnerException.Response) {
        try {
            $responseStream = $ErrorRecord.Exception.InnerException.Response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($responseStream)
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } catch {}
    }

    try {
        return ($ErrorRecord.Exception.Message | ConvertFrom-Json)
    } catch {}

    return $null
}

function Invoke-GraphGet {
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri
    )

    $headers = @{
        Authorization    = "Bearer $script:accessToken"
        ConsistencyLevel = "eventual"
    }

    return Invoke-RestMethod -Method GET -Uri $Uri -Headers $headers
}

function Get-GraphCollection {
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri
    )

    $items = @()
    $nextUri = $Uri

    while ($nextUri) {
        $response = Invoke-GraphGet -Uri $nextUri

        if ($response.value) {
            $items += $response.value
        }

        $nextUri = $response.'@odata.nextLink'
    }

    return $items
}

function Get-GraphReportCsvText {
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.Add("Authorization", "Bearer $script:accessToken")

    $response = $client.GetAsync($Uri).Result
    $statusCode = [int]$response.StatusCode
    $client.Dispose()
    $handler.Dispose()

    if ($statusCode -eq 302 -and $response.Headers.Location) {
        $blobClient = New-Object System.Net.Http.HttpClient
        $csvText = $blobClient.GetStringAsync($response.Headers.Location.AbsoluteUri).Result
        $blobClient.Dispose()
        return $csvText
    }

    if ($statusCode -eq 200) {
        return $response.Content.ReadAsStringAsync().Result
    }

    throw "Report API returned HTTP $statusCode for $Uri"
}

function Convert-GraphReportCsvToRows {
    param (
        [Parameter(Mandatory)]
        [string]
        $CsvText
    )

    $csvText = $CsvText.TrimStart([char]0xFEFF)
    $lines = $csvText -split "`r?`n"
    $headerLine = $lines | Where-Object { $_ -match "User Principal Name|Owner Principal Name" } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        throw "Could not find a user header row in the Graph report CSV."
    }

    $headerIndex = [array]::IndexOf($lines, $headerLine)
    $csvBody = ($lines[$headerIndex..($lines.Count - 1)] -join "`n")

    return @($csvBody | ConvertFrom-Csv)
}

function Resolve-ReportUserPrincipalName {
    param (
        [Parameter()]
        [string]
        $Identifier
    )

    if ([string]::IsNullOrWhiteSpace($Identifier)) {
        return $null
    }

    $normalizedIdentifier = $Identifier.ToLowerInvariant()

    if ($script:userLookup.ContainsKey($normalizedIdentifier)) {
        return $script:userLookup[$normalizedIdentifier]
    }

    $matchingKey = $script:userLookup.Keys | Where-Object { $_ -like "$normalizedIdentifier*" } | Select-Object -First 1
    if ($matchingKey) {
        return $script:userLookup[$matchingKey]
    }

    return $Identifier
}

function Get-UsageReportLookup {
    param (
        [Parameter(Mandatory)]
        [string]
        $Uri,

        [Parameter(Mandatory)]
        [string]
        $UserColumnName,

        [Parameter(Mandatory)]
        [string]
        $UsageColumnName
    )

    $lookup = @{}
    $rows = Convert-GraphReportCsvToRows -CsvText (Get-GraphReportCsvText -Uri $Uri)

    foreach ($row in $rows) {
        $upn = Resolve-ReportUserPrincipalName -Identifier $row.$UserColumnName

        if ([string]::IsNullOrWhiteSpace($upn)) {
            continue
        }

        try {
            $bytes = [double]($row.$UsageColumnName -replace "[^0-9]", "")
            $lookup[$upn.ToLowerInvariant()] = [math]::Round(($bytes / 1GB), 2)
        } catch {}
    }

    return $lookup
}

function Get-RegisteredDeviceAuditData {
    param (
        [Parameter(Mandatory)]
        [string]
        $UserId,

        [Parameter()]
        [int]
        $ActivityTimeFrameDays = 0
    )

    $deviceNames = @()
    $deviceActivityDates = @()
    $activityCutoff = if ($ActivityTimeFrameDays -gt 0) { (Get-Date).AddDays(-$ActivityTimeFrameDays) } else { $null }

    $registeredDevices = Get-GraphCollection -Uri "$graphBaseUri/users/$UserId/registeredDevices/microsoft.graph.device?`$select=id,displayName,approximateLastSignInDateTime&`$top=999"

    foreach ($device in $registeredDevices) {
        $lastActivity = $null

        if (-not [string]::IsNullOrWhiteSpace($device.approximateLastSignInDateTime)) {
            try {
                $lastActivity = [DateTime]$device.approximateLastSignInDateTime
            } catch {}
        }

        if ($activityCutoff -and (-not $lastActivity -or $lastActivity -lt $activityCutoff)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($device.displayName)) {
            $deviceNames += $device.displayName
        }

        if ($lastActivity) {
            $deviceActivityDates += $lastActivity.ToString("yyyy-MM-dd")
        }
    }

    return [PSCustomObject]@{
        Names             = @($deviceNames | Sort-Object -Unique)
        LastActivityDates = @($deviceActivityDates | Sort-Object -Unique -Descending)
    }
}

function Convert-LicenseSkuIdsToNames {
    param (
        [Parameter()]
        [object[]]
        $AssignedLicenses,

        [Parameter(Mandatory)]
        [hashtable]
        $SkuLookup
    )

    if (-not $AssignedLicenses -or $AssignedLicenses.Count -eq 0) {
        return ""
    }

    $licenseNames = foreach ($license in $AssignedLicenses) {
        $skuId = $license.skuId.ToString()

        if ($SkuLookup.ContainsKey($skuId)) {
            $SkuLookup[$skuId]
        } else {
            $skuId
        }
    }

    return (($licenseNames | Sort-Object -Unique) -join ", ")
}

function Convert-AccountEnabledToActivationStatus {
    param (
        [Parameter()]
        [Nullable[bool]]
        $AccountEnabled
    )

    if ($AccountEnabled -eq $true) {
        return "Active"
    }

    if ($AccountEnabled -eq $false) {
        return "Disabled"
    }

    return "Unknown"
}

function Convert-AccountEnabledToSignInBlocked {
    param (
        [Parameter()]
        [Nullable[bool]]
        $AccountEnabled
    )

    if ($AccountEnabled -eq $true) {
        return "No"
    }

    if ($AccountEnabled -eq $false) {
        return "Yes"
    }

    return "Unknown"
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$outputPath = Join-Path -Path $OutputDir -ChildPath $OutputFileName

$script:accessToken = Get-GraphAccessToken -Tenant $TenantIdOrDomain -ClientId $graphClientId -Scopes $graphScopes -PromptUPN $AdminUPN
Write-Host "Successfully authenticated to Microsoft Graph." -ForegroundColor Green

Write-Host "Checking tenant report privacy settings..." -ForegroundColor Yellow
try {
    $reportSettings = Invoke-GraphGet -Uri "$graphBaseUri/admin/reportSettings"
    if ($reportSettings.displayConcealedNames -eq $true) {
        Write-Host "Report anonymization is enabled. Resolving report IDs to users from the Graph user list." -ForegroundColor Yellow
    } else {
        Write-Host "Reports contain real user names." -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not check report privacy settings. Continuing with report ID resolution."
}

Write-Host "Getting subscribed SKU lookup..." -ForegroundColor Yellow
$skuLookup = @{}
$subscribedSkus = Get-GraphCollection -Uri "$graphBaseUri/subscribedSkus"
foreach ($sku in $subscribedSkus) {
    $skuLookup[$sku.skuId.ToString()] = $sku.skuPartNumber
}

Write-Host "Getting all member users..." -ForegroundColor Yellow
$encodedFilter = [System.Uri]::EscapeDataString("userType eq 'Member'")
$usersUri = "$graphBaseUri/users?`$filter=$encodedFilter&`$select=id,displayName,userPrincipalName,accountEnabled,assignedLicenses,userType,creationType&`$top=999"
$users = @(Get-GraphCollection -Uri $usersUri |
    Where-Object {
        $_.userPrincipalName -notlike "*#EXT#*" -and
        $_.creationType -ne "Invitation"
    } |
    Sort-Object displayName, userPrincipalName)

Write-Host "Found $($users.Count) member, non-external users." -ForegroundColor Green

$script:userLookup = @{}
foreach ($user in $users) {
    $script:userLookup[$user.id.ToLowerInvariant()] = $user.userPrincipalName
    $script:userLookup[$user.userPrincipalName.ToLowerInvariant()] = $user.userPrincipalName
}

Write-Host "Getting mailbox usage report from the latest D7 report snapshot..." -ForegroundColor Yellow
$mailboxUsageLookup = Get-UsageReportLookup `
    -Uri "$graphBaseUri/reports/getMailboxUsageDetail(period='$usageReportPeriod')" `
    -UserColumnName "User Principal Name" `
    -UsageColumnName "Storage Used (Byte)"

Write-Host "Getting OneDrive usage report from the latest D7 report snapshot..." -ForegroundColor Yellow
$oneDriveUsageLookup = Get-UsageReportLookup `
    -Uri "$graphBaseUri/reports/getOneDriveUsageAccountDetail(period='$usageReportPeriod')" `
    -UserColumnName "Owner Principal Name" `
    -UsageColumnName "Storage Used (Byte)"

if ($DeviceActivityTimeFrame -gt 0) {
    Write-Host "Registered devices will be limited to activity in the last $DeviceActivityTimeFrame days." -ForegroundColor Yellow
} else {
    Write-Host "Registered device output will include all registered devices." -ForegroundColor Yellow
}

$results = @()
$currentUser = 0

foreach ($user in $users) {
    $currentUser++
    $percentComplete = if ($users.Count -gt 0) { [math]::Round(($currentUser / $users.Count) * 100, 2) } else { 100 }

    Write-Progress -Activity "Building Microsoft 365 user/device audit" `
        -Status "Processing $currentUser of $($users.Count) users ($percentComplete% complete)" `
        -CurrentOperation $user.userPrincipalName `
        -PercentComplete $percentComplete

    # Write-Host "[$currentUser/$($users.Count)] $($user.userPrincipalName)" -ForegroundColor White

    $registeredDeviceNames = @()
    $registeredDeviceActivityDates = @()

    try {
        $registeredDeviceData = Get-RegisteredDeviceAuditData -UserId $user.id -ActivityTimeFrameDays $DeviceActivityTimeFrame
        $registeredDeviceNames = $registeredDeviceData.Names
        $registeredDeviceActivityDates = $registeredDeviceData.LastActivityDates
    } catch {
        Write-Warning "Could not get registered devices for $($user.userPrincipalName). $($_.Exception.Message)"
    }

    $usageLookupKey = $user.userPrincipalName.ToLowerInvariant()

    $results += [PSCustomObject]@{
        DisplayName       = $user.displayName
        UserPrincipalName = $user.userPrincipalName
        EntraObjectId     = $user.id
        ActivationStatus  = Convert-AccountEnabledToActivationStatus -AccountEnabled $user.accountEnabled
        SignInBlocked     = Convert-AccountEnabledToSignInBlocked -AccountEnabled $user.accountEnabled
        RegisteredDevices            = ($registeredDeviceNames -join ", ")
        RegisteredDeviceActivityDates = ($registeredDeviceActivityDates -join ", ")
        Licenses                     = Convert-LicenseSkuIdsToNames -AssignedLicenses $user.assignedLicenses -SkuLookup $skuLookup
        MailboxUsageGB               = if ($mailboxUsageLookup.ContainsKey($usageLookupKey)) { $mailboxUsageLookup[$usageLookupKey] } else { $null }
        OneDriveUsageGB              = if ($oneDriveUsageLookup.ContainsKey($usageLookupKey)) { $oneDriveUsageLookup[$usageLookupKey] } else { $null }
    }
}

Write-Progress -Activity "Building Microsoft 365 user/device audit" -Completed

$results | Export-Csv -Path $outputPath -NoTypeInformation

Write-Host ""
Write-Host "Audit complete." -ForegroundColor Green
Write-Host "Users exported: $($results.Count)" -ForegroundColor Cyan
Write-Host "CSV exported to: $outputPath" -ForegroundColor Green
