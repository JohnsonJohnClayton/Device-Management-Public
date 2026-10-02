<#
.SYNOPSIS
    Device setup and provisioning script for Windows devices during OOBE.

.DESCRIPTION
    This script performs initial setup and configuration tasks for a Windows device, including:
    - Creating a PPKG-Deployment directory and copying files
    - Configuring RunOnce for post-logon setup
    - Importing custom Start Menu configuration
    - Enabling location services
    - Configuring system and user profile settings
    - Removing bloatware and unnecessary features

.NOTES
    Author: John Johnson
    Creation Date: 12/19/2024
    Last Modified: 04/04/2025

.OUTPUTS
    Log file: $env:ProgramData\PPKG-Deployment\OOBE_DeviceSetupLog.txt
#>

# Begin logging
$dir = "$($env:ProgramData)\PPKG-Deployment"
Start-Transcript -Path "$dir\DeviceSetupLog.txt"

Write-Host "Provisioning script started at: $(Get-Date)"

# Run Setup-SCSDevice  once after machine log-on. See MS documentation on RegKey: https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys
New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "Setup-Device" -Value ("cmd /c powershell.exe -ExecutionPolicy Bypass -File {0}\Setup-Device_IWR.ps1" -f $dir)

# Import Start Menu from moved provisioning package files
# TODO: Download Start2.bin from a reliable source instead of locally copying it.
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

###########################################
######## Configure Misc. Settings #########
###########################################

# Credit to Michael Niehaus for much of the logic here: https://github.com/mtniehaus

# Enable location services so the time zone will be set automatically (even when skipping the privacy page in OOBE) when an administrator signs in
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Type "String" -Value "Allow" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" -Name "SensorPermissionState" -Type "DWord" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate" -Name "Start" -Value 3
Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue

# Disable Privacy Experience for every new user login
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE /v DisablePrivacyExperience /t REG_DWORD /d 1

# Disable Cloud Consumer Features
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableConsumerAccountStateContent" /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f

# Enable Profile Defaults
reg.exe load HKLM\TempUser "C:\Users\Default\NTUSER.DAT" | Out-Host
# Enable location services for desktop apps
reg.exe add  "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" /v Value /t REG_SZ /d "Allow" | Out-Host
# Enable automatic time zone updates
reg.exe add  "HKLM\TempUser\Control Panel\TimeDate" /v AutoTimeZoneUpdate /t REG_DWORD /d 1 | Out-Host
# Hide "Learn more about this picture" from the desktop
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" /t REG_DWORD /d 1 /f | Out-Host
# Disable Windows Spotlight as per https://github.com/mtniehaus/AutopilotBranding/issues/13#issuecomment-2449224828
Write-Host "Disabling Windows Spotlight for Desktop"
reg.exe add "HKLM\TempUser\Software\Policies\Microsoft\Windows\CloudContent" /v DisableSpotlightCollectionOnDesktop /t REG_DWORD /d 1 /f | Out-Host
# Disable widgets
reg.exe add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh" /V "AllowNewsAndInterests" /T REG_DWORD /D "0" /F
# Disable Windows bloat
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn /t REG_DWORD /d 0 /f | Out-Host
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338387Enabled /t REG_DWORD /d 0 /f | Out-Host
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v RotatingLockScreenOverlayEnabled /t REG_DWORD /d 0 /f | Out-Host
reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f | Out-Host
# Unload default profile
reg.exe unload HKLM\TempUser | Out-Host

# Set account passwords to not expire
# net accounts /maxpwage:UNLIMITED

###################################
############# Debloat #############
###################################

# Credit here to Andrew S. Taylor: https://github.com/andrew-s-taylor

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

# Note: Some installs can be done in the provisioning package itself for sake of simplicity

Write-Host "Attempting Google Drive Install.."
Start-Process -FilePath "$dir\GoogleDriveSetup.exe" -ArgumentList '--silent --desktop_shortcut --skip_launch_new' -Wait | Out-Host

Write-Host "Attempting Google Chome Install.."
Start-Process -FilePath "$dir\googlechromestandaloneenterprise64.msi" -ArgumentList '/qn /norestart' -Wait | Out-Host

Write-Host "Attempting Slack Install"
Start-Process -FilePath "$dir\SlackSetup.msi" -ArgumentList 'INSTALLLEVEL=2 /qn /norestart' -Wait | Out-Host


#########################################
######## Google Drive Shortcuts #########
#########################################

# Ensure the Desktop folder exists in the Default profile.
$defaultDesktop = "C:\Users\Default\Desktop"
if (-not (Test-Path $defaultDesktop)) {
    New-Item -ItemType Directory -Path $defaultDesktop -Force | Out-Null
    Write-Host "Created Default user's Desktop folder at $defaultDesktop"
}

