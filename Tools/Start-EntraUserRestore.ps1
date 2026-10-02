<#
.SYNOPSIS
    Restores Entra ID user configuration from backup JSON in Azure Blob Storage.

.DESCRIPTION
    This script restores the following for users from a backup created by Start-EntraUserBackup.ps1:
    - Group memberships and group ownership
    - Entra role assignments
    - App role assignments and app ownership
    - Email aliases/proxy addresses (requires Exchange Online)

    The user must already exist in Entra ID. This script will NOT create users.
    Can restore individual users or all users in the backup.

    By default, the script connects to the same Azure Blob Storage location used by
    Start-EntraUserBackup.ps1, finds the most recent MTO_Users_*.json backup, downloads it,
    and restores from it.

.PARAMETER BackupFile
    Optional local path to backup JSON file created by Start-EntraUserBackup.ps1.
    If omitted, the script downloads a backup from Azure Blob Storage.

.PARAMETER BackupDate
    Optional backup date to restore from. The newest MTO_Users_*.json backup whose Last-Modified date or filename
    date matches this value is selected. If omitted, the newest .json backup is selected.

.PARAMETER UserUPN
    UPN of user to restore (must already exist in Entra ID). Supports either the guest #EXT# UPN
    or the source UPN represented by that guest account. If not specified, restores all users in backup.

.PARAMETER RestoreAll
    Switch to restore all users in the backup file without prompting.

.PARAMETER WhatIf
    Preview mode (no actual changes)

.PARAMETER IncludeEmailAliases
    Restore email aliases via Exchange Online. Requires Exchange Online connection.
    Default: $true

.EXAMPLE
    .\Start-EntraUserRestore.ps1 -StorageAccountName "<storageAccountName>" -SharePointClientId "[clientID]" -UserUPN "user_example.net#EXT#@tenant.onmicrosoft.com"

.EXAMPLE
    .\Start-EntraUserRestore.ps1 -StorageAccountName "<storageAccountName>" -SharePointClientId "[clientID]" -BackupDate "2026-01-16" -UserUPN "user@example.net"

.EXAMPLE
    .\Start-EntraUserRestore.ps1 -BackupFile "C:\temp\MTO_Users_2026-01-16_14-30-00.json" -UserUPN "user@example.net" -IncludeSharePointPermissions:$false -WhatIf
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$BackupFile,

    [Parameter(Mandatory = $false)]
    [Nullable[datetime]]$BackupDate,

    [Parameter(Mandatory = $false)]
    [string[]]$UserUPN,

    [Parameter(Mandatory = $false)]
    [switch]$RestoreAll = $false,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf = $false,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeEmailAliases = $true,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeSharePointPermissions = $true,

    [Parameter(Mandatory = $false)]
    [string]$SharePointClientId,
    [string]$StorageAccountName,
    [string]$ContainerName = "mto-backups"
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Continue"
if (-not $BackupFile -and -not $StorageAccountName) {
    throw 'Supply BackupFile for a local backup or StorageAccountName for Azure Storage.'
}
if ($IncludeSharePointPermissions -and -not $SharePointClientId) {
    throw 'Supply SharePointClientId or disable IncludeSharePointPermissions.'
}
$BackupBlobNamePattern = "MTO_Users_*.json"

$RequiredGraphModules = @(
    "Microsoft.Graph.Authentication"
    "Microsoft.Graph.Users"
    "Microsoft.Graph.Groups"
    "Microsoft.Graph.Applications"
    "Microsoft.Graph.Identity.Governance"
)

