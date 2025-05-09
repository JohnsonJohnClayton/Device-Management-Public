<#
.SYNOPSIS
    Automates the setup and configuration of a new device, specifically the necessary .exe and per-user installs.

.DESCRIPTION
    This script performs various tasks to set up a new device, including:
    - Installing specified software packages
    - Configuring power settings
    - Initiating BitLocker encryption
    - Running Windows Updates

.NOTES
    Author: John Johnson
    Creation Date: 05/08/2025

.OUTPUTS
    Logs are written to "$env:ProgramData\PPKG-Deployment\DeviceSetupLog.txt".
#>

# Begin logging
$dir = "C:\ProgramData\PPKG-Deployment"
Start-Transcript -Path "$dir\DeviceSetupLog.txt" -Append

Write-Host "Provisioning script started at: $(Get-Date)"

##########################################
############ Define Installs #############
##########################################

# Credit is needed here, as this logic is not mine. I having difficulty finding the original source. 
# These installs are run as-needed from the PPKG command files
# Files can be ran as system or user - user installs will install for all users

$packages =
[PSCustomObject]@{
    Name         = "Install"
    Exe          = "install.exe"
    Type         = "User"
    SilentSwitch = "/S"
}

# Double-Check if McAfee needs to be uninstalled (needed for A/V installs)
Get-WmiObject -Class Win32_Product | Where-Object {$_.Name -like "*McAfee*"} | ForEach-Object {$_.Uninstall()} | Out-Host
Get-AppxPackage -AllUsers *mcafee* | Remove-AppPackage -AllUsers
Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like "*McAfee*"} | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -AllUsers }

###################################
######## Install Packages #########
###################################

Write-Host "Installing Packages...`n" -ForegroundColor Yellow

foreach ($package in $packages) {
    switch ($package.Type) {
        "Machine" {
        Write-Host "Executing $($package.Name)"

        if($package.exe -Like "*.msi"){
            $execute = @{
                FilePath         = "msiexec"
                ArgumentList     = "/i $($dir)\$($package.exe) $($package.SilentSwitch)"
                NoNewWindow      = $true
                PassThru         = $true
                Wait             = $true
            }
        }
        else{
            $execute = @{
                FilePath         = "$($dir)\$($package.exe)"
                ArgumentList     = $package.SilentSwitch
                NoNewWindow      = $true
                PassThru         = $true
                Wait             = $true
            }
        }
        $result = Start-Process @execute | Out-Host
        Write-Host "    ExitCode: $($result.ExitCode)"
        Remove-Item "$($dir)\$($package.exe)" -Force
        break
    }
    "User" {
        Write-Host "Setting up $($package.Name) for user-wide installation"
        if([string]::IsNullOrEmpty($package.SilentSwitch)){
            New-Item "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\Install $($package.Name)" | New-ItemProperty -Name StubPath -Value ('REG ADD "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "Install {0}" /t REG_SZ /d "{1}"' -f $package.Name, "$($dir)\$($package.exe)") | Out-Null
        }
        else{
            New-Item "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\Install $($package.Name)" | New-ItemProperty -Name StubPath -Value ('REG ADD "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "Install {0}" /t REG_SZ /d "{1} {2}"' -f $package.Name, "$($dir)\$($package.exe)", $package.SilentSwitch) | Out-Null
        }
        break
    }
    }
}

##################################
######## Winget Installs #########
##################################

Write-Host "Installing Adobe Acrobat via Winget..."
# Check if winget is installed
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "Winget is not installed. Forcing installation using Add-AppxPackage..."
    try {
        # Force re-register the DesktopAppInstaller package by its family name.
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -Confirm:$false
        Start-Sleep -Seconds 5  # Pause briefly to allow installation to complete
    }
    catch {
        Write-Error "Failed to install winget using Add-AppxPackage. Error: $_"
    }
    # Verify if winget is now available
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Error "Winget installation appears to have failed. Continuing..."
    }
    else {
        Write-Host "Winget installed successfully. Continuing..."
    }
}
else {
    Write-Host "Winget is already installed. Continuing..."
}

# Force install Adobe Acrobat Reader using winget
Write-Host "Installing Adobe Acrobat Reader using winget..."
$wingetArgs = "install --id XPDP273C0XHQH2 --exact --accept-package-agreements --accept-source-agreements"
try {
    $wingetProcess = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru
    if ($wingetProcess.ExitCode -eq 0) {
        Write-Host "Adobe Acrobat Reader installed successfully."
    }
    else {
        Write-Error "Adobe Acrobat Reader installation may have failed. Exit code: $($wingetProcess.ExitCode)"
    }
}
catch {
    Write-Error "Error executing winget command: $_"
}

Write-Host "Installation Process Completed.`n" -ForegroundColor Green

##############################
########## Setttings #########
##############################

# Set Power Settings
Write-Host "Setting power and screen lock settings.."

