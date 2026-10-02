[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $OutputDir = "C:\Temp",

    [Parameter(Mandatory)]
    [string]
    $UPNList,

    [Parameter()]
    [Int32]
    $DayCutoff = 30,

    [Parameter()]
    [switch]
    $GetMailboxStats,

    [Parameter()]
    [switch]
    $ExportAllResults
)

# Connect to the Graph with the appropriate perms
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Green
try { Connect-MgGraph -Scopes 'User.Read.All', 'AuditLog.Read.All', 'Directory.Read.All' -NoWelcome}
catch {
    Write-Warning "There was an issue connecting to Microsoft Graph. Exiting..."
    throw
    exit 1
}   
Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green

# Initialize a CSV from the UPN list
Write-Host "Loading UPN list from: $UPNList" -ForegroundColor Yellow
try {
    $UPNs = Get-Content -Path $UPNList
    Write-Host "Successfully loaded $($UPNs.Count) UPNs from CSV" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to load CSV file: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

# Calculate cutoff time for log checks
$cutoffDate = (Get-Date).AddDays(-$dayCutoff)
$cutoff = $cutoffDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "Using cutoff date: $($cutoffDate.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Cyan

# Initialize progress tracking variables
$totalUsers = $UPNs.Count
$currentUser = 0
$inactiveCount = 0

# Initialize arrays for custom user objects
$userResults = @()
$inactiveUsers = @()

Write-Host "Starting analysis of $totalUsers users for inactive accounts..." -ForegroundColor Yellow

# Loop through user UPNs to generate list of inactive users
foreach ($upn in $UPNs) {
    $currentUser++
    Write-Host "[$currentUser/$totalUsers] Checking user: $upn" -ForegroundColor White

    $percentComplete = [math]::Round(($currentUser / $totalUsers) * 100, 2)
    Write-Progress -Activity "Analyzing User Sign-in Activity" `
                   -Status "Processing $currentUser of $totalUsers users ($percentComplete% complete)" `
                   -CurrentOperation "Current user: $upn" `
                   -PercentComplete $percentComplete

    try {
        $user = Get-MgUser -UserId $upn
        $user = Get-MgUser -UserId $user.id -Property "Id,UserPrincipalName,SignInActivity" -ErrorAction Stop
        $lastSignIn = $user.SignInActivity.LastSignInDateTime
        $lastSignInDate = $null
        if ($lastSignIn) {
            $lastSignInDate = [DateTime]$lastSignIn
        }

        # Create and add the custom object to the results array
        $userObj = [PSCustomObject]@{
            UserPrincipalName = $user.UserPrincipalName
            Id                = $user.Id
            LastSignInDate    = $lastSignInDate
        }
        $userResults += $userObj

        if (-not $lastSignInDate -or ($lastSignInDate -lt $cutoffDate)) {
            $inactiveCount++
            $inactiveUsers += $userObj
            if (-not $lastSignInDate) { Write-Host "  -> INACTIVE: Never signed in" -ForegroundColor Red }
            else { Write-Host "  -> INACTIVE: Last sign-in $($lastSignInDate.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Red }
        } else { Write-Host "  -> ACTIVE: Last sign-in $($lastSignInDate.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green }
    } catch { Write-Host "  -> ERROR: Failed to retrieve user data: $($_.Exception.Message)" -ForegroundColor DarkRed }
}

Write-Progress -Activity "Analyzing User Sign-in Activity" -Completed

Write-Host "`nAnalysis Complete!" -ForegroundColor Green
Write-Host "Total users processed: $totalUsers" -ForegroundColor Cyan
Write-Host "Inactive users found: $inactiveCount" -ForegroundColor Yellow
Write-Host "Active users: $($totalUsers - $inactiveCount)" -ForegroundColor Green

if($ExportAllResults){
    Write-Host "`nAll Results: $($totalUsers - $inactiveCount)"
    $userResults | Format-Table

    # Export all sign in results to a file
    $fileName = "$OutputDir\SignInResults_$(Get-Date -Format "yyyyMMdd").csv"
    $userResults | Export-Csv -Path $fileName -NoTypeInformation
    Write-Host "`nSign In Results Report Exported to: $($filename)" -ForegroundColor Green
}

# Export inactive results to a file
$fileName = "$OutputDir\InactiveUserReport_Last $($DayCutoff)Days_$(Get-Date -Format ("yyyyMMdd")).csv"
$inactiveUsers | Export-Csv -Path $fileName -NoTypeInformation
Write-Host "`nInactive User Results Report Exported to: $($filename)" -ForegroundColor Green
