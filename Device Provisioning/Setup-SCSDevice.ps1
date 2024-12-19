###################################
############ Installs #############
###################################

$dir = "$($env:ProgramData)\ZenGuard"

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
},
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
}


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


###################################
########## Windows Update #########
###################################
Write-Host "Running Windows Updates..."

# Setup Windows Update
# Check if NuGet package provider is available
$nuget = Get-PackageProvider 'NuGet' -ListAvailable -ErrorAction SilentlyContinue

# Install NuGet package provider if not found
if ($null -eq $nuget) {
    Install-PackageProvider -Name NuGet -Confirm:$false -Force
}

# Check if the PSWindowsUpdate module is available
$module = Get-Module 'PSWindowsUpdate' -ListAvailable

# Install PSWindowsUpdate module if not found
if ($null -eq $module) {
    Install-Module PSWindowsUpdate -Confirm:$false -Force
}

# Retrieve available Windows updates
$updates = Get-WindowsUpdate 

# Install Windows updates if any are available
if ($null -ne $updates) {
    Install-WindowsUpdate -AcceptAll -Install -IgnoreReboot | 
    Select-Object KB, Result, Title, Size  # Select specific properties to display
}

# Check if a reboot is required after updates are installed
$status = Get-WURebootStatus -Silent

Write-Host "`nWindows Updates Complete`n" -ForegroundColor Green

###################################
############# Debloat #############
###################################
Write-Host "Beginning Debloat Process..."
cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File "$dir\Prep-Device.ps1"
Write-Host "Debloat Complete`n" -ForegroundColor Green

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

            $result = Start-Process @execute

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

###################################
############# Reboot ##############
###################################

Write-Host "Provisioining Complete!`n" -ForegroundColor Green
Write-Host "Rebooting in 1 minute to apply updates..." -ForegroundColor Yellow
Start-Sleep -seconds 60; Restart-Computer -Force