# Set screen timeout on battery to 10 min
powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 600
# Set screen timeout when plugged in to 15 min
powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 900
# Set sleep settings
powercfg /change -standby-timeout-dc 15
powercfg /change -standby-timeout-ac 0
# Set lid close action (sleep on battery, do nothing when plugged in)
powercfg /SETDCVALUEINDEX SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
powercfg /SETACVALUEINDEX SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1
# Ensure the computer requires a password on wakeup
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
# Apply changes
powercfg /setactive scheme_current

# Enable the "Machine\System\Power Management\Sleep Settings\Require a password when a computer wakes (on battery)" policy
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51" -Name "DCSettingIndex" -Value 1 -Type DWord -Force
# Enable the "Machine\System\Power Management\Sleep Settings\Require a password when a computer wakes (plugged in)" policy
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51" -Name "ACSettingIndex" -Value 1 -Type DWord -Force
# Set the "Interactive logon: Machine inactivity limit" policy to 600 seconds (10 minutes)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "InactivityTimeoutSecs" -Value 600 -Type DWord -Force

Write-Host "Custom power plan created and activated with specified settings."

###################################
############# Debloat #############
###################################

# Running Andrew Taylor's Debloat script again, as it is sometimes missed depending on the system and order of installs

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

##########################################
############  Windows Updates ############
##########################################

# Here, we will run Windows Updates once everything is installed.

# Install needed modules if necessary for installation in stage 2

# Check if NuGet package provider is available
Write-Host "Installing NuGet..." -ForegroundColor Yellow
$nuget = Get-PackageProvider 'NuGet' -ListAvailable -ErrorAction SilentlyContinue
# Install NuGet package provider if not found
if ($null -eq $nuget) {
    Install-PackageProvider -Name NuGet -Confirm:$false -Force
}

# Check if the PSWindowsUpdate module is available
$module = Get-Module 'PSWindowsUpdate' -ListAvailable
# Install PSWindowsUpdate module if not found
if ($null -eq $module) {
    Write-Host "Installing PSWindowsUpdate module..."
    Install-Module PSWindowsUpdate -Confirm:$false -Force
}

# Initiate Windows Updates in a separate process
# Move this to the second stage if a reboot is needed
Write-Host "Running Windows Updates in a separate process..."
Import-Module PSWindowsUpdate -force
Start-Process powershell.exe -ArgumentList '-WindowStyle Minimized -NoProfile -ExecutionPolicy Bypass -Command `
    "Start-Transcript -Path "C:\ProgramData\PPKG-Deployment\DeviceSetupLog.txt" -Append; `
    Write-Host "Beginning Windows Updates..."; `
    Install-WindowsUpdate -AcceptAll -Install | Select-Object KB, Result, Title, Size;"'
Write-Host "`nWindows Updates Begun`n" -ForegroundColor DarkGreen

####################################
############# Cleanup ##############
####################################
# Move this to the second stage if a reboot is needed
try {
    # Remove the script files
    Write-Host "Cleaning up scripts..."
    Get-ChildItem -Path $dir -Filter "*.ps1" -File | Remove-Item -Force
    schtasks /Delete /TN "ProvisioningStage2" /F
    Write-Host "Successfully removed." -ForegroundColor Green
}
catch {
    Write-Host "Cleanup Completed with some errors." -ForegroundColor Yellow
    Write-Host "Error: $_" -ForegroundColor Red
}

Write-Host "Provisioning complete!`n" -ForegroundColor Green
Write-Host "See other window for Windows Update status" -ForegroundColor Yellow


# Uncomment the below lines to run a stage 2 script after a reboot:
# 
# ####################################
# ############# Stage 2 ##############
# ####################################
# 
# # This stage can be configured to run after the next login, if a reboot needs to be performed before any final steps.
# 
# $stage2Content = @"
#     # Start logging
#     Start-Transcript -Path "C:\ProgramData\PPKG-Deployment\DeviceSetupLog.txt" -Append
# 
#     Write-Host "###################`nBeginning Stage 2 of Provisioning...`n###################`n" -ForegroundColor Green
# 
#     # Place any additional logic here that need to be run last after a reboot.
# 
#     Stop-Transcript
# "@
# 
# $stage2Path = "$dir\Stage2Script.ps1"
# Set-Content -Path $stage2Path -Value $stage2Content
# # Schedule Stage 2
# $action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$stage2Path`""
# $trigger = New-ScheduledTaskTrigger -AtLogOn
# Register-ScheduledTask -TaskName "ProvisioningStage2" -Action $action -Trigger $trigger -RunLevel Highest -Force
# 
# ##################################
# ############# Reboot #############
# ##################################
# 
# Write-Host "Rebooting to continue provisoing..." -ForegroundColor Yellow
# Restart-Computer -Force
# Stop-Transcript