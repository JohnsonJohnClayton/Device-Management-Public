[CmdletBinding()]
param (
    [string]$GroupEmailAddresses,

    [string]$InputFile,

    [int]$WaitTimeoutMinutes = 30,

    [switch]$WhatIfOnly,

    [string]$LogRootPath = (Join-Path (Get-Location) 'MigrationLogs')
)

# ==========================================================
# INPUT NORMALIZATION
# ==========================================================
$ResolvedGroups = @()

if ($GroupEmailAddresses) {
    $ResolvedGroups += $GroupEmailAddresses -split ',' | ForEach-Object { $_.Trim() }
}

if ($InputFile) {
    if (-not (Test-Path $InputFile)) {
        throw "Input file not found"
    }

    if ($InputFile -like "*.csv") {
        $ResolvedGroups += Import-Csv $InputFile | Select-Object -ExpandProperty EmailAddress
    }
    else {
        $ResolvedGroups += Get-Content $InputFile
    }
}

$ResolvedGroups = $ResolvedGroups | Where-Object { $_ } | Sort-Object -Unique

if (-not $ResolvedGroups.Count) {
    throw "No valid group email addresses provided"
}

# ==========================================================
# GLOBAL MIGRATION SCOPE
# ==========================================================
$MigrationScope = New-Object System.Collections.Generic.List[string]
$ResolvedGroups | ForEach-Object { $MigrationScope.Add($_) }

# ==========================================================
# LOGGING INIT
# ==========================================================
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rootLogDir = Join-Path $LogRootPath $timestamp

New-Item -ItemType Directory -Path $rootLogDir -Force | Out-Null

$logFile = Join-Path $rootLogDir "Migration.log"
New-Item -ItemType File -Path $logFile -Force | Out-Null

function Write-Log {
    param($msg, $level='INFO')
    $line="[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $msg"
    Add-Content $logFile $line
    Write-Host $line
}

function Invoke-IfNotWhatIf {
    param([scriptblock]$s)
    if ($WhatIfOnly) {
        Write-Log $s.ToString() 'WHATIF'
    }
    else {
        Write-Log "Executing: $($s.ToString())"
        & $s
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "🔎 Logging to:" -ForegroundColor Cyan
Write-Host " $logFile" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "Starting bulk migration"
Write-Log "Group count: $($ResolvedGroups.Count)"
Write-Log "WhatIf mode: $WhatIfOnly"

# ==========================================================
# PROCESS EACH GROUP
# ==========================================================
foreach ($GroupEmailAddress in $ResolvedGroups) {

    Write-Log "---- Processing: $GroupEmailAddress ----"

    try {
        $safe = $GroupEmailAddress.Replace('@','_').Replace('.','_')
        $groupDir = Join-Path $rootLogDir $safe
        New-Item -ItemType Directory -Path $groupDir -Force | Out-Null

        # ----------------------------
        # STEP 1: GET GROUP
        # ----------------------------
        $group = Get-DistributionGroup -Identity $GroupEmailAddress -ErrorAction Stop

        $group | Export-Clixml "$groupDir\Group.xml"

        $members = Get-DistributionGroupMember $GroupEmailAddress
        $members | Select PrimarySmtpAddress |
            Export-Csv "$groupDir\Members.csv" -NoTypeInformation

        Get-RecipientPermission $GroupEmailAddress |
            Export-Clixml "$groupDir\SendAs.xml"

        # Mailbox permissions (if security group)
        if ($group.RecipientTypeDetails -like "*SecurityGroup*") {
            Get-Mailbox -ResultSize Unlimited |
                ForEach-Object {
                    Get-MailboxPermission $_.Identity |
                    Where-Object { $_.User -eq $GroupEmailAddress }
                } |
                Export-Clixml "$groupDir\MailPerms.xml"
        }

        # ----------------------------
        # STEP 2: NESTED GROUP CHECK
        # ----------------------------
        foreach ($m in $members) {
            if ($m.RecipientType -match "Group") {
                $nested = $m.PrimarySmtpAddress

                if (-not $MigrationScope.Contains($nested)) {
                    Write-Host "`n⚠ Nested group detected: $nested" -ForegroundColor Yellow
                    $resp = Read-Host "Add to migration scope? (Y/N)"

                    if ($resp -match '^y') {
                        $MigrationScope.Add($nested)
                        Write-Log "Added nested group: $nested"
                    }
                    else {
                        Write-Log "Skipped nested group: $nested" "WARN"
                    }
                }
            }
        }

        # ----------------------------
        # STEP 3: WAIT FOR DESYNC
        # ----------------------------
        $timeout = (Get-Date).AddMinutes($WaitTimeoutMinutes)

        do {
            Start-Sleep 30
            try {
                Get-DistributionGroup -Identity $GroupEmailAddress -ErrorAction Stop
                $exists = $true
            }
            catch { $exists = $false }

        } while ($exists -and (Get-Date -lt $timeout))

        if ($exists) {
            throw "Timeout waiting for de-sync"
        }

        # ----------------------------
        # STEP 4: RECREATE
        # ----------------------------
        $props = Import-Clixml "$groupDir\Group.xml"

        Invoke-IfNotWhatIf {
            New-DistributionGroup `
                -Name $props.Name `
                -DisplayName $props.DisplayName `
                -Alias $props.Alias `
                -PrimarySmtpAddress $props.PrimarySmtpAddress
        }

        # Restore props
        Invoke-IfNotWhatIf {
            Set-DistributionGroup $props.PrimarySmtpAddress `
                -HiddenFromAddressListsEnabled $props.HiddenFromAddressListsEnabled `
                -RequireSenderAuthenticationEnabled $props.RequireSenderAuthenticationEnabled `
                -ModerationEnabled $props.ModerationEnabled `
                -ModeratedBy $props.ModeratedBy `
                -BypassSecurityGroupManagerCheck
        }

        # Restore members
        Import-Csv "$groupDir\Members.csv" | ForEach-Object {
            Invoke-IfNotWhatIf {
                Add-DistributionGroupMember `
                    -Identity $props.PrimarySmtpAddress `
                    -Member $_.PrimarySmtpAddress
            }
        }

        # Restore permissions
        $sendAs = Import-Clixml "$groupDir\SendAs.xml"
        foreach ($p in $sendAs) {
            Invoke-IfNotWhatIf {
                Add-RecipientPermission `
                    -Identity $p.Identity `
                    -Trustee $props.PrimarySmtpAddress `
                    -AccessRights SendAs `
                    -Confirm:$false
            }
        }

        # Restore X500
        $x500 = $props.EmailAddresses | Where-Object { $_ -like "X500:*" }
        if ($x500) {
            Invoke-IfNotWhatIf {
                Set-DistributionGroup $props.PrimarySmtpAddress `
                    -EmailAddresses @{Add=$x500}
            }
        }

        Write-Log "Completed: $GroupEmailAddress"
    }
    catch {
        Write-Log "FAILED: $GroupEmailAddress - $($_.Exception.Message)" "ERROR"
        continue
    }
}

# ==========================================================
# FINAL OUTPUT
# ==========================================================
Write-Log "Bulk processing complete"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "✅ ALL OPERATIONS COMPLETE" -ForegroundColor Green
Write-Host "📄 Log file:" -ForegroundColor Green
Write-Host " $logFile" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""