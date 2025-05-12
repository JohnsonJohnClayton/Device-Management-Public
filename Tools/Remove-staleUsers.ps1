<#
.SYNOPSIS
    Deletes stale users
.DESCRIPTION
    This script deletes stale users from Azure AD based on a list of active UPNs provided in a CSV file. 
    It connects to Azure AD and MSOnline, retrieves all users, and compares them against the active UPNs. 
    Users not found in the active UPNs list are marked for deletion.
.NOTES
    Author: John Johnson
    Date: 09/30/2024
    THIS SCRIPT IS LEGACY AND IS NO LONGER SUPPORTED BY MICROSOFT
    NEED TO MIGRATE LOGIC TO MS GRAPH MODULES
#>

param (
    [string]$csvPath = ""
)
# Check if the provided path exists
if ($csvPath -and (-not (Test-Path -Path $csvFilePath))) {
    Write-Host "CSV file not found at $csvFilePath. Exiting..." -ForegroundColor Red
    exit 1
}

# Import UPNs from the CSV file and store them in an array

# Add the active UPNS manually to the below line if necessary
$activeUPNS = @(

)
$csvData = Import-Csv -Path $csvFilePath

# Assuming the CSV file has a column named "UPN"
$activeUPNS = $csvData | ForEach-Object { $_.UPN }
# Check if the array is empty, and exit if so
if(-not $activeUPNS) {
    Write-Warning "No date found for user UPNS`n
    Please manually add to the variable or give a valid path to a CSV with the column header of 'UPN' by using the parameter -csvPath"
    Read-Host "`n Press any button to exit script"# Wait for confirmation to end script
    exit 1
}

# Output and confirm the imported UPNs
Write-Host "UPNs imported from CSV:" -ForegroundColor Green
$activeUPNS
$confirmation = Read-Host "`nPlease confirm the UPN list by typing 'yes' or 'y' to proceed"
if ($confirmation -notmatch '^(yes|y)$') {
    Write-Host "Confirmation failed. Exiting..." -ForegroundColor Red
    exit
}

# Proceed with the script after confirmation
Write-Host "UPNs confirmed. Proceeding..." -ForegroundColor Yellow


## Continue with script logic ##


# Import needed modules if available, if not then install them
try {
    Write-Host "Attempting to import Azure and MSOnline modules..." -ForegroundColor Blue
    Import-Module AzureAD
    Import-Module MSOnline
    Write-Host "Successfully imported modules`n" -ForegroundColor Green
} catch {
    # Install modules if this fails
    Write-Host "Modules were not able to be imported - Installing/Updating them..." -ForegroundColor Yellow
    Install-Module AzureAD -force
    Install-Module MSOnline -Force
    Write-Host "Installed modules - Continuing...`n" -ForegroundColor Green
    Clear-Host
}

# Connecting to Azure & O365 Environment
Write-Host "Please log in to tenant with GA crednetials" -ForegroundColor Yellow
Read-Host "Press any button to continue"
try {
    Write-Host "Connecting to O365..."
    Connect-MsolService
} catch {
    Write-Warning "There was an error with authentication. Exiting..."
    Write-Error $_
    exit 1
}
Write-Host "Connecting to Azure..."
Connect-AzureAD


$allUsers = Get-AzureADUser
$usersToRemove = @()
$removedUsers 

foreach ($user in $allUsers){
    if($activeUPNS -contains [string]$user.UserPrincipalName){
        continue
    } else {
        $usersToRemove.Add($user)
    }
}

# Output and confirm the users to remove
Write-Warning "Users that will be deleted:"
$usersToRemove.UserPrincipalName
$confirmation = Read-Host "`nPlease confirm the UPN list by typing 'yes' or 'y' to proceed"
if ($confirmation -notmatch '^(yes|y)$') {
    Write-Host "Operation cancelled. Exiting..." -ForegroundColor Red
    exit
} else {
    Write-Host "UPNs confirmed. Proceeding..." -ForegroundColor Green
}

foreach ($user in $usersToRemove){
    # DEBUG # Remove-AzureADUser -ObjectId 
}

Write-Host "The list of removed users has been exported to your downloads folder" -ForegroundColor Yellow
$removedUsers | Export-Csv -Path $ENV:USERPROFILE\downloads