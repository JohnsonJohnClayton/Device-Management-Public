<#
.SYNOPSIS
    Cross-Tenant Mailbox and OneDrive Migration Automation Script

.DESCRIPTION
    This script automates the end-to-end process for Microsoft 365 cross-tenant mailbox and OneDrive migrations. It performs:
    - Connection to both source and target Exchange Online and Microsoft Graph tenants
    - Gathering of source mailbox data (DisplayName, FirstName, LastName, ExchangeGuid, LegacyExchangeDN, aliases)
    - Adding users to a specified migration security group
    - Creation of matching mail users in the target tenant, with domain/alias transformation as needed
    - Assignment of Cross-Tenant Migration licenses (and usage location) in the target tenant
    - Creation and starting of mailbox migration batches with user confirmation
    - Export of migrated users' email addresses to CSV
    - Automated OneDrive cross-tenant migration, including identity mapping file creation and upload
    - Logging of all actions, errors, and results to a specified directory

    PREREQUISITES:
    - Complete tenant prep work with the Prep-Tenants script
    - Required modules: ExchangeOnlineManagement, Microsoft.Graph (various), Microsoft.Online.SharePoint.PowerShell
    - Proper permissions in both source and target tenants

.PARAMETER CSVFilePath
    Path to the CSV file containing SourceUPN and TargetUPN columns for users to migrate.
    Example CSV format:
        SourceUPN,TargetUPN
        user1@source.example.com,user1@target.onmicrosoft.com
        user2@source.example.com,user2@target.onmicrosoft.com

.PARAMETER MigrationGroupName
    Name of the mail-enabled security group for migration scoping in the source tenant.

.PARAMETER SourceTenantAdminUPN
    UPN of the source tenant administrator.

.PARAMETER TargetTenantAdminUPN
    UPN of the target tenant administrator.

.PARAMETER BatchName
    Name for the mailbox migration batch.

.PARAMETER SourceEndpointName
    Name of the Exchange Online migration endpoint in the target tenant.

.PARAMETER SourceSPOURL
    Admin SharePoint Online URL for the source tenant (for OneDrive migration).

.PARAMETER TargetSPOURL
    Admin SharePoint Online URL for the target tenant (for OneDrive migration).

.PARAMETER TargetDeliveryDomain
    (Optional) Target tenant's .onmicrosoft.com domain for mailbox migration. If not provided, will be auto-detected.

.PARAMETER LogDirectory
    Directory where logs and reports will be saved (default: "$PSScriptRoot\MigrationLogs").

.PARAMETER DefaultPassword
    (Optional) Password for new mail users. If not provided, a random password will be generated.

.EXAMPLE
    .\Start-Migration.ps1 -CSVFilePath "C:\Migration\users.csv" -MigrationGroupName "CrossTenantMigration" -SourceTenantAdminUPN "admin@source.example.com" -TargetTenantAdminUPN "admin@target.onmicrosoft.com" -BatchName "Migration_Batch_01" -SourceEndpointName "MigrationEndpoint" -SourceSPOURL "https://source-admin.sharepoint.com" -TargetSPOURL "https://target-admin.sharepoint.com"

.NOTES
    Author: John Johnson
    Version: 2.0
    Last Updated: 07/16/2025
    Requirements: Exchange Online PowerShell, Microsoft Graph PowerShell, Microsoft SharePoint Online PowerShell
    Sources:
        https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide
        https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration?view=o365-worldwide

.OUTPUTS
    - Logs: <LogDirectory>\CrossTenantMigration_<date>.log
    - Error Logs: <LogDirectory>\CrossTenantMigration_Errors_<date>.log
    - Migration Results: C:\Reports\CrossTenantMigration_Report_<date>.csv
    - Migrated Users' Email Addresses: <LogDirectory>\MigratedUsers_EmailAddresses_<date>.csv
    - OneDrive Identity Mapping: <LogDirectory>\OneDriveIdentityMapping_<date>.csv
    - OneDrive Migration Results: <LogDirectory>\OneDriveMigration_Results_<date>.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CSVFilePath,
    
    [Parameter(Mandatory = $true)]
    [string]$MigrationGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$SourceTenantAdminUPN,
    
    [Parameter(Mandatory = $true)]
    [string]$TargetTenantAdminUPN,
    
    [Parameter(Mandatory = $true)]
    [string]$BatchName,
    
    [Parameter(Mandatory = $true)]
    [string]$SourceEndpointName,
    
    [Parameter(Mandatory = $true)]
    [string]$SourceSPOURL,
    
    [Parameter(Mandatory = $true)]
    [string]$TargetSPOURL,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetDeliveryDomain,
    
    [Parameter(Mandatory = $false)]
    [string]$SourceOnMicrosoftDomain,
    
    [Parameter(Mandatory = $false)]
    [string]$SourceDefaultDomain,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetOnMicrosoftDomain,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetDefaultDomain,

    [Parameter(Mandatory = $false)]
    [SecureString]$DefaultPassword,

    [parameter(Mandatory = $false)]
    [string]$LogDirectory
)

