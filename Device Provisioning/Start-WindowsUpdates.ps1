###################################
########## Windows Update #########
###################################

Start-Transcript -Path "$dir\DeviceSetupLog.txt"

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