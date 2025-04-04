<#
.SYNOPSIS
Checks for debloat folder and log
.NOTES
Written by John Johnson on 09/26/2024
#>

# Exit code for the script to return to Intune. Only modified if remediation is required
$exitCode = 0

#Check if log for debloat exists
$DebloatFolder = "C:\ProgramData\Debloat"
if (Test-Path $DebloatFolder) {
    Write-Host "$DebloatFolder exists. Checking for log."
    if(Test-Path "$DebloatFolder\debloat.log"){
        Write-Host "Log found - no remediation required."
    } else {
        Write-Host "$DebloatFolder\debloat.log not found - remediation required."
        # Reutrn error code to Intune, flagging for remediation
        $exitCode = 1
    }
}
else {
    Write-Host "$DebloatFolder not found - remediation required."
    # Reutrn error code to Intune, flagging for remediation
    $exitCode = 1
}

# Check for apps that need to be remediated.

# Define apps that require remediation
$badApps =@(
    "XBox",
    "McAfee",
    "Alexa"
)
$apps = Get-AppxPackage -AllUsers
foreach($app in $badApps){
    $badApp = $apps | Where-Object { $_.Name -like "*$($app)*" }
    if ($badApp){
        Write-Host "$($badApp.Name) found. Remediation required."
        $exitCode = 1
    }
}