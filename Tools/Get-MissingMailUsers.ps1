<#
.SYNOPSIS
    Reports matching Entra guest users that do not have an Exchange Online MailUser.

.DESCRIPTION
    Runs entirely in the current PowerShell session. The script queries Microsoft
    Graph once, retrieves Exchange Online MailUsers once, and compares their email
    addresses in memory. It does not create worker scripts or launch another
    PowerShell process.

.PARAMETER TenantId
    Entra tenant ID or verified tenant domain used by Connect-MgGraph.

.PARAMETER ExchangeAdminUPN
    Optional account to pass to Connect-ExchangeOnline.

.PARAMETER TargetUpnSuffix
    UPN suffix used to select the Entra guest users to check.

.PARAMETER OutputPath
    Destination CSV. The parent directory is created when necessary.

.PARAMETER DisableWAM
    Passes DisableWAM to Connect-ExchangeOnline. Enabled by default to avoid WAM
    broker failures in embedded terminals. Use -DisableWAM:$false to enable WAM.

.EXAMPLE
    .\Get-MissingMailUsers.ps1 -TenantId "[tenantID]" -TargetUpnSuffix "_example.net#EXT#@<targetTenant>.onmicrosoft.com" -ExchangeAdminUPN "admin@example.com"

.EXAMPLE
    .\Get-MissingMailUsers.ps1 -TenantId "[tenantID]" -TargetUpnSuffix "_example.net#EXT#@<targetTenant>.onmicrosoft.com" -DisableWAM:$false -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [string]$ExchangeAdminUPN,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory)]
    [string]$TargetUpnSuffix,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = ".\Missing-MailUsers_example_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [Alias('DisableWAMForEXO')]
    [switch]$DisableWAM = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-RequiredModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module '$Name' is not installed. Install it with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module -Name $Name -ErrorAction Stop
}

function Import-CompatibleGraphModules {
    $moduleNames = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users')
    $versionsByModule = @{}

    foreach ($moduleName in $moduleNames) {
        $versionsByModule[$moduleName] = @(
            Get-Module -ListAvailable -Name $moduleName |
                Select-Object -ExpandProperty Version -Unique
        )

        if ($versionsByModule[$moduleName].Count -eq 0) {
            throw "Required module '$moduleName' is not installed. Install or update the Microsoft.Graph PowerShell SDK."
        }
    }

    $commonVersions = @(
        $versionsByModule[$moduleNames[0]] | Where-Object {
            $candidateVersion = $_
            $versionsByModule[$moduleNames[1]] -contains $candidateVersion
        } | Sort-Object -Descending
    )

    if ($commonVersions.Count -eq 0) {
        $versionSummary = $moduleNames | ForEach-Object {
            "${_}: $($versionsByModule[$_] -join ', ')"
        }
        throw "Microsoft Graph modules do not have a common installed version. Update the SDK. Installed versions: $($versionSummary -join '; ')"
    }

    $selectedVersion = $commonVersions[0]
    $incompatibleModule = Get-Module -Name 'Microsoft.Graph.*' | Where-Object {
        $_.Version -ne $selectedVersion
    } | Select-Object -First 1

    if ($incompatibleModule) {
        throw "Microsoft Graph $($incompatibleModule.Version) is already loaded, but the installed modules require $selectedVersion. Start a fresh PowerShell session and run the script again."
    }

    foreach ($moduleName in $moduleNames) {
        Import-Module -Name $moduleName -RequiredVersion $selectedVersion -ErrorAction Stop
    }

    Write-Verbose "Loaded Microsoft Graph modules version $selectedVersion."
}

function Add-NormalizedAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$AddressSet,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return
    }

    $normalizedAddress = $Address.Trim()
    $colonIndex = $normalizedAddress.IndexOf(':')
    if ($colonIndex -ge 0) {
        $normalizedAddress = $normalizedAddress.Substring($colonIndex + 1)
    }

    if (-not [string]::IsNullOrWhiteSpace($normalizedAddress)) {
        $null = $AddressSet.Add($normalizedAddress)
    }
}

function Get-UserCandidateAddresses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$User
    )

    $addresses = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    Add-NormalizedAddress -AddressSet $addresses -Address $User.UserPrincipalName
    Add-NormalizedAddress -AddressSet $addresses -Address $User.Mail

    foreach ($address in @($User.OtherMails)) {
        Add-NormalizedAddress -AddressSet $addresses -Address $address
    }

    return ,$addresses
}

$graphConnected = $false
$exchangeConnected = $false

