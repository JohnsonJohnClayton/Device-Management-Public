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
    Version: 1.1
    Author: John Johnson
    Creation Date: 2025-03-31
    Modified Date: 2025-03-31
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ID
)

#region Initialization
$ErrorActionPreference = "Stop"
$logPath = "C:\ProgramData\CatalystTechnologyServices\WingetInstallLog.txt"

# Create log directory if missing
if (-not (Test-Path (Split-Path $logPath -Parent))) {
    New-Item -Path (Split-Path $logPath -Parent) -ItemType Directory -Force | Out-Null
}
#endregion

#region Logging Function
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $logPath -Value $logEntry -Encoding UTF8
}
#endregion

#region Winget Path Detection
function Get-WingetPath {
    # Check system-wide installation first
    $systemPaths = @(
        "${env:ProgramFiles}\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe",
        "${env:ProgramFiles}\WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe",
        "${env:ProgramFiles(x86)}\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe",
        "${env:ProgramFiles(x86)}\WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe"
    )

    foreach ($path in $systemPaths) {
        $wingetExe = Get-ChildItem $path -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
                     Select-Object -First 1 -ExpandProperty FullName
        if ($wingetExe) {
            return $wingetExe
        }
    }

    throw "Winget not found in system locations"
}
#endregion

try {
    Write-Log "### Starting Winget deployment for package $ID ###"

    #region Winget Installation Check
    Write-Log "Checking Winget installation"
    $wingetPath = Get-WingetPath
    Write-Log "Resolved Winget path: $wingetPath"

    if (Test-Path $wingetPath) {
        $wingetVersion = & $wingetPath --version
        Write-Log "Winget $wingetVersion detected"
    }
    else {
        Write-Log "Winget not found, initiating installation"
        
        # Install Microsoft.VCLibs dependency
        Add-AppxPackage -Path "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -ErrorAction Stop
        
        # Install Winget from Microsoft Desktop App Installer
        $wingetBundle = "https://aka.ms/getwinget"
        $installerPath = "$env:TEMP\Microsoft.DesktopAppInstaller.msixbundle"
        
        Invoke-WebRequest -Uri $wingetBundle -OutFile $installerPath -UseBasicParsing
        Add-AppxPackage -Path $installerPath -ErrorAction Stop
        
        $wingetPath = Get-WingetPath
        Write-Log "Winget successfully installed at: $wingetPath"
    }
    #endregion

    #region Package Installation
    Write-Log "### Starting installation of package $ID ###"
    $installResult = & $wingetPath install --id $ID --source winget --accept-package-agreements --accept-source-agreements --silent
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Successfully installed $ID"
    }
    else {
        throw "Installation failed with exit code $LASTEXITCODE. Output: $installResult"
    }
    #endregion

    Write-Log "### Deployment completed successfully ###"
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "### Deployment failed ###"
    exit 1
}