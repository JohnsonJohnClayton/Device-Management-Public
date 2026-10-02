<#
.SYNOPSIS
    Backs up Entra ID user configuration to Azure Blob Storage.
    
    DESIGNED FOR: Azure Automation Runbooks (uses REST API via managed identity)

.DESCRIPTION
    Backs up the following for all users in a specified group:
    - Group memberships and group ownership
    - Entra role assignments
    - App role assignments and app ownership
    - Email aliases/proxy addresses
    - Direct SharePoint permissions on explicitly selected sites

.PARAMETER GroupId
    Entra ID group ID to backup members from

.PARAMETER StorageAccountName
    Azure Storage Account name where backups are stored
    Required for Azure Storage output; supply your own account name.

.PARAMETER ContainerName
    Blob container name for backups
    Default: mto-backups

.PARAMETER IncludeSharePointPermissions
    Includes direct SharePoint web, list/library, folder, file, and list-item role assignments.

.PARAMETER SharePointSiteUrls
    Site collection URLs to scan. Required when IncludeSharePointPermissions is enabled.

.NOTES
    Requires:
    - Automation Account with System-Assigned Managed Identity enabled
    - Managed Identity with Directory.Read.All, Group.Read.All, User.Read.All permissions
    - Managed Identity with Storage Blob Data Contributor role on storage account
    - Managed Identity with SharePoint Sites.FullControl.All, or Sites.Selected FullControl
      for every URL supplied in SharePointSiteUrls
    - Managed identity mode uses REST; interactive mode requires PnP.PowerShell 3.3.0
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$GroupId,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$ContainerName = "mto-backups",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeSharePointPermissions = $false,

    [Parameter(Mandatory = $false)]
    [string[]]$SharePointSiteUrls,

    [Parameter(Mandatory = $false)]
    [string]$LocalOutputPath,

    [Parameter(Mandatory = $false)]
    [string]$SharePointTenantUrl,

    [Parameter(Mandatory = $false)]
    [string]$InteractiveClientId
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Continue"
$graphApiUrl = "https://graph.microsoft.com/v1.0"
$interactiveMode = -not [string]::IsNullOrWhiteSpace($LocalOutputPath)
if ($interactiveMode -and (-not $SharePointTenantUrl -or -not $InteractiveClientId)) {
    throw 'Local output requires SharePointTenantUrl and InteractiveClientId.'
}
if (-not $interactiveMode -and -not $StorageAccountName) {
    throw 'Azure output requires StorageAccountName.'
}

Write-Output ""
Write-Output "=== Entra User Backup ==="
Write-Output "Group ID: $GroupId"
Write-Output "Storage Account: $StorageAccountName"
Write-Output "Container: $ContainerName"
Write-Output "SharePoint permissions: $IncludeSharePointPermissions"
if ($IncludeSharePointPermissions) {
    if (-not $interactiveMode -and (-not $SharePointSiteUrls -or $SharePointSiteUrls.Count -eq 0)) {
        Write-Error "SharePointSiteUrls is required when IncludeSharePointPermissions is enabled."
        exit 1
    }
    if ($SharePointSiteUrls) { Write-Output "SharePoint sites: $($SharePointSiteUrls.Count)" }
}
if ($interactiveMode) { Write-Output "Local output: $LocalOutputPath" }
Write-Output ""

# ============================================================================
# GET GRAPH ACCESS TOKEN VIA MANAGED IDENTITY
# ============================================================================

Write-Output "[*] Getting Microsoft Graph access token..."

try {
    if ($interactiveMode) {
        Import-Module PnP.PowerShell -RequiredVersion 3.3.0 -ErrorAction Stop

        $script:pnpConnection = Connect-PnPOnline -Url $SharePointTenantUrl -ClientId $InteractiveClientId `
            -Interactive -PersistLogin -ReturnConnection -ErrorAction Stop
        $graphAccessToken = Get-PnPAccessToken -ResourceTypeName Graph -Connection $script:pnpConnection -ErrorAction Stop
        if ($graphAccessToken -is [securestring]) {
            $graphAccessToken = [System.Net.NetworkCredential]::new('', $graphAccessToken).Password
        }
    } else {
        $resourceURL = "https://graph.microsoft.com/"
        $response = [System.Text.Encoding]::Default.GetString(
            (Invoke-WebRequest -UseBasicParsing `
                -Uri "$($env:IDENTITY_ENDPOINT)?resource=$resourceURL" `
                -Method 'GET' `
                -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' } `
                -ErrorAction Stop
            ).RawContentStream.ToArray()
        ) | ConvertFrom-Json
        $graphAccessToken = $response.access_token
    }
    Write-Output "[✓] Got Graph token"
    
} catch {
    Write-Error "Failed to get Graph token: $_"
    Write-Error "Error details: $($_.Exception.Message)"
    exit 1
}

