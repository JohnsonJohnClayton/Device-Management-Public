## NOTE: THIS HAS TO RUN IN 64-BIT MODE!
## Source: https://github.com/andrew-s-taylor/public/blob/main/Powershell%20Scripts/Intune/set-background.ps1
## Configured by John Johnson on 08/19/2024

#Set URLs
$url_Desktop = "https://negeneralstorage.blob.core.windows.net/ne-wallpaperdeployment/wallpaper.png"
$url_LockScreen = "https://negeneralstorage.blob.core.windows.net/ne-wallpaperdeployment/lockscreen.png"

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
[Wallpaper]::Refresh($url_Desktop)