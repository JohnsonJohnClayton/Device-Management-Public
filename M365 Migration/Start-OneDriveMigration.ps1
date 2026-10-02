<#
.SYNOPSIS
    Source-Target Cross-Tenant Mailbox and OneDrive Migration Automation Script

.DESCRIPTION
    This script automates the end-to-end process for Microsoft 365 cross-tenant mailbox and OneDrive migrations specifcally for the Source-Target Migration.
    It performs:
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

.PARAMETER SourceTenantAdminUPN
    UPN of the source tenant administrator.

.PARAMETER TargetTenantAdminUPN
    UPN of the target tenant administrator.

.PARAMETER SourceSPOURL
    Admin SharePoint Online URL for the source tenant (for OneDrive migration).

.PARAMETER TargetSPOURL
    Admin SharePoint Online URL for the target tenant (for OneDrive migration).

.PARAMETER LogDirectory
    Directory where logs and reports will be saved (default: "$PSScriptRoot\MigrationLogs").

.EXAMPLE


.NOTES
    Author: John Johnson
    Version: 3.0
    Last Updated: 07/22/2025
    Requirements: Microsoft Graph PowerShell, Microsoft SharePoint Online PowerShell
    Sources:
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
    [string]$SourceTenantAdminUPN,
    
    [Parameter(Mandatory = $true)]
    [string]$TargetTenantAdminUPN,

    [Parameter(Mandatory)]
    [string]$SourceSPOURL,
    
    [Parameter(Mandatory)]
    [string]$TargetSPOURL,

    [parameter(Mandatory = $false)]
    [string]$SourceTenantID = "[sourceTenantID]",

    [parameter(Mandatory = $false)]
    [string]$TargetTenantID = "[targetTenantID]",

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
$LogPath = Join-Path $LogDirectory "OneDrive-CrossTenantMigration_$(Get-Date -Format 'yyyyMMdd').log"
$ErrorLogPath = Join-Path $LogDirectory "OneDrive-CrossTenantMigration_Errors_$(Get-Date -Format 'yyyyMMdd').log"


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
    }
}
# Function to connect to Microsoft Graph
function Connect-MicrosoftGraphTenant {
    param(
        [Parameter (Mandatory = $true)]
        [string]$TenantName,
        [string]$TenantID
    )
    
    try {
        Write-Log "Connecting to Microsoft Graph for $TenantName tenant..."
        if($TenantID) { Connect-MgGraph -Scopes "User.ReadWrite.All", "Organization.Read.All" -TenantId $TenantID -NoWelcome }
        else { Connect-MgGraph -Scopes "User.ReadWrite.All", "Organization.Read.All" -NoWelcome }
        Write-Log "Successfully connected to Microsoft Graph for $TenantName tenant" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph for $TenantName tenant: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
} 
# Function to assign licenses
function Set-UserLicense {
    param(
        [Parameter (Mandatory = $true)]
        [string]$UserUPN
    )

    try {
        # Add Usage Location to allow for license assignment
        Update-MgUser -UserId $UserUPN -UsageLocation "US"
        $user = Get-MgUser -UserId $UserUPN -Select "UsageLocation"
        Write-Log "Set UsageLocation for $UserUPN to: $($user.UsageLocation)" -Level "INFO"

        # Find Cross-Tenant Migration license (expecting single match)
        $crossTenantLicense = Get-MgSubscribedSku -All | Where-Object { $_.SkuPartNumber -like "*CROSS*TENANT*" -or $_.SkuPartNumber -like "*MIGRATION*" } |Select-Object -First 1

        if (-not $crossTenantLicense) {
            Write-Log "Cross-Tenant Migration license not found in tenant" -Level "ERROR"
            return $false
        }
        
        # Check if user already has the license assigned
        $userLicenses = Get-MgUserLicenseDetail -UserId $UserUPN
        if ($userLicenses.SkuId -contains $crossTenantLicense.SkuId) {
            Write-Log "User $UserUPN already has the Cross-Tenant license assigned. Skipping." -Level "WARNING"
            return $true
        } else {
            # Prepare license assignment
            $licensesToAssign = @(@{ SkuId = $crossTenantLicense.SkuId })
    
            # Assign license to user
            Set-MgUserLicense -UserId $UserUPN -AddLicenses $licensesToAssign -RemoveLicenses @() -ErrorAction Stop
    
            Write-Log "Successfully assigned Cross-Tenant Migration license to $UserUPN" -Level "SUCCESS"
            return $true
        }
    }
    catch {
        Write-Log "Failed to assign licenses to $UserUPN`: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}
# Function to test SPO migration URLs
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
# Check and install required modules
function Enable-Module {
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

try {
    Clear-Host    
    Write-Log "`n`n======= Starting Cross-Tenant OneDrive Migration Script... =======`n" -Level "SUCCESS"
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

    # Validate Sharepoint URLs
    Test-URL -Url $SourceSPOUrl -UrlName "Source Admin SharePoint Online URL"
    Test-URL -Url $TargetSPOURL -UrlName "Target SharePoint OnlineURL"

    # Check SharePoint and Graph modules for mailbox migrations
    Enable-Module -ModuleName "Microsoft.Graph.Authentication"
    Enable-Module -ModuleName "Microsoft.Graph.Users"
    Enable-Module -ModuleName "Microsoft.Graph.Identity.DirectoryManagement"
    Enable-Module -ModuleName "Microsoft.Graph.Files"
    Enable-Module -ModuleName "Microsoft.Graph.Users.Actions"
    Enable-Module -ModuleName "Microsoft.Online.SharePoint.PowerShell"
    Write-Log "Modules checked and imported." -Level "SUCCESS"

    # Initialize collections
    $sourceOneDriveData = @{}
    $migrationResults = @()
    $successfulUsers = @()
    
    #region PHASE 1 - CHECK TARGET UPNS
    # === PHASE 1: CONNECT TO TARGET TENANT AND CHECK TARGET UPNs ===

    Write-Log "`n`n=== PHASE 1: CONNECTING TO TARGET TENANT AND CHECKING TARGET UPNs ===`n" -Level "SUCCESS"    
    
    Connect-MicrosoftGraphTenant -TenantName "Target" -TenantID $TargetTenantID

    # Check for matching accounts with TargetUPNs
    Write-Log "`nNow checking for matching Entra accounts against TargetUPNs..."
    $errorResults = @()
    foreach ($upn in $migrationUsers.TargetUPN) {
        try {
            $user = Get-MgUser -UserId $upn -ErrorAction Stop
            if ($user.AccountEnabled -eq $false) {
                # User is disabled, log as error
                $errorResults += [PSCustomObject]@{
                    UPN    = $upn
                    Status = "Disabled"
                }
            } else {
                Write-Log "User found for $($upn): $($user)" -Level "SUCCESS"
                Write-Log "Checking for cross-tenant user data migration license..."

            }
        }
        catch {
            # User not found error, log as error
            Write-Log "Issue with $upn. Either an account was not found or it was disabled" -Level "ERROR"
            $errorResults += [PSCustomObject]@{
                UPN    = $upn
                Status = "Not Found"
            }
        }
    }
    # Error out if errors are found
    if ($errorResults.Count -gt 0) {
        $exportPath = "$($LogDirectory)\UPN_Check_Errors.csv"
        $errorResults | Export-Csv -Path $exportPath -NoTypeInformation
        Write-Log "Errors found for some UPNs. Errors exported to $exportPath" -Level "ERROR"
        Write-Log "In order to migrate OneDrive sites, the user must have a valid M365/Entra user to stick the data to. Please remove these users from the batch or create an account for them." -Level "WARNING"
        exit 1
    } else { Write-Log "All UPNs found and active." -Level "SUCCESS" }
    #endregion PHASE 1 - CHECK TARGET UPNS
    
    #region PHASE 2 - CHECK TARGET ONEDRIVE
    # === PHASE 2: CHECKNG FOR ONEDRIVE PROVISIONING ON TARGET TENANT ===
    Write-Log "`n`n=== PHASE 2: CHECKNG FOR ONEDRIVE PROVISIONING ON TARGET TENANT ===`n" -Level "SUCCESS"

    Write-Log "Connecting to TARGET tenant SharePoint Online for migration checks..." -Level "INFO"
    try {
        Connect-SPOService -Url $TargetSPOURL -ErrorAction Stop
        Write-Log "Successfully connected to source tenant SharePoint Online" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to connect to source tenant SharePoint Online: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # Check for active OneDrive Environments
    
    # Get all Personal OneDrive sites
    Write-Log "`nChecking for provisioned OneDrive sites in target SPO tenant..."
    $targetODSites = Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'" | Where-Object { $migrationUsers.TargetUPN -contains $_.Owner }
    
    # Error and export if sites are found
    if($targetODSites) {
        $exportData = $targetODSites | select Owner, StorageUsageCurrent, Url
        $errorCSVPath = "$($LogDirectory)\OneDriveMigration_Error_TargetProvisionedSites$(Get-Date -Format 'yyyyMMdd').csv"
        $exportData | Export-Csv -Path $errorCSVPath

        Write-Log "! ERROR !`n`
        OneDrive sites have been detected in the target tenant that are already provisioined for these users. `
        They must either be removed from the batch or have their sites deleted (EVEN IF THEY CONTAIN NO DATA) to continue with the migration.`n" -Level "WARNING"
        Start-Sleep -Seconds 3

        Write-Log "Sites found:`n$($exportData)`n" -Level "WARNING"
        Write-Log "A csv report of this data has been generated at:$($errorCSVPath)`n`
        To remove the sites, you will need to run the following commands:`n
        'Remove-SPOSite -Identity '<SiteUrlFromReport>''`n
        'Remove-SPODeletedSite -Identity  '<SiteUrlFromReport>''" -Level "WARNING"
        exit 1
    } else {
        Write-Log "No provisioned OneDrive environments found. Continuing..." -Level "SUCCESS"
    }
    #endregion PHASE 2 - CHECK TARGET ONEDRIVE
    
    #region PHASE 3 - ASSIGN LICENSES
    # === PHASE 3: ASSIGNING CROSS-TENANT LICENSE ON TARGET TENANT ===

    Write-Log "`n`n=== PHASE 3: ASSIGNING CROSS-TENANT LICENSE ON TARGET TENANT ===`n" -Level "SUCCESS"
    Write-Log "Now assigning Cross-Tenant Migration Licenses"
    foreach ($upn in $migrationUsers.TargetUPN) { Set-UserLicense -UserUPN $upn }

    #endregion PHASE 3 - ASSIGN LICENSES

    # === PHASE 4: UPLOAD IDENTITY MAPPING FILE TO TARGET TENANT ===
    #region PHASE 4 - Upload Identity Mapping File
    Write-Log "`n`n=== PHASE 4: UPLOAD IDENTITY MAPPING FILE TO TARGET TENANT ===`n" -Level "SUCCESS"    
    
    # Step 1: Create Identity Mapping File
    Write-Log "Creating identity mapping file for OneDrive migration..." -Level "INFO"
    $identityMappingPath = "$($LogDirectory)\OneDriveIdentityMapping_$(Get-Date -Format 'yyyyMMdd').csv"
    $mappingCreated = New-OneDriveIdentityMappingFile -CSVFilePath $CSVFilePath -SourceTenantId $SourceTenantID -TargetTenantId $TargetTenantID -OutputPath $identityMappingPath

    if (-not $mappingCreated) {
        Write-Log "Failed to create identity mapping file. Cannot proceed with OneDrive migration." -Level "ERROR"
        return
    }

    # Step 2: Upload identity mapping file to TARGET tenant
    Write-Log "Uploading identity mapping file to target tenant..." -Level "INFO"
    try {
        Add-SPOTenantIdentityMap -IdentityMapPath $identityMappingPath -ErrorAction Stop
        Write-Log "Successfully uploaded identity mapping file to target tenant" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to upload identity mapping file: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # Step 3: Get target tenant cross-tenant host URL
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
#endregion PHASE 4 - Upload Identity Mapping file

    # === PHASE 5: CONNCET TO SOURCE TENANT TO INITIATE MIGRATION ===
    #region PHASE 5 - Initiate Migration
    Write-Log "`n`n=== PHASE 5: CONNCET TO SOURCE TENANT TO INITIATE MIGRATION ===`n" -Level "SUCCESS"

    # Step 1: Connect to Source tenant
    Write-Log "Connecting to SOURCE tenant SharePoint Online for migration initiation..." -Level "INFO"
    try {
        Connect-SPOService -Url $SourceSPOURL -ErrorAction Stop
        Write-Log "Successfully connected to source tenant SharePoint Online" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to connect to source tenant SharePoint Online: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # Step 2: Verify cross-tenant compatibility status
    <#
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
    #>
    
    # Step 3: Process each user for OneDrive migration

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
    #endregion Phase 5 - Initiate Migration

    #region PHASE 6 - MIGRATION SUMMARY
    # === PHASE 6: DISPLAY MIGRATION SUMMARY ===
    Write-Log "`n`n=== PHASE 6: DISPLAY MIGRATION SUMMARY ===`n" -Level "SUCCESS"

    Write-Log "OneDrive Migration Summary:" -Level "SUCCESS"
    Write-Log "Total Users Processed: $($migrationUsers.Count)" -Level "INFO"
    Write-Log "Successful Migration Initiations: $successfulOneDriveMigrations" -Level "SUCCESS"
    Write-Log "Failed Migration Initiations: $failedOneDriveMigrations" -Level "WARNING"

    # Export results and provide monitoring guidance
    $oneDriveReportPath = "$($LogDirectory)\OneDrive-CrossTenantMigration_Report_$(Get-Date -Format 'yyyyMMdd').csv"
    $oneDriveMigrationResults | Export-Csv -Path $oneDriveReportPath -NoTypeInformation
    Write-Log "OneDrive migration results exported to: $oneDriveReportPath" -Level "SUCCESS"

    # Provide monitoring instructions
    Write-Log "OneDrive Migration Monitoring Instructions:" -Level "INFO"
    Write-Log "To check individual user migration status, use the below cmdlets in the SOURCE tenant:" -Level "INFO"
    Write-Log "Get-SPOCrossTenantUserContentMoveState -PartnerCrossTenantHostURL '$TargetCrossTenantHostUrl' -SourceUserPrincipalName 'user@example.com'" -Level "INFO"
    Write-Host "`n`n"
    Write-Log "Identity mapping file location: $identityMappingPath" -Level "INFO"

    Write-Log "=== ONEDRIVE CROSS-TENANT MIGRATION COMPLETED ===" -Level "SUCCESS"
    #endregion PHASE 4

    #region PHASE 7 - CLEANUP
    # === PHASE 7: CLEANUP ===
    Write-Log "`n`n=== PHASE 7: CLEANUP ===`n" -Level "SUCCESS"
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
}
finally {
    # Cleanup connections
    Disconnect-SPOService
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    
    Write-Log "Script execution completed. Check logs at:"
    Write-Log "- Main Log: $LogPath"
    Write-Log "- Error Log: $ErrorLogPath"
}
#endregion PHASE 7 - CLEANUP