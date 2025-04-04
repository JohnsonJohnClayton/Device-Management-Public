<#
.SYNOPSIS
    Remediates over-sized mailboxes
.DESCRIPTION
    Runs Milbox Archive for a defined-number (12) loops to reduce active mailbox size, and activates mailbox archive if it has not been already.
    Can be used to fix mailbox in-crisis
    For larger mailboxes, more loops may need to be done
.NOTES
    Written by John Johnson on 09/09/24
    Credit to Alyssa Phillips for core logic  
#>

param (
    #The ammount of times to run archival on the mailbox (default is 12)
    [int]
    $loops = 12,
    #Amount of time in seconds that archival will wait in-between passes (default is 300)
    [int]
    $sleep = 300,
    #UPN/email address of mailbox to run archival tool on
    [string]
    $account
)

# Set Default number of loops 
$timesToRun = $loops
# Default time to sleep in between loops
$sleepTime = $sleep

# install-module ExchangeOnlineManagement -force
try {
    # Connect to tenant in question with Exchange Admin perms
    Connect-ExchangeOnline -ShowProgress $true
    # Affected account
    $account = Read-Host "Enter the UPN of the mailbox to run archival tool"

    # Check if the archive is enabled
    $mailbox = Get-Mailbox -Identity $account

    # Enable the archive if it is not enabled
    if ($mailbox.ArchiveStatus -eq 'None') {
        Write-Host "`nArchive is not enabled for $account. Enabling archive..." -ForegroundColor Yellow
        Enable-Mailbox -Identity $account -Archive
        Write-Host "Archive enabled." -ForegroundColor Green
    } else {
        Write-Host "`nArchive is already enabled for $account." -ForegroundColor Green
    }

    # Get the size of the primary mailbox
    $oldPrimaryMailboxStats = Get-MailboxStatistics -Identity $account
    # Get the size of the archive mailbox, if it exists
    $oldArchiveMailboxStats = Get-MailboxStatistics -Archive -Identity $account

    # Output the sizes
    Write-Host "`nCurrent Primary Mailbox Size for $($oldPrimaryMailboxStats.DisplayName): " -NoNewline
    Write-Host "$($oldPrimaryMailboxStats.TotalItemSize)" -ForegroundColor Yellow
    if ($oldArchiveMailboxStats) {
        Write-Host "Archive Mailbox Size: " -NoNewline
        Write-Host "$($oldArchiveMailboxStats.TotalItemSize)" -ForegroundColor Yellow
    } else {
        Write-Host "Archive Mailbox not found or not available yet."
    }
} catch {
    Write-Warning "Unable to connect to Exchange Online. Is the module installed?"
    Write-Error $_
    exit 1
}

try {
    $i = 0
    Write-Host "`nStarting Archival Process on $account..." -ForegroundColor Green
    # Run mail archival for pre-defined number of loops
    do{
        # Loop variable used for logging
        $loop = $i+1

        # Create progress bar for archival
        Write-Progress -id 1 -PercentComplete (($i/$timesToRun)*100) -Activity "Running Archival Tool" -Status "Loop $loop out of $timesToRun"
        Write-Host "`nBeginning archive loop $loop..." -ForegroundColor Yellow
        try {
            start-managedfolderassistant $account
            Write-Output "Archival loop $loop completed"   
        }
        catch {
            # If a loop fails for some reason
            Write-Error "There was an error for the archival process of $account on loop $($i):"
            Write-Error $_
            Write-Warning "Exiting script..."
            #Exit with error code
            exit 0
        }
        $i++
        Write-Output "Allowing time for O365 to process..."

        # Wait for time in seconds defined in $sleepTime and display progress bar
        $doneTime = (Get-Date).AddSeconds($sleepTime)
        while($doneTime -gt (Get-Date)) {
        $secondsLeft = $doneTime.Subtract((Get-Date)).TotalSeconds
        $percent = ($sleepTime - $secondsLeft) / $sleepTime * 100
        Write-Progress -ParentId 1 -Activity "Allowing time for O365 to replicate & sync" -Status "Waiting for $sleepTime seconds..." -SecondsRemaining $secondsLeft -PercentComplete $percent
        [System.Threading.Thread]::Sleep(500)
        }
        Write-Progress -Activity "Allowing time for O365 to replicate & sync" -Status "Waiting for $($sleepTime/60) minutes..." -SecondsRemaining 0 -Completed
        } while($i -lt $timesToRun)

        Write-Progress -id 1 -PercentComplete ($i/$timesToRun) -Activity "Running Archival Tool" -Status "Loop $loop out of $timesToRun" -Completed
        Write-Host "`nSuccessfully archived account $account for $loop loops" -ForegroundColor Green

        # Get the updated size of the primary and archive mailboxes
        $newPrimaryMailboxStats = Get-MailboxStatistics -Identity $account
        $newArchiveMailboxStats = Get-MailboxStatistics -Archive -Identity $account
        # Output the sizes
        if ($newArchiveMailboxStats) {
            Write-Host "Post-Archive Size Comparison for $($account):"
            Write-Host "Pre-Archive : " -NoNewline
                Write-Host "$($oldPrimaryMailboxStats.TotalItemSize) " -NoNewline -ForegroundColor Yellow
                Write-Host "| Archive: " -NoNewline
                Write-Host "$($oldArchiveMailboxStats.TotalItemSize)"  -ForegroundColor Yellow
            Write-Host "Post-Archive : " -NoNewline
                Write-Host "$($newPrimaryMailboxStats.TotalItemSize) " -NoNewline -ForegroundColor Yellow
                Write-Host "| Archive: " -NoNewline
                Write-Host "$($newArchiveMailboxStats.TotalItemSize)"  -ForegroundColor Yellow
        } else {
            Write-Host "Pre-Archive : " -NoNewline
                Write-Host "$($oldPrimaryMailboxStats.TotalItemSize) " -ForegroundColor Yellow
            Write-Host "Post-Archive : " -NoNewline
                Write-Host "$($newPrimaryMailboxStats.TotalItemSize) " -ForegroundColor Yellow
        }
        Write-Host ""
} catch {
    Write-Error "There was a fatal error:"
    Write-Error $_
}