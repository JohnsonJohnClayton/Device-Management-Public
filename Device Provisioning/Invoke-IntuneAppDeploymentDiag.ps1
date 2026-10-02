<#
.SYNOPSIS
    Full-fidelity dump + diagnosis of a single Intune Win32/LOB app deployment.

.DESCRIPTION
    The Intune GUI ("Device install status" export) only gives you outcome rows.
    It does NOT give you: install context, detection rules, requirement rules,
    return codes, supersedence/dependency chains, assignment intent, or the
    per-assignment install context. This script pulls all of that from Graph,
    then joins it against the device/user install status so you can see WHY
    a device is reporting Failed.

    Outputs a multi-sheet-style set of CSVs + a JSON dump of the raw app object,
    plus an on-screen diagnosis summary.

.PARAMETER AppId
    The mobileApp GUID. If you exported from the portal, it is in the filename:
    DeviceInstallStatusByApp_<AppId>.csv

.PARAMETER CsvPath
    Optional. Path to the portal-exported DeviceInstallStatusByApp CSV. If given,
    it is merged with the Graph data instead of re-pulling status.

.PARAMETER TenantId
    Entra tenant ID or verified tenant domain used for the Graph connection.
    Required. Specifying the tenant prevents
    an existing Microsoft Graph session for another tenant from being reused.

.PARAMETER OutputFolder
    Where to drop the artifacts. Defaults to .\IntuneAppDiag_<AppId>_<timestamp>

.EXAMPLE
    .\Invoke-IntuneAppDeploymentDiag.ps1 -TenantId "[tenantID]" -AppId "[appID]" -CsvPath .\DeviceInstallStatusByApp_[appID].csv

.NOTES
    Required Graph scopes (delegated):
        DeviceManagementApps.Read.All
        DeviceManagementManagedDevices.Read.All
        Group.Read.All
        User.Read.All
    Modules: Microsoft.Graph.Authentication (Invoke-MgGraphRequest is used
    throughout so no beta SDK cmdlet drift).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AppId,

    [string]$CsvPath,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory)]
    [string]$TenantId,

    [string]$OutputFolder
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region ---------- Setup ----------
if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Get-Location) ("IntuneAppDiag_{0}_{1}" -f $AppId, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$null = New-Item -Path $OutputFolder -ItemType Directory -Force

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft.Graph.Authentication module not found. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$requiredScopes = @(
    'DeviceManagementApps.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'Group.Read.All',
    'User.Read.All'
)

$ctx = Get-MgContext
$missingScopes = @($requiredScopes | Where-Object { -not $ctx -or $_ -notin $ctx.Scopes })

# TenantId can be either a GUID or a verified domain, whereas Get-MgContext
# returns the tenant GUID. Reconnect whenever TenantId is supplied so an
# otherwise valid cached Graph session from another tenant is never reused.
if (-not $ctx -or $missingScopes.Count -gt 0 -or $TenantId) {
    Write-Host "Connecting to Microsoft Graph tenant '$TenantId'..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome | Out-Null
    $ctx = Get-MgContext
}

if (-not $ctx) {
    throw 'Microsoft Graph connection was not established.'
}

Write-Host ("Graph context: {0} (tenant {1})" -f $ctx.Account, $ctx.TenantId) -ForegroundColor DarkGray

function Invoke-GraphPaged {
    param([Parameter(Mandatory)][string]$Uri)
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($resp.PSObject.Properties.Name -contains 'value') { $resp.value | ForEach-Object { $all.Add($_) } }
        else { $all.Add($resp) }
        $next = if ($resp.PSObject.Properties.Name -contains '@odata.nextLink') { $resp.'@odata.nextLink' } else { $null }
    }
    return $all
}

$base = 'https://graph.microsoft.com/beta/deviceAppManagement'
#endregion

