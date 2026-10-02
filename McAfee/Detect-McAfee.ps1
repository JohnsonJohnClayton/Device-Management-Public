<#
.SYNOPSIS
Detect McAffe Agent
.DESCRIPTION
Looks for McAffee installation in Registry at:
HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall, HKLM:\Software\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall
.NOTES
Written by John Johnson on 09/23/2024
#>

Write-Host "Detecting McAfee..."

$remediation = "false"
$mcafeeinstalled = "false"

$InstalledSoftware = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($obj in $InstalledSoftware) {
    $name = $obj.GetValue('DisplayName')
    if($name -like "*McAfee*"){
        Write-Host "McAffe detected at HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        $mcafeeinstalled = "true"
    }
}

$InstalledSoftware32 = Get-ChildItem "HKLM:\Software\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($obj32 in $InstalledSoftware32) {
    $name32 = $obj32.GetValue('DisplayName')
    if($name32 -like "*McAfee*"){
        Write-Host "McAffe detected at HKLM:\Software\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall"
        $mcafeeinstalled = "true"
    }
}

if(Get-AppxPackage *mcafee* -AllUsers){
    Write-Host "McAffe detected as an AppxPackage"
    $mcafeeinstalled = "true"
}

# If Mcafee is installed, we will return with a failure / negative status, as remediation is needed to remove it
if ($mcafeeinstalled -eq "true") {
    write-host '<-Start Result->'
    write-host "Needs Remediation= $mcafeeinstalled"
    write-host '<-End Result->'
    exit 1
}

# If Mcafee is not installed, we will return with a success / positive status, as no remediation is needed
if ($mcafeeinstalled -eq "false") {
    write-host '<-Start Result->'
    write-host "Needs Remediation= $mcafeeinstalled"
    write-host '<-End Result->'
    exit 0
}