#region SETUP

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


#region FUNCTIONS 

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

# Function to generate random password
function New-RandomSecureStringPassword {
    param(
        [int]$Length = 16
    )
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    $secureString = New-Object -TypeName System.Security.SecureString
    for ($i = 0; $i -lt $Length; $i++) {
        $char = $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
        $secureString.AppendChar($char)
    }
    $secureString.MakeReadOnly()
    return $secureString
}

# Function to connect to Exchange Online
function Connect-ExchangeOnlineTenant {
    param(
        [string]$TenantAdmin,
        [string]$TenantName
    )
    
    try {
        Write-Log "Connecting to Exchange Online for $TenantName tenant..."
        Connect-ExchangeOnline -UserPrincipalName $TenantAdmin -ShowBanner:$false
        Write-Log "Successfully connected to Exchange Online for $TenantName tenant" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to connect to Exchange Online for $TenantName tenant: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Function to connect to Microsoft Graph
function Connect-MicrosoftGraphTenant {
    param(
        [string]$TenantAdmin,
        [string]$TenantName,
        [string]$TenantID
    )
    
    try {
        Write-Log "Connecting to Microsoft Graph for $TenantName tenant..."
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Organization.Read.All" -TenantId $TenantID -NoWelcome
        Write-Log "Successfully connected to Microsoft Graph for $TenantName tenant" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph for $TenantName tenant: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Function to get source mailbox data
function Get-SourceMailboxData {
    param([string]$SourceUPN)
    
    try {
        $mailbox = Get-Mailbox -Identity $SourceUPN -ErrorAction Stop
        
        $mailboxData = @{
            SourceUPN = $SourceUPN
            DisplayName = $mailbox.DisplayName
            FirstName = $mailbox.FirstName
            LastName = $mailbox.LastName
            ExchangeGuid = $mailbox.ExchangeGuid
            LegacyExchangeDN = $mailbox.LegacyExchangeDN
            EmailAddresses = $mailbox.EmailAddresses
            SMTPAliases = ($mailbox.EmailAddresses | Where-Object { $_.StartsWith('smtp:') })  # Case-sensitive; only lowercase matches
            X500Aliases = ($mailbox.EmailAddresses | Where-Object { $_ -like "X500:*" })
            Username = $SourceUPN.Split('@')[0]
        }
        
        Write-Log "Successfully retrieved data for $SourceUPN" -Level "SUCCESS"
        return $mailboxData
    }
    catch {
        Write-Log "Failed to retrieve data for $SourceUPN`: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

# Function to add user to migration group
function Add-UserToMigrationGroup {
    param(
        [string]$UserUPN,
        [string]$GroupName
    )
    
    try {
        Add-DistributionGroupMember -Identity $GroupName -Member $UserUPN -ErrorAction Stop
        Write-Log "Successfully added $UserUPN to migration group $GroupName" -Level "SUCCESS"
        return $true
    }
    catch {
        if ($_.Exception.Message -like "*already a member*") {
            Write-Log "User $UserUPN is already a member of $GroupName" -Level "WARNING"
            return $true
        }
        else {
            Write-Log "Failed to add $UserUPN to migration group $GroupName`: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
}

# Function to create mail user in target tenant
function New-TargetMailUser {
    param(
        [hashtable]$SourceData,
        [string]$TargetUPN,
        [SecureString]$Password
    )

    # Replace SourceCompany domains with TargetCompany domains on smtp aliases
    $Target
    
    try {
        # Step 1: Create MailUser
        $mailUser = New-MailUser `
            -Name $SourceData.DisplayName `
            -Alias  $SourceData.Username`
            -MicrosoftOnlineServicesID $TargetUPN `
            -ExternalEmailAddress $SourceData.SourceUPN `
            -FirstName $SourceData.FirstName `
            -LastName $SourceData.LastName `
            -DisplayName $SourceData.DisplayName `
            -Password $Password `
            -ErrorAction Stop

        Write-Log "Successfully created mail user $TargetUPN" -Level "SUCCESS"
        
        # Step 2: Set Exchange Guid and LegacyExchangeDN
        if ($SourceData.ExchangeGuid) {
            Set-MailUser -Identity $TargetUPN -ExchangeGuid $SourceData.ExchangeGuid -ErrorAction Stop
        }
        if ($SourceData.LegacyExchangeDN) {
            Set-MailUser -Identity $TargetUPN -EmailAddresses @{Add="X500:$($SourceData.LegacyExchangeDN)"} -ErrorAction Stop
        }

        # Step 3: Add smtp and X500 aliases as previously discussed
        foreach ($alias in $SourceData.SMTPAliases) {
            try { Set-MailUser -Identity $TargetUPN -EmailAddresses @{Add = $alias} -ErrorAction Stop }
            catch { Write-Log "There was an issue when trying to add SMTP alias $alias to mail user $TargetUPN`: $($_.Exception.Message)" -Level "WARNING" }
        }
        foreach ($x500 in $SourceData.X500Aliases) {
            Set-MailUser -Identity $TargetUPN -EmailAddresses @{Add = $x500} -ErrorAction Stop
        }
        # Add .onmicrosoft.com alias to MailUser
        Set-MailUser -Identity $TargetUPN -EmailAddresses @{Add = "smtp:$($SourceData.Username)@$($TargetDeliveryDomain)"}
        return $true
    }
    catch {
        Write-Log "Failed to create mail user $TargetUPN`: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Function to assign licenses
function Set-UserLicense {
    param(
        [string]$UserUPN
    )

    # Wait for user account to propagate
    Write-Log "Waiting 30 seconds for user account $UserUPN to propagate to Entra fully before assigning licenses..." -Level "INFO"
    Start-Sleep -Seconds 30
    
    try {

        # Add Usage Location to allow for license assignment
        Update-MgUser -UserId $UserUPN -UsageLocation "US"
        $user = Get-MgUser -UserId $UserUPN -Property UsageLocation
        Write-Log "Set UsageLocation for $UserUPN to: $($user.UsageLocation)"

        # Get available licenses
        $licenses = Get-MgSubscribedSku -All
        
        # Find Cross-Tenant Migration license
        $crossTenantLicense = $licenses | Where-Object { $_.SkuPartNumber -like "*CROSS*TENANT*" -or $_.SkuPartNumber -like "*MIGRATION*" }
        
        $licensesToAssign = @()
        
        # Add Cross-Tenant Migration license
        if ($crossTenantLicense) {
            $licensesToAssign += @{SkuId = $crossTenantLicense.SkuId}
            Write-Log "Adding Cross-Tenant Migration license to $UserUPN" -Level "INFO"
        }
        else {
            Write-Log "Cross-Tenant Migration license not found in tenant" -Level "ERROR"
        }
        
        # Assign licenses
        if ($licensesToAssign.Count -gt 0) {
            Set-MgUserLicense -UserId $UserUPN -AddLicenses $licensesToAssign -RemoveLicenses @() -ErrorAction Stop
            Write-Log "Successfully assigned licenses to $UserUPN" -Level "SUCCESS"
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to assign licenses to $UserUPN`: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Function to create migration batch
function New-CrossTenantMigrationBatch {
    param(
        [string]$SourceEndpointName,
        [array]$UsersToMigrate,
        [string]$BatchName,
        [string]$TargetDeliveryDomain
    )
    
    try {
        # Create CSV data for migration batch
        $csvData = "EmailAddress`r`n"
        foreach ($user in $UsersToMigrate) {
            $csvData += "$($user.TargetUPN)`r`n"
        }
        
        # Convert to byte array
        $csvBytes = [System.Text.Encoding]::UTF8.GetBytes($csvData)
        
        # Create migration batch
        $batch = New-MigrationBatch -Name $BatchName -SourceEndpoint $SourceEndpointName -CSVData $csvBytes -TargetDeliveryDomain $TargetDeliveryDomain -ErrorAction Stop
        
        Write-Log "Successfully created migration batch: $BatchName" -Level "SUCCESS"
        return $batch
    }
    catch {
        Write-Log "Failed to create migration batch: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

# Function to create identity mapping file for OneDrive migration
function New-OneDriveIdentityMappingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CSVFilePath,
        [Parameter(Mandatory = $true)]
        [string]$SourceTenantId,
        [Parameter(Mandatory = $true)]
        [string]$TargetTenantId,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    try {
        # Load user mappings from original CSV
        $userMappings = Import-Csv -Path $CSVFilePath
        
        # Create identity mapping entries (no headers as per Microsoft requirements)
        $identityMappingEntries = @()
        
        foreach ($mapping in $userMappings) {
            $sourceUPN = $mapping.SourceUPN
            $targetUPN = $mapping.TargetUPN
            
            # Create identity mapping entry for each user
            # Format: User, SourceTenantCompanyID, SourceUserUpn, TargetUserUpn, TargetUserEmail, UserType
            $identityMappingEntries += @(
                "User",
                $SourceTenantId,
                $sourceUPN,
                $targetUPN,
                $targetUPN,
                "RegularUser"
            ) -join ","
        }
        
        # Write to CSV file without headers
        $identityMappingEntries | Out-File -FilePath $OutputPath -Encoding UTF8
        
        Write-Log "Identity mapping file created at: $OutputPath" -Level "SUCCESS"
        Write-Log "Total users in mapping file: $($userMappings.Count)" -Level "INFO"
        
        return $true
    }
    catch {
        Write-Log "Failed to create identity mapping file: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Test-URL {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $false)]
        [string]$UrlName = "URL"
    )
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Head -ErrorAction Stop
            if ($response.StatusCode -eq 200) { Write-Log "$($UrlName) is reachable" -Level "SUCCESS" } 
            else {
                Write-Log "URL was unreachable and responded with: $($response)" -Level "WARNING"
                while ($response.StatusCode -ne 200) {
                    Write-Log "URL response: $($response.StatusCode)" -Level "Wanring"
                    $Url = Read-Host -Prompt "Enter a new $($UrlName) to retry or press CTRL+C to exit..."
                    Write-Log "Retrying connection to $($UrlName): $Url" -Level "INFO"
                    $response = Invoke-WebRequest -Uri $Url -Method Head -ErrorAction Stop
                }
            }
        } catch {
            Write-Host "$($UrlName) is not reachable: $($_.Exception.Message)"
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
    
#endregion FUNCTIONS

#region MAIN SCRIPT LOGIC
# Main script execution


try {
    cls    
    Write-Log "`n`n======= Starting Cross-Tenant Migration Script... =======`n" -Level "SUCCESS"
    Write-Log "Script Parameters:"
    Write-Log "- CSV File: $CSVFilePath"
    Write-Log "- Migration Group: $MigrationGroupName"
    Write-Log "- Source Tenant Admin: $SourceTenantAdminUPN"
    Write-Log "- Target Tenant Admin: $TargetTenantAdminUPN"
    if($TargetDeliveryDomain) {Write-Log "- Target Delivery Domain: $TargetDeliveryDomain"} else {Write-Log "- Target Delivery Domain: Not specified, will pull from Target Tenant"}
    if($SourceOnMicrosoftDomain) {Write-Log "- Target Delivery Domain: $SourceOnMicrosoftDomain"}
    if($SourceDefaultDomain) {Write-Log "- Target Delivery Domain: $SourceDefaultDomain"}
    if($TargetOnMicrosoftDomain) {Write-Log "- Target Delivery Domain: $TargetOnMicrosoftDomain"}
    if($TargetDefaultDomain) {Write-Log "- Target Delivery Domain: $TargetDefaultDomain"}
    Write-Log "- Batch Name: $BatchName"
    
    # Validate CSV file exists
    if (-not (Test-Path $CSVFilePath)) {
        throw "CSV file not found: $CSVFilePath"
    }
    
    # Import CSV data
    Write-Log "Importing CSV data from $CSVFilePath"
    $migrationUsers = Import-Csv $CSVFilePath
    
    if (-not $migrationUsers -or $migrationUsers.Count -eq 0) {
        throw "No users found in CSV file or CSV file is empty"
    }
    
    # Validate CSV headers
    $requiredHeaders = @("SourceUPN", "TargetUPN")
    $csvHeaders = $migrationUsers[0].PSObject.Properties.Name
    
    foreach ($header in $requiredHeaders) {
        if ($header -notin $csvHeaders) {
            throw "Required CSV header '$header' not found. Required headers: $($requiredHeaders -join ', ')"
        }
    }
    
    Write-Log "Found $($migrationUsers.Count) users to migrate" -Level "SUCCESS"
    
    # Generate default password if not provided
    if (-not $DefaultPassword) {
        $generatedPassword = New-RandomSecureStringPassword -Length 16
        $DefaultPassword = ConvertTo-SecureString $generatedPassword -AsPlainText -Force
        Write-Log "Generated random password for mail users: $generatedPassword" -Level "WARNING"
    }
    else {
        $generatedPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($DefaultPassword))
    }
    
    # Always check Exchange Online, SharePoint, and Graph modules for mailbox migrations
    Ensure-Module -ModuleName "ExchangeOnlineManagement" -RequiredVersion "3.6.0" # As of 07/16/2025, this version is more stable. Current version has connection issues.
    Ensure-Module -ModuleName "Microsoft.Graph.Authentication"
    Ensure-Module -ModuleName "Microsoft.Graph.Users"
    Ensure-Module -ModuleName "Microsoft.Graph.Identity.DirectoryManagement"
    Ensure-Module -ModuleName "Microsoft.Graph.Files"
    Ensure-Module -ModuleName "Microsoft.Graph.Users.Actions"
    Ensure-Module -ModuleName "Microsoft.Online.SharePoint.PowerShell"
    Write-Log "Modules checked and imported." -Level "SUCCESS"

    # Initialize collections
    $sourceMailboxData = @{}
    $migrationResults = @()
    $successfulUsers = @()
    
    #region PHASE 1 - SOURCE EXCHANGE
    # === PHASE 1: CONNECT TO SOURCE TENANT AND GATHER DATA ===
    Write-Log "`n`n=== PHASE 1: CONNECTING TO SOURCE TENANT AND GATHERING DATA ===`n" -Level "SUCCESS"
    
    if (-not (Connect-ExchangeOnlineTenant -TenantAdmin $SourceTenantAdminUPN -TenantName "Source")) {
        throw "Failed to connect to source tenant Exchange Online"
    }

    # Get source tenant ID
    $SourceTenantID = Get-ConnectionInformation | Select TenantID | Select-Object -ExpandProperty TenantId
    # Get Source .onmicrosoft.com domain
    if(-not $SourceOnMicrosoftDomain) {$SourceOnMicrosoftDomain = (Get-AcceptedDomain | Select-Object -ExpandProperty OrganizationalUnitRoot)[0]}
    # Get Source default domain
    if(-not $SourceDefaultDomain) {$SourceDefaultDomain = (Get-AcceptedDomain | Select-Object -ExpandProperty Name)[0]}

    # Gather source mailbox data
    Write-Log "Gathering source mailbox data..."
    foreach ($user in $migrationUsers) {
        $sourceData = Get-SourceMailboxData -SourceUPN $user.SourceUPN
        if ($sourceData) {
            $sourceMailboxData[$user.SourceUPN] = $sourceData
            Write-Log "Collected data for $($user.SourceUPN)" -Level "SUCCESS"
        }
        else {
            Write-Log "Failed to collect data for $($user.SourceUPN)" -Level "WARNING"
            Write-Log "Skipping user $($user.SourceUPN) for mailbox migration due to missing data" -Level "WARNING"
        }
    }
    
    # Add users to migration group
    Write-Log "Adding users to migration group: $MigrationGroupName"
    foreach ($user in $migrationUsers) {
        if ($sourceMailboxData.ContainsKey($user.SourceUPN)) {
            Add-UserToMigrationGroup -UserUPN $user.SourceUPN -GroupName $MigrationGroupName
        }
    }
    
    # Disconnect from source tenant
    Write-Log "Disconnecting from source tenant..."
    Disconnect-ExchangeOnline -Confirm:$false
    #endregion PHASE 1

    #region PHASE 2 - CREATE MAIL USERS
    # === PHASE 2: CONNECT TO TARGET TENANT AND CREATE MAIL USERS ===
    Write-Log "`n`n=== PHASE 2: CONNECTING TO TARGET TENANT AND CREATING MAIL USERS ===`n" -Level "SUCCESS"
    
    if (-not (Connect-ExchangeOnlineTenant -TenantAdmin $TargetTenantAdminUPN -TenantName "Target" -TenantId $TargetTenantID)) {
        Write-Log "Failed to connect to target tenant Exchange Online. `n$_" -Level "ERROR"
    }
    
    # Get target tenant ID
    $TargetTenantID = Get-ConnectionInformation | Select TenantID | Select-Object -ExpandProperty TenantId
    # Get Target .onmicrosoft.com domain
    if(-not $TargetOnMicrosoftDomain) {$TargetOnMicrosoftDomain = (Get-AcceptedDomain | Select-Object -ExpandProperty OrganizationalUnitRoot)[0]}
    # Get Target default domain
    if(-not $TargetDefaultDomain) {$TargetDefaultDomain = (Get-AcceptedDomain | Select-Object -ExpandProperty Name)[0]}
    # Set TargetDeliveryDomain if not provided
    if (-not $TargetDeliveryDomain) {$TargetDeliveryDomain = $TargetOnMicrosoftDomain}

    if (-not (Connect-MicrosoftGraphTenant -TenantAdmin $TargetTenantAdminUPN -TenantName "Target" -TenantID $TargetTenantID)) {
        Write-Log "Failed to connect to target tenant Microsoft Graph: `n$_" -Level "ERROR"
    }
    
    # Create mail users in target tenant
    Write-Log "Creating mail users in target tenant..."
    foreach ($user in $migrationUsers) {
        if ($sourceMailboxData.ContainsKey($user.SourceUPN)) {
            # Check if TargetUPN is already taken
            $upnTaken = $false
            try {
                $existingUser = Get-MailUser -Identity $user.TargetUPN -ErrorAction SilentlyContinue
                if ($existingUser) { $upnTaken = $true }
            } catch {}
            # If not taken, create the mail user
            if (-not $upnTaken) {
                # Clean up source data
                $MailUserAlias = $user.SourceUPN.Split('@')[0]

                # Replace all smtp aliases with the target domain
                $SourceData = Get-SourceMailboxData -SourceUPN $user.SourceUPN
                # Replace any domain after @ with $TargetDefaultDomain
                $SourceData.SMTPAliases = $SourceData.SMTPAliases | ForEach-Object {
                    if ($_ -match "^smtp:(.+)@.+$") {
                        $localPart = $Matches[1]
                        "smtp:$localPart@$TargetDefaultDomain"
                    } else {
                        $_
                    }
                }

                $success = New-TargetMailUser -SourceData $sourceMailboxData[$user.SourceUPN] -TargetUPN $user.TargetUPN -Password $generatedPassword
                if ($success) {
                    $successfulUsers += $user
                    $migrationResults += [PSCustomObject]@{
                        SourceUPN = $user.SourceUPN
                        TargetUPN = $user.TargetUPN
                        Status = "Success"
                        Error = ""
                    }
                } else {
                    $migrationResults += [PSCustomObject]@{
                        SourceUPN = $user.SourceUPN
                        TargetUPN = $user.TargetUPN
                        Status = "Failed"
                        Error = "Failed to create mail user"
                    }
                }
            } else {
                # Collect taken UPNs for reporting
                if (-not $script:takenUPNs) { $script:takenUPNs = @() }
                $script:takenUPNs += $user.TargetUPN
                $migrationResults += [PSCustomObject]@{
                    SourceUPN = $user.SourceUPN
                    TargetUPN = $user.TargetUPN
                    Status = "Failed"
                    Error = "TargetUPN already exists"
                }
            }
        }
        else {
            $migrationResults += [PSCustomObject]@{
                SourceUPN = $user.SourceUPN
                TargetUPN = $user.TargetUPN
                Status = "Failed"
                Error = "Source mailbox data not found"
            }
        }
    }

    # If any TargetUPNs are taken, log and exit
    if ($script:takenUPNs -and $script:takenUPNs.Count -gt 0) {
        Write-Log "The following TargetUPNs are already taken and cannot be used:" -Level "WARNING"
        foreach ($upn in $script:takenUPNs) {
            Write-Log "  $upn" -Level "ERROR"
        }
        Write-Log "Exiting script due to duplicate TargetUPNs." -Level "ERROR"
        exit 1
    }
    #endregion PHASE 2

    #region PHASE 3 - MAILBOX MIGRATION
    # === PHASE 3: MAILBOX MIGRATION BATCH CREATION ===
    Write-Log "`n`n=== PHASE 3: MAILBOX MIGRATION BATCH CREATION ===`n" -Level "SUCCESS"
    
    if ($successfulUsers.Count -gt 0) {
        # Display migration summary
        Write-Log "Migration Summary:" -Level "SUCCESS"
        Write-Log "Total Users to Migrate: $($migrationUsers.Count)"
        Write-Log "Successfully Prepared Users: $($successfulUsers.Count)"
        Write-Log "Failed Users: $($migrationUsers.Count - $successfulUsers.Count)"
        
        Write-Log "`nUsers to be migrated:" -Level "SUCCESS"
        foreach ($user in $successfulUsers) {
            Write-Log "  $($user.SourceUPN) -> $($user.TargetUPN)"
        }
        
        # Confirmation prompt
        Write-Log "`nReady to start migration batch." -Level "WARNING"
        $confirmation = Read-Host "Do you want to proceed with creating and starting the migration batch? (y/N)"
        
        if ($confirmation -eq 'y' -or $confirmation -eq 'Y') {
            # Create migration batch
            $batch = New-CrossTenantMigrationBatch -SourceEndpointName $SourceEndpointName -UsersToMigrate $successfulUsers -BatchName $BatchName -TargetDeliveryDomain $TargetDeliveryDomain -
            
            if ($batch) {
                Write-Log "Migration batch '$BatchName' created successfully" -Level "SUCCESS"
                Write-Log "Batch Status: $($batch.Status)"
                Write-Log "Total Count: $($batch.TotalCount)"
                
                # Start migration batch
                try {
                    Start-MigrationBatch -Identity $BatchName -ErrorAction Stop
                    Write-Log "Migration batch '$BatchName' started successfully" -Level "SUCCESS"
                    # Export migrated users' EmailAddresses to CSV in log directory
                    $emailExport = @()
                    foreach ($user in $successfulUsers) {
                        if ($sourceMailboxData.ContainsKey($user.SourceUPN)) {
                            $mailbox = $sourceMailboxData[$user.SourceUPN]
                            foreach ($address in $mailbox.EmailAddresses) {
                                $emailExport += [PSCustomObject]@{
                                    SourceUPN = $user.SourceUPN
                                    TargetUPN = $user.TargetUPN
                                    EmailAddress = $address
                                }
                            }
                        }
                    }
                    $emailExportPath = Join-Path $LogDirectory "MigratedUsers_EmailAddresses_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                    $emailExport | Export-Csv -Path $emailExportPath -NoTypeInformation
                    Write-Log "Exported migrated users' EmailAddresses to: $emailExportPath" -Level "SUCCESS"
                }
                catch {
                    Write-Log "Failed to start migration batch: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        }
        else {
            Write-Log "Migration batch creation cancelled by user" -Level "WARNING"
        }
    }
    else {
        Write-Log "No users were successfully prepared for migration" -Level "ERROR"
    }
    #endregion PHASE 3

    #region PHASE 4 - ONEDRIVE
    # === PHASE 4: ONEDRIVE MIGRATION BATCH CREATION ===
    Write-Log "`n`n=== PHASE 4: ONEDRIVE MIGRATION BATCH CREATION ===`n" -Level "SUCCESS"

    # Disconnect from target tenant and connect to source tenant for OneDrive migration
    Write-Log "Disconnecting from target tenant and preparing for OneDrive migration..." -Level "INFO"
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Disconnect-MgGraph -ErrorAction SilentlyContinue

    #region STEP 1
    # Step 1: Validate SPO URLs
    Test-URL -Url $SourceAdminSPOUrl -UrlName "Source Admin SharePoint Online URL"
    Test-URL -Url $TargetSPOURL -UrlName "Target SharePoint OnlineURL"
    #endregion STEP 1

    #region STEP 2
    # Step 2: Create Identity Mapping File
    Write-Log "Creating identity mapping file for OneDrive migration..." -Level "INFO"

    # Create identity mapping file
    $identityMappingPath = "$($LogDirectory)\OneDriveIdentityMapping_$(Get-Date -Format 'yyyyMMdd').csv"
    $mappingCreated = New-OneDriveIdentityMappingFile -CSVFilePath $CSVFilePath -SourceTenantId $SourceTenantID -TargetTenantId $TargetTenantID -OutputPath $identityMappingPath

    if (-not $mappingCreated) {
        Write-Log "Failed to create identity mapping file. Cannot proceed with OneDrive migration." -Level "ERROR"
        return
    }
    #endregion STEP 2

    #region STEP 3
    # Step 3: Connect to TARGET tenant SharePoint Online to upload identity mapping
    Write-Log "Connecting to TARGET tenant SharePoint Online to upload identity mapping..." -Level "INFO"
    try {
        Connect-SPOService -Url $TargetSPOURL -ErrorAction Stop
        Write-Log "Successfully connected to target tenant SharePoint Online" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to connect to target tenant SharePoint Online: $($_.Exception.Message)" -Level "ERROR"
        return
    }
    #endregion STEP 3

    #region STEP 4
    # Step 4: Upload identity mapping file to TARGET tenant
    Write-Log "Uploading identity mapping file to target tenant..." -Level "INFO"
    try {
        Add-SPOTenantIdentityMap -IdentityMapPath $identityMappingPath -ErrorAction Stop
        Write-Log "Successfully uploaded identity mapping file to target tenant" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to upload identity mapping file: $($_.Exception.Message)" -Level "ERROR"
        return
    }
    #endregion STEP 4

    #region STEP 5
    # Step 5: Get target tenant cross-tenant host URL
    Write-Log "Retrieving target tenant cross-tenant host URL..." -Level "INFO"
    try {
        $hostUrlOutput = Get-SPOCrossTenantHostUrl -ErrorAction Stop
        # Extract URL using regex pattern
        if ($hostUrlOutput -match "https://[^\s]+") {
            $TargetCrossTenantHostUrl = $matches[0]
            Write-Log "Successfully extracted target cross-tenant host URL: $TargetCrossTenantHostUrl" -Level "SUCCESS"
        } else {
            throw "Could not extract URL from Get-SPOCrossTenantHostUrl output"
        }
        Write-Log "Target cross-tenant host URL: $TargetCrossTenantHostUrl" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to retrieve target tenant host URL: $($_.Exception.Message)" -Level "ERROR"
        return
    }
    #endregion STEP 5

    #region STEP 6
    # Step 6: Connect to SOURCE tenant SharePoint Online for migration initiation
    Write-Log "Connecting to SOURCE tenant SharePoint Online for migration initiation..." -Level "INFO"
    try {
        Connect-SPOService -Url $SourceSPOURL -ErrorAction Stop
        Write-Log "Successfully connected to source tenant SharePoint Online" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to connect to source tenant SharePoint Online: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # Verify cross-tenant compatibility status
    Write-Log "Verifying cross-tenant compatibility status..." -Level "INFO"
    try {
        $compatibilityStatus = Get-SPOCrossTenantCompatibilityStatus -PartnerCrossTenantHostURL $TargetCrossTenantHostUrl -ErrorAction Stop
        
        if ($compatibilityStatus -eq "Compatible") { Write-Log "Cross-tenant compatibility status: $compatibilityStatus - Migration can proceed" -Level "SUCCESS"}
        elseif ($compatibilityStatus -eq "Warning") { Write-Log "Cross-tenant compatibility status: $compatibilityStatus - Migration has issues, but can proceed" -Level "WARNING"}
        else {
            Write-Log "Cross-tenant compatibility status: $compatibilityStatus - Migration cannot proceed" -Level "ERROR"
            return
        }
    }
    catch {
        Write-Log "Failed to verify compatibility status: $($_.Exception.Message)" -Level "ERROR"
        return
    }
    #endregion STEP 6

    #region STEP 7
    # Step 7: Process each user for OneDrive migration

    # Initialize OneDrive migration tracking
    $oneDriveMigrationResults = @()
    $successfulOneDriveMigrations = 0
    $failedOneDriveMigrations = 0

    Write-Log "Starting OneDrive cross-tenant migrations..." -Level "INFO"

    foreach ($user in $migrationUsers) {
        $SourceUserUPN = $user.SourceUPN
        $TargetUserUPN = $user.TargetUPN
        
        try {
            Write-Log "Initiating OneDrive migration for $SourceUserUPN -> $TargetUserUPN" -Level "INFO"
            
            # Start OneDrive cross-tenant migration (initiated from SOURCE tenant)
            Start-SPOCrossTenantUserContentMove `
                -SourceUserPrincipalName $SourceUserUPN `
                -TargetUserPrincipalName $TargetUserUPN `
                -TargetCrossTenantHostUrl $TargetCrossTenantHostUrl `
                -ErrorAction Stop
            
            Write-Log "Successfully initiated OneDrive migration for $SourceUserUPN" -Level "SUCCESS"
            $successfulOneDriveMigrations++
            
            $oneDriveMigrationResults += [PSCustomObject]@{
                SourceUPN = $SourceUserUPN
                TargetUPN = $TargetUserUPN
                Status = "Migration Initiated"
                Error = ""
                Timestamp = Get-Date
            }
            
            # Small delay to avoid throttling
            Start-Sleep -Seconds 2
        }
        catch {
            Write-Log "Failed to initiate OneDrive migration for $SourceUserUPN`: $($_.Exception.Message)" -Level "WARNING"
            Write-Log "Skipping user $SourceUserUPN for OneDrive migration" -Level "WARNING"
            Write-Log "Does the user have a OneDrive site?" -Level "WARNING"
            $failedOneDriveMigrations++
            
            $oneDriveMigrationResults += [PSCustomObject]@{
                SourceUPN = $SourceUserUPN
                TargetUPN = $TargetUserUPN
                Status = "Migration Failed"
                Error = $_.Exception.Message
                Timestamp = Get-Date
            }
        }
    }
    #endregion STEP 7

    #region STEP 8
    # Step 8: Display migration summary
    Write-Log "OneDrive Migration Summary:" -Level "SUCCESS"
    Write-Log "Total Users Processed: $($migrationUsers.Count)" -Level "INFO"
    Write-Log "Successful Migration Initiations: $successfulOneDriveMigrations" -Level "SUCCESS"
    Write-Log "Failed Migration Initiations: $failedOneDriveMigrations" -Level "ERROR"
    #endregion STEP 8

    #region STEP 9
    # Step 9: Export results and provide monitoring guidance
    $oneDriveReportPath = "$($LogDirectory)\OneDriveMigration_Results_$(Get-Date -Format 'yyyyMMdd').csv"
    $oneDriveMigrationResults | Export-Csv -Path $oneDriveReportPath -NoTypeInformation
    Write-Log "OneDrive migration results exported to: $oneDriveReportPath" -Level "SUCCESS"
    #endregion STEP 9

    #region STEP 10
    # Step 10: Provide monitoring instructions
    Write-Log "OneDrive Migration Monitoring Instructions:" -Level "INFO"
    Write-Log "To check individual user migration status, use:" -Level "INFO"
    Write-Log "Get-SPOCrossTenantUserContentMoveState -PartnerCrossTenantHostURL '$TargetCrossTenantHostUrl' -SourceUserPrincipalName 'user@example.com'" -Level "INFO"
    Write-Log "Identity mapping file location: $identityMappingPath" -Level "INFO"

    <# # Optional: Check status for a few sample users
    if ($successfulOneDriveMigrations -gt 0) {
        Write-Log "Checking initial migration status for sample users..." -Level "INFO"
        Start-Sleep -Seconds 30
        
        $sampleUsers = $migrationUsers | Select-Object -First 3
        foreach ($user in $sampleUsers) {
            try {
                $migrationStatus = Get-SPOCrossTenantUserContentMoveState `
                    -PartnerCrossTenantHostURL $TargetCrossTenantHostUrl `
                    -SourceUserPrincipalName $user.SourceUPN `
                    -ErrorAction SilentlyContinue
                
                if ($migrationStatus) {
                    Write-Log "Migration status for $($user.SourceUPN): $($migrationStatus.Status)" -Level "INFO"
                }
            }
            catch {
                Write-Log "Could not retrieve status for $($user.SourceUPN): $($_.Exception.Message)" -Level "WARNING"
            }
        }
    }
        #>
    #endregion STEP 10

    Write-Log "=== PHASE 4: ONEDRIVE CROSS-TENANT MIGRATION COMPLETED ===" -Level "SUCCESS"


    #endregion PHASE 4

    #region PHASE 5 - CLEANUP
    # === PHASE 5: CLEANUP & REPORT GENERATION ===
    Write-Log "`n`n=== PHASE 5: CLEANUP & REPORT GENERATION ===`n" -Level "SUCCESS"
    
    # Generate final report
    $reportPath = "C:\Reports\CrossTenantMigration_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $reportDir = Split-Path $reportPath -Parent
    
    if (-not (Test-Path $reportDir)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }
    
    $migrationResults | Export-Csv -Path $reportPath -NoTypeInformation
    Write-Log "Migration report exported to: $reportPath" -Level "SUCCESS"
    
    Write-Log "`n=== CROSS-TENANT MIGRATION SCRIPT COMPLETED ===" -Level "SUCCESS"
}
#endregion PHASE 5
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
}
finally {
    # Cleanup connections
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    }
    catch {
        # Ignore cleanup errors
    }
    
    Write-Log "Script execution completed. Check logs at:"
    Write-Log "- Main Log: $LogPath"
    Write-Log "- Error Log: $ErrorLogPath"
}
#endregion MAIN SCRIPT LOGIC