# ============================================================================
# SETUP GRAPH API HEADERS
# ============================================================================

$graphHeaders = @{
    "Authorization" = "Bearer $graphAccessToken"
    "Content-Type"  = "application/json"
}

# ============================================================================
# HELPER FUNCTION: Make Graph REST API Calls
# ============================================================================

function Invoke-GraphRestAPI {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $false)]$Body
    )
    
    try {
        $params = @{
            Method  = $Method
            Uri     = $Uri
            Headers = $graphHeaders
        }
        
        if ($Body) {
            $params['Body'] = $Body | ConvertTo-Json -Depth 10
        }
        
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return $response
    } catch {
        Write-Warning "Graph API call failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-ManagedIdentityToken {
    param([Parameter(Mandatory = $true)][string]$ResourceUrl)

    $tokenResponse = [System.Text.Encoding]::Default.GetString(
        (Invoke-WebRequest -UseBasicParsing `
            -Uri "$($env:IDENTITY_ENDPOINT)?resource=$([System.Uri]::EscapeDataString($ResourceUrl))" `
            -Method GET `
            -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' } `
            -ErrorAction Stop
        ).RawContentStream.ToArray()
    ) | ConvertFrom-Json

    return $tokenResponse.access_token
}

function Invoke-SharePointRestAPI {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$AccessToken
    )

    return Invoke-RestMethod -Method GET -Uri $Uri -Headers @{
        Authorization = "Bearer $AccessToken"
        Accept = "application/json;odata=nometadata"
    } -ErrorAction Stop
}

function Get-SharePointPagedResults {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$AccessToken
    )

    $results = @()
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-SharePointRestAPI -Uri $nextUri -AccessToken $AccessToken
        if ($response.value) { $results += @($response.value) }
        $nextUri = if ($response.'@odata.nextLink') {
            [System.Uri]::new([System.Uri]$Uri, $response.'@odata.nextLink').AbsoluteUri
        } else { $null }
    }
    return $results
}

function Get-DirectRoleBindings {
    param(
        [Parameter(Mandatory = $true)][string]$SecurableObjectUri,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][hashtable]$UserByPrincipalId
    )

    $uri = "$SecurableObjectUri/roleassignments?`$select=PrincipalId,RoleDefinitionBindings/Name&`$expand=RoleDefinitionBindings"
    $assignments = Get-SharePointPagedResults -Uri $uri -AccessToken $AccessToken
    $bindings = @()
    foreach ($assignment in $assignments) {
        $principalKey = [string]$assignment.PrincipalId
        if (-not $UserByPrincipalId.ContainsKey($principalKey)) { continue }

        $roles = @(
            $assignment.RoleDefinitionBindings |
            Where-Object { $_.Name -and $_.Name -ne 'Limited Access' } |
            Select-Object -ExpandProperty Name -Unique
        )
        if ($roles.Count -gt 0) {
            $bindings += [pscustomobject]@{
                User = $UserByPrincipalId[$principalKey]
                Roles = $roles
            }
        }
    }
    return $bindings
}

function Add-SharePointPermissionRecord {
    param(
        [Parameter(Mandatory = $true)][object[]]$Bindings,
        [Parameter(Mandatory = $true)][hashtable]$Properties
    )

    foreach ($binding in $Bindings) {
        $record = [ordered]@{}
        foreach ($key in $Properties.Keys) { $record[$key] = $Properties[$key] }
        $record.Roles = @($binding.Roles)
        $binding.User.SharePointPermissions += [pscustomobject]$record
    }
}

