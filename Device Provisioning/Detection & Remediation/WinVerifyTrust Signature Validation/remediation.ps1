## Detection Script for WinVerifyTrust Signature Validation CVE-2013-3900 Mitigation (EnableCertPaddingCheck) ## 
# Configured by John Johnson on 05/06/2024


$Path = "HKLM:\SOFTWARE\Microsoft\Cryptography\Wintrust\Config\"
$Key = "EnableCertPaddingCheck"
$KeyFormat = "String"
$Value = 1

try{
    if(!(Test-Path $Path)){New-Item -Path $Path -Force}
    if(!$Key){Set-Item -Path $Path -Value $Value}
    else{Set-ItemProperty -Path $Path -Name $Key -Value $Value -Type $KeyFormat}
    Write-Output "Key set: $Key = $Value"
}catch{
    Write-Error $_
}