# Toggle GAL visibility for AD-synced mail-enabled objects.
# Reads a CSV with DistinguishedName or UserPrincipalName.
# Sets msExchHideFromAddressLists to $true (hide from GAL) or $false (show in GAL).
# Requires: AD module, permissions to modify the attribute.

param (
    [Parameter(Mandatory)]
    [string]$CsvPath,    # Path to input CSV: must have 'DistinguishedName' or 'UserPrincipalName'
    [Parameter()]
    [switch]$Unhide # If present, sets attribute to $false to show in GAL
)

# Import input; support both DN and UPN identifiers
$list = Import-Csv -Path $CsvPath

foreach ($entry in $list) {
    # Determine which identifier to use for AD query (DN preferred)
    $filter = if ($entry.DistinguishedName) {
        "DistinguishedName -eq '$($entry.DistinguishedName)'"
    } elseif ($entry.UserPrincipalName) {
        "UserPrincipalName -eq '$($entry.UserPrincipalName)'"
    } else {
        Write-Warning "No DN or UPN in row: $($entry | Out-String)"
        continue
    }

    # Locate the AD object with the selected identifier
    $adObject = Get-ADObject -LDAPFilter "(|(distinguishedName=$($entry.DistinguishedName))(userPrincipalName=$($entry.UserPrincipalName)))" -Properties msExchHideFromAddressLists

    if ($adObject) {
        # $true = hide from GAL; $false = show in GAL
        $newValue = if ($Unhide) { $false } else { $true }
        Set-ADObject -Identity $adObject.DistinguishedName -Replace @{msExchHideFromAddressLists = $newValue}
        Write-Verbose "Set msExchHideFromAddressLists=$newValue for $($adObject.DistinguishedName)"
    } else {
        Write-Warning "Object not found: $($entry | Out-String)"
    }
}
# Change is synced to Exchange Online after next Azure AD Connect cycle.