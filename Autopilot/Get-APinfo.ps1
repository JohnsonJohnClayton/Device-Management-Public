<#
Script to manually save Autopilot hardware hash ID (HWID) to a CSV to be uploaded into Autopilot Tenant

Configured by John Johnson on 07/31/2024
Modified by:
Source: https://learn.microsoft.com/en-us/autopilot/add-devices
Source: https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.8/Content/Get-WindowsAutopilotInfo.ps1
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Directory to save Hardware Hash to
$Dir = "$PSScriptRoot\Autopilot HWID"

# Does the directory exist? If not, create it
If (-not (Test-Path -Path $Dir)) {
    Write-Warning "Directory $Dir not found at script root`n
    Creating directory... $Dir"
    New-Item -Type Directory -Path $Dir
}
else {
    Write-Output "The directory $Dir already exists at this script's root; `nContinuing...`n`n"
    Set-Location -Path $Dir
}

# Save Hardware Hash to a csv in the specified directory
try {
    $env:Path += ";$env:ProgramFiles\WindowsPowerShell\Scripts"
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
    Install-Script -Name Get-WindowsAutopilotInfo -Force

    Get-WindowsAutopilotInfo -OutputFile $Dir\AutopilotHWID.csv -Append #Add this? PARAMETER AddToGroup = Specifies the name of the Azure AD group that the new device should be added to.
    Set-Location -Path $PSScriptRoot
}
catch {
    Write-Error "There was an error:"
    Write-Error $_
}