<#
.SYNOPSIS
    Audits a user's local Documents folder for file/folder paths that may fail OneDrive Known Folder Move/sync.

.DESCRIPTION
    This script scans the local Documents folder and calculates the projected path length after
    the content is moved/synced under:
        C:\Users\<User>\OneDrive - <Company Name>\Documents

    It reports:
      - Projected paths over or near 260 characters
      - Cloud-relative paths over 400 characters
      - Individual file/folder names over 255 characters
      - Invalid OneDrive characters/names
      - Leading/trailing spaces
      - Top offending parent folders

.NOTES
    This script is audit-only. It does not rename, move, or delete anything.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = [Environment]::GetFolderPath('MyDocuments'),

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OneDriveRoot,

    [ValidateNotNullOrEmpty()]
    [string]$TargetFolderName = 'Documents',

    [ValidateRange(1, [int]::MaxValue)]
    [int]$WarnAtLength = 240,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$CriticalLength = 260,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$CloudPathLimit = 400,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$OneDriveSyncPathLimit = 520,

    [string]$OutputFolder
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-SafeRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$FullPath,

        [Parameter(Mandatory)]
        [string]$RootPath
    )

    $trimCharacters = [char[]]@('\', '/')
    $normalizedRoot = [IO.Path]::GetFullPath($RootPath).TrimEnd($trimCharacters)
    $normalizedFull = [IO.Path]::GetFullPath($FullPath)

    if ($normalizedFull.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return ''
    }

    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$FullPath' is not under root '$RootPath'."
    }

    return $normalizedFull.Substring($rootPrefix.Length)
}

function Test-OneDriveInvalidName {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$RelativePath
    )

    $issues = New-Object System.Collections.Generic.List[string]

    # Characters not allowed in OneDrive/SharePoint names.
    # Windows normally prevents most of these locally, but this still catches edge cases.
    $invalidCharsPattern = '["*:<>?/\\|]'
    if ($Name -match $invalidCharsPattern) {
        $issues.Add('InvalidOneDriveCharacter')
    }

    if ($Name -ne $Name.Trim()) {
        $issues.Add('LeadingOrTrailingSpace')
    }

    if ($Name.EndsWith('.')) {
        $issues.Add('TrailingPeriod')
    }

    $reservedNames = @(
        '.lock',
        'CON',
        'PRN',
        'AUX',
        'NUL',
        'COM0',
        'COM1',
        'COM2',
        'COM3',
        'COM4',
        'COM5',
        'COM6',
        'COM7',
        'COM8',
        'COM9',
        'LPT0',
        'LPT1',
        'LPT2',
        'LPT3',
        'LPT4',
        'LPT5',
        'LPT6',
        'LPT7',
        'LPT8',
        'LPT9',
        'desktop.ini'
    )

    $deviceName = ($Name -split '\.', 2)[0]
    if (($reservedNames -contains $Name) -or ($reservedNames -contains $deviceName)) {
        $issues.Add('ReservedOneDriveName')
    }

    if ($Name -like '~$*') {
        $issues.Add('OfficeTempLockFileName')
    }

    if ($Name -like '*_vti_*') {
        $issues.Add('Contains_vti')
    }

    # "forms" is invalid at the root level of a library.
    # For KFM, Documents is effectively the library-root folder path being projected.
    if ($Name -ieq 'forms' -and ($RelativePath -notmatch '\\')) {
        $issues.Add('FormsAtLibraryRoot')
    }

    return $issues
}

function Get-TopParentFolder {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return ''
    }

    $parts = $RelativePath -split '\\'
    if ($parts.Count -gt 1) {
        return $parts[0]
    }

    return '[Root of Documents]'
}


function Export-CsvReport {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Columns,

        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if ($InputObject.Count -gt 0) {
        $InputObject | Select-Object -Property $Columns |
            Export-Csv -LiteralPath $LiteralPath -NoTypeInformation -Encoding UTF8
        return
    }

    # Export-Csv creates no file for an empty pipeline, so explicitly create a
    # header-only report. This keeps every path listed in the summary usable.
    $emptyRow = [ordered]@{}
    foreach ($column in $Columns) {
        $emptyRow[$column] = $null
    }

    $header = ([pscustomobject]$emptyRow | ConvertTo-Csv -NoTypeInformation)[0]
    Set-Content -LiteralPath $LiteralPath -Value $header -Encoding UTF8
}

# Validate paths.
if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "SourcePath does not exist: $SourcePath"
}

$sourceItem = Get-Item -LiteralPath $SourcePath -Force
if (-not $sourceItem.PSIsContainer) {
    throw "SourcePath must be a folder: $SourcePath"
}

