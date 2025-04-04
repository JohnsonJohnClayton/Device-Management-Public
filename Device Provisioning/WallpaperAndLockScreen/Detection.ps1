<#
## Detection Script for setting company wallpaper & lockscreen##
# ChangeID (Monday): 7241828735 
# Configured by John Johnson on 08/19/2024
# Modified by Ignacio Galdos on 08/21/2024
#>

Write-Output "`n-- Detection Results For Host $Env:COMPUTERNAME --"

#Set URLs
$url_Desktop = "https://negeneralstorage.blob.core.windows.net/ne-wallpaperdeployment/wallpaper.png"
$url_LockScreen = "https://negeneralstorage.blob.core.windows.net/ne-wallpaperdeployment/lockscreen.png"

#ActualValue$ActualValue Path where keys live
$Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"

#Directory where image is saved
$directory = "$env:HOMEDRIVE\NetworkElites"

$ExpectedValues = @{
    # Uncomment if needed, but this path should be set automatically
    ##"DesktopImagePath"   = "$directory\wallpaper.png"
    "DesktopImageStatus"  = "1"
    "DesktopImageUrl"     = $url_Desktop
    # Uncomment if needed, but this path should be set automatically
    ##"LockScreenImagePath"= "$directory\lockscreen.png"
    "LockScreenImageStatus" = "1"
    "LockScreenImageUrl"  = $url_LockScreen
}

#Compliance will be notated in this log, then evaluated at the end
$Log = ""
function Get-Compliance {
  Param
    (
      [Parameter(Mandatory=$true)]
      [string] $Name,
      
      [Parameter(Mandatory=$true)]
      [string] $ExpectedValue
    )

  # Evaluate given regkey and value to see if it exists and/or has the correct value. Machine is Not Compliant unless both are true.
  Try {
      $ActualValue = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name

      If ($ActualValue -eq $ExpectedValue) {
        $script:Log += "`nCompliant: $Path\$Name set to expected value: $ExpectedValue - No action required"
      } Else {
        $script:Log += "`nNot Compliant: $Path\$Name not set to expected value... Value Found: $ActualValue, Expected: $ExpectedValue, - Requires Remediation."
      }
  } Catch {
     $script:Log += "`nNot Compliant: $Path\$Name not found - Requires Remediation."
  }
}

#Check Compliance for each defined regkey at under the $Path
ForEach ($Name in $ExpectedValues.keys)
{
    Get-Compliance -Name $Name -ExpectedValue $ExpectedValues[$Name]
}

# Evaluate Log for compliance and write to console
If ($Log -match "Not Compliant"){
    Write-Warning $Log
    Exit 1
}
Elseif ($Log -match "No action required"){
    Write-Output $Log
    Exit 0
} Else {Write-Error "Unexpected error during compliance check: `n$Log`n"}