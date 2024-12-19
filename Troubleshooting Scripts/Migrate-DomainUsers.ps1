<#
.SYNOPSIS
    Migrates users from one primary domain to another
.DESCRIPTION
    This script retrieves all user from a specified domain and adds the new specified domain as their primary address.
    It checks the list of users against and exception list that will not perform the task if those usernames are present in the list.
    Users without a license or with sign-in blocked will also be excluded.
.NOTES
    Author: John Johnson
    Date: 09/23/2024
    Requires: PowerShell 4.0 or later
    Running this script requires the MSOnline and ExchangeOnlineManagement modules
    Add users to to $excludedUPNS to exclude the script from running on them
#>

$excludedUPNS = @(
    "admin@victorydevelopment01.onmicrosoft.com"
    # Waiting on confirmation from Ampio (Sharepoint Vendor):
    "asmigrationadmin@victorydevelopment01.onmicrosoft.com"
    "_svc_PowerPlatform@victorydevelopment.com"

    # Deprecated/UPN Change not needed:
    "VRED-Main@victorydevelopment.com"
    "vredmain@victorydevelopment01.onmicrosoft.com"
    "Vred-main@victorydevelopment01.onmicrosoft.com"
    "buildinginvoices@victorydevelopment.com"
    "cattlemen@victorydevelopment.com"
    "VOIPauto@victorydevelopment01.onmicrosoft.com"
    "sharpcon@victorydevelopment.com"
    "nemigadmin@victorydevelopment01.onmicrosoft.com"
    "TenantServicePrincipal@victorydevelopment01.onmicrosoft.com"
)

# Import needed modules if available, if not then install them
try {
    Write-Host "Attempting to import MSOnline and ExchangeOnlineManagement modules..." -ForegroundColor Blue
    Import-Module ExchangeOnlineManagement
    Import-Module MSOnline
    Write-Host "Successfully imported modules`n" -ForegroundColor Green
}
catch {
    # Install modules if this fails
    Write-Host "Modules were not able to be imported - Installing/Updating them..." -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -force
    Install-Module MSOnline -Force
    Write-Host "Installed modules - Continuing...`n" -ForegroundColor Green
    Clear-Host
}

# Connecting to M365 & Exchange Environment
Write-Host "Please log in to tenant with GA crednetials" -ForegroundColor Yellow
Read-Host "Press any button to continue"
try {
    Write-Host "Connecting to O365..."
    Connect-MsolService
}
catch {
    Write-Warning "There was an error with authentication. Exiting..."
    Write-Error $_
    exit 1
}
Write-Host "Connecting to Exchange..."
Connect-ExchangeOnline

do {
    $loop = 'true'
    #Get Domain Names and Validate
    Write-Host "`nAvailable Domains in tenant:" -ForegroundColor Cyan
    $domains = Get-MsolDomain | Select-Object -ExpandProperty Name
    # Check if there are any domains returned
    if ($domains.Count -eq 0) {
        Write-Host "No domains found. Exiting.." -ForegroundColor Red
        exit
    }
    $i=0
    foreach ($domain in $domains) {
        $i+=1
        Write-Host "Option $($i): "$domain
    }
    $selection = Read-Host "`nSelect the NEW domain to migrate users TO"
    while (-not ($selection -match '^\d+$' -and [int]$selection -gt 0 -and [int]$selection -le $domains.Count)) {
        Write-Host "Incorrect selection. Please select a valid number"
        $selection = Read-Host "Select the NEW domain to migrate users TO"
    }
    # Convert selection to an index (PowerShell arrays are 0-based, so we subtract 1)
    $newDomain = $domains[$selection - 1]
    Write-Host "`nYou selected: $newDomain" -ForegroundColor Yellow

    $confirmation = Read-Host "Continue? (yes/no)"
    if ($confirmation.ToLower() -eq 'yes' -or $confirmation.ToLower() -eq 'y') {
        Write-Host "`nProceeding with changes...`n" -ForegroundColor Green
        $loop = 'false'
        break
    } else {
        $loop = 'true'
    }
} while ($loop = 'true')


