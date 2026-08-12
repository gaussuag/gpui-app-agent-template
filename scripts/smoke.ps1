[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")
$targetTriple = "x86_64-pc-windows-msvc"
$successMarker = "GPUI_SMOKE_OK"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "The native GPUI smoke requires Windows."
}

Push-Location $root
try {
    if (-not $SkipBuild) {
        Write-Host "==> Windows smoke build"
        & $cargoPath build --package desktop --target $targetTriple --locked
        if ($LASTEXITCODE -ne 0) {
            throw "Windows smoke build failed with exit code $LASTEXITCODE."
        }
    }

    $executable = Join-Path $root "target\$targetTriple\debug\gpui-app-agent-template.exe"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Windows smoke executable is missing: $executable"
    }

    Write-Host "==> native first-frame smoke"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.Arguments = "--smoke-test"
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Windows smoke process did not start."
        }

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Windows smoke exceeded its ${TimeoutSeconds}s deadline."
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0 -or -not $stdout.Contains($successMarker)) {
            throw "Windows smoke failed with exit code $($process.ExitCode).`nstdout:`n$stdout`nstderr:`n$stderr"
        }
    }
    finally {
        $process.Dispose()
    }

    Write-Host "==> native last-window close smoke"
    $closeStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $closeStartInfo.FileName = $executable
    $closeStartInfo.WorkingDirectory = $root
    $closeStartInfo.UseShellExecute = $false
    $closeStartInfo.RedirectStandardOutput = $true
    $closeStartInfo.RedirectStandardError = $true
    $closeStartInfo.CreateNoWindow = $true

    $closeProcess = [System.Diagnostics.Process]::new()
    $closeProcess.StartInfo = $closeStartInfo
    $closeProcessStarted = $false
    try {
        if (-not $closeProcess.Start()) {
            throw "Windows close smoke process did not start."
        }
        $closeProcessStarted = $true

        $windowDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $closeProcess.Refresh()
            if ($closeProcess.HasExited) {
                $stdout = $closeProcess.StandardOutput.ReadToEnd()
                $stderr = $closeProcess.StandardError.ReadToEnd()
                throw "Windows close smoke exited before opening its main window with code $($closeProcess.ExitCode).`nstdout:`n$stdout`nstderr:`n$stderr"
            }

            if ($closeProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                break
            }

            [void]$closeProcess.WaitForExit(50)
        } while ([DateTime]::UtcNow -lt $windowDeadline)

        if ($closeProcess.MainWindowHandle -eq [IntPtr]::Zero) {
            throw "Windows close smoke did not observe a main window within ${TimeoutSeconds}s."
        }
        if (-not $closeProcess.CloseMainWindow()) {
            throw "Windows close smoke could not request main-window closure."
        }
        if (-not $closeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Windows close smoke process did not exit within ${TimeoutSeconds}s after its main window closed."
        }

        $stdout = $closeProcess.StandardOutput.ReadToEnd()
        $stderr = $closeProcess.StandardError.ReadToEnd()
        if ($closeProcess.ExitCode -ne 0) {
            throw "Windows close smoke failed with exit code $($closeProcess.ExitCode).`nstdout:`n$stdout`nstderr:`n$stderr"
        }
    }
    finally {
        if ($closeProcessStarted -and -not $closeProcess.HasExited) {
            $closeProcess.Kill()
            $closeProcess.WaitForExit()
        }
        $closeProcess.Dispose()
    }
}
finally {
    Pop-Location
}

Write-Host "Windows first-frame and last-window close smoke passed."