if ($WarnAtLength -ge $CriticalLength) {
    throw 'WarnAtLength must be less than CriticalLength.'
}

$resolvedSourcePath = $sourceItem.FullName.TrimEnd([char[]]@('\', '/'))
$targetDocumentsRoot = Join-Path $OneDriveRoot $TargetFolderName

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopPath)) {
        $desktopPath = $env:USERPROFILE
    }
    $OutputFolder = Join-Path $desktopPath "OneDrive-Documents-Audit-$timestamp"
}

New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null

$reportPath = Join-Path $OutputFolder 'OneDrive-Documents-Path-Audit.csv'
$summaryPath = Join-Path $OutputFolder 'OneDrive-Documents-Path-Audit-Summary.txt'
$errorPath = Join-Path $OutputFolder 'OneDrive-Documents-Path-Audit-EnumerationErrors.csv'
$topFoldersPath = Join-Path $OutputFolder 'OneDrive-Documents-Top-Offending-Folders.csv'

$results = New-Object System.Collections.Generic.List[object]
$enumerationErrors = New-Object System.Collections.Generic.List[object]

Write-Host "Scanning source path:" -ForegroundColor Cyan
Write-Host "  $resolvedSourcePath"
Write-Host ""
Write-Host "Projected OneDrive Documents root:" -ForegroundColor Cyan
Write-Host "  $targetDocumentsRoot"
Write-Host ""

# Use stack-based enumeration so inaccessible folders do not stop the full scan.
$foldersToScan = New-Object System.Collections.Generic.Stack[string]
$foldersToScan.Push($resolvedSourcePath)

$totalItemsScanned = 0

while ($foldersToScan.Count -gt 0) {
    $currentFolder = $foldersToScan.Pop()

    try {
        $children = Get-ChildItem -LiteralPath $currentFolder -Force -ErrorAction Stop
    }
    catch {
        $enumerationErrors.Add([pscustomobject]@{
            Path  = $currentFolder
            Error = $_.Exception.Message
        })
        continue
    }

    foreach ($item in $children) {
        $totalItemsScanned++

        $isReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($item.PSIsContainer -and -not $isReparsePoint) {
            $foldersToScan.Push($item.FullName)
        }

        $itemType = if ($item.PSIsContainer) { 'Folder' } else { 'File' }
        $relativePath = Get-SafeRelativePath -FullPath $item.FullName -RootPath $resolvedSourcePath
        $projectedPath = Join-Path $targetDocumentsRoot $relativePath

        # Cloud-relative approximation starts at Documents.
        # Example: Documents\Folder\File.docx
        $cloudRelativePath = Join-Path $TargetFolderName $relativePath

        $issueList = New-Object System.Collections.Generic.List[string]

        if ($isReparsePoint) {
            # Avoid following junctions/symbolic links outside the audit root or
            # entering a cycle. The item itself remains visible in the report.
            $issueList.Add('ReparsePointNotTraversed')
        }

        if ($projectedPath.Length -ge $CriticalLength) {
            $issueList.Add("ProjectedLocalPathOver$CriticalLength")
        }
        elseif ($projectedPath.Length -ge $WarnAtLength) {
            $issueList.Add("ProjectedLocalPathNear$CriticalLength")
        }

        if ($cloudRelativePath.Length -gt $CloudPathLimit) {
            $issueList.Add("CloudRelativePathOver$CloudPathLimit")
        }

        if ($projectedPath.Length -gt $OneDriveSyncPathLimit) {
            $issueList.Add("OneDriveSyncPathOver$OneDriveSyncPathLimit")
        }

        if ($item.Name.Length -gt 255) {
            $issueList.Add('NameOver255Characters')
        }

        $nameIssues = Test-OneDriveInvalidName -Name $item.Name -RelativePath $relativePath
        foreach ($nameIssue in $nameIssues) {
            $issueList.Add($nameIssue)
        }

        if ($issueList.Count -gt 0) {
            $results.Add([pscustomobject]@{
                ItemType                = $itemType
                Name                    = $item.Name
                NameLength              = $item.Name.Length
                CurrentFullPathLength   = $item.FullName.Length
                ProjectedFullPathLength = $projectedPath.Length
                CloudRelativePathLength = $cloudRelativePath.Length
                TopParentFolder         = Get-TopParentFolder -RelativePath $relativePath
                IssueTypes              = ($issueList -join '; ')
                CurrentFullPath         = $item.FullName
                ProjectedOneDrivePath   = $projectedPath
                CloudRelativePath       = $cloudRelativePath
            })
        }
    }
}

