<#
# Intune deployment for Mountain Duck Software for the replacement of on-prem sites
# Install command: powershell.exe -executionpolicy bypass -file Install-Software.ps1

# Other configs will connect the software to Amazon S3 buckets

# Source docs:
    Registration: https://docs.mountainduck.io/mountainduck/installation/#registration-key

    Install: https://mountainduck.io/changelog/
    Unsure what the explorer extension install does

    Configuration: 
    Add Hidden Configuration Options to Mountain Duck and Cyberduck — Cyberduck Help documentation
    Connection Profiles — Cyberduck Help documentation

    CLI: Command Line Interface (CLI) — Cyberduck Help documentation
#>

# Copy installer to permanent directory
New-Item -Path C:\temp -ItemType Directory -Force | Out-Null
Copy-Item "Mountain Duck Installer-4.17.2.22563.msi" -Destination C:\temp -Force
Copy-Item "Mountain Duck Installer-4.17.2.22563.exe" -Destination C:\temp -Force

# Install the MSI
Start-Process msiexec.exe -ArgumentList '/i "C:\temp\Mountain Duck Installer-4.17.2.22563.msi" /qn' -Wait -NoNewWindow

# Wait to ensure the install finishes creating any directories
Start-Sleep 15

# License the software by injecting license file
Copy-Item 'example.mountainducklicense' -Destination 'C:\Program Files\Mountain Duck\' -Force