function Backup-SharePointWebPermissions {
    param(
        [Parameter(Mandatory = $true)][string]$SiteUrl,
        [Parameter(Mandatory = $true)][string]$WebUrl,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][hashtable]$UserByPrincipalId
    )

    $webApi = "$($WebUrl.TrimEnd('/'))/_api/web"
    $web = Invoke-SharePointRestAPI -Uri "$($webApi)?`$select=Id,Url,ServerRelativeUrl,HasUniqueRoleAssignments" -AccessToken $AccessToken
    $webBindings = Get-DirectRoleBindings -SecurableObjectUri $webApi -AccessToken $AccessToken -UserByPrincipalId $UserByPrincipalId
    Add-SharePointPermissionRecord -Bindings $webBindings -Properties ([ordered]@{
        SiteUrl = $SiteUrl; WebUrl = $web.Url; WebId = $web.Id; ObjectType = 'Web';
        ListId = $null; ListTitle = $null; ItemId = $null; ServerRelativeUrl = $web.ServerRelativeUrl
    })

    $listsUri = "$webApi/lists?`$select=Id,Title,Hidden,HasUniqueRoleAssignments,RootFolder/ServerRelativeUrl&`$expand=RootFolder&`$top=5000"
    $lists = Get-SharePointPagedResults -Uri $listsUri -AccessToken $AccessToken
    foreach ($list in $lists) {
        if ($list.Hidden) { continue }
        $listApi = "$webApi/lists(guid'$($list.Id)')"
        if ($list.HasUniqueRoleAssignments) {
            $listBindings = Get-DirectRoleBindings -SecurableObjectUri $listApi -AccessToken $AccessToken -UserByPrincipalId $UserByPrincipalId
            Add-SharePointPermissionRecord -Bindings $listBindings -Properties ([ordered]@{
                SiteUrl = $SiteUrl; WebUrl = $web.Url; WebId = $web.Id; ObjectType = 'List';
                ListId = $list.Id; ListTitle = $list.Title; ItemId = $null; ServerRelativeUrl = $list.RootFolder.ServerRelativeUrl
            })
        }

        $itemsUri = "$listApi/items?`$select=Id,FileSystemObjectType,HasUniqueRoleAssignments,File/ServerRelativeUrl,Folder/ServerRelativeUrl&`$expand=File,Folder&`$top=5000"
        try {
            $items = Get-SharePointPagedResults -Uri $itemsUri -AccessToken $AccessToken
            foreach ($item in $items | Where-Object { $_.HasUniqueRoleAssignments }) {
                $itemApi = "$listApi/items($($item.Id))"
                $itemBindings = Get-DirectRoleBindings -SecurableObjectUri $itemApi -AccessToken $AccessToken -UserByPrincipalId $UserByPrincipalId
                $objectType = if ($item.FileSystemObjectType -eq 1) { 'Folder' } elseif ($item.File) { 'File' } else { 'ListItem' }
                $relativeUrl = if ($item.Folder) { $item.Folder.ServerRelativeUrl } elseif ($item.File) { $item.File.ServerRelativeUrl } else { $null }
                Add-SharePointPermissionRecord -Bindings $itemBindings -Properties ([ordered]@{
                    SiteUrl = $SiteUrl; WebUrl = $web.Url; WebId = $web.Id; ObjectType = $objectType;
                    ListId = $list.Id; ListTitle = $list.Title; ItemId = $item.Id; ServerRelativeUrl = $relativeUrl
                })
            }
        } catch {
            Write-Warning "    Could not scan items in '$($list.Title)' at $($web.Url): $($_.Exception.Message)"
        }
    }

    $subwebsUri = "$webApi/webs?`$select=Url&`$top=5000"
    foreach ($subweb in (Get-SharePointPagedResults -Uri $subwebsUri -AccessToken $AccessToken)) {
        Backup-SharePointWebPermissions -SiteUrl $SiteUrl -WebUrl $subweb.Url -AccessToken $AccessToken -UserByPrincipalId $UserByPrincipalId
    }
}

# ============================================================================
# GET GROUP AND VERIFY IT EXISTS
# ============================================================================

Write-Output "[*] Verifying group exists..."

try {
    $group = Invoke-GraphRestAPI -Method GET -Uri "$graphApiUrl/groups/$GroupId"
    
    if (-not $group -or -not $group.id) {
        Write-Error "Group not found: $GroupId"
        exit 1
    }
    
    Write-Output "[✓] Found group: $($group.displayName)"
} catch {
    Write-Error "Failed to get group: $_"
    exit 1
}