# Export detailed results.
$resultColumns = @(
    'ItemType', 'Name', 'NameLength', 'CurrentFullPathLength',
    'ProjectedFullPathLength', 'CloudRelativePathLength', 'TopParentFolder',
    'IssueTypes', 'CurrentFullPath', 'ProjectedOneDrivePath', 'CloudRelativePath'
)
$sortedResults = @(
    $results | Sort-Object -Property @(
        @{ Expression = 'ProjectedFullPathLength'; Descending = $true },
        @{ Expression = 'CloudRelativePathLength'; Descending = $true }
    )
)
Export-CsvReport -InputObject $sortedResults -Columns $resultColumns -LiteralPath $reportPath

# Export enumeration errors, if any.
Export-CsvReport -InputObject $enumerationErrors.ToArray() -Columns @('Path', 'Error') -LiteralPath $errorPath

# Top offending folder rollup.
$topFolders =
    $results |
    Group-Object TopParentFolder |
    Sort-Object Count -Descending |
    Select-Object @{
        Name = 'TopParentFolder'
        Expression = { $_.Name }
    }, @{
        Name = 'ProblemItemCount'
        Expression = { $_.Count }
    }, @{
        Name = 'LongestProjectedPath'
        Expression = {
            ($_.Group | Measure-Object -Property ProjectedFullPathLength -Maximum).Maximum
        }
    }, @{
        Name = 'LongestCloudRelativePath'
        Expression = {
            ($_.Group | Measure-Object -Property CloudRelativePathLength -Maximum).Maximum
        }
    }

$topFolderColumns = @('TopParentFolder', 'ProblemItemCount', 'LongestProjectedPath', 'LongestCloudRelativePath')
Export-CsvReport -InputObject @($topFolders) -Columns $topFolderColumns -LiteralPath $topFoldersPath

# Summary counts.
$totalProblemItems = $results.Count
$over260Count = @($results | Where-Object { $_.ProjectedFullPathLength -ge $CriticalLength }).Count
$near260Count = @($results | Where-Object { $_.ProjectedFullPathLength -ge $WarnAtLength -and $_.ProjectedFullPathLength -lt $CriticalLength }).Count
$cloudOver400Count = @($results | Where-Object { $_.CloudRelativePathLength -gt $CloudPathLimit }).Count
$nameOver255Count = @($results | Where-Object { $_.NameLength -gt 255 }).Count
$invalidNameCount = @($results | Where-Object { $_.IssueTypes -match 'Invalid|Reserved|LeadingOrTrailingSpace|TrailingPeriod|Contains_vti|FormsAtLibraryRoot|OfficeTempLockFileName' }).Count

$summary = @"
OneDrive Documents Path Audit Summary
Generated: $(Get-Date)

Source Documents Path:
$resolvedSourcePath

Projected OneDrive Documents Root:
$targetDocumentsRoot

Total items scanned:
$totalItemsScanned

Total problematic items found:
$totalProblemItems

Projected local paths over or equal to $CriticalLength characters:
$over260Count

Projected local paths between $WarnAtLength and $($CriticalLength - 1) characters:
$near260Count

Cloud-relative paths over $CloudPathLimit characters:
$cloudOver400Count

Individual names over 255 characters:
$nameOver255Count

Invalid/reserved OneDrive name issues:
$invalidNameCount

Enumeration errors:
$($enumerationErrors.Count)

Reports created:
$reportPath
$topFoldersPath
$errorPath

Recommended next steps:
1. Open OneDrive-Documents-Top-Offending-Folders.csv first.
2. Identify the top-level folders causing the most long-path issues.
3. Shorten folder names or flatten the folder structure locally before enabling/syncing Documents.
4. Re-run this audit until the over-$CriticalLength count is 0 or acceptably low.
5. Avoid auto-renaming unless the user approves the naming changes.
"@

$summary | Out-File -LiteralPath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "Audit complete." -ForegroundColor Green
Write-Host ""
Write-Host "Summary:"
Write-Host "  Total scanned: $totalItemsScanned"
Write-Host "  Problem items: $totalProblemItems"
Write-Host "  Paths >= $CriticalLength chars: $over260Count"
Write-Host "  Paths $WarnAtLength-$($CriticalLength - 1) chars: $near260Count"
Write-Host "  Cloud-relative paths > $CloudPathLimit chars: $cloudOver400Count"
Write-Host "  Invalid/reserved name issues: $invalidNameCount"
Write-Host ""
Write-Host "Output folder:" -ForegroundColor Cyan
Write-Host "  $OutputFolder"
