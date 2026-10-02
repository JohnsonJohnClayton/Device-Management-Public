# Create an Outlook Application COM Object
$outlook = New-Object -ComObject Outlook.Application

# Get the namespace for the Outlook session
$namespace = $outlook.GetNamespace("MAPI")

# Get the default calendar folder (You can use the current user here)
$sharedMailbox = "shared@example.com"

# Add the shared mailbox to the calendar view
$calendarFolder = $namespace.CreateRecipient($sharedMailbox)
$calendarFolder.Resolve()

if ($calendarFolder.Resolved) {
    $namespace.GetSharedDefaultFolder($calendarFolder, [Microsoft.Office.Interop.Outlook.OlDefaultFolders]::olFolderCalendar).Display()
    Write-Host "Shared Calendar added successfully."
} else {
    Write-Host "Failed to add shared calendar. Check if the mailbox exists and if you have permissions."
}