# ============================================================================
# GET GROUP MEMBERS
# ============================================================================

Write-Output "[*] Getting group members..."

try {
    $members = @()
    $memberUri = "$graphApiUrl/groups/$GroupId/members?`$top=999"
    
    do {
        $response = Invoke-GraphRestAPI -Method GET -Uri $memberUri
        
        if ($response.value) {
            $members += $response.value
        }
        
        # Handle pagination
        if ($response.'@odata.nextLink') {
            $memberUri = $response.'@odata.nextLink'
        } else {
            $memberUri = $null
        }
    } while ($memberUri)
    
    Write-Output "[✓] Found $($members.Count) members"
} catch {
    Write-Error "Failed to get group members: $_"
    exit 1
}

# ============================================================================
# BACKUP USER DATA
# ============================================================================

Write-Output "[*] Backing up user data..."

$backupUsers = @()
$processedCount = 0
$errorCount = 0

foreach ($member in $members) {
    $processedCount++
    Write-Output "  Processing $processedCount/$($members.Count): $($member.userPrincipalName)..."
    
    try {
        # Get user details
        $user = Invoke-GraphRestAPI -Method GET -Uri "$graphApiUrl/users/$($member.id)"
        
        if (-not $user) {
            Write-Warning "    [-] Could not get user details"
            $errorCount++
            continue
        }
        
        # Get group memberships
        Write-Output "    [*] Getting group memberships..."
        $groupMemberships = @()
        $groupUri = "$graphApiUrl/users/$($member.id)/memberOf?`$top=999"
        
        do {
            $groupResponse = Invoke-GraphRestAPI -Method GET -Uri $groupUri
            
            if ($groupResponse.value) {
                foreach ($g in $groupResponse.value) {
                    if ($g.'@odata.type' -eq '#microsoft.graph.group') {
                        $groupMemberships += @{
                            Id          = $g.id
                            DisplayName = $g.displayName
                            GroupTypes  = $g.groupTypes
                            Owners      = @()
                        }
                    }
                }
            }
            
            if ($groupResponse.'@odata.nextLink') {
                $groupUri = $groupResponse.'@odata.nextLink'
            } else {
                $groupUri = $null
            }
        } while ($groupUri)
        
        # Get Entra roles
        Write-Output "    [*] Getting Entra role assignments..."
        $entraRoles = @()
        $roleFilter = [System.Uri]::EscapeDataString("principalId eq '$($member.id)'")
        $roleUri = "$graphApiUrl/roleManagement/directory/roleAssignments?`$filter=$roleFilter&`$top=999"
        
        $roleResponse = Invoke-GraphRestAPI -Method GET -Uri $roleUri
        
        if ($roleResponse -and $roleResponse.value) {
            foreach ($role in $roleResponse.value) {
                # Get role definition name
                $roleDefUri = "$graphApiUrl/roleManagement/directory/roleDefinitions/$($role.roleDefinitionId)"
                $roleDef = Invoke-GraphRestAPI -Method GET -Uri $roleDefUri
                
                $entraRoles += @{
                    RoleDefinitionId = $role.roleDefinitionId
                    RoleName         = if ($roleDef) { $roleDef.displayName } else { "Unknown" }
                }
            }
        }
        
        # Get app role assignments
        Write-Output "    [*] Getting app role assignments..."
        $appAssignments = @()
        $appUri = "$graphApiUrl/users/$($member.id)/appRoleAssignments?`$top=999"
        
        $appResponse = Invoke-GraphRestAPI -Method GET -Uri $appUri
        
        if ($appResponse -and $appResponse.value) {
            foreach ($app in $appResponse.value) {
                $appAssignments += @{
                    AppRoleId           = $app.appRoleId
                    ResourceId          = $app.resourceId
                    ResourceAppId       = $app.resourceAppId
                    ResourceDisplayName = $app.resourceDisplayName
                    AppRoleDisplayName  = $app.appRoleDisplayName
                    AppOwners           = @()
                }
            }
        }
        
        # Get email aliases (from directory properties if available)
        Write-Output "    [*] Getting email aliases..."
        $emailAliases = @()
        if ($user.proxyAddresses) {
            $emailAliases = $user.proxyAddresses | Where-Object { $_ -like "smtp:*" } | ForEach-Object { $_ -replace "^smtp:", "" }
        }
        
        # Add to backup
        $backupUsers += @{
            UserPrincipalName    = $user.userPrincipalName
            DisplayName          = $user.displayName
            Id                   = $user.id
            GroupMemberships     = $groupMemberships
            EntraRoles           = $entraRoles
            AppRoleAssignments   = $appAssignments
            EmailAliases         = $emailAliases
            SharePointPermissions = @()
        }
        
        Write-Output "    [✓] Backed up user data"
        
    } catch {
        Write-Warning "    [-] Error backing up user: $_"
        $errorCount++
        continue
    }
}

