<#
.SYNOPSIS
    Retrieves all running scheduled tasks, asks for user confirmation before disabling them, and reboots the system at the end.

.DESCRIPTION
    This script retrieves all scheduled tasks on the system using the Get-ScheduledTask cmdlet.
    It checks each task's status using Get-ScheduledTaskInfo to determine if the task is running.
    For each running task, the script will ask the user whether they want to disable the task.
    Once the tasks are processed, the script will ask for confirmation before rebooting the system.

.NOTES
    Author: John Johnson
    Date: 09/23/2024
    Requires: PowerShell 4.0 or later
    Running this script requires administrative privileges.

    This script disables running tasks but does not stop the currently running instances.
    To stop running tasks, you can use Stop-ScheduledTask separately.
    Rebooting the system at the end is optional based on user confirmation.

#>

# Get all scheduled tasks
$allTasks = Get-ScheduledTask

# Track if there are any running tasks
$runningTasksFound = $false

foreach ($task in $allTasks) {
    # Get the task's status using Get-ScheduledTaskInfo
    $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath
    
    # Check if the task is currently running
    if ($taskInfo.State -eq 'Running') {
        $runningTasksFound = $true
        Write-Host "`nTask: $($task.TaskName)" -ForegroundColor Cyan
        Write-Host "State: $($taskInfo.State)" -ForegroundColor Cyan
        Write-Host "Path: $($task.TaskPath)" -ForegroundColor Cyan
        
        # Prompt user for confirmation to disable the task
        $confirmation = Read-Host "Do you want to disable this task? (Y/N or A to abort script)"
        
        switch ($confirmation.ToUpper()) {
            "Y" {
                Write-Host "Disabling task: $($task.TaskName)" -ForegroundColor Yellow
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            }
            "N" {
                Write-Host "Skipping task: $($task.TaskName)" -ForegroundColor Green
                continue
            }
            "A" {
                Write-Host "Aborting the operation." -ForegroundColor Red
                break
            }
            default {
                Write-Host "Invalid input. Skipping task: $($task.TaskName)" -ForegroundColor Green
                continue
            }
        }
    }
}

if (-not $runningTasksFound) {
    Write-Host "No running tasks found." -ForegroundColor Green
}

# Ask for confirmation to reboot the system
$rebootConfirmation = Read-Host "`nDo you want to reboot the system now? (Y/N)"

if ($rebootConfirmation.ToUpper() -eq 'Y') {
    Write-Host "Rebooting the system..." -ForegroundColor Yellow
    Restart-Computer -Confirm
} else {
    Write-Host "System reboot skipped." -ForegroundColor Green
}