#region ---------- 1. App object + config ----------
Write-Host "`n[1/6] Pulling app definition..." -ForegroundColor Cyan
$appUri = "$base/mobileApps/$AppId"
try {
    $app = Invoke-MgGraphRequest -Method GET -Uri $appUri -OutputType PSObject
} catch {
    $graphError = $_.Exception.Message
    if ($graphError -match '(?i)\b404\b|ResourceNotFound|App with id .+ not found') {
        throw @"
Intune mobile app '$AppId' was not found in the connected tenant.

Connected account: $($ctx.Account)
Connected tenant:  $($ctx.TenantId)
Requested tenant:  $TenantId

Confirm that AppId is the Intune mobile-app ID from Apps > All apps (not an
Entra application/client ID, assignment ID, or managed-app ID), and that the
app has not been deleted. To use another tenant, rerun with -TenantId.

Graph request: $appUri
"@
    }

    throw "Unable to retrieve Intune mobile app '$AppId' from tenant '$($ctx.TenantId)'. $graphError"
}
$app | ConvertTo-Json -Depth 30 | Out-File (Join-Path $OutputFolder 'app_raw.json') -Encoding utf8

$odataType = $app.'@odata.type'
Write-Host ("      {0}  [{1}]" -f $app.displayName, $odataType) -ForegroundColor Gray

$appSummary = [pscustomobject]@{
    DisplayName            = $app.displayName
    Id                     = $app.id
    Type                   = $odataType
    Publisher              = $app.publisher
    DisplayVersion         = if ($app.PSObject.Properties.Name -contains 'displayVersion') { $app.displayVersion } else { $null }
    FileName               = if ($app.PSObject.Properties.Name -contains 'fileName') { $app.fileName } else { $null }
    SetupFilePath          = if ($app.PSObject.Properties.Name -contains 'setupFilePath') { $app.setupFilePath } else { $null }
    InstallCommandLine     = if ($app.PSObject.Properties.Name -contains 'installCommandLine') { $app.installCommandLine } else { $null }
    UninstallCommandLine   = if ($app.PSObject.Properties.Name -contains 'uninstallCommandLine') { $app.uninstallCommandLine } else { $null }
    InstallContext         = if ($app.PSObject.Properties.Name -contains 'installExperience') { $app.installExperience.runAsAccount } else { $null }
    DeviceRestartBehavior  = if ($app.PSObject.Properties.Name -contains 'installExperience') { $app.installExperience.deviceRestartBehavior } else { $null }
    MaxRunTimeInMinutes    = if ($app.PSObject.Properties.Name -contains 'installExperience') { $app.installExperience.maxRunTimeInMinutes } else { $null }
    AllowAvailableUninstall= if ($app.PSObject.Properties.Name -contains 'allowAvailableUninstall') { $app.allowAvailableUninstall } else { $null }
    MinimumSupportedOS     = if ($app.PSObject.Properties.Name -contains 'minimumSupportedWindowsRelease') { $app.minimumSupportedWindowsRelease } else { $null }
    ApplicableArchitectures= if ($app.PSObject.Properties.Name -contains 'applicableArchitectures') { $app.applicableArchitectures } else { $null }
    CreatedDateTime        = $app.createdDateTime
    LastModifiedDateTime   = $app.lastModifiedDateTime
    UploadState            = if ($app.PSObject.Properties.Name -contains 'uploadState') { $app.uploadState } else { $null }
    PublishingState        = $app.publishingState
}
$appSummary | Export-Csv (Join-Path $OutputFolder '01_app_summary.csv') -NoTypeInformation
$appSummary | Format-List | Out-String | Write-Host
#endregion

#region ---------- 2. Detection / requirement / return codes ----------
Write-Host "[2/6] Detection rules, requirement rules, return codes..." -ForegroundColor Cyan