function Import-CompatibleGraphModules {
    $availableVersionsByModule = @{}

    foreach ($moduleName in $RequiredGraphModules) {
        $versions = @(
            Get-Module -ListAvailable -Name $moduleName |
            Select-Object -ExpandProperty Version -Unique
        )

        if ($versions.Count -eq 0) {
            throw "Required module '$moduleName' is not installed. Install or update the Microsoft.Graph PowerShell SDK."
        }

        $availableVersionsByModule[$moduleName] = $versions
    }

    $compatibleVersions = @(
        $availableVersionsByModule[$RequiredGraphModules[0]] | Where-Object {
            $candidateVersion = $_
            -not ($RequiredGraphModules | Where-Object {
                $availableVersionsByModule[$_] -notcontains $candidateVersion
            })
        } | Sort-Object -Descending
    )

    if ($compatibleVersions.Count -eq 0) {
        $installedVersionSummary = $RequiredGraphModules | ForEach-Object {
            "${_}: $($availableVersionsByModule[$_] -join ', ')"
        }
        throw "The required Microsoft.Graph modules do not have a common installed version. Update the Microsoft.Graph SDK so all submodules use the same version. Installed versions: $($installedVersionSummary -join '; ')"
    }

    $graphVersion = $compatibleVersions[0]
    $incompatibleLoadedModule = Get-Module -Name "Microsoft.Graph.*" | Where-Object {
        $_.Version -ne $graphVersion
    } | Select-Object -First 1

    if ($incompatibleLoadedModule) {
        throw "Microsoft Graph module '$($incompatibleLoadedModule.Name)' version $($incompatibleLoadedModule.Version) is already loaded, but this script requires the common version $graphVersion. Start the script in a new PowerShell session."
    }

    foreach ($moduleName in $RequiredGraphModules) {
        Import-Module $moduleName -RequiredVersion $graphVersion -ErrorAction Stop
    }

    Write-Host "[+] Loaded Microsoft Graph modules version $graphVersion" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Entra User Restoration ===" -ForegroundColor Cyan
if ($BackupFile) {
    Write-Host "Backup file: $BackupFile"
} else {
    Write-Host "Storage Account: $StorageAccountName"
    Write-Host "Container: $ContainerName"
    Write-Host "Blob pattern: $BackupBlobNamePattern"
    if ($BackupDate) {
        Write-Host "Backup date: $($BackupDate.ToString('yyyy-MM-dd'))"
    } else {
        Write-Host "Backup selection: newest matching JSON"
    }
}
if ($WhatIf) { Write-Host "Mode: WhatIf (preview only)" -ForegroundColor Yellow }
Write-Host ""

try {
    Write-Host "[*] Loading compatible Microsoft Graph modules..." -ForegroundColor Yellow
    Import-CompatibleGraphModules
} catch {
    Write-Error "Failed to load Microsoft Graph modules: $_"
    exit 1
}

# ============================================================================
# STORAGE HELPER FUNCTIONS
# ============================================================================

function Get-ManagedIdentityAccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceUrl
    )

    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) {
        throw "Managed identity environment variables were not found. Run in Azure Automation or provide -BackupFile for local restore."
    }

    $response = [System.Text.Encoding]::Default.GetString(
        (Invoke-WebRequest -UseBasicParsing `
            -Uri "$($env:IDENTITY_ENDPOINT)?resource=$ResourceUrl" `
            -Method 'GET' `
            -Headers @{
                'X-IDENTITY-HEADER' = "$env:IDENTITY_HEADER"
                'Metadata' = 'True'
            } `
            -ErrorAction Stop
        ).RawContentStream.ToArray()
    ) | ConvertFrom-Json

    return $response.access_token
}

function ConvertTo-EscapedBlobPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    return (($Name -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
}

function Get-BackupBlobContent {
    param(
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobNamePattern,
        [Parameter(Mandatory = $false)][Nullable[datetime]]$BackupDate
    )

    Write-Host "[*] Getting Azure Storage access token via managed identity..." -ForegroundColor Yellow
    $storageAccessToken = Get-ManagedIdentityAccessToken -ResourceUrl "https://storage.azure.com/"
    Write-Host "[✓] Got storage token" -ForegroundColor Green

    $storageHeaders = @{
        "Authorization" = "Bearer $storageAccessToken"
        "x-ms-version"  = "2021-08-06"
    }

    Write-Host "[*] Listing backup blobs..." -ForegroundColor Yellow
    $listUri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName?restype=container&comp=list"
    [xml]$blobList = Invoke-RestMethod -Method GET -Uri $listUri -Headers $storageHeaders -ErrorAction Stop

    $jsonBlobs = @(
        $blobList.EnumerationResults.Blobs.Blob |
        Where-Object { $_.Name -like $BlobNamePattern } |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                LastModified = if ($_.Properties.'Last-Modified') { [datetime]$_.Properties.'Last-Modified' } else { [datetime]::MinValue }
            }
        }
    )

    if ($jsonBlobs.Count -eq 0) {
        throw "No backup blobs matching '$BlobNamePattern' were found in container '$ContainerName'."
    }

    if ($BackupDate) {
        $dateText = $BackupDate.ToString("yyyy-MM-dd")
        $jsonBlobs = @(
            $jsonBlobs | Where-Object {
                $_.LastModified.Date -eq $BackupDate.Date -or
                $_.Name -like "*$dateText*"
            }
        )

        if ($jsonBlobs.Count -eq 0) {
            throw "No backup blobs matching '$BlobNamePattern' were found for $dateText in container '$ContainerName'."
        }
    }

    $selectedBlob = $jsonBlobs | Sort-Object LastModified -Descending | Select-Object -First 1

    Write-Host "[✓] Selected backup blob: $($selectedBlob.Name)" -ForegroundColor Green
    Write-Host "    Last modified: $($selectedBlob.LastModified)" -ForegroundColor Gray

    $escapedBlobName = ConvertTo-EscapedBlobPath -Name $selectedBlob.Name
    $downloadUri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$escapedBlobName"
    Write-Host "[*] Downloading backup JSON..." -ForegroundColor Yellow

    return @{
        Name = $selectedBlob.Name
        Content = Invoke-RestMethod -Method GET -Uri $downloadUri -Headers $storageHeaders -ErrorAction Stop
    }
}

# ============================================================================
# LOAD BACKUP
# ============================================================================