# Begin parsing through users to migrate

# Ensure excludedUPNS is in lowercase for case-insensitive matching
$excludedUPNS = $excludedUPNS | ForEach-Object { $_.ToLower() }
# Get all users
$allUsers = Get-MsolUser -All | Select-Object UserPrincipalName, DisplayName, isLicensed, BlockCredential
# Initialize an empty arrays for users to change and excluded users
$usersToChange = @()
$unlicensedOrBlocked = @()
# Filter the users manually
foreach ($user in $allUsers) {
    $userUPN = $user.UserPrincipalName.ToLower()
    # Check if the user's UPN is NOT in the excludedUPNS array
    if (-not ($excludedUPNS -contains $userUPN)) {
        # Check if user is allowed to sign in and licensed
        if((-not $user.BlockCredential) -and ($user.IsLicensed)){
            $usersToChange += $user
            Write-Host "Adding user: $($user.UserPrincipalName)"  -ForegroundColor Green # Debug output
        } else {
            $unlicensedOrBlocked += $user
            Write-Host "$($user.UserPrincipalName) is unlicensed or blocked. Excluding..." -ForegroundColor Red # Debug output
        }
    } else {
        Write-Host "Excluding user: $($user.UserPrincipalName)" -ForegroundColor Red # Debug output
    }
    #Start-Sleep -Milliseconds 600
}

# Output the filtered users and confirm
Write-Host "`nUsers excluded due to licensing or sign-in:" -ForegroundColor DarkYellow
$unlicensedOrBlocked | ForEach-Object { $_.UserPrincipalName } | Format-Table -AutoSize
Write-Host "`nUsers to be modified:" -ForegroundColor Green
$usersToChange | ForEach-Object { $_.UserPrincipalName } | Format-Table -AutoSize

Write-Host "`nDo you want to proceed with changing these users? (yes/no)" -ForegroundColor Yellow
$confirmation = Read-Host
if ($confirmation.ToLower() -eq 'yes' -or $confirmation.ToLower() -eq 'y') {
    Write-Host "Proceeding with changes..."
} else {
    Write-Host "Operation cancelled."
    exit 1
}

#Save UPNS that were changed in a key-value pair hashtable to print out once we're done
$upnsChanged =@{}

foreach ($user in $usersToChange){
    #If user's old domain name matches and is not in exclusion list:
        #Capture old UPN and split into username and domain
        $oldUPN = [string]$user.UserPrincipalName
        $username, $prevDomain = $oldUPN -split "@"

        #Define the new UPN by appending the new domain
        $newUPN = "$username@$newDomain"
        Write-Host "Changing UPN for $($user.DisplayName): $oldUPN -> $newUPN"
        try {
            $currentAliases = $user.ProxyAddresses
            Set-MsolUserPrincipalName -UserPrincipalName $oldUPN -NewUserPrincipalName $newUPN
            $upnsChanged.Add($oldUPN, $newUPN)

            # Ensure the current aliases are fetched properly and the new alias isn't already present
            if ($currentAliases -notcontains $newAlias) {
                # Update the user's proxy addresses with the old UPN as an alias
                Set-Mailbox -Identity $newUPN -EmailAddresses @{add=$oldUPN}
            } else {
                Write-Host "Alias $newAlias is already present for user $newUPN"
            }
            
            Write-Host "Added old UPN $oldUPN as alias to $newUPN"
        } catch {
            Write-Host "Error processing $($user.DisplayName): $($_.Exception.Message)"
        }
    
        Write-Host "------------------------------"
}
Write-Host "Setting new domain $newDomain to the default domain in the tenant for future user creation..."
Set-MsolDomain -Name $newDomain -IsDefault

Write-Host "`n Domain migration to $newDomain completed.`nUsers migrated:`n"
Write-Host $upnsChanged
