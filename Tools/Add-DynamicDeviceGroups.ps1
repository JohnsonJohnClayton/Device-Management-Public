#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$GroupPrefix
)

$ErrorActionPreference = "Stop"

# Connect if there is no current Graph session.
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "Group.ReadWrite.All" -NoWelcome
}

# Add the optional prefix and a trailing space.
# Example: -GroupPrefix "Intune" produces "Intune - All Windows Devices"
if ($GroupPrefix) {
    $NamePrefix = "$($GroupPrefix.Trim()) - "
}
else {
    $NamePrefix = ""
}

# Dynamic group definitions
$Groups = @(
    # All operating systems, separated by ownership
    @{
        Name = "All Corporate Devices"
        Rule = '(device.deviceOwnership -eq "Company")'
    }
    @{
        Name = "All Personal Devices"
        Rule = '(device.deviceOwnership -eq "Personal")'
    }

    # Windows
    @{
        Name = "All Windows Devices"
        Rule = '(device.deviceOSType -eq "Windows")'
    }
    @{
        Name = "All Corporate Windows Devices"
        Rule = '(device.deviceOSType -eq "Windows") -and (device.deviceOwnership -eq "Company")'
    }
    @{
        Name = "All Personal Windows Devices"
        Rule = '(device.deviceOSType -eq "Windows") -and (device.deviceOwnership -eq "Personal")'
    }

    # macOS
    @{
        Name = "All macOS Devices"
        Rule = '(device.deviceOSType -eq "MacMDM")'
    }
    @{
        Name = "All Corporate macOS Devices"
        Rule = '(device.deviceOSType -eq "MacMDM") -and (device.deviceOwnership -eq "Company")'
    }
    @{
        Name = "All Personal macOS Devices"
        Rule = '(device.deviceOSType -eq "MacMDM") -and (device.deviceOwnership -eq "Personal")'
    }

    # Android
    @{
        Name = "All Android Devices"
        Rule = '(device.deviceOSType -startsWith "Android")'
    }
    @{
        Name = "All Corporate Android Devices"
        Rule = '(device.deviceOSType -startsWith "Android") -and (device.deviceOwnership -eq "Company")'
    }
    @{
        Name = "All Personal Android Devices"
        Rule = '(device.deviceOSType -startsWith "Android") -and (device.deviceOwnership -eq "Personal")'
    }

    # iOS and iPadOS
    @{
        Name = "All iOS Devices"
        Rule = '((device.deviceOSType -eq "iPhone") -or (device.deviceOSType -eq "iPad"))'
    }
    @{
        Name = "All Corporate iOS Devices"
        Rule = '((device.deviceOSType -eq "iPhone") -or (device.deviceOSType -eq "iPad")) -and (device.deviceOwnership -eq "Company")'
    }
    @{
        Name = "All Personal iOS Devices"
        Rule = '((device.deviceOSType -eq "iPhone") -or (device.deviceOSType -eq "iPad")) -and (device.deviceOwnership -eq "Personal")'
    }
)

# Retrieve existing groups once
$ExistingGroups = Get-MgGroup -All -Property Id, DisplayName

foreach ($Group in $Groups) {
    $DisplayName = "$NamePrefix$($Group.Name)"

    $ExistingGroup = $ExistingGroups |
        Where-Object DisplayName -eq $DisplayName |
        Select-Object -First 1

    if ($ExistingGroup) {
        Write-Host "Already exists: $DisplayName" -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess($DisplayName, "Create dynamic device group")) {
        $MailNickname = (
            $DisplayName -replace '[^A-Za-z0-9]', ''
        ) + (Get-Random -Minimum 1000 -Maximum 9999)

        $NewGroupParameters = @{
            DisplayName                   = $DisplayName
            Description                   = "Dynamic device group: $($Group.Name)"
            MailEnabled                   = $false
            MailNickname                  = $MailNickname
            SecurityEnabled               = $true
            GroupTypes                    = @("DynamicMembership")
            MembershipRule                = $Group.Rule
            MembershipRuleProcessingState = "On"
        }

        $NewGroup = New-MgGroup @NewGroupParameters

        Write-Host "Created: $DisplayName" -ForegroundColor Green
        Write-Host "Rule:    $($Group.Rule)" -ForegroundColor DarkGray
    }
}