<#
.SYNOPSIS
    Checks for applications deployed via Winget CLI on Windows 11 devices through Microsoft Intune or other script deployment methods.
    
.DESCRIPTION
    This script provides detection of Winget packages with comprehensive logging
    and dependency checking. Designed for use with Microsoft Intune deployments.

    Intune execution: powershell.exe -ExecutionPolicy Bypass -File Verify-Install.ps1 -ID "Microsoft.PowerShell"

.NOTES
    Version: 1.0
    Author: John Johnson
    Creation Date: 04-02-2025
    Modified Date: 
    Dependencies: Winget CLI must be installed and configured on the system.
    Logging: Logs are stored in C:\ProgramData\CatalystTechnologyServices\WingetInstallLog.txt.
#>

#region Initialization
$appID = "Microsoft.VisualStudioCode"
$ErrorActionPreference = "Stop"
$logPath = "C:\ProgramData\CatalystTechnologyServices\WingetInstallLog.txt"

# Ensure the directory for logs exists
if (-not (Test-Path (Split-Path $logPath -Parent))) {
    New-Item -Path (Split-Path $logPath -Parent) -ItemType Directory -Force | Out-Null
}

# Start transcript for session-wide logging
Start-Transcript -Path $logPath -Append -UseMinimalHeader
#endregion

#region Application Detection
$app = winget list $appID -e --accept-source-agreements
winget list $appID -e --accept-source-agreements

if ($app -notmatch "No installed package found matching input criteria.") {
    Write-Output "$appID detected"
    exit 0
} else {
    Write-Output "$appID not detected"
    exit 1
}
#endregion

# Stop transcript to end session logging
Write-Host "Stopping transcript..."
Stop-Transcript | Out-Null