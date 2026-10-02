# Toggle receiving mail from external senders for AD-synced mail-enabled objects.
# This script reads a CSV with either DistinguishedName or UserPrincipalName.
# Sets msExchRequireAuthToSendTo to $true (block externals) or $false (allow externals).
# Requires: Active Directory module, account with permission to modify target objects.

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$CsvPath,    # Input CSV path; must contain 'DistinguishedName' or 'UserPrincipalName'
    [Parameter()]
    [switch]$AllowExternal # Switch: If present, allows receiving external mail (sets attribute to $false)
)

# Import the object list from CSV; supports DN or UPN fields.
$list = Import-Csv -Path $CsvPath

foreach ($entry in $list) {
    # Determine unique AD filter to locate object.
    $filter = if ($entry.DistinguishedName) {
        "DistinguishedName -eq '$($entry.DistinguishedName)'"
    } elseif ($entry.UserPrincipalName) {
        "UserPrincipalName -eq '$($entry.UserPrincipalName)'"
    } else {
        Write-Warning "No DN or UPN found for row: $($entry | Out-String)"
        continue
    }

    # Look up the AD object, requesting the required attribute property.
    $adObject = Get-ADObject -LDAPFilter $filter -Properties msExchRequireAuthToSendTo

    if ($adObject) {
        # Set msExchRequireAuthToSendTo. $true = block external. $false = allow external.
        $newValue = if ($AllowExternal) { $false } else { $true }
        Set-ADObject -Identity $adObject.DistinguishedName -Replace @{msExchRequireAuthToSendTo = $newValue}
        Write-Verbose "Set msExchRequireAuthToSendTo=$newValue for $($adObject.DistinguishedName)"
    } else {
        Write-Warning "Object not found: $($entry | Out-String)"
    }
}
# Note: Changes sync to Exchange Online after the next AD Connect cycle.