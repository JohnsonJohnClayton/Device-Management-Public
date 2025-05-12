## Remediation Script for Disabling of IPv6 ##
# Ticket: https://jira-edhc.atlassian.net/browse/BOP-3348
# 
# Configured by John Johnson on 06/12/2024
# 
# Source: https://scloud.work/registry-key-with-intune/

$Path = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\"
$Key = "DisabledComponents"
$KeyFormat = "DWord"
$Value = 255

try{
    if(!(Test-Path $Path)){New-Item -Path $Path -Force}
    if(!$Key){Set-Item -Path $Path -Value $Value}
    else{Set-ItemProperty -Path $Path -Name $Key -Value $Value -Type $KeyFormat}
    Write-Output "Key set: $Key = $Value"
}catch{
    Write-Error $_
}