try {
    if ($BackupFile) {
        if (-not (Test-Path $BackupFile)) {
            Write-Error "Backup file not found: $BackupFile"
            exit 1
        }

        Write-Host "[*] Loading backup file..." -ForegroundColor Yellow
        $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json -ErrorAction Stop
        $backupSource = $BackupFile
    } else {
        $backupBlob = Get-BackupBlobContent -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobNamePattern $BackupBlobNamePattern -BackupDate $BackupDate
        $backup = $backupBlob.Content
        $backupSource = $backupBlob.Name
    }

    Write-Host "[✓] Backup loaded (v$($backup.BackupMetadata.BackupVersion))" -ForegroundColor Green
    Write-Host "    Source: $backupSource" -ForegroundColor Gray
    Write-Host "    Created: $($backup.BackupMetadata.BackupDate)" -ForegroundColor Gray
    Write-Host "    Users in backup: $($backup.Users.Count)" -ForegroundColor Gray
} catch {
    Write-Error "Failed to load backup: $_"
    exit 1
}

# Determine which users to restore
$usersToRestore = @()

if ($RestoreAll) {
    $usersToRestore = $backup.Users | ForEach-Object { $_.UserPrincipalName }
    Write-Host "[*] Restoring all users from backup: $($usersToRestore.Count) user(s)" -ForegroundColor Yellow
}
elseif ($UserUPN) {
    $usersToRestore = $UserUPN  # already a string[]
    Write-Host "[*] Restoring $($usersToRestore.Count) user(s) by UPN" -ForegroundColor Yellow
}
else {
    Write-Host "[*] Available users in backup:"
    $backup.Users | ForEach-Object { Write-Host "    - $($_.UserPrincipalName) ($($_.DisplayName))" }
    Write-Host ""
    $userInput = Read-Host "Enter user UPN(s) to restore (comma-separated, or leave blank for all)"
    
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        $usersToRestore = $backup.Users | ForEach-Object { $_.UserPrincipalName }
        Write-Host "[*] Restoring all users from backup: $($usersToRestore.Count) user(s)" -ForegroundColor Yellow
    } else {
        $usersToRestore = @($userInput -split "," | ForEach-Object { $_.Trim() })
        Write-Host "[*] Restoring $($usersToRestore.Count) user(s)" -ForegroundColor Yellow
    }
}

Write-Host ""

# ============================================================================
# CONNECT TO MICROSOFT GRAPH
# ============================================================================

try {
    Write-Host "[*] Connecting to Microsoft Graph..." -ForegroundColor Yellow
    $mgContext = Get-MgContext -ErrorAction SilentlyContinue
    
    if ($null -eq $mgContext) {
        if ($env:IDENTITY_ENDPOINT) {
            Connect-MgGraph -Identity -ErrorAction Stop | Out-Null
        } else {
            Connect-MgGraph -Scopes "User.Read.All", "Group.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "Application.ReadWrite.All", "Directory.ReadWrite.All" `
              -ErrorAction Stop | Out-Null
        }
    }
    Write-Host "[✓] Connected to Graph" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to Graph: $_"
    exit 1
}

# ============================================================================
# CONNECT TO EXCHANGE ONLINE (if email aliases included)
# ============================================================================

$exoConnected = $false
if ($IncludeEmailAliases) {
    Write-Host "[*] Connecting to Exchange Online..." -ForegroundColor Yellow
    try {
        $exoContext = Get-ConnectionInformation -ErrorAction SilentlyContinue
        if ($null -eq $exoContext) {
            $connectExchangeParameters = @{ ErrorAction = "Stop" }
            if ((Get-Command Connect-ExchangeOnline -ErrorAction Stop).Parameters.ContainsKey("DisableWAM")) {
                $connectExchangeParameters.DisableWAM = $true
            }
            Connect-ExchangeOnline @connectExchangeParameters | Out-Null
        }
        Write-Host "[✓] Connected to Exchange Online" -ForegroundColor Green
        $exoConnected = $true
    } catch {
        Write-Warning "Failed to connect to Exchange Online: $_"
        Write-Warning "Email aliases will be skipped"
        $exoConnected = $false
    }
}

# ============================================================================
# RESTORE HELPER FUNCTIONS
# ============================================================================

function Restore-UserGroupMemberships {
    param(
        [object]$UserBackup,
        [string]$RestoredUserId,
        [bool]$WhatIfMode
    )
    
    $groupRestoreCount = 0
    $groupSkippedDynamicCount = 0
    $groupErrorCount = 0

    if ($UserBackup.GroupMemberships.Count -eq 0) {
        Write-Host "    [*] No group memberships to restore"
        return @{ Restored = $groupRestoreCount; Skipped = $groupSkippedDynamicCount; Errors = $groupErrorCount }
    }

    foreach ($groupBackup in $UserBackup.GroupMemberships) {
        try {
            $groupId = $groupBackup.Id
            $groupName = $groupBackup.DisplayName
            
            # Check if group is dynamic
            try {
                $groupDetails = Get-MgGroup -GroupId $groupId -ErrorAction SilentlyContinue
                if ($groupDetails.GroupTypes -contains "DynamicMembership") {
                    Write-Host "    ⊘ Skipped (dynamic): $groupName"
                    $groupSkippedDynamicCount++
                    continue
                }
            } catch {
                Write-Warning "    Could not verify group type: $groupName"
            }

            # Check if already member
            $isMember = Get-MgGroupMember -GroupId $groupId -ErrorAction SilentlyContinue | 
                        Where-Object { $_.Id -eq $RestoredUserId }
            
            if ($isMember) {
                Write-Host "    ⚠ Already member of: $groupName"
                continue
            }

            if ($WhatIfMode) {
                Write-Host "    [WhatIf] Would add to: $groupName"
            } else {
                New-MgGroupMember -GroupId $groupId -DirectoryObjectId $RestoredUserId -ErrorAction Stop | Out-Null
                Write-Host "    [+] Added to group: $groupName"
            }
            
            $groupRestoreCount++

        } catch {
            Write-Warning "    [-] Failed to add group: $_"
            $groupErrorCount++
        }
    }

    return @{ Restored = $groupRestoreCount; Skipped = $groupSkippedDynamicCount; Errors = $groupErrorCount }
}