$detection = @()
if ($app.PSObject.Properties.Name -contains 'detectionRules' -and $app.detectionRules) {
    $detection = $app.detectionRules | ForEach-Object {
        [pscustomobject]@{
            RuleType        = $_.'@odata.type' -replace '#microsoft.graph.win32LobApp',''
            Path            = $_.path
            FileOrFolder    = $_.fileOrFolderName
            KeyPath         = $_.keyPath
            ValueName       = $_.valueName
            Check32BitOn64  = $_.check32BitOn64System
            Operator        = $_.operator
            DetectionType   = $_.detectionType
            DetectionValue  = $_.detectionValue
            ProductCode     = $_.productCode
            ProductVersion  = $_.productVersion
            ProductVersionOperator = $_.productVersionOperator
            ScriptContent   = if ($_.scriptContent) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.scriptContent)) } else { $null }
        }
    }
    $detection | Export-Csv (Join-Path $OutputFolder '02_detection_rules.csv') -NoTypeInformation
    # Dump any detection script to its own file so you can actually read it
    $i = 0
    foreach ($d in $detection) {
        if ($d.ScriptContent) {
            $i++
            $d.ScriptContent | Out-File (Join-Path $OutputFolder ("02_detection_script_{0}.ps1" -f $i)) -Encoding utf8
        }
    }
    Write-Host "      Detection rules:" -ForegroundColor Gray
    $detection | Select-Object RuleType,Path,FileOrFolder,KeyPath,ValueName,Operator,DetectionType,DetectionValue,ProductCode,ProductVersion | Format-Table -AutoSize | Out-String | Write-Host
}

if ($app.PSObject.Properties.Name -contains 'requirementRules' -and $app.requirementRules) {
    $app.requirementRules | ForEach-Object {
        [pscustomobject]@{
            RuleType = $_.'@odata.type'; Path=$_.path; FileOrFolder=$_.fileOrFolderName
            KeyPath=$_.keyPath; ValueName=$_.valueName; Operator=$_.operator
            DetectionType=$_.detectionType; DetectionValue=$_.detectionValue
        }
    } | Export-Csv (Join-Path $OutputFolder '03_requirement_rules.csv') -NoTypeInformation
}

if ($app.PSObject.Properties.Name -contains 'returnCodes' -and $app.returnCodes) {
    $app.returnCodes |
        ForEach-Object { [pscustomobject]@{ ReturnCode=$_.returnCode; Type=$_.type } } |
        Export-Csv (Join-Path $OutputFolder '04_return_codes.csv') -NoTypeInformation
    Write-Host "      Return code map:" -ForegroundColor Gray
    $app.returnCodes | ForEach-Object { "        {0} => {1}" -f $_.returnCode, $_.type } | Write-Host
}
#endregion

#region ---------- 3. Supersedence & dependencies ----------
Write-Host "`n[3/6] Supersedence / dependency relationships..." -ForegroundColor Cyan
try {
    $rel = Invoke-GraphPaged "$base/mobileApps/$AppId/relationships"
    if ($rel.Count) {
        $rel | ForEach-Object {
            [pscustomobject]@{
                RelationshipType   = $_.'@odata.type'
                TargetId           = $_.targetId
                TargetDisplayName  = $_.targetDisplayName
                TargetDisplayVersion = $_.targetDisplayVersion
                TargetType         = $_.targetType
                SupersedenceType   = $_.supersedenceType   # update | replace
                DependencyType     = $_.dependencyType     # detect | autoInstall
            }
        } | Export-Csv (Join-Path $OutputFolder '05_relationships.csv') -NoTypeInformation
        $rel | Format-Table targetDisplayName, targetDisplayVersion, supersedenceType, dependencyType -AutoSize | Out-String | Write-Host
    } else { Write-Host "      None." -ForegroundColor Gray }
} catch { Write-Warning "Relationships query failed: $($_.Exception.Message)" }
#endregion