# Function to create a shortcut.
function Create-Shortcut {
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutPath,
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$IconLocation = "",
        [string]$WorkingDirectory = ""
    )

    $WshShell = New-Object -ComObject WScript.Shell
    $shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    if ($Arguments) {
        $shortcut.Arguments = $Arguments
    }
    if ($IconLocation) {
        $shortcut.IconLocation = $IconLocation
    }
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    $shortcut.Save()

    # Copy Google shortcuts to default user desktop
    Write-Host "Installing Google Drive Shortcuts to Default User Desktop..."
    Copy-Item -Path $ShortcutPath -Destination $defaultDesktop
}

#Create Google Shortcuts in the Start Menu Program list
$StartPrograms = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"

# Paths for the executables / batch file.
$launchBat = "C:\Program Files\Google\Drive File Stream\launch.bat"
$gIconLocation = "C:\Program Files\Google\Drive File Stream\"

# Create the Google Docs shortcut.
$shortcutPath = Join-Path $StartPrograms "Google Docs.lnk"
Create-Shortcut -ShortcutPath $shortcutPath `
    -TargetPath $launchBat `
    -Arguments "-open_gdocs_root" `
    -IconLocation "$gIconLocation\docs.ico,0"

# Create the Google Sheets shortcut.
$shortcutPath = Join-Path $StartPrograms "Google Sheets.lnk"
Create-Shortcut -ShortcutPath $shortcutPath `
    -TargetPath $launchBat `
    -Arguments "-open_gsheets_root" `
    -IconLocation "$gIconLocation\sheets.ico,0"

# Create the Google Slides shortcut.
$shortcutPath = Join-Path $StartPrograms "Google Slides.lnk"
Create-Shortcut -ShortcutPath $shortcutPath `
    -TargetPath $launchBat `
    -Arguments "-open_gslides_root" `
    -IconLocation "$gIconLocation\slides.ico,0"

Write-Host "Shortcuts for Google Drive, Docs, Sheets, and Slides have been created at $StartPrograms."

###################################
############# Taskbar #############
###################################

# NOTE: This logic no longer works as of 24H2. There are currently no workarounds that I know of

# Define which layout to deploy: "Standard" for a set of pinned apps, or "Blank" for an empty taskbar.
$LayoutType = "Standard"  # Change to "Blank" if desired

# Build the XML content for the Taskbar layout.
# For a standard layout, we include a few common apps (adjust AppUserModelIDs as needed).
if ($LayoutType -eq "Standard") {
    $xmlContent = @'
<?xml version="1.0" encoding="utf-8"?>
<TaskbarLayout>
    <TaskbarPinList>
        <TaskbarPin AppUserModelID="Microsoft.Windows.FileExplorer_8wekyb3d8bbwe!App" />
        <TaskbarPin AppUserModelID="Chrome" />
        <TaskbarPin AppUserModelID="{6D809377-6AF0-444B-8957-A3773F02200E}\Google\Drive File Stream\98.0.0.0\GoogleDriveFS.exe" />
        <TaskbarPin AppUserModelID="Microsoft.AutoGenerated.{5B049DEF-4B77-0961-3D17-DFC67B882EE0}" />
        <TaskbarPin AppUserModelID="Microsoft.AutoGenerated.{6DCE622C-2633-136E-F1C6-3B17AF5D1BBE}" />
        <TaskbarPin AppUserModelID="com.squirrel.slack.slack" />
        <TaskbarPin AppUserModelID="zoom.us.Zoom Video Meetings" />
    </TaskbarPinList>
</TaskbarLayout>
'@
}
else {
    # A blank layout—no pinned items.
    $xmlContent = @'
<?xml version="1.0" encoding="utf-8"?>
<TaskbarLayout>
    <TaskbarPinList>
    </TaskbarPinList>
</TaskbarLayout>
'@
}

# Determine the folder for the Default user's Shell.
# New user profiles will inherit the contents of the "Default" profile.
$defaultShellPath = "C:\Users\Default\AppData\Local\Microsoft\Windows\Shell"
# Ensure the folder exists.
if (-not (Test-Path $defaultShellPath)) {
    New-Item -Path $defaultShellPath -ItemType Directory -Force | Out-Null
}
# Define the destination path for the Taskbar layout XML.
$destinationXml = Join-Path $defaultShellPath "TaskbarLayoutModification.xml"
# Write out the XML content.
$xmlContent | Out-File -FilePath $destinationXml -Force -Encoding UTF8
Write-Host "Default Taskbar layout file ($LayoutType) deployed to: $destinationXml"

Stop-Transcript