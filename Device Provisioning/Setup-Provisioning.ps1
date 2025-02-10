<#
.SYNOPSIS
    Device setup and provisioning script for Windows SafetyChain Software devices.

.DESCRIPTION
    This script performs initial setup and configuration tasks for a Windows device, including:
    - Creating a ZenGuard directory and copying files
    - Configuring RunOnce for post-logon setup
    - Importing custom Start Menu configuration
    - Enabling location services
    - Configuring system and user profile settings
    - Removing bloatware and unnecessary features

.NOTES
    Author: John Johnson (ZenGuard Managed Services, LLC)
    Creation Date: 12/19/2024
    Last Modified: 02/06/2025

.OUTPUTS
    Log file: $env:ProgramData\ZenGuard\OOBE_DeviceSetupLog.txt
#>

# Start Log
$dir = "$($env:ProgramData)\ZenGuard"
Start-Transcript -Path "$dir\OOBE_DeviceSetupLog.txt"

# Create a Zenguard directory, where we will work from, and move all command contents from the package into it that is not this script
$dir = "$($env:ProgramData)\ZenGuard"
New-Item $dir -ItemType Directory -Force | Out-Null

Get-ChildItem | Where-Object{$_.name -ne "Setup-Provisioning.ps1"} | ForEach-Object{
    Copy-Item $_.FullName "$($dir)\$($_.name)" -Force
}

# Run Setup-SCSDevice  once after machine log-on. See MS documentation on RegKey: https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys
New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "Setup-Device" -Value ("cmd /c powershell.exe -ExecutionPolicy Bypass -File {0}\Setup-SCSDevice_IRM.ps1" -f $dir)

# Import Start Menu
# Define source and destination paths
$sourceFile = "$dir\start2.bin"
$destinationDirectory = "$env:SystemDrive\Users\Default\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\"
$destinationFile = Join-Path -Path $destinationDirectory -ChildPath "start2.bin"

# Check if the destination directory exists; if not, create it
if (!(Test-Path -Path $destinationDirectory)) {
    New-Item -Path $destinationDirectory -ItemType Directory -Force
}

# Copy the file to the destination, overwriting if it already exists
Copy-Item -Path $sourceFile -Destination $destinationFile -Force

# Enable location services so the time zone will be set automatically (even when skipping the privacy page in OOBE) when an administrator signs in
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Type "String" -Value "Allow" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" -Name "SensorPermissionState" -Type "DWord" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate" -Name "Start" -Value 3
Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue

# Enable Profile Defaults
reg.exe load HKLM\TempUser "C:\Users\Default\NTUSER.DAT" | Out-Host
# Hide "Learn more about this picture" from the desktop
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" /t REG_DWORD /d 1 /f | Out-Host
# Disable Windows Spotlight as per https://github.com/mtniehaus/AutopilotBranding/issues/13#issuecomment-2449224828
Log "Disabling Windows Spotlight for Desktop"
reg.exe add "HKLM\TempUser\Software\Policies\Microsoft\Windows\CloudContent" /v DisableSpotlightCollectionOnDesktop /t REG_DWORD /d 1 /f | Out-Host
reg.exe unload HKLM\TempUser | Out-Host
# Disable widgets
REG ADD "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh" /V "AllowNewsAndInterests" /T REG_DWORD /D "0" /F
# Disable Windows bloat
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Host
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338387Enabled /t REG_DWORD /d 0 /f | Out-Host
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v RotatingLockScreenOverlayEnabled /t REG_DWORD /d 0 /f | Out-Host
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f | Out-Host
# Remove Edge Desktop icon
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v DisableEdgeDesktopShortcutCreation /t REG_DWORD /d 1 /f /reg:64 | Out-Host
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" /v "CreateDesktopShortcutDefault" /t REG_DWORD /d 0 /f /reg:64 | Out-Host
# Unload default profile
reg.exe unload HKLM\TempUser | Out-Host

###################################
############# Debloat #############
###################################
Write-Host "Beginning Debloat Process..."
$DebloatFolder = "C:\ProgramData\Debloat"
If (Test-Path $DebloatFolder) {
    Write-Output "$DebloatFolder exists. Skipping."
}
Else {
    Write-Output "The folder '$DebloatFolder' doesn't exist. This folder will be used for storing logs created after the script runs. Creating now."
    Start-Sleep 1
    New-Item -Path "$DebloatFolder" -ItemType Directory
    Write-Output "The folder $DebloatFolder was successfully created."
}

$templateFilePath = "C:\ProgramData\Debloat\removebloat.ps1"

Invoke-WebRequest `
-Uri "https://raw.githubusercontent.com/andrew-s-taylor/public/main/De-Bloat/RemoveBloat.ps1" `
-OutFile $templateFilePath `
-UseBasicParsing `
-Headers @{"Cache-Control"="no-cache"}


# Populate between the speechmarks any apps you want to whitelist, comma-separated
$arguments = ' -customwhitelist ""'
invoke-expression -Command "$templateFilePath $arguments"

# Attempt to remove McAfee
Get-WmiObject -Class Win32_Product | Where-Object {$_.Name -like "*McAfee*"} | ForEach-Object {$_.Uninstall()}

####################################
############# Installs #############
####################################

Write-Host "Attempting GCPW Install.."
Start-Process -FilePath "$dir\SAFETYCHAIN_gcpwstandaloneenterprise64.exe" -ArgumentList '/silent /install' | Out-Host

Stop-Transcript