#region ---------- 4. Assignments (this is where install-context lives) ----------
Write-Host "[4/6] Assignments..." -ForegroundColor Cyan
$assignments = Invoke-GraphPaged "$base/mobileApps/$AppId/assignments"
$assignRows = foreach ($a in $assignments) {
    $t = $a.target
    $groupName = $null
    if ($t.PSObject.Properties.Name -contains 'groupId' -and $t.groupId) {
        try { $groupName = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($t.groupId)?`$select=displayName" -OutputType PSObject).displayName }
        catch { $groupName = "<unresolvable: $($t.groupId)>" }
    }
    [pscustomobject]@{
        Intent          = $a.intent                                  # required | available | uninstall
        TargetType      = $t.'@odata.type'
        GroupId         = if ($t.PSObject.Properties.Name -contains 'groupId') { $t.groupId } else { $null }
        GroupName       = $groupName
        # THE critical field: per assignment, does this deliver in user or device context?
        InstallContext  = if ($a.settings -and ($a.settings.PSObject.Properties.Name -contains 'deliveryOptimizationPriority')) { $a.settings.'@odata.type' } else { $null }
        Notifications   = if ($a.settings) { $a.settings.notifications } else { $null }
        RestartSettings = if ($a.settings -and $a.settings.restartSettings) { ($a.settings.restartSettings | ConvertTo-Json -Compress) } else { $null }
        DeadlineUtc     = if ($a.settings -and $a.settings.installTimeSettings) { $a.settings.installTimeSettings.deadlineDateTime } else { $null }
        AvailableUtc    = if ($a.settings -and $a.settings.installTimeSettings) { $a.settings.installTimeSettings.startDateTime } else { $null }
        FilterId        = $t.deviceAndAppManagementAssignmentFilterId
        FilterType      = $t.deviceAndAppManagementAssignmentFilterType
        AutoUpdate      = if ($a.settings -and ($a.settings.PSObject.Properties.Name -contains 'autoUpdateSettings')) { ($a.settings.autoUpdateSettings | ConvertTo-Json -Compress) } else { $null }
    }
}
$assignRows | Export-Csv (Join-Path $OutputFolder '06_assignments.csv') -NoTypeInformation
$assignRows | Format-Table Intent, GroupName, TargetType, FilterType, DeadlineUtc -AutoSize | Out-String | Write-Host

# Flag the classic misconfiguration: same app targeted at BOTH user groups and device groups
$userTargets   = $assignRows | Where-Object { $_.TargetType -notmatch 'allDevices' }
$hasUserTarget = [bool]($assignRows | Where-Object { $_.TargetType -match 'allLicensedUsers' -or $_.GroupName })
#endregion

#region ---------- 5. Install status (device + user reports) ----------
Write-Host "[5/6] Pulling install status reports..." -ForegroundColor Cyan
$deviceStatus = Invoke-GraphPaged "$base/mobileApps/$AppId/deviceStatuses"
$userStatus   = Invoke-GraphPaged "$base/mobileApps/$AppId/userStatuses"

$deviceStatus | ForEach-Object {
    [pscustomobject]@{
        DeviceName=$_.deviceName; DeviceId=$_.deviceId; UserName=$_.userName
        UserPrincipalName=$_.userPrincipalName; InstallState=$_.installState
        InstallStateDetail=$_.installStateDetail; ErrorCode=$_.errorCode
        HexErrorCode = if ($_.errorCode) { '0x{0:X8}' -f ([uint32]([int64]$_.errorCode -band 0xFFFFFFFF)) } else { $null }
        OSVersion=$_.osVersion; OSDescription=$_.osDescription
        LastSyncDateTime=$_.lastSyncDateTime
    }
} | Export-Csv (Join-Path $OutputFolder '07_device_status.csv') -NoTypeInformation

$userStatus | ForEach-Object {
    [pscustomobject]@{
        UserPrincipalName=$_.userPrincipalName; UserDisplayName=$_.userDisplayName
        Installed=$_.installedDeviceCount; Failed=$_.failedDeviceCount
        NotInstalled=$_.notInstalledDeviceCount
    }
} | Export-Csv (Join-Path $OutputFolder '08_user_status.csv') -NoTypeInformation

$appInstallSummary = Invoke-MgGraphRequest -Method GET -Uri "$base/mobileApps/$AppId/installSummary" -OutputType PSObject
$appInstallSummary | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutputFolder '09_install_summary.json') -Encoding utf8
Write-Host "      Install summary:" -ForegroundColor Gray
$appInstallSummary | Format-List | Out-String | Write-Host
#endregion

#region ---------- 6. Diagnosis ----------
Write-Host "[6/6] Analysis..." -ForegroundColor Cyan

# Prefer the portal CSV if supplied (it carries the AppVersion column Graph omits)
$rows = $null
if ($CsvPath -and (Test-Path $CsvPath)) {
    $rows = Import-Csv $CsvPath
} else {
    $rows = Import-Csv (Join-Path $OutputFolder '07_device_status.csv')
}

$norm = foreach ($r in $rows) {
    $state = if ($r.PSObject.Properties.Name -contains 'AppInstallState_loc') { $r.'AppInstallState_loc' } else { $r.InstallState }
    $hex   = if ($r.PSObject.Properties.Name -contains 'HexErrorCode') { $r.HexErrorCode } else { $r.HexErrorCode }
    $when  = if ($r.PSObject.Properties.Name -contains 'LastModifiedDateTime') { $r.LastModifiedDateTime } else { $r.LastSyncDateTime }
    [pscustomobject]@{
        DeviceName = $r.DeviceName
        UPN        = $r.UserPrincipalName
        Context    = if ([string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { 'Device(SYSTEM)' } else { 'User' }
        Version    = if ($r.PSObject.Properties.Name -contains 'AppVersion') { $r.AppVersion } else { $null }
        State      = $state
        Hex        = $hex
        When       = try { [datetime]$when } catch { $null }
    }
}

Write-Host "`n--- Outcome by reporting context ---" -ForegroundColor Yellow
$norm | Group-Object Context, State | Sort-Object Name |
    ForEach-Object { "{0,-28} {1}" -f $_.Name, $_.Count } | Write-Host

Write-Host "`n--- Outcome by app version ---" -ForegroundColor Yellow
$norm | Where-Object Version | Group-Object Version, State | Sort-Object Name |
    ForEach-Object { "{0,-28} {1}" -f $_.Name, $_.Count } | Write-Host

Write-Host "`n--- Error code distribution ---" -ForegroundColor Yellow
$norm | Where-Object Hex | Group-Object Hex |
    ForEach-Object { "{0,-14} {1}" -f $_.Name, $_.Count } | Write-Host

Write-Host "`n--- Failure onset (first failure per error code) ---" -ForegroundColor Yellow
$norm | Where-Object { $_.Hex -and $_.When } | Group-Object Hex | ForEach-Object {
    "{0,-14} first={1:u}  last={2:u}  n={3}" -f $_.Name,
        ($_.Group.When | Measure-Object -Minimum).Minimum,
        ($_.Group.When | Measure-Object -Maximum).Maximum, $_.Count
} | Write-Host

Write-Host "`n--- Devices reporting Installed (device ctx) AND Failed (user ctx) ---" -ForegroundColor Yellow
$dual = $norm | Group-Object DeviceName | Where-Object {
    ($_.Group | Where-Object { $_.Context -eq 'Device(SYSTEM)' -and $_.State -eq 'Installed' }) -and
    ($_.Group | Where-Object { $_.Context -eq 'User' -and $_.State -eq 'Failed' })
}
Write-Host ("      {0} device(s). These are almost certainly NOT real failures." -f $dual.Count)
$dual | Select-Object -ExpandProperty Name | Sort-Object |
    Export-Csv (Join-Path $OutputFolder '10_false_failures.csv') -NoTypeInformation

Write-Host "`n--- Devices that have NEVER reported Installed (real investigation targets) ---" -ForegroundColor Yellow
$realFail = $norm | Group-Object DeviceName | Where-Object { 'Installed' -notin $_.Group.State }
$realFail | Select-Object @{n='DeviceName';e={$_.Name}},
    @{n='Errors';e={ ($_.Group.Hex | Sort-Object -Unique) -join ',' }} |
    Tee-Object -Variable rf | Format-Table -AutoSize | Out-String | Write-Host
$rf | Export-Csv (Join-Path $OutputFolder '11_real_failures.csv') -NoTypeInformation

Write-Host "`nArtifacts written to: $OutputFolder" -ForegroundColor Green
#endregion