function Restore-UserGroupOwnership {
    param(
        [object]$UserBackup,
        [string]$RestoredUserId,
        [bool]$WhatIfMode
    )
    
    $groupOwnerRestoreCount = 0
    $groupOwnerErrorCount = 0

    $groupsWithOwnership = $UserBackup.GroupMemberships | Where-Object { $_.Owners.Count -gt 0 }
    
    if ($groupsWithOwnership.Count -eq 0) {
        return @{ Restored = $groupOwnerRestoreCount; Errors = $groupOwnerErrorCount }
    }

    foreach ($groupBackup in $groupsWithOwnership) {
        try {
            $groupId = $groupBackup.Id
            $groupName = $groupBackup.DisplayName
            
            # Check if user is already owner
            $isOwner = Get-MgGroupOwner -GroupId $groupId -ErrorAction SilentlyContinue | 
                       Where-Object { $_.Id -eq $RestoredUserId }
            
            if ($isOwner) {
                Write-Host "    ⚠ Already owner of: $groupName"
                continue
            }

            if ($WhatIfMode) {
                Write-Host "    [WhatIf] Would add as owner: $groupName"
            } else {
                $params = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$RestoredUserId"
                }
                New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter $params -ErrorAction Stop | Out-Null
                Write-Host "    [+] Added as owner: $groupName"
            }
            
            $groupOwnerRestoreCount++

        } catch {
            Write-Warning "    [-] Failed to add group owner: $_"
            $groupOwnerErrorCount++
        }
    }

    return @{ Restored = $groupOwnerRestoreCount; Errors = $groupOwnerErrorCount }
}

function Restore-UserEntraRoles {
    param(
        [object]$UserBackup,
        [string]$RestoredUserId,
        [bool]$WhatIfMode
    )
    
    $roleRestoreCount = 0
    $roleErrorCount = 0

    if ($UserBackup.EntraRoles.Count -eq 0) {
        Write-Host "    [*] No Entra roles to restore"
        return @{ Restored = $roleRestoreCount; Errors = $roleErrorCount }
    }

    foreach ($roleBackup in $UserBackup.EntraRoles) {
        try {
            $roleDefinitionId = $roleBackup.RoleDefinitionId
            $roleName = $roleBackup.RoleName
            
            # Check if already assigned
            $existingRole = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$RestoredUserId' and roleDefinitionId eq '$roleDefinitionId'" -ErrorAction SilentlyContinue
            
            if ($existingRole) {
                Write-Host "    ⚠ Already has role: $roleName"
                continue
            }

            if ($WhatIfMode) {
                Write-Host "    [WhatIf] Would assign role: $roleName"
            } else {
                $params = @{
                    principalId      = $RestoredUserId
                    roleDefinitionId = $roleDefinitionId
                    directoryScopeId = "/"
                }
                
                New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $params -ErrorAction Stop | Out-Null
                Write-Host "    [+] Assigned role: $roleName"
            }
            
            $roleRestoreCount++

        } catch {
            Write-Warning "    [-] Failed to assign role: $_"
            $roleErrorCount++
        }
    }

    return @{ Restored = $roleRestoreCount; Errors = $roleErrorCount }
}

