<#
.SYNOPSIS
    Adds matching source-group members to a target group and optionally removes them from the source.

.DESCRIPTION
    The reference determines which source-group members are selected. ReferenceGroup may be an AD group
    identity or a CSV file containing a UserPrincipalName column. ReferenceGroup and SourceGroup are both
    optional, but at least one must be specified.

    When both are supplied, only source-group members present in the reference are processed. When only
    SourceGroup is supplied, all source-group members are processed. When only ReferenceGroup is supplied,
    all members in that AD group (or users in that CSV) are processed. CSV input has no source membership
    to remove, so those users can only be added to the target group.

    Any direct member of the source group that also exists in the reference group will be:
        1. Added to the target group
        2. Removed from the source group unless RetainSourceMembers is specified

    A separately specified reference group or CSV file is not modified. RecursiveReferenceGroup applies
    only when the reference is an AD group.

.NOTES
    Requires RSAT ActiveDirectory module.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ReferenceGroup,

    [string]$SourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$TargetGroup,

    [switch]$RecursiveReferenceGroup,

    [switch]$RetainSourceMembers,

    [string]$LogPath = ".\Move-ADGroupMembers.log"
)

begin {
    Import-Module ActiveDirectory -ErrorAction Stop

    function Write-Log {
        param(
            [string]$Message,
            [string]$Level = "INFO"
        )

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] [$Level] $Message"

        Write-Host $entry
        Add-Content -Path $LogPath -Value $entry
    }

    function ConvertTo-LdapFilterValue {
        param([string]$Value)

        $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace(([char]0).ToString(), '\00')
    }

    $ReferenceIsSpecified = -not [string]::IsNullOrWhiteSpace($ReferenceGroup)
    $SourceIsSpecified = -not [string]::IsNullOrWhiteSpace($SourceGroup)

    if (-not $ReferenceIsSpecified -and -not $SourceIsSpecified) {
        throw "Specify at least one of ReferenceGroup or SourceGroup."
    }

    $ReferenceIsCsv = $ReferenceIsSpecified -and [System.IO.Path]::GetExtension($ReferenceGroup) -eq '.csv'
    $EffectiveSourceGroup = if ($SourceIsSpecified) {
        $SourceGroup
    }
    elseif (-not $ReferenceIsCsv) {
        $ReferenceGroup
    }
    $EffectiveReferenceGroup = if ($ReferenceIsSpecified) { $ReferenceGroup } else { $SourceGroup }

    Write-Log "Starting AD group membership migration."
    Write-Log "Reference: $EffectiveReferenceGroup$(if (-not $ReferenceIsSpecified) { ' (using source group)' })"
    if ([string]::IsNullOrWhiteSpace($EffectiveSourceGroup)) {
        Write-Log "Source group: not specified; reference CSV supplies all candidate users"
    }
    else {
        Write-Log "Source group: $EffectiveSourceGroup$(if (-not $SourceIsSpecified) { ' (using reference group)' })"
    }
    Write-Log "Target group: $TargetGroup"
    Write-Log "Recursive reference group lookup: $RecursiveReferenceGroup"
    Write-Log "Retain members in source group: $RetainSourceMembers"
}

