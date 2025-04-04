<#
Script to manually save Autopilot hardware hash ID (HWID) to a CSV to be uploaded into Autopilot Tenant
Modified to output to a csv in the user's downloads folder

Configured by John Johnson on 07/31/2024
Modified by:
Source: https://learn.microsoft.com/en-us/autopilot/add-devices
Source: https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.8/Content/Get-WindowsAutopilotInfo.ps1
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Directory to save Hardware Hash to
$Dir = "$env:USERPROFILE"
Set-Location -Path $Dir

# Save Hardware Hash to a csv in the specified directory
try {
    $env:Path += ";$env:ProgramFiles\WindowsPowerShell\Scripts"
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
    Install-Script -Name Get-WindowsAutopilotInfo -Force

    Get-WindowsAutopilotInfo -OutputFile $Dir\HWID.csv -Append #Add this? PARAMETER AddToGroup = Specifies the name of the Azure AD group that the new device should be added to.
}
catch {
    Write-Error "There was an error:"
    Write-Error $_
}