function Restore-UserAppRoleAssignments {
    param(
        [object]$UserBackup,
        [string]$RestoredUserId,
        [bool]$WhatIfMode
    )
    
    $appRestoreCount = 0
    $appErrorCount = 0

    if ($UserBackup.AppRoleAssignments.Count -eq 0) {
        Write-Host "    [*] No app assignments to restore"
        return @{ Restored = $appRestoreCount; Errors = $appErrorCount }
    }

    foreach ($appBackup in $UserBackup.AppRoleAssignments) {
        try {
            $appRoleId = $appBackup.AppRoleId
            $resourceId = $appBackup.ResourceId
            $resourceAppId = $appBackup.ResourceAppId
            $resourceDisplayName = $appBackup.ResourceDisplayName
            $appRoleDisplayName = $appBackup.AppRoleDisplayName
            
            # Check if already assigned
            $existingAssignment = Get-MgUserAppRoleAssignment -UserId $RestoredUserId -ErrorAction SilentlyContinue | 
                                  Where-Object { $_.ResourceId -eq $resourceId }
            
            if ($existingAssignment) {
                Write-Host "    ⚠ Already assigned to: $resourceDisplayName"
                continue
            }

            # Get service principal (try by ResourceId first, fallback to AppId)
            $servicePrincipal = Get-MgServicePrincipal -ServicePrincipalId $resourceId -ErrorAction SilentlyContinue
            
            if (-not $servicePrincipal) {
                $servicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$resourceAppId'" -ErrorAction SilentlyContinue
            }
            
            if (-not $servicePrincipal) {
                Write-Warning "    [-] Could not find service principal: $resourceDisplayName"
                $appErrorCount++
                continue
            }

            if ($WhatIfMode) {
                Write-Host "    [WhatIf] Would assign to: $resourceDisplayName ($appRoleDisplayName)"
            } else {
                try {
                    # Get the app role object
                    $appRole = $servicePrincipal.AppRoles | Where-Object { $_.Id -eq $appRoleId }
                    
                    if (-not $appRole) {
                        # If role not found, use "User" role
                        $appRole = $servicePrincipal.AppRoles | Where-Object { 
                            $_.DisplayName -eq "User" -and $_.AllowedMemberTypes -contains "User" 
                        }
                    }
                    
                    if ($appRole) {
                        $params = @{
                            principalId = $RestoredUserId
                            resourceId  = $servicePrincipal.Id
                            appRoleId   = $appRole.Id
                        }
                        
                        New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $servicePrincipal.Id `
                          -BodyParameter $params -ErrorAction Stop | Out-Null
                        
                        Write-Host "    [+] Assigned to: $resourceDisplayName ($($appRole.DisplayName))"
                    } else {
                        Write-Warning "    [-] Could not find app role in service principal: $resourceDisplayName"
                        $appErrorCount++
                        continue
                    }

                } catch {
                    Write-Warning "    [-] Failed to assign app: $_"
                    $appErrorCount++
                    continue
                }
            }
            
            $appRestoreCount++

        } catch {
            Write-Warning "    [-] Failed to process app assignment: $_"
            $appErrorCount++
        }
    }

    return @{ Restored = $appRestoreCount; Errors = $appErrorCount }
}

function Restore-UserAppOwnership {
    param(
        [object]$UserBackup,
        [string]$RestoredUserId,
        [bool]$WhatIfMode
    )
    
    $appOwnerRestoreCount = 0
    $appOwnerErrorCount = 0

    $appsWithOwnership = $UserBackup.AppRoleAssignments | Where-Object { $_.AppOwners.Count -gt 0 }
    
    if ($appsWithOwnership.Count -eq 0) {
        return @{ Restored = $appOwnerRestoreCount; Errors = $appOwnerErrorCount }
    }

    foreach ($appBackup in $appsWithOwnership) {
        try {
            $resourceId = $appBackup.ResourceId
            $resourceAppId = $appBackup.ResourceAppId
            $resourceDisplayName = $appBackup.ResourceDisplayName
            
            # Get service principal
            $servicePrincipal = Get-MgServicePrincipal -ServicePrincipalId $resourceId -ErrorAction SilentlyContinue
            
            if (-not $servicePrincipal) {
                $servicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$resourceAppId'" -ErrorAction SilentlyContinue
            }
            
            if (-not $servicePrincipal) {
                Write-Warning "    [-] Could not find service principal: $resourceDisplayName"
                $appOwnerErrorCount++
                continue
            }
            
            # Check if already owner
            $isOwner = Get-MgServicePrincipalOwner -ServicePrincipalId $servicePrincipal.Id -ErrorAction SilentlyContinue | 
                       Where-Object { $_.Id -eq $RestoredUserId }
            
            if ($isOwner) {
                Write-Host "    ⚠ Already owner of: $resourceDisplayName"
                continue
            }

            if ($WhatIfMode) {
                Write-Host "    [WhatIf] Would add as owner: $resourceDisplayName"
            } else {
                $params = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$RestoredUserId"
                }
                New-MgServicePrincipalOwnerByRef -ServicePrincipalId $servicePrincipal.Id `
                  -BodyParameter $params -ErrorAction Stop | Out-Null
                Write-Host "    [+] Added as owner: $resourceDisplayName"
            }
            
            $appOwnerRestoreCount++

        } catch {
            Write-Warning "    [-] Failed to add app owner: $_"
            $appOwnerErrorCount++
        }
    }

    return @{ Restored = $appOwnerRestoreCount; Errors = $appOwnerErrorCount }
}

function Restore-UserEmailAliases {
    param(
        [object]$UserBackup,
        [string]$UserUPN,
        [bool]$WhatIfMode,
        [bool]$ExoConnected
    )
    
    $emailRestoreCount = 0
    $emailErrorCount = 0

    if ($UserBackup.EmailAliases.Count -eq 0 -or -not $ExoConnected) {
        return @{ Restored = $emailRestoreCount; Errors = $emailErrorCount }
    }

    try {
        # Determine recipient type
        $mailUser = $null
        $mailbox = $null
        $recipientType = $null
        $recipientId = $null
        
        try {
            $mailUser = Get-MailUser -Identity $UserUPN -ErrorAction SilentlyContinue
            if ($mailUser) {
                $recipientType = "MailUser"
                $recipientId = $mailUser.Identity
            }
        } catch { }
        
        if (-not $recipientType) {
            try {
                $mailbox = Get-Mailbox -Identity $UserUPN -ErrorAction SilentlyContinue
                if ($mailbox) {
                    $recipientType = "Mailbox"
                    $recipientId = $mailbox.Identity
                }
            } catch { }
        }
        
        if ($recipientType) {
            # Get current emails
            if ($recipientType -eq "MailUser") {
                $recipient = Get-MailUser -Identity $recipientId
                $currentEmails = $recipient.EmailAddresses
            } else {
                $recipient = Get-Mailbox -Identity $recipientId
                $currentEmails = $recipient.EmailAddresses
            }
            
            # Restore each email
            foreach ($email in $UserBackup.EmailAliases) {
                try {
                    if ($currentEmails -contains $email) {
                        Write-Host "    ⚠ Already has: $email"
                        continue
                    }
                    
                    if ($WhatIfMode) {
                        Write-Host "    [WhatIf] Would add: $email"
                    } else {
                        if ($recipientType -eq "MailUser") {
                            Set-MailUser -Identity $recipientId -EmailAddresses @{Add=$email} -ErrorAction Stop
                        } else {
                            Set-Mailbox -Identity $recipientId -EmailAddresses @{Add=$email} -ErrorAction Stop
                        }
                        Write-Host "    [+] Added: $email"
                    }
                    
                    $emailRestoreCount++
                    
                } catch {
                    Write-Warning "    [-] Failed to add email: $_"
                    $emailErrorCount++
                }
            }
        } else {
            Write-Warning "    Could not find MailUser or Mailbox for: $UserUPN"
        }
        
    } catch {
        Write-Warning "    Failed to restore email aliases: $_"
    }

    return @{ Restored = $emailRestoreCount; Errors = $emailErrorCount }
}

function Restore-UserSharePointPermissions {
    param(
        [Parameter(Mandatory = $true)][object]$UserBackup,
        [Parameter(Mandatory = $true)][string]$SharePointUserIdentity,
        [Parameter(Mandatory = $true)][bool]$WhatIfMode
    )

    $restoredCount = 0
    $errorCount = 0
    $permissions = @($UserBackup.SharePointPermissions)
    if ($permissions.Count -eq 0 -or -not $IncludeSharePointPermissions) {
        return @{ Restored = 0; Errors = 0 }
    }

    if (-not (Get-Command Connect-PnPOnline -ErrorAction SilentlyContinue)) {
        Import-Module PnP.PowerShell -RequiredVersion 3.3.0 -ErrorAction Stop
    }

    if (-not $script:SharePointConnectionCache) { $script:SharePointConnectionCache = @{} }

    foreach ($permission in $permissions) {
        try {
            $siteUrl = $permission.SiteUrl.TrimEnd('/')
            if (-not $script:SharePointConnectionCache.ContainsKey($siteUrl)) {
                $connectionParams = @{
                    Url = $siteUrl
                    ClientId = $SharePointClientId
                    ReturnConnection = $true
                    ErrorAction = 'Stop'
                }
                if ($env:IDENTITY_ENDPOINT) {
                    $connectionParams.Remove('ClientId')
                    $connectionParams.ManagedIdentity = $true
                } else {
                    $connectionParams.Interactive = $true
                    $connectionParams.PersistLogin = $true
                }
                $script:SharePointConnectionCache[$siteUrl] = Connect-PnPOnline @connectionParams
            }
            $connection = $script:SharePointConnectionCache[$siteUrl]

            if (-not $WhatIfMode) {
                New-PnPUser -LoginName $SharePointUserIdentity -Connection $connection -ErrorAction Stop | Out-Null
            }

            foreach ($roleName in @($permission.Roles)) {
                if ($WhatIfMode) {
                    Write-Host "    [WhatIf] Would grant '$roleName' on $($permission.ObjectType): $($permission.ServerRelativeUrl)"
                    $restoredCount++
                    continue
                }

                switch ($permission.ObjectType) {
                    'Web' {
                        Set-PnPWebPermission -Identity $permission.WebId -User $SharePointUserIdentity `
                            -AddRole $roleName -Connection $connection -ErrorAction Stop
                    }
                    'List' {
                        Set-PnPListPermission -Identity $permission.ListId -User $SharePointUserIdentity `
                            -AddRole $roleName -Connection $connection -ErrorAction Stop
                    }
                    { $_ -in @('Folder', 'File', 'ListItem') } {
                        Set-PnPListItemPermission -List $permission.ListId -Identity $permission.ItemId `
                            -User $SharePointUserIdentity -AddRole $roleName -SystemUpdate `
                            -Connection $connection -ErrorAction Stop
                    }
                    default { throw "Unsupported SharePoint object type '$($permission.ObjectType)'." }
                }
                Write-Host "    [+] Granted '$roleName' on $($permission.ObjectType): $($permission.ServerRelativeUrl)"
                $restoredCount++
            }
        } catch {
            Write-Warning "    [-] Failed SharePoint permission at $($permission.ServerRelativeUrl): $($_.Exception.Message)"
            $errorCount++
        }
    }

    return @{ Restored = $restoredCount; Errors = $errorCount }
}

function ConvertFrom-GuestUserPrincipalName {
    param(
        [Parameter(Mandatory = $false)][string]$UserPrincipalName
    )

    if ([string]::IsNullOrWhiteSpace($UserPrincipalName) -or $UserPrincipalName -notmatch '#EXT#') {
        return $null
    }

    $guestPrefix = ($UserPrincipalName -split '#EXT#')[0]
    $lastUnderscore = $guestPrefix.LastIndexOf('_')

    if ($lastUnderscore -lt 1 -or $lastUnderscore -ge ($guestPrefix.Length - 1)) {
        return $null
    }

    return "$($guestPrefix.Substring(0, $lastUnderscore))@$($guestPrefix.Substring($lastUnderscore + 1))"
}

function Find-UserBackupRecord {
    param(
        [Parameter(Mandatory = $true)][object[]]$BackupUsers,
        [Parameter(Mandatory = $true)][string]$RequestedUPN
    )

    $normalizedRequestedUPN = $RequestedUPN.Trim()

    $matches = @(
        $BackupUsers | Where-Object {
            $_.UserPrincipalName -ieq $normalizedRequestedUPN -or
            (ConvertFrom-GuestUserPrincipalName -UserPrincipalName $_.UserPrincipalName) -ieq $normalizedRequestedUPN -or
            ($_.EmailAliases | Where-Object { $_ -ieq $normalizedRequestedUPN })
        }
    )

    if ($matches.Count -gt 1) {
        Write-Warning "Multiple backup users matched '$RequestedUPN'. Using first match: $($matches[0].UserPrincipalName)"
    }

    return $matches | Select-Object -First 1
}

# ============================================================================
# RESTORE USERS
# ============================================================================

Write-Host "[*] Starting restoration process..." -ForegroundColor Yellow
Write-Host ""

$totalUsers = 0
$successfulUsers = 0
$globalStats = @{
    Groups = @{ Restored = 0; Skipped = 0; Errors = 0 }
    GroupOwnership = @{ Restored = 0; Errors = 0 }
    Roles = @{ Restored = 0; Errors = 0 }
    Apps = @{ Restored = 0; Errors = 0 }
    AppOwnership = @{ Restored = 0; Errors = 0 }
    Emails = @{ Restored = 0; Errors = 0 }
    SharePoint = @{ Restored = 0; Errors = 0 }
}

foreach ($upn in $usersToRestore) {
    $totalUsers++
    
    Write-Host "[*] User $totalUsers/$($usersToRestore.Count): $upn" -ForegroundColor Yellow
    
    # Find user in backup. User input can be the guest #EXT# UPN or the source UPN.
    $userBackup = Find-UserBackupRecord -BackupUsers $backup.Users -RequestedUPN $upn
    
    if (-not $userBackup) {
        Write-Error "User '$upn' not found in backup"
        continue
    }
    
    $restoreUserUPN = $userBackup.UserPrincipalName
    $sourceUserUPN = ConvertFrom-GuestUserPrincipalName -UserPrincipalName $restoreUserUPN

    Write-Host "  [✓] Found in backup: $($userBackup.DisplayName) <$restoreUserUPN>" -ForegroundColor Green
    if ($sourceUserUPN) {
        Write-Host "      Source UPN: $sourceUserUPN" -ForegroundColor Gray
    }
    
    # Find user in Entra ID
    try {
        $escapedRestoreUserUPN = $restoreUserUPN.Replace("'", "''")
        $restoredUser = Get-MgUser -Filter "userPrincipalName eq '$escapedRestoreUserUPN'" -ErrorAction Stop
        if (-not $restoredUser) {
            Write-Error "User '$restoreUserUPN' not found in Entra ID"
            continue
        }
    } catch {
        Write-Error "Failed to look up user: $_"
        continue
    }
    
    Write-Host "  [✓] Found in Entra ID (ID: $($restoredUser.Id))" -ForegroundColor Green
    $restoredUserId = $restoredUser.Id
    
    # Restore group memberships
    Write-Host "  [*] Restoring group memberships..."
    $groupResult = Restore-UserGroupMemberships -UserBackup $userBackup -RestoredUserId $restoredUserId -WhatIfMode $WhatIf
    Write-Host "    [✓] $($groupResult.Restored) added, $($groupResult.Skipped) skipped, $($groupResult.Errors) errors"
    $globalStats.Groups.Restored += $groupResult.Restored
    $globalStats.Groups.Skipped += $groupResult.Skipped
    $globalStats.Groups.Errors += $groupResult.Errors
    
    # Restore group ownership
    if ($userBackup.GroupMemberships | Where-Object { $_.Owners.Count -gt 0 }) {
        Write-Host "  [*] Restoring group ownership..."
        $ownerResult = Restore-UserGroupOwnership -UserBackup $userBackup -RestoredUserId $restoredUserId -WhatIfMode $WhatIf
        Write-Host "    [✓] $($ownerResult.Restored) added, $($ownerResult.Errors) errors"
        $globalStats.GroupOwnership.Restored += $ownerResult.Restored
        $globalStats.GroupOwnership.Errors += $ownerResult.Errors
    }
    
    # Restore Entra roles
    Write-Host "  [*] Restoring Entra roles..."
    $roleResult = Restore-UserEntraRoles -UserBackup $userBackup -RestoredUserId $restoredUserId -WhatIfMode $WhatIf
    Write-Host "    [✓] $($roleResult.Restored) assigned, $($roleResult.Errors) errors"
    $globalStats.Roles.Restored += $roleResult.Restored
    $globalStats.Roles.Errors += $roleResult.Errors
    
    # Restore app assignments
    Write-Host "  [*] Restoring app assignments..."
    $appResult = Restore-UserAppRoleAssignments -UserBackup $userBackup -RestoredUserId $restoredUserId -WhatIfMode $WhatIf
    Write-Host "    [✓] $($appResult.Restored) assigned, $($appResult.Errors) errors"
    $globalStats.Apps.Restored += $appResult.Restored
    $globalStats.Apps.Errors += $appResult.Errors
    
    # Restore app ownership
    if ($userBackup.AppRoleAssignments | Where-Object { $_.AppOwners.Count -gt 0 }) {
        Write-Host "  [*] Restoring app ownership..."
        $appOwnerResult = Restore-UserAppOwnership -UserBackup $userBackup -RestoredUserId $restoredUserId -WhatIfMode $WhatIf
        Write-Host "    [✓] $($appOwnerResult.Restored) added, $($appOwnerResult.Errors) errors"
        $globalStats.AppOwnership.Restored += $appOwnerResult.Restored
        $globalStats.AppOwnership.Errors += $appOwnerResult.Errors
    }
    
    # Restore email aliases
    if ($userBackup.EmailAliases.Count -gt 0) {
        Write-Host "  [*] Restoring email aliases..."
        $emailResult = Restore-UserEmailAliases -UserBackup $userBackup -UserUPN $restoreUserUPN -WhatIfMode $WhatIf -ExoConnected $exoConnected
        Write-Host "    [✓] $($emailResult.Restored) added, $($emailResult.Errors) errors"
        $globalStats.Emails.Restored += $emailResult.Restored
        $globalStats.Emails.Errors += $emailResult.Errors
    }

    if ($IncludeSharePointPermissions -and @($userBackup.SharePointPermissions).Count -gt 0) {
        Write-Host "  [*] Restoring direct SharePoint permissions..."
        $sharePointIdentity = if ($sourceUserUPN) { $sourceUserUPN } else { $restoreUserUPN }
        $sharePointResult = Restore-UserSharePointPermissions -UserBackup $userBackup `
            -SharePointUserIdentity $sharePointIdentity -WhatIfMode $WhatIf
        Write-Host "    [✓] $($sharePointResult.Restored) granted, $($sharePointResult.Errors) errors"
        $globalStats.SharePoint.Restored += $sharePointResult.Restored
        $globalStats.SharePoint.Errors += $sharePointResult.Errors
    }
    
    Write-Host "  [✓] User restoration complete" -ForegroundColor Green
    $successfulUsers++
    Write-Host ""
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "=== Restoration Summary ===" -ForegroundColor Cyan
Write-Host "Total users processed: $totalUsers"
Write-Host "Successful restores: $successfulUsers"
Write-Host ""
Write-Host "Global Statistics:"
Write-Host "  Groups: $($globalStats.Groups.Restored) added, $($globalStats.Groups.Skipped) skipped, $($globalStats.Groups.Errors) errors"
Write-Host "  Group Ownership: $($globalStats.GroupOwnership.Restored) added, $($globalStats.GroupOwnership.Errors) errors"
Write-Host "  Entra Roles: $($globalStats.Roles.Restored) assigned, $($globalStats.Roles.Errors) errors"
Write-Host "  App Assignments: $($globalStats.Apps.Restored) assigned, $($globalStats.Apps.Errors) errors"
Write-Host "  App Ownership: $($globalStats.AppOwnership.Restored) added, $($globalStats.AppOwnership.Errors) errors"
if ($exoConnected) {
    Write-Host "  Email Aliases: $($globalStats.Emails.Restored) added, $($globalStats.Emails.Errors) errors"
}
if ($IncludeSharePointPermissions) {
    Write-Host "  SharePoint Permissions: $($globalStats.SharePoint.Restored) granted, $($globalStats.SharePoint.Errors) errors"
}
if ($WhatIf) {
    Write-Host ""
    Write-Host "This was a WhatIf preview. Run without -WhatIf to apply changes." -ForegroundColor Yellow
}
Write-Host ""
