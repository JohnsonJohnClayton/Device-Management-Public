<#
.SYNOPSIS
    Backs up Entra ID user configuration including groups, roles, and email aliases.

.DESCRIPTION
    This script backs up the following for specified users:
    - Group memberships and group ownership
    - Entra role assignments
    - App role assignments and app ownership
    - Email aliases/proxy addresses (via Graph)

    Can backup individual users by UPN or all users in a specific group by GroupId.
    Output is saved as a JSON file with timestamp.

.PARAMETER UserUPNs
    Array of user UPNs to backup (e.g., "user1@example.com", "user2@example.com")

.PARAMETER GroupId
    GroupId to backup all members from. If specified, UserUPNs is ignored.

.PARAMETER BackupPath
    Directory to save backup JSON file. Default: C:\temp

.EXAMPLE
    .\Start-EntraUserBackup_Local.ps1 -UserUPNs "user@example.net" -BackupPath "C:\temp"

.EXAMPLE
    .\Start-EntraUserBackup_Local.ps1 -UserUPNs "user1@example.com","user2@example.com" -BackupPath "C:\backups"

.EXAMPLE
    .\Start-EntraUserBackup_Local.ps1 -GroupId "12345678-1234-1234-1234-123456789012" -BackupPath "C:\temp"
#>

