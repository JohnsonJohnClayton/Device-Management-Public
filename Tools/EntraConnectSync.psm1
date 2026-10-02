<#
    .SYNOPSIS
    Triggers a Delta synchronization cycle on the <syncServer> server for Azure AD Connect.

    .DESCRIPTION
    The Start-DeltaSync function remotely invokes the Start-ADSyncSyncCycle cmdlet with the Delta policy type on the <syncServer> server. If access is denied, it prompts for credentials and retries using Kerberos authentication.

    .EXAMPLE
    Start-DeltaSync -ComputerName "<syncServer>"
    Initiates a Delta sync on <syncServer>. If access is denied, prompts for credentials.

    .NOTES
    Author: John Johnson
    Date: August 6, 2025
    Requires: Remote PowerShell access to <syncServer> and appropriate permissions.
#>
function Start-DeltaSync {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ComputerName)
    try {
        Invoke-Command `
        -ComputerName $ComputerName `
        -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta }`
        -ErrorAction Stop
    }
    catch {
        if($_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -and $_.Exception.Message -match "Access is denied") {
            Invoke-Command `
            -ComputerName $ComputerName `
            -Credential (Get-Credential) `
            -Authentication Kerberos `
            -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta }`
            -ErrorAction Stop
        } elseif ($_.Exception.Message -match "AAD is busy") {
            Write-Host "Sync Agent is currently working. Running command again in 10 seconds..."
            Start-Sleep -Seconds 10
            Invoke-Command `
            -ComputerName $ComputerName `
            -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta }`
            -ErrorAction Stop
        }
        else {throw $_}
    }
}