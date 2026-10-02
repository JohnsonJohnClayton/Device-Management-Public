<#
.SYNOPSIS
    Restores Entra ID user configuration from backup JSON file.

.DESCRIPTION
    This script restores the following for users from a backup file:
    - Group memberships and group ownership
    - Entra role assignments
    - App role assignments and app ownership
    - Email aliases/proxy addresses (requires Exchange Online)

    The user must already exist in Entra ID. This script will NOT create users.
    Can restore individual users or all users in the backup file.

.PARAMETER BackupFile
    Path to backup JSON file created by Start-EntraUserBackup.ps1

.PARAMETER UserUPN
    UPN of user to restore (must already exist in Entra ID). If not specified, restores all users in backup.

.PARAMETER RestoreAll
    Switch to restore all users in the backup file without prompting.

.PARAMETER WhatIf
    Preview mode (no actual changes)

.PARAMETER IncludeEmailAliases
    Restore email aliases via Exchange Online. Requires Exchange Online connection.
    Default: $true

.EXAMPLE
    .\Start-EntraUserRestore_Local.ps1 -BackupFile "C:\temp\MTO_Users_2026-01-16_14-30-00.json" -UserUPN "user@example.net"

.EXAMPLE
    .\Start-EntraUserRestore_Local.ps1 -BackupFile "C:\temp\MTO_Users_2026-01-16_14-30-00.json" -RestoreAll

.EXAMPLE
    .\Start-EntraUserRestore_Local.ps1 -BackupFile "C:\temp\MTO_Users_2026-01-16_14-30-00.json" -UserUPN "user@example.net" -WhatIf
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$BackupFile,

    [Parameter(Mandatory = $false)]
    [string[]]$UserUPN,

    [Parameter(Mandatory = $false)]
    [switch]$RestoreAll = $false,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf = $false,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeEmailAliases = $true
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "=== Entra User Restoration ===" -ForegroundColor Cyan
Write-Host "Backup file: $BackupFile"
if ($WhatIf) { Write-Host "Mode: WhatIf (preview only)" -ForegroundColor Yellow }
Write-Host ""

# ============================================================================
# VALIDATE BACKUP FILE
# ============================================================================

if (-not (Test-Path $BackupFile)) {
    Write-Error "Backup file not found: $BackupFile"
    exit 1
}

try {
    Write-Host "[*] Loading backup file..." -ForegroundColor Yellow
    $backup = Get-Content $BackupFile | ConvertFrom-Json -ErrorAction Stop
    Write-Host "[✓] Backup loaded (v$($backup.BackupMetadata.BackupVersion))" -ForegroundColor Green
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
        Connect-MgGraph -Scopes "User.Read.All", "Group.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "Application.ReadWrite.All", "Directory.ReadWrite.All" `
          -ErrorAction Stop | Out-Null
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
            Connect-ExchangeOnline -ErrorAction Stop | Out-Null
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
}

foreach ($upn in $usersToRestore) {
    $totalUsers++
    
    Write-Host "[*] User $totalUsers/$($usersToRestore.Count): $upn" -ForegroundColor Yellow
    
    # Find user in backup
    $userBackup = $backup.Users | Where-Object { $_.UserPrincipalName -eq $upn }
    
    if (-not $userBackup) {
        Write-Error "User '$upn' not found in backup file"
        continue
    }
    
    Write-Host "  [✓] Found in backup: $($userBackup.DisplayName)" -ForegroundColor Green
    
    # Find user in Entra ID
    try {
        $restoredUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction Stop
        if (-not $restoredUser) {
            Write-Error "User '$upn' not found in Entra ID"
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
        $emailResult = Restore-UserEmailAliases -UserBackup $userBackup -UserUPN $upn -WhatIfMode $WhatIf -ExoConnected $exoConnected
        Write-Host "    [✓] $($emailResult.Restored) added, $($emailResult.Errors) errors"
        $globalStats.Emails.Restored += $emailResult.Restored
        $globalStats.Emails.Errors += $emailResult.Errors
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
if ($WhatIf) {
    Write-Host ""
    Write-Host "This was a WhatIf preview. Run without -WhatIf to apply changes." -ForegroundColor Yellow
}
Write-Host ""