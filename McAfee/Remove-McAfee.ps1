<#
.SYNOPSIS
Remove McAffe Agent
.DESCRIPTION
Looks for McAffee installation in Registry at:
HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall, HKLM:\Software\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall
.NOTES
Source: Taken from debloat script: https://raw.githubusercontent.com/andrew-s-taylor/public/main/De-Bloat/RemoveBloat.ps1
Written by John Johnson on 09/23/2024
#>

Write-Host "Detecting McAfee, Huntress, and Cynet"

$remediation = "false"
$mcafeeinstalled = "false"
$cynetInstalled = "false"
$huntressInstalled = "false"

$InstalledSoftware = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($obj in $InstalledSoftware) {
    $name = $obj.GetValue('DisplayName')
    if($name -like "*McAfee*"){
        $mcafeeinstalled = "true"
        Write-Host "$name found"
        continue
    } if($name -like "*Cynet*"){
        $cynetInstalled = "true"
        Write-Host "$name found"
        continue
    } if($name -like "*Huntress*"){
        $huntressInstalled = "true"
        Write-Host "$name found"
        continue
    }
}

$InstalledSoftware32 = Get-ChildItem "HKLM:\Software\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($obj32 in $InstalledSoftware32) {
    $name32 = $obj32.GetValue('DisplayName')
    if($name32 -like "*McAfee*"){
        $mcafeeinstalled = "true"
        Write-Host "$name32 found"
        continue
    } if($name32 -like "*Cynet*"){
        $cynetInstalled = "true"
        Write-Host "$name32 found"
        continue
    } if($name32 -like "*Huntress*"){
        $huntressInstalled = "true"
        Write-Host "$name32 found"
        continue
    }
}

if(Get-AppxPackage *mcafee* -AllUsers) {$mcafeeinstalled = "true"}

if($mcafeeinstalled -eq "true" -and ($cynetInstalled -eq "true" -and $huntressInstalled -eq "true")){$remediation = "true"}

write-host '<-Start Result->'
write-host "Needs Remediation=$remediation"
write-host '<-End Result->'

if ($remediation -eq "true") {
    write-output "McAfee detected as well as Cynet and Huntress. Removing..."
    #Remove McAfee bloat
    ##McAfee
    ### Download McAfee Consumer Product Removal Tool ###
    write-output "Downloading McAfee Removal Tool"
    # Download Source
    $URL = 'https://github.com/andrew-s-taylor/public/raw/main/De-Bloat/mcafeeclean.zip'

    # Set Save Directory
    $destination = 'C:\ProgramData\Debloat\mcafee.zip'
    #Create Folder
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

    Start-Transcript -Path "C:\ProgramData\Debloat\Debloat.log"

    #Download the file
    Invoke-WebRequest -Uri $URL -OutFile $destination -Method Get

    Expand-Archive $destination -DestinationPath "C:\ProgramData\Debloat" -Force

    write-output "Removing McAfee"
    # Automate Removal and kill services
    start-process "C:\ProgramData\Debloat\Mccleanup.exe" -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s"
    write-output "McAfee Removal Tool has been run"

    ###New MCCleanup
    ### Download McAfee Consumer Product Removal Tool ###
    write-output "Downloading McAfee Removal Tool"
    # Download Source
    $URL = 'https://github.com/andrew-s-taylor/public/raw/main/De-Bloat/mccleanup.zip'

    # Set Save Directory
    $destination = 'C:\ProgramData\Debloat\mcafeenew.zip'

    #Download the file
    Invoke-WebRequest -Uri $URL -OutFile $destination -Method Get

    New-Item -Path "C:\ProgramData\Debloat\mcnew" -ItemType Directory
    Expand-Archive $destination -DestinationPath "C:\ProgramData\Debloat\mcnew" -Force

    write-output "Removing McAfee"
    # Automate Removal and kill services
    start-process "C:\ProgramData\Debloat\mcnew\Mccleanup.exe" -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s"
    write-output "McAfee Removal Tool has been run"

    $InstalledPrograms = $allstring | Where-Object { ($_.Name -like "*McAfee*") }
    $InstalledPrograms | ForEach-Object {

        write-output "Attempting to uninstall: [$($_.Name)]..."
        $uninstallcommand = $_.String

        Try {
            if ($uninstallcommand -match "^msiexec*") {
                #Remove msiexec as we need to split for the uninstall
                $uninstallcommand = $uninstallcommand -replace "msiexec.exe", ""
                $uninstallcommand = $uninstallcommand + " /quiet /norestart"
                $uninstallcommand = $uninstallcommand -replace "/I", "/X "
                #Uninstall with string2 params
                Start-Process 'msiexec.exe' -ArgumentList $uninstallcommand -NoNewWindow -Wait
            }
            else {
                #Exe installer, run straight path
                $string2 = $uninstallcommand
                start-process $string2
            }
            #$A = Start-Process -FilePath $uninstallcommand -Wait -passthru -NoNewWindow;$a.ExitCode
            #$Null = $_ | Uninstall-Package -AllVersions -Force -ErrorAction Stop
            write-output "Successfully uninstalled: [$($_.Name)]"
        }
        Catch { Write-Warning -Message "Failed to uninstall: [$($_.Name)]" }
    }

    #Attempt to Remove by AppxPackage
    try {
        Get-AppxPackage -AllUsers *mcafee* | Remove-AppxPackage -AllUsers
        Write-Host "Removed McAfee by AppxPackage"
    }
    catch {
        If(Get-AppxPackage -AllUsers *mcafee*) {Write-Host "Unable to find McAfee by AppxPackage"}
        Else {Write-Host "There was an issue when removing McAfee by AppxPackage - `n$_"}
    }
    
    ##Remove Safeconnect
    $safeconnects = Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall, HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall | Get-ItemProperty | Where-Object { $_.DisplayName -match "McAfee Safe Connect" } | Select-Object -Property UninstallString

    ForEach ($sc in $safeconnects) {
        If ($sc.UninstallString) {
            cmd.exe /c $sc.UninstallString /quiet /norestart
        }
    }

    ##
    ##remove some extra leftover Mcafee items from StartMenu-AllApps and uninstall registry keys
    ##
    if (Test-Path -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee") {
        Remove-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee" -Recurse -Force
    }
    if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS") {
        Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS" -Recurse -Force
    }
    #Interesting emough, this producese an error, but still deletes the package anyway
    get-appxprovisionedpackage -online | sort-object displayname | format-table displayname, packagename
    get-appxpackage -allusers | sort-object name | format-table name, packagefullname
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq "McAfeeWPSSparsePackage" | Remove-AppxProvisionedPackage -Online -AllUsers
}