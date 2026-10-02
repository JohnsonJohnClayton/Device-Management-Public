<#
.SYNOPSIS
Searches for and remediates specified local user accounts by resetting their passwords.

.DESCRIPTION
This script is designed for RMM/PDQ Connect deployment to identify and remediate specified local user accounts.
It accepts one or more account names and securely sets a new password for any matching accounts found on the system.
The script handles both single account names and arrays of account names using the same parameter.

.PARAMETER AccountNames
Specifies one or more local user account names to search for and remediate.
Accepts a single string or an array of strings.

.PARAMETER SecurePassword
The password to set for the remediated accounts. This should be passed securely from PDQ/RMM.
The parameter accepts a plain text string but converts it to a SecureString internally for use with Set-LocalUser; the input remains plaintext at the call boundary.

.PARAMETER WhatIf
Shows what would happen if the script runs without actually making changes.

.EXAMPLE
.\Remediate-LocalAccounts.ps1 -AccountNames "Admin123" -SecurePassword $PasswordFromSecretStore
Searches for the account "Admin123" and resets its password if found.

.EXAMPLE
.\Remediate-LocalAccounts.ps1 -AccountNames @("Admin123", "Support", "TempUser") -SecurePassword $PasswordFromSecretStore
Searches for multiple accounts and resets their passwords if found.

.EXAMPLE
.\Remediate-LocalAccounts.ps1 -AccountNames "Admin123" -SecurePassword $PasswordFromSecretStore -WhatIf
Shows what would happen without actually resetting passwords.

.NOTES
Author: PowerShell Support
Version: 1.0
Requires: PowerShell 5.1 or later
Requires: Local Administrator privileges
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Account name(s) to search for and remediate
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$AccountNames,

    # Password to set for remediated accounts (passed as plain text from RMM, converted to SecureString)
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SecurePassword
)

begin {
    Write-Verbose "Starting account remediation process..."
    Write-Verbose "Target accounts: $($AccountNames -join ', ')"

    # Convert the password string to SecureString for secure handling
    $securePasswordString = ConvertTo-SecureString -String $SecurePassword -AsPlainText -Force

    # Clear the plain text password from memory as soon as possible
    Remove-Variable -Name SecurePassword -ErrorAction SilentlyContinue

    # Initialize tracking variables
    $remediatedAccounts = @()
    $notFoundAccounts = @()
    $failedAccounts = @()

    Write-Verbose "Retrieving all local user accounts..."
    try {
        $allLocalAccounts = Get-LocalUser -ErrorAction Stop
        Write-Verbose "Found $($allLocalAccounts.Count) local accounts on the system"
    }
    catch {
        Write-Error "Failed to retrieve local user accounts: $_"
        exit 1
    }
}

process {
    foreach ($accountName in $AccountNames) {
        Write-Verbose "Processing account: $accountName"

        # Search for the account (case-insensitive)
        $targetAccount = $allLocalAccounts | Where-Object { $_.Name -eq $accountName }

        if ($targetAccount) {
            Write-Verbose "Account found: $accountName (SID: $($targetAccount.SID))"

            try {
                if ($PSCmdlet.ShouldProcess($accountName, "Reset password")) {
                    # Set the new password
                    Set-LocalUser -Name $accountName -Password $securePasswordString -ErrorAction Stop

                    Write-Output "Successfully remediated account: $accountName"
                    Write-Verbose "Account $accountName - Password reset"

                    $remediatedAccounts += [PSCustomObject]@{
                        AccountName = $accountName
                        Status      = 'Remediated'
                        SID         = $targetAccount.SID
                        Timestamp   = Get-Date
                    }
                }
            }
            catch {
                Write-Error "Failed to remediate account '$accountName': $_"
                $failedAccounts += [PSCustomObject]@{
                    AccountName = $accountName
                    Status      = 'Failed'
                    Error       = $_.Exception.Message
                    Timestamp   = Get-Date
                }
            }
        }
        else {
            Write-Warning "Account not found on this system: $accountName"
            $notFoundAccounts += [PSCustomObject]@{
                AccountName = $accountName
                Status      = 'NotFound'
                Timestamp   = Get-Date
            }
        }
    }
}

end {
    # Clear the secure password from memory
    if ($securePasswordString) {
        $securePasswordString.Dispose()
        Remove-Variable -Name securePasswordString -ErrorAction SilentlyContinue
    }

    Write-Verbose "Remediation process completed"

    # Generate summary report
    $summary = [PSCustomObject]@{
        TotalAccountsTargeted = $AccountNames.Count
        AccountsRemediated    = $remediatedAccounts.Count
        AccountsNotFound      = $notFoundAccounts.Count
        AccountsFailed        = $failedAccounts.Count
        ComputerName          = $env:COMPUTERNAME
        ExecutionTime         = Get-Date
    }

    Write-Output "`n=== Remediation Summary ==="
    Write-Output $summary

    if ($remediatedAccounts.Count -gt 0) {
        Write-Output "`n=== Remediated Accounts ==="
        $remediatedAccounts | Format-Table -AutoSize
    }

    if ($notFoundAccounts.Count -gt 0) {
        Write-Output "`n=== Accounts Not Found ==="
        $notFoundAccounts | Format-Table -AutoSize
    }

    if ($failedAccounts.Count -gt 0) {
        Write-Output "`n=== Failed Accounts ==="
        $failedAccounts | Format-Table -AutoSize
    }

    # Return appropriate exit code for RMM monitoring
    if ($failedAccounts.Count -gt 0) {
        Write-Warning "Some accounts failed to remediate. Exit code: 2"
        exit 2
    }
    elseif ($remediatedAccounts.Count -eq 0 -and $notFoundAccounts.Count -eq $AccountNames.Count) {
        Write-Output "No target accounts found on this system. Exit code: 0"
        exit 0
    }
    else {
        Write-Output "Remediation completed successfully. Exit code: 0"
        exit 0
    }
}
