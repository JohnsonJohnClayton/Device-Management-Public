<#
.SYNOPSIS
Sets the ImmutableId on Azure AD users to hard-match them with their on-premises AD accounts.

.DESCRIPTION
This script processes a list of user principal names (UPNs), retrieves their corresponding on-premises Active Directory objectGUIDs,
converts these GUIDs to Base64 strings, and sets them as the ImmutableId property of the matching Azure AD user objects.
This ensures a hard match between on-premises accounts and Azure AD accounts following tenant-to-tenant mailbox and OneDrive migrations.

.PARAMETER CsvPath
Specifies the path to a CSV file containing the list of UPNs to process.
The CSV must have a header named 'UPN' with user principal names under it.

.EXAMPLE
.\Sync-EntraAccounts.ps1 -CsvPath .\ListOfUpns.csv

Processes each UPN in ListOfUpns.csv, sets the ImmutableId for the corresponding Azure AD user to enable hard matching.

.EXAMPLE
.\Sync-EntraAccounts.ps1 -CsvPath .\UsersToMatch.csv -Verbose

Runs the script with verbose output, providing detailed information for each step.

.NOTES
Author: John Johnson
Version: 1.0
Date: 07/16/2025
Requires: ActiveDirectory and AzureAD PowerShell modules  
Run this script with appropriate permissions in both on-prem AD and Azure AD.  
Ensure Azure AD Connect sync configuration is set appropriately to process changes after running.

.LINK
https://learn.microsoft.com/en-us/azure/active-directory/hybrid/how-to-connect-sync-feature-immutableid
#>

param(
    [Parameter(Mandatory)]
    [object]$InputUsers,
    [Parameter(Mandatory)]
    [uri]$ExchangeConnectionUri,
    [Parameter(Mandatory)]
    [string]$RemoteRoutingDomain,

    [string]$LogDirectory
)

# Initialize logging

# If not specified, set log directory to $PSScriptRoot\MigrationLogs 
if(-not $LogDirectory) {
    $LogDir = $PSScriptRoot
    if (-not $LogDir) { $LogDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent }
    $LogDirectory = "$($LogDir)\MigrationLogs"
}
# Ensure log directory exists
if (-not (Test-Path $LogDirectory)) {
    try {New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null}
    catch {Write-Error "There was an issue initializing the Log Directory:`n$_"}
}
# Define log files
$LogPath = Join-Path $LogDirectory "CrossTenantMigration_$(Get-Date -Format 'yyyyMMdd').log"
$ErrorLogPath = Join-Path $LogDirectory "CrossTenantMigration_Errors_$(Get-Date -Format 'yyyyMMdd').log"


# Logging function
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if($Level -eq "SUCCESS") { $LogEntry = "`n[$TimeStamp] [$Level] $Message" } else {$LogEntry = "[$TimeStamp] [$Level] $Message"}
    
    Write-Host $LogEntry -ForegroundColor $(
        switch ($Level) {
            "INFO" { "White" }
            "SUCCESS" { "Green" }
            "WARNING" { "Yellow" }
            "ERROR" { "Red" }
            default { "White" }
        }
    )
    
    Add-Content -Path $LogPath -Value $LogEntry
    
    if ($Level -eq "ERROR") {
        Add-Content -Path $ErrorLogPath -Value $LogEntry

        Write-Host "`nThere was an error in the script execution. Check the error log at: $ErrorLogPath`n" -ForegroundColor Red
        Read-Host -Prompt "Press Enter to continue or Ctrl+C to exit..."
    }
}

# Check and install required modules
function Ensure-Module {
    param(
        [string]$ModuleName,
        [string]$InstallName = $ModuleName,
        [string]$RequiredVersion = $null
    )
    Write-Log "Checking for module: $ModuleName" -Level "INFO"
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Log "$ModuleName module not found. Installing..." -Level "WARNING"
        if ($RequiredVersion) {
            Install-Module -Name $InstallName -RequiredVersion $RequiredVersion -Force -ErrorAction Stop
        } else {
            Install-Module -Name $InstallName -Force -ErrorAction Stop
        }
        Write-Log "$ModuleName module installed." -Level "SUCCESS"
    } else {
        if(-not (Get-Module -Name $ModuleName)) {
            Write-Log "Importing $ModuleName module..." -Level "INFO"
            Import-Module -Name $ModuleName -Force -ErrorAction Stop
            Write-Log "$ModuleName module imported." -Level "SUCCESS"
        } else {
            Write-Log "$ModuleName module already installed & imported." -Level "SUCCESS"
        }
    }
}