param (
    [Parameter(Mandatory = $false)]
    [string[]]$UserUPNs,

    [Parameter(Mandatory = $false)]
    [string]$GroupId,

    [Parameter(Mandatory = $false)]
    [string]$BackupPath = "C:\temp"
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backupFile = Join-Path $BackupPath "MTO_Users_$timestamp.json"

Write-Host ""
Write-Host "=== Entra User Backup ===" -ForegroundColor Cyan
Write-Host "Backup path: $BackupPath"
Write-Host "Timestamp: $timestamp"
Write-Host ""

# Validate backup path
if (-not (Test-Path $BackupPath)) {
    Write-Host "[*] Creating backup directory: $BackupPath" -ForegroundColor Yellow
    try {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        Write-Host "[✓] Directory created" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create backup directory: $_"
        exit 1
    }
}

# Determine backup source (GroupId or UserUPNs)
if ($GroupId) {
    Write-Host "[*] Backing up all users in group: $GroupId" -ForegroundColor Yellow
} else {
    # Get user UPNs if not provided
    if (-not $UserUPNs) {
        $userInput = Read-Host "Enter user UPN(s) to backup (comma-separated)"
        $UserUPNs = @($userInput -split "," | ForEach-Object { $_.Trim() })
    }
    
    Write-Host "[*] Users to backup: $($UserUPNs.Count)"
    $UserUPNs | ForEach-Object { Write-Host "    - $_" }
}
Write-Host ""

# ============================================================================
# CONNECT TO MICROSOFT GRAPH
# ============================================================================

Write-Host "[*] Connecting to Microsoft Graph..." -ForegroundColor Yellow
try {
    $mgContext = Get-MgContext -ErrorAction SilentlyContinue
    
    if ($null -eq $mgContext) {
        Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "RoleManagement.Read.Directory", "Application.Read.All" `
          -ErrorAction Stop | Out-Null
    }
    Write-Host "[✓] Connected to Graph" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to Graph: $_"
    exit 1
}

# ============================================================================
# GET USERS TO BACKUP
# ============================================================================

$usersToBackup = @()

if ($GroupId) {
    Write-Host "[*] Retrieving group members..." -ForegroundColor Yellow
    try {
        $groupMembers = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop
        
        # Filter for user objects only (exclude other object types like devices, groups, etc.)
        $userMembers = $groupMembers | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.user" }
        
        Write-Host "[✓] Found $($userMembers.Count) user(s) in group" -ForegroundColor Green
        
        foreach ($member in $userMembers) {
            try {
                $user = Get-MgUser -UserId $member.Id -Property "id,userPrincipalName,displayName,mail,proxyAddresses" -ErrorAction SilentlyContinue
                if ($user) {
                    $usersToBackup += $user.UserPrincipalName
                }
            } catch {
                Write-Warning "Failed to retrieve user details for $($member.Id): $_"
            }
        }
        
        if ($usersToBackup.Count -eq 0) {
            Write-Error "No valid users found in group"
            exit 1
        }
        
        Write-Host "[✓] Users to backup: $($usersToBackup.Count)"
        $usersToBackup | ForEach-Object { Write-Host "    - $_" }
        
    } catch {
        Write-Error "Failed to retrieve group members: $_"
        exit 1
    }
} else {
    $usersToBackup = $UserUPNs
}

Write-Host ""

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================

function Get-UserGroupMemberships {
    param([string]$UserId)
    
    try {
        $groups = Get-MgUserMemberOf -UserId $UserId -ErrorAction SilentlyContinue | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.group" }
        $groupDetails = @()
        $groupCount = 0
        
        foreach ($group in $groups) {
            try {
                $groupInfo = Get-MgGroup -GroupId $group.Id -ErrorAction SilentlyContinue
                
                if ($groupInfo) {
                    # Get group owners
                    $owners = Get-MgGroupOwner -GroupId $group.Id -ErrorAction SilentlyContinue
                    $ownerList = @($owners | ForEach-Object { 
                        @{
                            Id   = $_.Id
                            Type = $_.AdditionalProperties["@odata.type"]
                        }
                    })
                    
                    $groupDetails += @{
                        Id             = $group.Id
                        DisplayName    = $groupInfo.DisplayName
                        GroupTypes     = $groupInfo.GroupTypes
                        Owners         = $ownerList
                    }
                    $groupCount++
                }
            } catch {
                Write-Warning "Failed to get details for group $($group.Id): $_"
            }
        }
        
        return @{
            Details = $groupDetails
            Count   = $groupCount
        }
    } catch {
        Write-Warning "Failed to get group memberships for user $UserId : $_"
        return @{
            Details = @()
            Count   = 0
        }
    }
}

function Get-UserEntraRoles {
    param([string]$UserId)
    
    try {
        $roleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$UserId'" -ErrorAction SilentlyContinue
        $roleDetails = @()
        $roleCount = 0
        
        foreach ($assignment in $roleAssignments) {
            try {
                $roleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId -ErrorAction SilentlyContinue
                
                if ($roleDefinition) {
                    $roleDetails += @{
                        RoleDefinitionId = $assignment.RoleDefinitionId
                        RoleName         = $roleDefinition.DisplayName
                        AssignmentId     = $assignment.Id
                        ScopeId          = $assignment.ResourceScope
                    }
                    $roleCount++
                }
            } catch {
                Write-Warning "Failed to get role details for assignment $($assignment.Id): $_"
            }
        }
        
        return @{
            Details = $roleDetails
            Count   = $roleCount
        }
    } catch {
        Write-Warning "Failed to get Entra roles for user $UserId : $_"
        return @{
            Details = @()
            Count   = 0
        }
    }
}

function Get-UserAppRoleAssignments {
    param([string]$UserId)
    
    try {
        $appAssignments = Get-MgUserAppRoleAssignment -UserId $UserId -ErrorAction SilentlyContinue
        $appDetails = @()
        $appCount = 0
        
        foreach ($assignment in $appAssignments) {
            try {
                $servicePrincipal = Get-MgServicePrincipal -ServicePrincipalId $assignment.ResourceId -ErrorAction SilentlyContinue
                
                if ($servicePrincipal) {
                    $appRole = $servicePrincipal.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }
                    
                    # Get app owners
                    $appOwners = Get-MgServicePrincipalOwner -ServicePrincipalId $servicePrincipal.Id -ErrorAction SilentlyContinue
                    $ownerList = @($appOwners | ForEach-Object { 
                        @{
                            Id   = $_.Id
                            Type = $_.AdditionalProperties["@odata.type"]
                        }
                    })
                    
                    $appDetails += @{
                        AppRoleId              = $assignment.AppRoleId
                        ResourceId             = $assignment.ResourceId
                        ResourceAppId          = $servicePrincipal.AppId
                        ResourceDisplayName    = $servicePrincipal.DisplayName
                        AppRoleDisplayName     = $appRole.DisplayName
                        AppOwners              = $ownerList
                    }
                    $appCount++
                }
            } catch {
                Write-Warning "Failed to get app details for assignment $($assignment.Id): $_"
            }
        }
        
        return @{
            Details = $appDetails
            Count   = $appCount
        }
    } catch {
        Write-Warning "Failed to get app role assignments for user $UserId : $_"
        return @{
            Details = @()
            Count   = 0
        }
    }
}

function Get-UserEmailAliases {
    param([object]$User)
    
    try {
        $aliases = @()
        
        # Get proxyAddresses from the user object
        if ($User.ProxyAddresses -and $User.ProxyAddresses.Count -gt 0) {
            $aliases = @($User.ProxyAddresses)
        }
        
        return $aliases
    } catch {
        Write-Warning "Failed to get email aliases for user $($User.UserPrincipalName) : $_"
        return @()
    }
}

# ============================================================================
# BACKUP USERS
# ============================================================================

$backupData = @{
    BackupMetadata = @{
        BackupVersion = "1.0"
        BackupDate    = Get-Date -Format "o"
        BackupBy      = $env:USERNAME
        ComputerName  = $env:COMPUTERNAME
    }
    Users          = @()
}

$totalUsers = 0
$successfulUsers = 0

foreach ($upn in $usersToBackup) {
    $totalUsers++
    
    Write-Host ""
    Write-Host "[*] Processing user: $upn" -ForegroundColor Yellow
    
    try {
        # Get user (include proxyAddresses)
        $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property "id,userPrincipalName,displayName,mail,proxyAddresses" -ErrorAction Stop
        
        if (-not $user) {
            Write-Warning "User '$upn' not found in Entra ID"
            continue
        }
        
        Write-Host "  [✓] Found user: $($user.DisplayName)" -ForegroundColor Green
        
        # Backup group memberships
        Write-Host "  [*] Backing up group memberships..." -ForegroundColor Cyan
        $groupResult = Get-UserGroupMemberships -UserId $user.Id
        Write-Host "  [✓] Backed up $($groupResult.Count) group(s)" -ForegroundColor Green
        
        # Backup Entra roles
        Write-Host "  [*] Backing up Entra roles..." -ForegroundColor Cyan
        $roleResult = Get-UserEntraRoles -UserId $user.Id
        Write-Host "  [✓] Backed up $($roleResult.Count) role(s)" -ForegroundColor Green
        
        # Backup app role assignments
        Write-Host "  [*] Backing up app role assignments..." -ForegroundColor Cyan
        $appResult = Get-UserAppRoleAssignments -UserId $user.Id
        Write-Host "  [✓] Backed up $($appResult.Count) app assignment(s)" -ForegroundColor Green
        
        # Backup email aliases
        Write-Host "  [*] Backing up email aliases..." -ForegroundColor Cyan
        $emailAliases = Get-UserEmailAliases -User $user
        Write-Host "  [✓] Backed up $($emailAliases.Count) email alias(es)" -ForegroundColor Green
        
        # Add to backup
        $backupData.Users += @{
            UserPrincipalName     = $user.UserPrincipalName
            ObjectId              = $user.Id
            DisplayName           = $user.DisplayName
            Mail                  = $user.Mail
            GroupMemberships      = $groupResult.Details
            EntraRoles            = $roleResult.Details
            AppRoleAssignments    = $appResult.Details
            EmailAliases          = $emailAliases
        }
        
        Write-Host "  [✓] User backup complete" -ForegroundColor Green
        $successfulUsers++
        
    } catch {
        Write-Error "Failed to backup user $upn : $_"
    }
}

# ============================================================================
# SAVE BACKUP FILE
# ============================================================================

Write-Host ""
Write-Host "[*] Saving backup file..." -ForegroundColor Yellow

try {
    $backupData | ConvertTo-Json -Depth 10 | Out-File -FilePath $backupFile -Encoding UTF8 -ErrorAction Stop
    Write-Host "[✓] Backup saved: $backupFile" -ForegroundColor Green
} catch {
    Write-Error "Failed to save backup file: $_"
    exit 1
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "=== Backup Summary ===" -ForegroundColor Cyan
Write-Host "Total users processed: $totalUsers"
Write-Host "Successful backups: $successfulUsers"
Write-Host "Backup file: $backupFile"
Write-Host "File size: $('{0:N0}' -f (Get-Item $backupFile).Length) bytes"
Write-Host ""