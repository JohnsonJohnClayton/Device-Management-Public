<#
.SYNOPSIS
    Automates the setup and configuration of a new device, specifically the necessary .exe and per-user installs.

.DESCRIPTION
    This script performs various tasks to set up a new device, including:
    - Installing specified software packages
    - Configuring power settings
    - Initiating BitLocker encryption
    - Running Windows Updates
    - Setting up Google Drive shortcuts
    - Running a BitDefender scan after install

.NOTES
    Author: John Johnson (ZenGuard Managed Services, LLC)
    Creation Date: 12/19/2024
    Last Modified: 02/06/2025

.OUTPUTS
    Logs are written to "$env:ProgramData\ZenGuard\DeviceSetupLog.txt".
#>

###################################
############ Installs #############
###################################

$dir = "$($env:ProgramData)\ZenGuard"

Start-Transcript -Path "$dir\DeviceSetupLog.txt" -Append

$packages =
[PSCustomObject]@{
    Name         = "Drata"
    Exe          = "Drata-Agent-win.exe"
    Type         = "User"
    SilentSwitch = "/S"
},
[PSCustomObject]@{
    Name         = "GoogleDrive"
    Exe          = "GoogleDriveSetup.exe"
    Type         = "Machine"
    SilentSwitch = "--silent --desktop_shortcut --skip_launch_new"
}<#,
[PSCustomObject]@{
    Name         = "GCPW"
    Exe          = "SAFETYCHAIN_gcpwstandaloneenterprise64.exe"
    Type         = "Machine"
    SilentSwitch = "/silent /install"
},
[PSCustomObject]@{
    Name         = "BitDefender"
    Exe          = "epskit_x64.exe"
    Type         = "Machine"
    SilentSwitch = "/bdparams /silent"
}#>

#Start Encryption
Write-Host "Starting BitLocker on $env:SystemDrive...`n"
try {
    cmd /c "manage-bde -on $env:SystemDrive"
}
catch {
    
    Write-Error "There was an error trying to initiate BitLocker Encryption:"
    Write-Host $_
    Start-Sleep -Seconds 5
}

# Wait for network connection
$ProgressPreference_bk = $ProgressPreference  # Back up the current progress preference
$ProgressPreference = 'SilentlyContinue'       # Suppress progress output temporarily

# Loop until a network connection is established
do {
    # Test network connection to Google's DNS server
    $ping = Test-NetConnection '8.8.8.8' -InformationLevel Quiet
    
    if (!$ping) {
        Clear-Host
        'Waiting for network connection' | Out-Host  # Inform the user
        Start-Sleep -s 5  # Wait for 5 seconds before retrying
    }
} while (!$ping)  # Continue looping until connection is successful

# Restore the original progress preference
$ProgressPreference = $ProgressPreference_bk

# Double-Check if McAfee needs to be uninstalled
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

Write-Host "Installation Process Completed...`n" -ForegroundColor Green

#################################################
######## Install Google Drive Shortcuts #########
#################################################
# move google shortcuts on scadmin desktop to default user desktop
Write-Host "Moving Google Drive Shortcuts to Default User Desktop"

# Define the source and destination paths
$sourceFolder = "C:\Users\scadmin\Desktop"
$destinationFolder = "C:\Users\Default\Desktop"

# Copy Google Drive shortcuts
Get-ChildItem -Path $sourceFolder -Filter "Google*" | ForEach-Object {
    Copy-Item $_.FullName -Destination $destinationFolder -Force
}

##############################
########## Setttings #########
##############################

# Set Power Settings
Write-Host "Setting power and screen lock settings.."

# Set sleep settings (10 minutes on battery (dc), 15 minutes when plugged in (ac))
powercfg /change -standby-timeout-dc 10
powercfg /change -standby-timeout-ac 15
# Set lid close action (sleep on battery, do nothing when plugged in)
powercfg /SETDCVALUEINDEX SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
powercfg /SETACVALUEINDEX SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1
# Ensure the computer requires a password on wakeup
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 1
# Apply changes
powercfg /setactive scheme_current

Write-Host "Custom power plan created and activated with specified settings."

# Start automatic time zone
# Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue

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
############# Stage 2 ##############
####################################

# Schedule BitDefender Install
#   -The endpoint needs to be rebooted in order to ensure that McAfee is uninstalled
#   -Updates applied afterwards
# Create Stage 2 script
$stage2Content = @"
# Start logging
$dir = "C:\ProgramData\ZenGuard"
Start-Transcript -Path "$dir\DeviceSetupLog.txt" -Append

Write-Host "Beginning Stage 2 of Provisioning...`n" -ForegroundColor Green

Write-Host "Running Windows Updates in the background..."
$job = Start-Job -ScriptBlock {
    # Setup Windows Update
    try {
        # Install NuGet package provider if not found
        if (!(Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Confirm:$false -Force
        }

        # Install and import PSWindowsUpdate module
        if (!(Get-Module -Name PSWindowsUpdate -ListAvailable)) {
            Install-Module PSWindowsUpdate -Confirm:$false -Force
        }
        Import-Module PSWindowsUpdate

        # Retrieve and install Windows updates
        $updates = Get-WindowsUpdate
        if ($updates) {
            Install-WindowsUpdate -AcceptAll -Install -AutoReboot | 
            Select-Object KB, Result, Title, Size
        } else {
            Write-Output "No updates available."
        }

        # Check if reboot is required
        $rebootStatus = Get-WURebootStatus -Silent
        if ($rebootStatus) {
            Write-Output "Reboot is required after updates."
        }

        Write-Output "Windows Updates process completed."
    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

# Monitor job progress
while ($job.State -eq 'Running') {
    Write-Host "Update job is still running... Please wait."
    Start-Sleep -Seconds 30
}

# Retrieve and display job output
Receive-Job -Job $job
Remove-Job -Job $job

Write-Host "Windows Updates process finished." -ForegroundColor Green

# Install BitDefender
Write-Host "Attempting BitDefender Install.."
Start-Process -FilePath "$dir\epskit_x64.exe" -ArgumentList '/bdparams /silent' -Wait | Out-Host

# Run BitDefender Scan
Write-Host "Running BitDefender scan job in the background..."
Start-Job -ScriptBlock {
    & 'C:\Program Files\Bitdefender\Endpoint Security\product.console.exe' /c FileScan.OnDemand.RunScanTask custom | Out-Host
}

# Remove the scheduled task
Unregister-ScheduledTask -TaskName "ProvisioningStage2" -Confirm:$false

# Remove the run once regkey
Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "Setup-Device" -Force

# Remove the script files
Get-ChildItem -Path $dir -Filter "*.ps1" -File | Remove-Item -Force

Write-Host "Provisioining complete!`n" -ForegroundColor Green
Write-Host "See other window for Windows Update status" -ForegroundColor Yellow
Read-Host "Press any button to close this window.."

Stop-Transcript
"@
$stage2Path = "$dir\Stage2Script.ps1"
Set-Content -Path $stage2Path -Value $stage2Content
# Schedule Stage 2
$action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$stage2Path`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "ProvisioningStage2" -Action $action -Trigger $trigger -RunLevel Highest -Force

# Force reboot
Write-Host "Rebooting to continue provisoing..." -ForegroundColor Yellow
Restart-Computer -Force
Stop-Transcript