#-----------------------------------------------------------------------#
# Call private script from GitHub to provision device during OOBE setup #
#-----------------------------------------------------------------------#

# Ensure TLS 1.2 is enabled (best practice for secure connections)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Begin logging
$dir = "C:\ProgramData\PPKG-Deployment"
New-Item -Path $dir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$dir\OOBE_DeviceSetupLog.txt" -Append

Write-Host "Provisioning script started at: $(Get-Date)"

# Move items from provisioning package
Get-ChildItem | Where-Object{$_.name -ne "Setup-Provisioning.ps1"} | ForEach-Object{
    Copy-Item $_.FullName "$($dir)\$($_.name)" -Force
}

try {
    # Download the script from private GitHub Repo
    Invoke-WebRequest -Uri "" `
    -OutFile "C:\ProgramData\PPKG-Deployment\Setup-Provisioning.ps1" `
    -UseBasicParsing `
    -Headers @{ 
        Authorization = ""
        Accept = "application/vnd.github.v3.raw" 
    } | cmd /c powershell -ExecutionPolicy Bypass -File "C:\ProgramData\PPKG-Deployment\Setup-Provisioning.ps1"
}
catch {
    Write-Host "Error encountered: $_"
}

# Stop logging
Stop-Transcript