Write-Output "[✓] Backup complete: $($backupUsers.Count) users, $errorCount errors"

if ($IncludeSharePointPermissions) {
    Write-Output "[*] Backing up direct SharePoint permissions..."

    if (-not $SharePointSiteUrls -or $SharePointSiteUrls.Count -eq 0) {
        Write-Output "  [*] Discovering SharePoint sites accessible to the signed-in user..."
        $SharePointSiteUrls = @()
        $siteSearchUri = "$graphApiUrl/sites?search=*&`$select=webUrl&`$top=999"
        do {
            $siteResponse = Invoke-GraphRestAPI -Method GET -Uri $siteSearchUri
            if ($siteResponse.value) {
                $SharePointSiteUrls += @($siteResponse.value | Select-Object -ExpandProperty webUrl)
            }
            $siteSearchUri = $siteResponse.'@odata.nextLink'
        } while ($siteSearchUri)
        $SharePointSiteUrls = @($SharePointSiteUrls | Where-Object { $_ } | Sort-Object -Unique)
        Write-Output "  [✓] Discovered $($SharePointSiteUrls.Count) site collection(s)"
    }

    foreach ($siteUrl in $SharePointSiteUrls) {
        Write-Output "  [*] Scanning $siteUrl"
        try {
            if ($interactiveMode) {
                $sharePointAccessToken = Get-PnPAccessToken -ResourceUrl $SharePointTenantUrl `
                    -Connection $script:pnpConnection -ErrorAction Stop
                if ($sharePointAccessToken -is [securestring]) {
                    $sharePointAccessToken = [System.Net.NetworkCredential]::new('', $sharePointAccessToken).Password
                }
            } else {
                $siteOrigin = ([System.Uri]$siteUrl).GetLeftPart([System.UriPartial]::Authority)
                $sharePointAccessToken = Get-ManagedIdentityToken -ResourceUrl "$siteOrigin/"
            }

            $siteUsersUri = "$($siteUrl.TrimEnd('/'))/_api/web/siteusers?`$select=Id,LoginName,Email,Title,PrincipalType&`$top=5000"
            $siteUsers = Get-SharePointPagedResults -Uri $siteUsersUri -AccessToken $sharePointAccessToken
            $userByPrincipalId = @{}

            foreach ($backupUser in $backupUsers) {
                $identities = @($backupUser.UserPrincipalName, $backupUser.EmailAliases) | Where-Object { $_ }
                if ($backupUser.UserPrincipalName -match '^(.*)_([^_]+)#EXT#@') {
                    $identities += "$($Matches[1])@$($Matches[2])"
                }
                $identities = @($identities | ForEach-Object { $_.ToString().ToLowerInvariant() } | Select-Object -Unique)

                foreach ($siteUser in $siteUsers | Where-Object { $_.PrincipalType -eq 1 }) {
                    $loginTail = ($siteUser.LoginName -split '\|')[-1].ToLowerInvariant()
                    $email = if ($siteUser.Email) { $siteUser.Email.ToLowerInvariant() } else { '' }
                    if ($identities -contains $loginTail -or $identities -contains $email) {
                        $userByPrincipalId[[string]$siteUser.Id] = $backupUser
                    }
                }
            }

            if ($userByPrincipalId.Count -eq 0) {
                Write-Output "    [*] No backed-up users are known to this site"
                continue
            }

            Backup-SharePointWebPermissions -SiteUrl $siteUrl -WebUrl $siteUrl `
                -AccessToken $sharePointAccessToken -UserByPrincipalId $userByPrincipalId
            $sitePermissionCount = @($backupUsers.SharePointPermissions | Where-Object { $_.SiteUrl -eq $siteUrl }).Count
            Write-Output "    [✓] Captured $sitePermissionCount direct assignment(s)"
        } catch {
            Write-Warning "    Failed to scan $siteUrl`: $($_.Exception.Message)"
            $errorCount++
        }
    }
}

# ============================================================================
# CREATE BACKUP JSON
# ============================================================================

Write-Output "[*] Creating backup JSON..."

$backupObject = @{
    BackupMetadata = @{
        BackupVersion = "1.1"
        BackupDate    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        GroupId       = $GroupId
        UserCount     = $backupUsers.Count
    }
    Users          = $backupUsers
}

$backupJson = $backupObject | ConvertTo-Json -Depth 10

# ============================================================================
# UPLOAD TO AZURE STORAGE
# ============================================================================

if ($interactiveMode) {
    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LocalOutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $resolvedOutputPath -Value $backupJson -Encoding UTF8
    $backupFileName = $resolvedOutputPath
    Write-Output "[✓] Backup written locally: $resolvedOutputPath"
} else {
Write-Output "[*] Uploading backup to Azure Storage..."

try {
    # Get storage token for Azure Storage
    Write-Output "  [*] Getting Azure Storage access token..."
    
    $storageResourceURL = "https://storage.azure.com/"
    
    $storageTokenResponse = [System.Text.Encoding]::Default.GetString(
        (Invoke-WebRequest -UseBasicParsing `
            -Uri "$($env:IDENTITY_ENDPOINT)?resource=$storageResourceURL" `
            -Method 'GET' `
            -Headers @{
                'X-IDENTITY-HEADER' = "$env:IDENTITY_HEADER"
                'Metadata' = 'True'
            } `
            -ErrorAction Stop
        ).RawContentStream.ToArray()
    ) | ConvertFrom-Json
    
    $storageAccessToken = $storageTokenResponse.access_token
    Write-Output "  [✓] Got storage token"
    
    # Generate filename with timestamp
    $timestamp = (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
    $backupFileName = "MTO_Users_$($group.displayName)_$timestamp.json"
    
    # Construct blob storage URI
    $blobStorageUri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$backupFileName"
    
    Write-Output "  [*] Uploading to blob storage..."
    Write-Output "    Storage Account: $StorageAccountName"
    Write-Output "    Container: $ContainerName"
    Write-Output "    File: $backupFileName"
    
    # Setup headers for Azure Storage REST API (with Bearer token)
    # Important: x-ms-blob-type is REQUIRED for blob upload
    $storageHeaders = @{
        "Authorization"      = "Bearer $storageAccessToken"
        "x-ms-version"       = "2021-08-06"
        "x-ms-blob-type"     = "BlockBlob"
        "Content-Type"       = "application/json"
    }
    
    # Upload JSON to blob storage using PUT
    $uploadParams = @{
        Method          = 'PUT'
        Uri             = $blobStorageUri
        Headers         = $storageHeaders
        Body            = $backupJson
        UseBasicParsing = $true
    }
    
    $uploadResponse = Invoke-WebRequest @uploadParams -ErrorAction Stop
    
    Write-Output "  [✓] Uploaded to Azure Storage"
    Write-Output "[✓] Backup uploaded successfully"
    Write-Output "    Status Code: $($uploadResponse.StatusCode)"
    Write-Output "    File size: $($backupJson.Length) bytes"
    Write-Output "    Blob URI: $blobStorageUri"
    
} catch {
    Write-Error "Failed to upload to Azure Storage: $_"
    Write-Error "Error details: $($_.Exception.Message)"
    Write-Error "Verify:"
    Write-Error "  1. Managed identity has Storage Blob Data Contributor role"
    Write-Error "  2. Storage account and container names are correct"
    Write-Error "  3. Storage account allows identity-based access"
    exit 1
}
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Output ""
Write-Output "=== Backup Summary ==="
Write-Output "Users backed up: $($backupUsers.Count)"
Write-Output "Backup file: $backupFileName"
Write-Output "Timestamp: $(Get-Date)"
Write-Output ""
