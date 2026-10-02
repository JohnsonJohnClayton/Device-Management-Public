[CmdletBinding()]
param([Parameter(Mandatory)][string]$PrimaryDomain)

$objects = Get-ADUser -Filter * -Properties proxyAddresses
foreach ($obj in $objects) {
    $originalProxies = $obj.proxyAddresses
    $newProxies = @()
    foreach ($proxy in $originalProxies) {
        if ($proxy -like "SMTP:*@$PrimaryDomain") {
            # Leave the configured primary domain as "SMTP:"
            $newProxies += $proxy
        } elseif ($proxy -like 'SMTP:*') {
            # Change all other "SMTP:" to "smtp:"
            $newProxies += $proxy -replace '^SMTP:', 'smtp:'
        } else {
            $newProxies += $proxy
        }
    }
    # Only update if changes are needed
    if (-not (@($originalProxies) -eq @($newProxies))) {
        Set-ADUser -Identity $obj -Replace @{proxyAddresses = $newProxies}
        Write-Host "Updated proxyAddresses for $($obj.SamAccountName)"
    }
}