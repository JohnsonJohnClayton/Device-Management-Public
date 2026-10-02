<#
.SYNOPSIS
    Enables archive and auto-expanding archive for a specified mailbox in Exchange Online.

.DESCRIPTION
    This script checks if auto-expanding archive is enabled for the tenant and enables it if not.
    It then enables the archive mailbox for a specific user (if not already enabled) and finally,
    enables auto-expanding archive for that user.

    If the UserPrincipalName parameter is not provided, the script will prompt the user to enter 
    the email address of the mailbox they wish to enable archiving for.

.NOTES
    Author: John Johnson
    Date: 10.31.2024
    Requires: ExchangeOnlineManagement PowerShell module

    Before running this script, make sure you have installed the ExchangeOnlineManagement module
    and have the necessary permissions to modify organization-level and mailbox-level settings.
#>

param (
    # UPN of mailbox to be modified can be optionally passed here
    [string]$UserPrincipalName
)

#=======================================================================================#
#                               Connect to Exchange Online                              #
#=======================================================================================#

# Import needed modules if available, if not then install them
try {
    Write-Host "Attempting to import ExchangeOnlineManagement modules..." -ForegroundColor Blue
    Import-Module ExchangeOnlineManagement
    Write-Host "Successfully imported module`n" -ForegroundColor Green
}
catch {
    # Install modules if this fails
    Write-Host "Module was not able to be imported - Installing/Updating them..." -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -Force
    Write-Host "Installed modules - Continuing...`n" -ForegroundColor Green
    Clear-Host
}

# Connecting to Exchange Environment
Write-Host "Please log in to tenant with Exchange Admin crednetials" -ForegroundColor Yellow
try {
    Write-Host "Connecting to Exchange..."
    Connect-ExchangeOnline
}
catch {
    Write-Warning "There was an error with authentication. Exiting..."
    Write-Error $_
    exit 1
}

#=======================================================================================#
#                                     Archiving Logic                                   #
#=======================================================================================#

# Function to enable archive and auto-expanding archive for a specific user
function Enable-AutoExpandingArchive {
    param (
        [string]$UserPrincipalName
    )

    # Prompt for the UserPrincipalName if it is not provided as a parameter
    if (-not $UserPrincipalName) {
        $UserPrincipalName = Read-Host -Prompt "Please enter the UserPrincipalName (email) of the mailbox"
    }

    # Check if auto-expanding archive is enabled at the tenant level
    $autoExpandingEnabled = Get-OrganizationConfig | Select-Object -ExpandProperty AutoExpandingArchiveEnabled

    if ($autoExpandingEnabled -eq $false) {
        Write-Host "Auto-expanding archive is not enabled for the tenant. Enabling it now..." -ForegroundColor Yellow
        Set-OrganizationConfig -AutoExpandingArchiveEnabled
        Start-Sleep -Seconds 10 # Wait for settings to propagate
    } else {
        Write-Output "Auto-expanding archive is already enabled at the tenant level."
    }

    # Check if the archive mailbox is already enabled for the user
    $mailbox = Get-Mailbox -Identity $UserPrincipalName
    if ($mailbox.ArchiveStatus -eq "None") {
        Write-Output "Archive mailbox is not enabled for $UserPrincipalName. Enabling it now..."
        
        # Enable archive mailbox
        Enable-Mailbox -Identity $UserPrincipalName -Archive
        Start-Sleep -Seconds 10 # Wait for archive mailbox provisioning to complete
    } else {
        Write-Output "Archive mailbox is already enabled for $UserPrincipalName."
    }

    # Enable auto-expanding archive for the specific user
    try {
        Enable-Mailbox $UserPrincipalName -AutoExpandingArchive
        Write-Output "Auto-expanding archive has been enabled for $UserPrincipalName."
    } catch {
        Write-Output "Failed to enable auto-expanding archive for $UserPrincipalName. Do they have the correct license?`n Error: $_"
    }
}

# Call the function, prompting for UserPrincipalName if not provided
Enable-AutoExpandingArchive

# Disconnect from Exchange Online
Disconnect-ExchangeOnline -Confirm:$false