try {
    Write-Host 'Loading Microsoft Graph and Exchange Online modules...' -ForegroundColor Cyan
    Import-CompatibleGraphModules
    Import-RequiredModule -Name ExchangeOnlineManagement

    $graphConnectParameters = @{
        Scopes    = 'User.Read.All'
        NoWelcome = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $graphConnectParameters.TenantId = $TenantId
    }

    Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
    Connect-MgGraph @graphConnectParameters
    $graphConnected = $true

    $escapedSuffix = $TargetUpnSuffix.Replace("'", "''")
    Write-Host "Querying Entra users ending in '$TargetUpnSuffix'..." -ForegroundColor Cyan
    $graphUsers = @(
        Get-MgUser -All -ConsistencyLevel eventual `
            -Filter "endsWith(userPrincipalName,'$escapedSuffix')" `
            -Property 'id,displayName,userPrincipalName,mail,otherMails,userType,externalUserState,createdDateTime'
    )

    Write-Host "Found $($graphUsers.Count) matching Entra user(s)." -ForegroundColor Green

    $connectExchangeParameters = @{ ShowBanner = $false }
    if (-not [string]::IsNullOrWhiteSpace($ExchangeAdminUPN)) {
        $connectExchangeParameters.UserPrincipalName = $ExchangeAdminUPN
    }

    $connectExchangeCommand = Get-Command Connect-ExchangeOnline -ErrorAction Stop
    if ($DisableWAM) {
        if ($connectExchangeCommand.Parameters.ContainsKey('DisableWAM')) {
            $connectExchangeParameters.DisableWAM = $true
        }
        else {
            Write-Warning 'DisableWAM was requested, but this ExchangeOnlineManagement version does not support it.'
        }
    }

    Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
    Connect-ExchangeOnline @connectExchangeParameters
    $exchangeConnected = $true

    Write-Host 'Retrieving Exchange Online MailUsers...' -ForegroundColor Cyan
    $mailUsers = @(Get-MailUser -ResultSize Unlimited)
    $exchangeAddresses = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($mailUser in $mailUsers) {
        Add-NormalizedAddress -AddressSet $exchangeAddresses -Address ([string]$mailUser.UserPrincipalName)
        Add-NormalizedAddress -AddressSet $exchangeAddresses -Address ([string]$mailUser.WindowsEmailAddress)
        Add-NormalizedAddress -AddressSet $exchangeAddresses -Address ([string]$mailUser.PrimarySmtpAddress)
        Add-NormalizedAddress -AddressSet $exchangeAddresses -Address ([string]$mailUser.ExternalEmailAddress)

        foreach ($proxyAddress in @($mailUser.EmailAddresses)) {
            Add-NormalizedAddress -AddressSet $exchangeAddresses -Address ([string]$proxyAddress)
        }
    }

    Write-Host "Indexed $($exchangeAddresses.Count) address(es) from $($mailUsers.Count) MailUser(s)." -ForegroundColor Green

    $missingUsers = foreach ($graphUser in $graphUsers) {
        $candidateAddresses = Get-UserCandidateAddresses -User $graphUser
        $matchingAddress = $candidateAddresses | Where-Object { $exchangeAddresses.Contains($_) } | Select-Object -First 1

        if (-not $matchingAddress) {
            [pscustomobject]@{
                UserPrincipalName = $graphUser.UserPrincipalName
                DisplayName       = $graphUser.DisplayName
                Mail              = $graphUser.Mail
                OtherMails        = @($graphUser.OtherMails) -join ';'
                UserType          = $graphUser.UserType
                ExternalUserState = $graphUser.ExternalUserState
                GraphObjectId     = $graphUser.Id
                CreatedDateTime   = $graphUser.CreatedDateTime
                Reason            = 'No Exchange Online MailUser has a matching email address'
            }
        }
        else {
            Write-Verbose "Matched '$($graphUser.UserPrincipalName)' using '$matchingAddress'."
        }
    }

    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    }

    $missingUsers = @($missingUsers | Sort-Object UserPrincipalName)
    if ($missingUsers.Count -gt 0) {
        $missingUsers | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding utf8
    }
    else {
        '"UserPrincipalName","DisplayName","Mail","OtherMails","UserType","ExternalUserState","GraphObjectId","CreatedDateTime","Reason"' |
            Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    Write-Host "Found $($missingUsers.Count) user(s) without a matching MailUser." -ForegroundColor $($missingUsers.Count -eq 0 ? 'Green' : 'Yellow')
    Write-Host "Report written to: $resolvedOutputPath" -ForegroundColor Green
}
finally {
    if ($exchangeConnected) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }

    if ($graphConnected) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}