# Create new AD User
function New-MirroredADUser {
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceUPN
    )
     # Confirm Microsoft Graph is connected
    if (-not (Get-Module Microsoft.Graph.Users)) {
        Write-Log "Microsoft Graph Users module not loaded. Connecting to the Graph now..." -Level "WARNING"
        Connect-MgGraph -Scopes "User.ReadWrite.All" -NoWelcome
    }

    # Retrieve Azure AD user properties needed for mirroring
    try {
        $aadUser = Get-MgUser -UserId $SourceUPN -Property `
        DisplayName,`
        GivenName,`
        Surname,`
        Mail,`
        UserPrincipalName,`
        JobTitle,`
        Department,`
        MobilePhone,`
        OfficeLocation,`
        StreetAddress,`
        City,`
        State,`
        PostalCode,`
        Country,`
        TelephoneNumber,`
        ProxyAddresses
    }
    catch {
        Write-Log "Failed to find Azure AD user with UPN '$SourceUPN'. $_" -Level "ERROR"
        return
    }

    if (-not $aadUser) {
        Write-Log "Azure AD user '$SourceUPN' not found." -Level "ERROR"
        return
    }

     # Ensure proxyAddresses is an array of strings
    $aadProxies = $aadUser.ProxyAddresses
    if (-not $aadProxies -or $aadProxies.Count -eq 0) {
        Write-Log "AAD user does not have any proxyAddresses. Proceeding without them." -Level "WARNING"
        $aadProxies = @()
    }
    
    # Get the desired DN OU for this user
    $isValid = $false
    while (-not $isValid) {
        $ouDn = Read-Host "Enter the distinguished name (DN) of the OU where the user should be created (e.g., OU=Users,DC=contoso,DC=com)"
        try {
            $ouObject = Get-ADOrganizationalUnit -Identity $ouDn -ErrorAction Stop
            if($ouObject) { $isValid = $true }  
        }
        catch {
            Write-Log "'$ouDn' is not a valid OU distinguished name. Please try again." -Level "WARNING"
        }
    }

    # Determine sAMAccountName: typically the username portion before @
    $samAccountName = ($aadUser.UserPrincipalName.Split('@')[0]).ToLower()

    # Check if user with same sAMAccountName already exists on-premises
    $existingUser = Get-ADUser -Filter { SamAccountName -eq $samAccountName } -ErrorAction SilentlyContinue
    while ($existingUser) {
        Write-Log "A user with sAMAccountName '$samAccountName' already exists in AD; Continue to manually enter a value" -Level "ERROR"
        $samAccountName = Read-Host "Enter a new sAMAccountName for the user: $($SourceUPN)..."
        $existingUser = Get-ADUser -Filter { SamAccountName -eq $samAccountName } -ErrorAction SilentlyContinue
    }

    # Prepare parameters for New-ADUser
    $newUserParams = @{
        Name              = $aadUser.DisplayName
        GivenName         = $aadUser.GivenName
        Surname           = $aadUser.Surname
        SamAccountName    = $samAccountName
        UserPrincipalName = $aadUser.UserPrincipalName
        Path              = $ouDn
        Enabled           = $true
        Title             = $aadUser.JobTitle
        Department        = $aadUser.Department
        OfficePhone       = $aadUser.TelephoneNumber
        MobilePhone       = $aadUser.MobilePhone
        Office            = $aadUser.OfficeLocation
        StreetAddress     = $aadUser.StreetAddress
        City              = $aadUser.City
        State             = $aadUser.State
        PostalCode        = $aadUser.PostalCode
        Country           = $aadUser.Country
        EmailAddress      = $aadUser.Mail
        # Password and other mandatory attributes will be set below
    }

    # Set a temporary password (required). This must comply with your AD password policy.
    # Recommend generating a secure random password or ask admin to reset after creation.
    
    while (-not $tempPassword) {
        $tempPassword = Read-Host "Enter temporary password for the new user" -AsSecureString
        Write-Log "A password is required to create the user." -Level "WARNING"
    }

    # Create the new AD user
    try {
        New-ADUser @newUserParams -AccountPassword $tempPassword -ChangePasswordAtLogon $true
        Write-Log "Successfully created user '$($aadUser.UserPrincipalName)' in AD OU '$ouDn'." -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to create AD user. $_" -Level "ERROR"
        return
    }

    # Set proxyAddresses on the new AD user to match AAD
    try {
        # Make sure all proxyAddresses are strings
        [string[]]$proxyArray = $aadProxies
        Set-ADUser -Identity $samAccountName -Replace @{proxyAddresses = $proxyArray}
        Write-Log "Set proxyAddresses on new AD user."
    }
    catch {
        Write-Log "Failed to set proxyAddresses: $_" -Level "ERROR"
    }

    # Give AD time to write object (rare race condition, but just in case)
    Start-Sleep -Seconds 3

    $createdADUser = Get-ADUser -Identity $samAccountName -Properties ObjectGUID
    Write-Log "`nOn-prem user created:`n$createdADUser"
}

