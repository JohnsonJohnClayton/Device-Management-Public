<#
.SYNOPSIS
    Remediate need for wallpaper and lock screen images for a Windows device
.DESCRIPTION
    This script remediates the need for wallpaper and lock screen images for a Windows device.
    It downloads the images from public URLs and updates the registry to set them as the desktop and lock screen backgrounds.
.NOTES
    Author: John Johnson
    Creation Date: 05/12/2025
.OUTPUTS
    None
#>


#Set URLs
$url_Desktop = "https://example.blob.core.windows.net/example/wallpaper.png"
$url_LockScreen = "https://example.blob.core.windows.net/example/lockscreen.png"

#Regkey where these values are held
$RegKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"

#Setting Desktop Image
$DesktopPath = "DesktopImagePath"
$DesktopStatus = "DesktopImageStatus"
$DesktopUrl = "DesktopImageUrl"

#Setting Lockscreen Image
$LockScreenPath = "LockScreenImagePath"
$LockScreenStatus = "LockScreenImageStatus"
$LockScreenUrl = "LockScreenImageUrl"

$StatusValue = "1"

#Where the files will live on the device
$directory = "$env:windir\NetworkElites"
$DesktopImageValue = "$directory\wallpaper.png"
$LockScreenImageValue = "$directory\lockscreen.png"

#Create the NetworkElites Directory if it does not already exist
If ((Test-Path -Path $directory) -eq $false)
{
New-Item -Path $directory -ItemType directory
}

#Download and set the wallpaper
$wc1 = New-Object System.Net.WebClient
$wc1.DownloadFile($url_Desktop, $DesktopImageValue)
if (!(Test-Path $RegKeyPath))
{
Write-Host "Creating registry path $($RegKeyPath)."
New-Item -Path $RegKeyPath -Force | Out-Null
}
New-ItemProperty -Path $RegKeyPath -Name $DesktopStatus -Value $Statusvalue -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $RegKeyPath -Name $DesktopPath -Value $DesktopImageValue -PropertyType STRING -Force | Out-Null
New-ItemProperty -Path $RegKeyPath -Name $DesktopUrl -Value $url_Desktop -PropertyType STRING -Force | Out-Null

#Download and set the lockscreen
$wc2 = New-Object System.Net.WebClient
$wc2.DownloadFile($url_LockScreen, $LockScreenImageValue)
if (!(Test-Path $RegKeyPath))
{
Write-Host "Creating registry path $($RegKeyPath)."
New-Item -Path $RegKeyPath -Force | Out-Null
}
New-ItemProperty -Path $RegKeyPath -Name $LockScreenStatus -Value $Statusvalue -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $RegKeyPath -Name $LockScreenPath -Value $LockScreenImageValue -PropertyType STRING -Force | Out-Null
New-ItemProperty -Path $RegKeyPath -Name $LockScreenUrl -Value $url_LockScreen -PropertyType STRING -Force | Out-Null

#Refresh Wallpaper
# Inline c# code to refresh the wallpaper
Add-Type @"
    using System.Runtime.InteropServices;

    public class Wallpaper {
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
        private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

        public static void Refresh(string path) {
            SystemParametersInfo(20, 0, path, 0x01|0x02); 
        }
    }
"@
[Wallpaper]::Refresh($DesktopImageValue)