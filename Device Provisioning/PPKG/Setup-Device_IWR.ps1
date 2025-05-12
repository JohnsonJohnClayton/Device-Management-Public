<#
.SYNOPSIS
Provisions a device during the OOBE setup process by calling a private script hosted on a a repository (e.g. GitHub).

.DESCRIPTION
This script is executed as part of the PPKG command file during the device provisioning process. 
It retrieves and runs a script from a repository to configure the device according to 
the pre-defined, cloud-native script requirements to be run on first login.

.NOTES
- Ensure that the script has the necessary permissions to access the repository.
- This script is intended for use during the Out-Of-Box Experience (OOBE) setup phase from the Setup-Provisioning script, where it is up to be run on first logon.
- This script is one of only 2 files that would be called locally on the device and manually injected into the PPKG; All other script logic lives in the cloud repository.
    Author: John Johnson
    Creation Date: 12/19/2024
    Last Modified: 04/04/2025
#>

# Ensure TLS 1.2 is enabled (best practice for secure connections)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Begin logging
$dir = "C:\ProgramData\PPKG-Deployment"
Start-Transcript -Path "$dir\DeviceSetupLog.txt" -Append

Write-Host "Provisioning script started at: $(Get-Date)"

# Public-access repo call:
try {
    # Download the script from public GitHub Repo
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/YourPublicRepo/YourScriptPath/main/Setup-Device.ps1" `
    -OutFile "C:\ProgramData\PPKG-Deployment\Setup-Device.ps1" `
    -UseBasicParsing `
     | cmd /c powershell -WindowStyle Maximized -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Device.ps1"

    # Execute the downloaded script
    powershell -WindowStyle Maximized -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Device.ps1"
}
catch {
    Write-Host "Error encountered: $_"
}

# Private Repo call:
<#
try {
    # Download the script from private GitHub Repo
    Invoke-WebRequest -Uri "" `
    -OutFile "C:\ProgramData\PPKG-Deployment\Setup-Device.ps1" `
    -UseBasicParsing `
    -Headers @{ 
        Authorization = ""
        Accept = "application/vnd.github.v3.raw" 
    } | cmd /c powershell -WindowStyle Maximized -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Device.ps1"
}
catch {
    Write-Host "Error encountered: $_"
}
#>

# Stop logging
Stop-Transcript