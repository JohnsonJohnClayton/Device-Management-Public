<#
.SYNOPSIS
    PowerShell module to create an ISO image containing a Windows provisioning package (PPKG).
.DESCRIPTION
    Creates an ISO file from a given .ppkg file, suitable for mounting to Hyper-V or other virtual machines during Windows OOBE.
    Automates the process for repeatable, secure deployment.
.NOTES
    Author: Windows System Administrator
    Version: 1.0.0
    Compatible with: Windows PowerShell 5.1+, PowerShell 7+
    Requires: OSCDIMG.exe (Windows ADK) or New-IsoFile (Windows 11), or fallback COM method
.EXAMPLE
    New-PPKGISO -PPKGPath "C:\Provisioning\CustomConfig.ppkg" -OutputPath "C:\ISOs\PPKG-Deploy.iso"
#>

function New-PPKGISO {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline, Position=0, HelpMessage="Path to the .ppkg file to include in the ISO.")]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$PPKGPath,

        [Parameter(Mandatory=$false, HelpMessage="Output path for created ISO file. Defaults to user's Documents.")]
        [string]$OutputPath = (Join-Path -Path $(Get-Item $PPKGPath).Directory.FullName -ChildPath ("PPKG-" + $(Get-Item $PPKGPath).BaseName)) + '.iso',

        [Parameter()]
        [switch]$Force
    )

    begin {
        function Write-Log {
            param([string]$Message, [string]$Color = "White")
            Write-Host "[PPKGIsoToolkit] $Message" -ForegroundColor $Color
        }
    }

    process {
        try {
            # Validate input
            if (!(Test-Path $PPKGPath)) {
                throw "The PPKG file '$PPKGPath' does not exist."
            }
            if (Test-Path $OutputPath) {
                Write-Warning "Output ISO '$OutputPath' already exists. Choose a different path or remove the existing file."
                if(-not $Force) { Read-Host "Press Enter to overwrite or Ctrl+C to cancel" }
                Remove-Item -Path $OutputPath -Force
            }
            $ppkgFileName = [IO.Path]::GetFileName($PPKGPath)

            # Create a temporary folder for ISO content
            $tempDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP -ChildPath ("PPKGISO-" + ([Guid]::NewGuid().ToString()))) -Force
            Copy-Item -Path $PPKGPath -Destination $tempDir.FullName -Force

            Write-Log "Created build workspace: $($tempDir.FullName)" "Yellow"
            Write-Log "Preparing ISO '$OutputPath' with $ppkgFileName" "Cyan"

            # --- Attempt to use OSCDIMG.exe ---
            $oscdimgPaths = @(
                "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
                "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe"
            )
            $oscdimgExe = $oscdimgPaths | Where-Object {Test-Path $_} | Select-Object -First 1

            if ($oscdimgExe) {
                Write-Log "Using OSCDIMG: $oscdimgExe" "Green"
                & $oscdimgExe -n -m "$($tempDir.FullName)" "$OutputPath" | Out-Null
                if (!(Test-Path $OutputPath)) {
                    throw "OSCDIMG failed to create the ISO at $OutputPath."
                }
            } elseif (Get-Command New-IsoFile -ErrorAction SilentlyContinue) {
                Write-Log "Using New-IsoFile cmdlet." "Green"
                New-IsoFile -Source $tempDir.FullName -DestinationIso $OutputPath -Force
            } else {
                Write-Log "No standard ISO builder found. Attempting fallback COM object method..." "Yellow"
                # --- COM fallback (Windows-only) ---
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
                $fsi.ChooseImageDefaults("ISO")
                $fsi.VolumeName = "PPKGDEPLOY"
                $fsi.Root.AddFile($ppkgFileName, $fsi.CreateFileItem($PPKGPath))
                $resultImage = $fsi.CreateResultImage()
                $imageStream = $resultImage.ImageStream
                $outFile = [System.IO.File]::OpenWrite($OutputPath)
                $buffer = New-Object byte[] 1MB
                do {
                    $bytesRead = $imageStream.Read($buffer,0,$buffer.Length)
                    $outFile.Write($buffer,0,$bytesRead)
                } while ($bytesRead -gt 0)
                $outFile.Close()
                if (!(Test-Path $OutputPath)) {
                    throw "COM fallback failed to create the ISO."
                }
            }
            Write-Log "ISO successfully created at '$OutputPath'." "Cyan"
            Write-Log "Mount the ISO to your VM and press Windows key 5 times in OOBE/region screen to provision." "Magenta"
        }
        catch {
            throw "New-PPKGISO: $($_.Exception.Message)"
        }
        finally {
            if ($tempDir -and (Test-Path $tempDir.FullName)) {
                Remove-Item -Path $tempDir.FullName -Recurse -Force
                Write-Log "Cleaned up temporary workspace." "Gray"
            }
        }
    }
}

Export-ModuleMember -Function New-PPKGISO
