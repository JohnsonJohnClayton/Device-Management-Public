# PDQ Connect – Outlook Classic & OneDrive Full Reset (No New Outlook Touch)
# SYSTEM context; no parameters; review and test before deployment
# Version: 2025-07-17

Write-Output "Starting classic Outlook and OneDrive profile reset..."

# Ensure Registry HKU drive
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
}

# 1. Stop Outlook/OneDrive processes
'outlook','OneDrive' | ForEach-Object {
    Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

# 2. Get all domain user SIDs (non-system)
$profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$userSids = Get-ChildItem $profileList |
    Where-Object { $_.PSChildName -like 'S-1-5-21-*' } |
    Select-Object -ExpandProperty PSChildName

foreach ($sid in $userSids) {
    try {
        $regProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $profilePath = (Get-ItemProperty -Path $regProfile -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath -or -not (Test-Path $profilePath)) { continue }
        $hkuPath = "HKU:\$sid"
        if (-not (Test-Path $hkuPath -ErrorAction SilentlyContinue)) { continue }

        Write-Output "`nProcessing SID: $sid"
        $localApp = Join-Path $profilePath 'AppData\Local'
        $outlookLocal = Join-Path $localApp 'Microsoft\Outlook'

        # 3. Archive classic Outlook OST/PST files
        if (Test-Path $outlookLocal) {
            $ts = (Get-Date).ToString('yyyy-MMdd_HHmmss')
            $archive = Join-Path $outlookLocal "Pre-Migration Mail Files\$ts"
            New-Item -Path $archive -ItemType Directory -Force | Out-Null
            Get-ChildItem -Path $outlookLocal -Include '*.ost','*.pst' -File -ErrorAction SilentlyContinue |
                Move-Item -Destination $archive -Force -ErrorAction SilentlyContinue
            Write-Output "  Archived mail to: $archive"
        }

        # 4. Remove Outlook Classic registry profiles/policies
        @('16.0','15.0','14.0','12.0','11.0') | ForEach-Object {
            $base = "$hkuPath\Software\Microsoft\Office\$_\Outlook"
            Remove-Item -Path "$base\Profiles" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $base -Name 'DefaultProfile' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path "$base\Setup" -Name 'First-Run','ImportPST' -ErrorAction SilentlyContinue
        }
        Remove-Item -Path "$hkuPath\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles" -Recurse -Force -ErrorAction SilentlyContinue

        # 5. Remove policy-pushed 'DefaultProfile' entries (if present)
        $policyOffice = "$hkuPath\Software\Policies\Microsoft\Office"
        if (Test-Path $policyOffice) {
            Get-ChildItem -Path $policyOffice -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*Outlook*' } |
                ForEach-Object {
                    Remove-ItemProperty -Path $_.PSPath -Name 'DefaultProfile' -ErrorAction SilentlyContinue
                }
        }
        @('16.0','15.0','14.0','12.0','11.0') | ForEach-Object {
            $prefs = "$hkuPath\Software\Microsoft\Office\$_\Outlook\Preferences"
            Remove-ItemProperty -Path $prefs -Name 'DefaultProfile' -ErrorAction SilentlyContinue
        }

        # 6. Ensure Outlook key exists so profile wizard triggers
        $mainOutlook = "$hkuPath\Software\Microsoft\Office\16.0\Outlook"
        if (-not (Test-Path $mainOutlook)) {
            New-Item -Path $mainOutlook -Force | Out-Null
        }

        # 7. OneDrive registry cleanup
        $odKeys = @(
            "$hkuPath\Software\Microsoft\OneDrive",
            "$hkuPath\Software\Microsoft\IdentityCRL"
        )
        foreach ($key in $odKeys) {
            if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # Remove OneDrive PreSignIn config if present
        $preSign = Join-Path $localApp 'Microsoft\OneDrive\settings\PreSignInSettingsConfig.json'
        if (Test-Path $preSign) { Remove-Item $preSign -Force -ErrorAction SilentlyContinue }

        # 8. Optionally, reset OneDrive client if present
        $odExe = Join-Path $localApp 'Microsoft\OneDrive\OneDrive.exe'
        if (Test-Path $odExe) {
            try {
                Start-Process -FilePath $odExe -ArgumentList '/reset' -WindowStyle Hidden
            } catch {
                Write-Output "  OneDrive reset failed for $sid"
            }
        }

        Write-Output "  Profile reset completed for SID: $sid"
    }
    catch {
        Write-Output "  ERROR processing SID $($sid): $($_.Exception.Message)"
    }
}

# Log completion event
$src = 'OutlookCompleteResetScript'
if (-not (Get-EventLog -LogName Application -Source $src -ErrorAction SilentlyContinue)) {
    New-EventLog -LogName Application -Source $src -ErrorAction SilentlyContinue
}
Write-EventLog -LogName Application -Source $src -EntryType Information -EventId 3000 `
    -Message "Classic Outlook and OneDrive profile reset completed." -ErrorAction SilentlyContinue

Write-Output "`nAll operations complete for Outlook Classic and OneDrive (New Outlook untouched)."
