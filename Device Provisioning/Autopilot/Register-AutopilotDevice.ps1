#requires -version 5.1

<#
.SYNOPSIS
    Registers a Windows device with Windows Autopilot during OOBE.
#>

$GroupTag = "USB Reg"
$AssignedComputerName = ""
$WaitForAssignment = $true
$RebootAfterRegistration = $true

$LogRoot = "C:\ProgramData\AutopilotRegistration"
$LogFile = Join-Path $LogRoot "Register-AutopilotDevice.log"

New-Item -Path $LogRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $Line
    Add-Content -LiteralPath $LogFile -Value $Line
}

function Stop-WithError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$ExitCode = 1
    )

    Write-Log -Message $Message -Level ERROR
    exit $ExitCode
}

function Wait-RebootCountdown {
    param([ValidateRange(1, 3600)][int]$Seconds = 30)

    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $LastDisplayedSecond = -1

    while ($Stopwatch.Elapsed.TotalSeconds -lt $Seconds) {
        $RemainingSeconds = [Math]::Ceiling($Seconds - $Stopwatch.Elapsed.TotalSeconds)

        if ($RemainingSeconds -ne $LastDisplayedSecond) {
            Write-Host -NoNewline "`rRebooting in $RemainingSeconds second(s). Press Enter to reboot now... "
            $LastDisplayedSecond = $RemainingSeconds
        }

        try {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                return $true
            }
        }
        catch {
            # Input can be unavailable when the script is not running in an interactive console.
        }

        Start-Sleep -Milliseconds 100
    }

    Write-Host ""
    return $false
}

Write-Log "Starting Windows Autopilot registration."

try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as administrator. At OOBE, launch it from Shift+F10."
    }
}
catch {
    Stop-WithError "Elevation check failed: $($_.Exception.Message)" 10
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $GalleryResponse = Invoke-WebRequest `
        -Uri "https://www.powershellgallery.com/api/v2/" `
        -UseBasicParsing `
        -TimeoutSec 15 `
        -ErrorAction Stop

    if ($GalleryResponse.StatusCode -lt 200 -or $GalleryResponse.StatusCode -ge 400) {
        throw "PowerShell Gallery returned HTTP $($GalleryResponse.StatusCode)."
    }
}
catch {
    Stop-WithError "No valid connection to PowerShell Gallery: $($_.Exception.Message)" 20
}

# Bootstrap NuGet before Install-Script. These settings suppress both PowerShell
# confirmation prompts and the PackageManagement provider bootstrap prompt.
try {
    $ConfirmPreference = "None"
    $NuGetProvider = Install-PackageProvider `
        -Name NuGet `
        -MinimumVersion 2.8.5.201 `
        -Scope AllUsers `
        -ForceBootstrap `
        -Force `
        -Confirm:$false `
        -ErrorAction Stop

    Import-PackageProvider `
        -Name $NuGetProvider.Name `
        -Force `
        -ErrorAction Stop | Out-Null
}
catch {
    Stop-WithError "NuGet installation failed: $($_.Exception.Message)" 30
}

try {
    $Repository = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue

    if (-not $Repository) {
        Register-PSRepository -Default -ErrorAction Stop
    }

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop

    $AutopilotCommand = Get-Command Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue

    if (-not $AutopilotCommand) {
        Install-Script `
            -Name Get-WindowsAutopilotInfo `
            -Scope AllUsers `
            -Force `
            -Confirm:$false `
            -ErrorAction Stop

        $AutopilotCommand = Get-Command Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue
    }

    if ($AutopilotCommand) {
        $AutopilotScriptPath = $AutopilotCommand.Source
    }
    else {
        $AutopilotScriptPath = Join-Path $env:ProgramFiles "WindowsPowerShell\Scripts\Get-WindowsAutopilotInfo.ps1"

        if (-not (Test-Path -LiteralPath $AutopilotScriptPath)) {
            throw "Get-WindowsAutopilotInfo was installed but could not be located."
        }
    }
}
catch {
    Stop-WithError "Autopilot script installation failed: $($_.Exception.Message)" 40
}

try {
    $DeviceSerialNumber = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber.Trim()

    if ([string]::IsNullOrWhiteSpace($DeviceSerialNumber)) {
        $DeviceSerialNumber = "UNKNOWN"
    }
}
catch {
    $DeviceSerialNumber = "UNKNOWN"
    Write-Log "Could not read the device serial number: $($_.Exception.Message)" WARN
}

try {
    $AutopilotParams = @{
        Online   = $true
        GroupTag = $GroupTag
    }

    if (-not [string]::IsNullOrWhiteSpace($AssignedComputerName)) {
        $AutopilotParams.AssignedComputerName = $AssignedComputerName
    }

    if ($WaitForAssignment) {
        $AutopilotParams.Assign = $true
    }

    & $AutopilotScriptPath @AutopilotParams

    if (-not $?) {
        throw "Get-WindowsAutopilotInfo reported a failure."
    }
}
catch {
    Stop-WithError "Autopilot registration failed: $($_.Exception.Message)" 50
}

Write-Log "Registration succeeded. Serial number: $DeviceSerialNumber"

if ($RebootAfterRegistration) {
    Write-Log "Rebooting in 30 seconds; press Enter to reboot now."
    $null = Wait-RebootCountdown -Seconds 30
    Restart-Computer -Force
}
else {
    Write-Log "Registration complete. Reboot the device manually."
}

exit 0
