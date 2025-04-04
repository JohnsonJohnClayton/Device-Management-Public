<#
.SYNOPSIS
Debloat script geared toward Windows 11 devices
.NOTES
Written by John Johnson on 09/11/2024
Credit to Andrew S Taylor for logic and backbone
Source: https://andrewstaylor.com/2022/08/09/removing-bloatware-from-windows-10-11-via-script/
#>

[CmdletBinding()]
param (
    #Clear start menu if switch is called (Off by default)
    [Parameter(Mandatory=$false)]
    [switch]$ClearStartMenu
)

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

invoke-expression -Command $templateFilePath

## Set other settings ##

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

function Clear-StartMenu {
    param(
        $message = "Clearing Pinned Items on Start Menu..."
    )

    Write-Output $message

    # Path to start menu template
    $startmenuTemplate = "$PSScriptRoot/Start/start2.bin"

    # Get all user profile folders
    $usersStartMenu = get-childitem -path "C:\Users\*\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"

    # Copy Start menu to all users folders
    ForEach ($startmenu in $usersStartMenu) {
        $startmenuBinFile = $startmenu.Fullname + "\start2.bin"

        # Check if bin file exists
        if(Test-Path $startmenuBinFile) {
            Copy-Item -Path $startmenuTemplate -Destination $startmenu -Force

            $cpyMsg = "Replaced start menu for user " + $startmenu.Fullname.Split("\")[2]
            Write-Output $cpyMsg
        }
        else {
            # Bin file doesn't exist, indicating the user is not running the correct version of windows. Exit function
            Write-Output "Error: Start menu file not found. Please make sure you're running Windows 11 22H2 or later"
            return
        }
    }

    # Also apply start menu template to the default profile

    # Path to default profile
    $defaultProfile = "C:\Users\default\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"

    # Create folder if it doesn't exist
    if(-not(Test-Path $defaultProfile)) {
        new-item $defaultProfile -ItemType Directory -Force | Out-Null
        Write-Output "Created LocalState folder for default user"
    }

    # Copy template to default profile
    Copy-Item -Path $startmenuTemplate -Destination $defaultProfile -Force
    Write-Output "Copied start menu template to default user folder"
}
# Check if the -ClearStartMenu switch parameter was passed
if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('ClearStartMenu')) {
Clear-StartMenu
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
    #   Gallery
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\Namespace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_41040327\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
    #   Home
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

#Clear out start menu (Not needed for most Autopilot deployments)
#Comment out if needed
#Can also be called from switch -ClearStartMenu
# Clear-StartMenu

#Restart explorer to apply changes
Restart-Explorer