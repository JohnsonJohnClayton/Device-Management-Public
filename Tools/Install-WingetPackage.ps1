<#
.SYNOPSIS
    Deploys applications via Winget CLI on Windows 11 devices through Microsft Intune or other script deployment methods.
    
.DESCRIPTION
    This script provides automated installation of Winget packages with comprehensive logging
    and dependency checking. Designed for use with Microsoft Intune deployments.

    Intune execution: powershell.exe -ExecutionPolicy Bypass -File Install-WingetPackage.ps1 -ID "Microsoft.PowerShell"

.PARAMETER ID
    Winget package ID to install (e.g., "Microsoft.PowerShell"). 
    This parameter is mandatory and specifies the unique identifier for the package to be installed.

.NOTES
    Version: 1.2
    Author: John Johnson
    Creation Date: 03-31-2025
    Modified Date: 04-02-2025
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ID
)

#region Initialization
$ErrorActionPreference = "Stop"
$logPath = "C:\ProgramData\CatalystTechnologyServices\WingetInstallLog.txt"

# Ensure the directory for logs exists
if (-not (Test-Path (Split-Path $logPath -Parent))) {
    New-Item -Path (Split-Path $logPath -Parent) -ItemType Directory -Force | Out-Null
}

# Start transcript for session-wide logging
Start-Transcript -Path $logPath -Append -UseMinimalHeader
#endregion

#region Winget Detection and Installation
function Test-Winget {
    Write-Host "Checking if 'winget' command exists"

    # Check if Winget is a valid command using Get-Command
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "'winget' command detected"
        return $true
    } else {
        Write-Host "'winget' command not found. Installing Winget..."

        # Install Microsoft.VCLibs dependency (required for Winget)
        Write-Host "Installing Microsoft.VCLibs dependency..."
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile "$env:TEMP\Microsoft.VCLibs.x64.14.00.Desktop.appx" -UseBasicParsing
        Add-AppxPackage -Path "$env:TEMP\Microsoft.VCLibs.x64.14.00.Desktop.appx" -ErrorAction Stop

        # Install Winget from Microsoft Desktop App Installer bundle
        Write-Host "Downloading and installing Winget..."
        $wingetBundle = "https://aka.ms/getwinget"
        $installerPath = "$env:TEMP\Microsoft.DesktopAppInstaller.msixbundle"
        
        Invoke-WebRequest -Uri $wingetBundle -OutFile $installerPath -UseBasicParsing
        Add-AppxPackage -Path $installerPath -ErrorAction Stop
        
        # Cleanup temporary files
        Remove-Item "$env:TEMP\Microsoft.VCLibs.x64.14.00.Desktop.appx" -Force
        Remove-Item $installerPath -Force

        Write-Host "Winget installation completed successfully"
        
        # Validate installation again
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "'winget' command is now available"
            return $true
        } else {
            throw "Failed to install 'winget'. Please check logs for details."
        }
    }
}
#endregion

try {
    Write-Host "### Starting Winget deployment for package ID: '$ID' ###"

    # Ensure Winget is installed and functional
    Test-Winget

    # Install the specified package using Winget
    Write-Host "Installing package ID: '$ID' with Winget..."
    winget install --id "$ID" --source winget --accept-package-agreements --accept-source-agreements --silent
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Successfully installed package ID: '$ID'"
    } else {
        throw "Installation failed with exit code: $LASTEXITCODE"
    }

    Write-Host "### Deployment completed successfully ###"
}
catch {
    Write-Host "ERROR: $_.Exception.Message"
}
finally {
    # Stop transcript to end session logging
    Write-Host "Stopping transcript..."
    Stop-Transcript | Out-Null
}