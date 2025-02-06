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

# Remove Edge Desktop icon
Write-Host "Turning off (old) Edge desktop shortcut"
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v DisableEdgeDesktopShortcutCreation /t REG_DWORD /d 1 /f /reg:64 | Out-Host
Write-Host "Turning off Edge desktop icon"
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" /v "CreateDesktopShortcutDefault" /t REG_DWORD /d 0 /f /reg:64 | Out-Host

###################################
########## Windows Update #########
###################################
$UpdateScript = "$dir\Run-Updates.ps1"
Write-Host "Running Windows Updates in a concurrent process..."
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/John-ZenGuard/Device-Management-Public/refs/heads/main/Device%20Provisioning/Start-WindowsUpdates.ps1" -OutFile $UpdateScript -UseBasicParsing 
Start-Process "powershell.exe" -ArgumentList '-File', $UpdateScript

## Set other settings ##
<#
#Get all SIDS to remove at user-level if needed
$UserSIDs = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" | Select-Object -ExpandProperty PSChildName
function Set-Regkey {
    # Requires the full path of the registry key to set
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $FullPath,
        
        [Parameter(Mandatory=$true)]
        [string] $value
        )
        
        #Extract key from full path
        $key = Split-Path -Leaf $FullPath
        $path = Split-Path $FullPath
        try {
            Write-Output "`nAttempting to set $path\$key to $value..."
            If (!(Test-Path $path)) {
                New-Item $path
            }
            If (Test-Path $path) {
                Set-ItemProperty $path $key -Value $value
            }
        Write-Output "Successfully set $path\$key to $value"
        #Do the same for all users
        if ($path.StartsWith("HKCU")) {
            
        $path = $path -replace "^HKCU:", ""
        foreach ($sid in $UserSIDs) {
            $userPath = "Registry::HKU\"+$sid+$path
            If (!(Test-Path $userPath)) {
                New-Item $userPath
            } Else {
                Set-ItemProperty $userPath $key -Value $value
            }
        }
        Write-Output "Successfully set $userPath\$key to $value for all users"
    }
} catch {
    Write-Warning "`nThere was an issue writing $path\$key"
    Write-Warning $_
}
}
function Remove-Regkey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $path
        )
        try {
            Write-Output "`nAttempting to remove $path"
            If (Test-Path $path) {
                Remove-Item $path -Recurse
                Write-Output "Removed $path and its child items"
            } else {
                Write-Output "No path found at $path"
            }
        } catch {
            Write-Warning "`nThere was an issue removing"
            Write-Warning $_
        }
    }
    function Restart-Explorer {
        Write-Output "> Restarting windows explorer to apply all changes."
        
        Start-Sleep 0.5
        
        taskkill /f /im explorer.exe
        
        Start-Process explorer.exe
        
        Write-Output ""
    }
    
    $RegkeysToSet = @{
        #Disable Bing from Search bar
        "HKLM:\Software\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions" = 00000001
        #Remove chat from taskbar
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarMn" = 00000000
        #Tailored experiences with diagnostic data for Current User
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy\TailoredExperiencesWithDiagnosticDataEnabled" = 00000000
        #Disable Lockscreen tips
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SubscribedContent-338387Enabled" = 00000000
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\RotatingLockScreenOverlayEnabled" = 00000000
        #Disable Improving Inking and Typing Recognition
    "HKCU:\Software\Microsoft\Input\TIPC\Enabled" = 00000000
    #Disable Widgets on Taskbar
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDa" = 00000000
    #Disable Widgets Service
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests\value" = 00000000
    "HKLM:\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests" = 00000000
}

$RegkeysToRemove = @(
    #Remove Gallery and Home from quick access
    # Gallery
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\Namespace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_41040327\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
    # Home
    #"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
    #"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_36354489\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"
    #Hide duplicate drives from Flie Explorer
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders\{F5FB2C77-0E2F-4A16-A381-3E560C68BC83}"
    )
    
    ForEach ($Path in $RegkeysToSet.Keys){
        Set-Regkey -FullPath $Path -value $RegkeysToSet[$Path]
    }
    
    ForEach($Path in $RegkeysToRemove){
        Remove-Regkey -path $Path
    }
    
    #Restart explorer to apply changes
    Restart-Explorer
    
    #Remove anything left over
    Get-AppxPackage -AllUsers *mirkat* | Remove-AppxPackage -AllUsers
    Get-AppxPackage -AllUsers *mcafee* | Remove-AppxPackage -AllUsers
    Get-AppxPackage -AllUsers *teams* | Remove-AppxPackage -AllUsers
    Get-AppxPackage -AllUsers *alexa* | Remove-AppxPackage -AllUsers
    
    Write-Host "Debloat Complete`n" -ForegroundColor Green
    
#>

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