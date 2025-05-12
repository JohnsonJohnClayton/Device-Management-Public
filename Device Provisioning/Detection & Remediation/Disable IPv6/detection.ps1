## Detection Script for Disabling of IPv6 ##
# Ticket: https://jira-edhc.atlassian.net/browse/BOP-3348
# 
# Configured by John Johnson on 06/12/2024
# 
# Source: https://scloud.work/registry-key-with-intune/

$Path = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\"
$Name = "DisabledComponents"
$Value = 255

Try {
    $Registry = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop | Select-Object -ExpandProperty $Name
    If ($Registry -eq $Value){
        Write-Output "Compliant"
        Exit 0
    } 
    Write-Warning "Not Compliant"
    Exit 1
} 
Catch {
    Write-Warning "Not Compliant"
    Exit 1
}