## Detection Script for WinVerifyTrust Signature Validation CVE-2013-3900 Mitigation (EnableCertPaddingCheck) ##
# Ticket: https://jira-edhc.atlassian.net/browse/SS-898

# 
# Configured by John Johnson on 05/06/2024
# 
# Source: https://scloud.work/registry-key-with-intune/

$Path = "HKLM:\SOFTWARE\Microsoft\Cryptography\Wintrust\Config\"
$Name = "EnableCertPaddingCheck"
$Value = 1

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