# Detect input type and process accordingly
if ($InputUsers -is [string] -and (Test-Path $InputUsers)) {
    $users = Import-Csv -Path $InputUsers | Select-Object -ExpandProperty UPN
}
elseif ($InputUsers -is [string[]]) {
    $users = $InputUsers
}
elseif ($InputUsers -is [string]) {
    $users = @($InputUsers)
}
else {
    throw "InputUsers parameter is invalid. Pass either a string array of UPNs or a valid CSV path."
}

# Make sure needed modules are imported/installed
Ensure-Module -ModuleName "ActiveDirectory"
Ensure-Module -ModuleName "Microsoft.Graph.Authentication"
Ensure-Module -ModuleName "Microsoft.Graph.Users"

# Connect to Azure AD (prompts for credentials)
Write-Verbose "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "User.ReadWrite.All" -NoWelcome

foreach ($upn in $users) {

    Write-Host "`n`n"
    Write-Log "Processing $upn"

    try {
        # Get on-prem AD user
        $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties ObjectGUID
        if (-not $adUser) {
            Write-Log "On-prem user $upn not found." -Level "WARNING"
            $response = Read-Host -Prompt "Would you like to attempt to automatically create an on-prem account for this user? (y/n)"
            while($response -notmatch '^(yes|y|no|n)$') { $response = Read-Host -Prompt "Please enter (y)es or (no).`nWould you like to attempt to automatically create an on-prem account for this user?" }
            if ($response -match '^(yes|y)$') { 
                New-MirroredADUser -SourceUPN $upn
                # Get on-prem AD user again now that it should be created
                $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties ObjectGUID
            }
            else { 
                Write-Log "Skipping account matchup for user $upn." 
                continue
            }
        }

        # Convert the objectGUID to ImmutableId (Base64)
        $immutableId = [System.Convert]::ToBase64String($adUser.ObjectGUID.ToByteArray())

        # Update the Azure AD user's OnPremisesImmutableId
        Update-MgUser -UserId $upn -OnPremisesImmutableId $immutableId

        Write-Log "Matched $upn successfully." -Level "SUCCESS"

        # Update email and proxyaddresses
        $MgUser = Get-MgUser -UserID $upn -Property proxyAddresses
        $Aliasses = $MgUser.ProxyAddresses

        # Mirror the proxyaddresses from cloud object
        Set-ADUser -Identity $adUser.DistinguishedName -Clear proxyAddresses
        
        # Add each alias individually
        foreach ($alias in $Aliases) {
            Try {
                Set-ADUser -Identity $adUser.DistinguishedName -Add @{proxyAddresses = $alias}
                Write-Log "Added alias $alias" -Level "SUCCESS"
            }
            Catch {
                Write-Log "Failed to add alias $alias : $_" -Level "WARNING"
            }
        }

        # Add email from UPN
        Set-ADUser -Identity $adUser.DistinguishedName -Replace @{mail = $adUser.UserPrincipalName}

        # Enable Remote Mailbox
        Write-Log "`nWe will now connect to the Exchange Server in order to enable the Remote Mailbox for the account..."
        Write-Log "Please enter your domain admin creds when prompted..." -Level "WARNING"

        # Connect to Exchange Server PowerShell session
        Import-PSSession (New-PSSession -ConfigurationName Microsoft.Exchange `
        -ConnectionUri $ExchangeConnectionUri `
        -Authentication Kerberos `
        -Credential (Get-Credential)) `
        -DisableNameChecking -AllowClobber

        # Enable the Remote Mailbox for the upn
        $remoteAddress = $adUser.UserPrincipalName -replace '@.*$', "@$RemoteRoutingDomain"
        Enable-RemoteMailbox -Identity $adUser.DistinguishedName -RemoteRoutingAddress $remoteAddress
        Write-Log "Enabled remote mailbox for $upn." -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed for $($upn): $_" -Level "ERROR"
    }
}

# Cleanup
Remove-PSSession *
Disconnect-Graph