process {
    try {
        $ResolvedSourceGroup = $null
        $ResolvedReferenceGroup = $null
        $ResolvedTargetGroup = Get-ADGroup -Identity $TargetGroup -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace($EffectiveSourceGroup)) {
            $ResolvedSourceGroup = Get-ADGroup -Identity $EffectiveSourceGroup -ErrorAction Stop
        }

        if (-not $ReferenceIsSpecified) {
            $ResolvedReferenceGroup = $ResolvedSourceGroup
        }
        elseif ($ReferenceIsCsv) {
            if ($RecursiveReferenceGroup) {
                throw "RecursiveReferenceGroup cannot be used when ReferenceGroup is a CSV file."
            }
            if (-not (Test-Path -LiteralPath $ReferenceGroup -PathType Leaf)) {
                throw "Reference CSV file not found: $ReferenceGroup"
            }
            $ResolvedReferenceCsvPath = (Resolve-Path -LiteralPath $ReferenceGroup -ErrorAction Stop).Path
        }
        else {
            $ResolvedReferenceGroup = Get-ADGroup -Identity $EffectiveReferenceGroup -ErrorAction Stop
        }

        if ($null -ne $ResolvedSourceGroup -and
            $ResolvedSourceGroup.DistinguishedName -eq $ResolvedTargetGroup.DistinguishedName) {
            throw "The source and target group references resolve to the same group. They must be different."
        }

        if ($ReferenceIsCsv) {
            Write-Log "Resolved reference CSV: $ResolvedReferenceCsvPath"
        }
        else {
            Write-Log "Resolved reference group: $($ResolvedReferenceGroup.DistinguishedName)"
        }
        if ($null -ne $ResolvedSourceGroup) {
            Write-Log "Resolved source group: $($ResolvedSourceGroup.DistinguishedName)"
        }
        else {
            Write-Log "Resolved source group: none (CSV reference mode)"
        }
        Write-Log "Resolved target group: $($ResolvedTargetGroup.DistinguishedName)"
    }
    catch {
        Write-Log "Failed to resolve group or reference input. Error: $($_.Exception.Message)" "ERROR"
        throw
    }

    try {
        if ($ReferenceIsCsv) {
            $header = Get-Content -LiteralPath $ResolvedReferenceCsvPath -TotalCount 1 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($header) -or $header -notmatch '(?i)(?:^|,)\s*"?UserPrincipalName"?\s*(?:,|$)') {
                throw "Reference CSV must contain a UserPrincipalName column."
            }

            $referenceRows = @(Import-Csv -LiteralPath $ResolvedReferenceCsvPath -ErrorAction Stop)
            $SkippedReferenceUsers = 0
            $ReferenceMembers = foreach ($row in $referenceRows) {
                $upn = [string]$row.UserPrincipalName
                if ([string]::IsNullOrWhiteSpace($upn)) {
                    continue
                }

                $upn = $upn.Trim()
                $ldapValue = ConvertTo-LdapFilterValue -Value $upn
                $resolvedUsers = @(Get-ADUser `
                    -LDAPFilter "(|(userPrincipalName=$ldapValue)(mail=$ldapValue)(proxyAddresses=smtp:$ldapValue))" `
                    -ErrorAction Stop)

                if ($resolvedUsers.Count -eq 0) {
                    Write-Log "No AD user found for CSV identity '$upn'; skipping." "WARN"
                    $SkippedReferenceUsers++
                    continue
                }
                if ($resolvedUsers.Count -gt 1) {
                    Write-Log "Multiple AD users found for CSV identity '$upn'; skipping." "WARN"
                    $SkippedReferenceUsers++
                    continue
                }
                $resolvedUsers[0]
            }
            Write-Log "CSV rows skipped because they did not resolve uniquely: $SkippedReferenceUsers"
        }
        elseif ($RecursiveReferenceGroup) {
            $ReferenceMembers = Get-ADGroupMember -Identity $ResolvedReferenceGroup -Recursive -ErrorAction Stop
        }
        else {
            $ReferenceMembers = Get-ADGroupMember -Identity $ResolvedReferenceGroup -ErrorAction Stop
        }

        # Source membership remains direct-only because only direct members can be safely removed.
        if ($null -ne $ResolvedSourceGroup) {
            $SourceGroupMembers = @(Get-ADGroupMember -Identity $ResolvedSourceGroup -ErrorAction Stop)
        }
        $TargetGroupMembers = Get-ADGroupMember -Identity $ResolvedTargetGroup -ErrorAction Stop

        Write-Log "Reference member count: $($ReferenceMembers.Count)"
        if ($null -ne $ResolvedSourceGroup) {
            Write-Log "Source group direct member count: $($SourceGroupMembers.Count)"
        }
        Write-Log "Target group existing member count: $($TargetGroupMembers.Count)"
    }
    catch {
        Write-Log "Failed to retrieve or resolve reference membership. Error: $($_.Exception.Message)" "ERROR"
        throw
    }

    # Use DistinguishedName as the matching key.
    $ReferenceMemberDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($member in $ReferenceMembers) {
        [void]$ReferenceMemberDNs.Add($member.DistinguishedName)
    }

    $TargetGroupMemberDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($member in $TargetGroupMembers) {
        [void]$TargetGroupMemberDNs.Add($member.DistinguishedName)
    }

    if ($null -ne $ResolvedSourceGroup) {
        $MembersToProcess = foreach ($member in $SourceGroupMembers) {
            if ($ReferenceMemberDNs.Contains($member.DistinguishedName)) {
                $member
            }
        }
    }
    else {
        $MembersToProcess = @($ReferenceMembers)
    }

    Write-Log "Members selected for processing: $($MembersToProcess.Count)"

    if (-not $MembersToProcess -or $MembersToProcess.Count -eq 0) {
        Write-Log "No matching members found. No changes required."
        return
    }

    foreach ($member in $MembersToProcess) {
        $memberLabel = "$($member.Name) <$($member.SamAccountName)> [$($member.objectClass)]"

        try {
            $alreadyInTargetGroup = $TargetGroupMemberDNs.Contains($member.DistinguishedName)
            $safeToRemove = $alreadyInTargetGroup

            if (-not $alreadyInTargetGroup) {
                if ($PSCmdlet.ShouldProcess($memberLabel, "Add to target group: $($ResolvedTargetGroup.Name)")) {
                    Add-ADGroupMember `
                        -Identity $ResolvedTargetGroup `
                        -Members $member `
                        -ErrorAction Stop

                    Write-Log "Added to target group: $memberLabel"
                    [void]$TargetGroupMemberDNs.Add($member.DistinguishedName)
                    $safeToRemove = $true
                }
                else {
                    Write-Log "Add to target group was not approved; retaining in source group: $memberLabel" "WARN"
                }
            }
            else {
                Write-Log "Already in target group, skipping add: $memberLabel"
            }

            # Remove from the source only when requested and after target membership is assured.
            if ($null -ne $ResolvedSourceGroup -and -not $RetainSourceMembers -and $safeToRemove -and $PSCmdlet.ShouldProcess($memberLabel, "Remove from source group: $($ResolvedSourceGroup.Name)")) {
                Remove-ADGroupMember `
                    -Identity $ResolvedSourceGroup `
                    -Members $member `
                    -Confirm:$false `
                    -ErrorAction Stop

                Write-Log "Removed from source group: $memberLabel"
            }
            elseif ($null -ne $ResolvedSourceGroup -and $RetainSourceMembers) {
                Write-Log "Retained in source group: $memberLabel"
            }
            elseif ($null -eq $ResolvedSourceGroup) {
                Write-Log "No source group membership to remove: $memberLabel"
            }
        }
        catch {
            Write-Log "Failed processing member $memberLabel. Error: $($_.Exception.Message)" "ERROR"
        }
    }
}

end {
    Write-Log "Completed AD group membership migration."
}
