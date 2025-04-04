<#
.SYNOPSIS
Provisions a device during the OOBE setup process by calling a private script hosted on a a repository (e.g. GitHub).

.DESCRIPTION
This script is executed as part of the PPKG command file during the device provisioning process. 
It retrieves and runs a script from a repository to configure the device according to 
the pre-defined, cloud-native script requirements.

.NOTES
- Ensure that the script has the necessary permissions to access the repository.
- This script is intended for use during the Out-Of-Box Experience (OOBE) setup phase.
- This script is one of only 2 files that would be called locally on the device and manually injected into the PPKG; All other script logic lives in the cloud repository.
#>

# Ensure TLS 1.2 is enabled (best practice for secure connections)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Begin logging
$dir = "C:\ProgramData\PPKG-Deployment"
New-Item -Path $dir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$dir\OOBE_DeviceSetupLog.txt" -Append

Write-Host "Provisioning script started at: $(Get-Date)"

# Move items from provisioning package
Get-ChildItem | Where-Object{$_.name -ne "Setup-Provisioning.ps1"} | ForEach-Object{
    Copy-Item $_.FullName "$($dir)\$($_.name)" -Force
}

# Public-access repo call:
try {
    # Download the script from public GitHub Repo
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/YourPublicRepo/YourScriptPath/main/Setup-Provisioning.ps1" `
    -OutFile "C:\ProgramData\PPKG-Deployment\Setup-Device.ps1" `
    -UseBasicParsing `
     | cmd /c powershell -WindowStyle Maximized -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Provisioning.ps1"

    # Execute the downloaded script
    powershell -WindowStyle Maximized -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Provisioning.ps1"
}
catch {
    Write-Host "Error encountered: $_"
}

# Private Repo call:
<#
try {
    # Download the script from private GitHub Repo
    Invoke-WebRequest -Uri "" `
    -OutFile "C:\ProgramData\PPKG-Deployment\Setup-Provisioning.ps1" `
    -UseBasicParsing `
    -Headers @{ 
        Authorization = ""
        Accept = "application/vnd.github.v3.raw" 
    } | cmd /c powershell -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Provisioning.ps1"
}
catch {
    Write-Host "Error encountered: $_"
}
    #>

# Stop logging
Stop-Transcript