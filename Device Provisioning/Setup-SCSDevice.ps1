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

Start-Transcript -Path "$dir\DeviceSetupLog.txt"

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

###################################
########## Windows Update #########
###################################
$UpdateScript = "$dir\Run-Updates.ps1"
Write-Host "Running Windows Updates in a concurrent process..."
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/John-ZenGuard/Device-Management-Public/refs/heads/main/Device%20Provisioning/Start-WindowsUpdates.ps1" -OutFile $UpdateScript -UseBasicParsing 
Start-Process "powershell.exe" -ArgumentList '-File', $UpdateScript

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


Write-Host "Attempting BitDefender Install.."
Start-Process -FilePath "$dir\epskit_x64.exe" -ArgumentList '/bdparams /silent' | Out-Host

#####################################
######## Run BitDefender Scan #########
#####################################
Write-Host "Running BitDefender Scan.."
& 'C:\Program Files\Bitdefender\Endpoint Security\product.console.exe' /c FileScan.OnDemand.RunScanTask custom

###################################
############# Reboot ##############
###################################

Write-Host "Provisioining Complete!`n" -ForegroundColor Green
Write-Host "Rebooting in 5 minutes to apply updates..." -ForegroundColor Yellow
Write-Host "-Press CTRL+C to cancel-"
Start-Sleep -seconds 300; Restart-Computer -Force
Stop-Transcript