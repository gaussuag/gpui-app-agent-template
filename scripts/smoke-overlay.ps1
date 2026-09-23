[CmdletBinding()]
param(
    [ValidateSet("all", "lifecycle", "input", "geometry", "fallback", "ime", "components", "dpi", "margins", "presentation")]
    [string]$Suite = "all"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")
$desktopTarget = & (Join-Path $PSScriptRoot "resolve-desktop-target.ps1")
$targetTriple = "x86_64-pc-windows-msvc"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "The native overlay smoke requires Windows."
}

function Invoke-OverlayProbe {
    param([string]$Mode, [string]$Marker, [int]$TimeoutSeconds)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fixture
    $startInfo.Arguments = "`"$probe`" $Mode"
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Overlay fixture did not start." }
        # Drain both streams while running, so diagnostics cannot fill a pipe.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(($TimeoutSeconds + 3) * 1000)) {
            # The fixture owns the child and enforces the tighter inner deadline.
            # Kill only this owned process tree if the fixture itself is stuck.
            $process.Kill($true)
            $process.WaitForExit()
            throw "Overlay fixture exceeded its bounded ${TimeoutSeconds}s run and shutdown grace."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Write-Host $stdout
        if ($stderr) { Write-Host $stderr }
        $inputVerified = $Mode -in @("--stress", "--host-exit", "--owner-close", "--external-close") -or $stdout.Contains("PROBE_REAL_INPUT_OK")
        if ($Mode -eq "--geometry") { $inputVerified = $stdout.Contains("PROBE_GEOMETRY_OK") }
        if ($Mode.Contains("--margins")) { $inputVerified = $stdout.Contains("PROBE_MARGINS_OK") }
        if ($Mode -eq "--dpi") { $inputVerified = $stdout.Contains("PROBE_DPI_OK") }
        if ($Mode -eq "--presentation") {
            $inputVerified = $stdout.Contains("PROBE_REAL_INPUT_OK") -and $stdout.Contains("PROBE_PRESENTATION_OCCLUSION_OK") -and $stdout.Contains("PROBE_PRESENTATION_FIRST_CLICK_OK") -and $stdout.Contains("PROBE_PRESENTATION_CAPTION_OK")
        }
        if ($Mode -eq "--caption") { $inputVerified = $stdout.Contains("PROBE_REAL_INPUT_OK") -and $stdout.Contains("PROBE_PRESENTATION_CAPTION_OK") }
        if ($Mode -eq "--fallback") {
            $inputVerified = $stdout.Contains("PROBE_FALLBACK_OK") -and $stdout -match 'OVERLAY_DROPPED_EVENTS=[1-9][0-9]*'
        }
        if ($process.ExitCode -ne 0 -or -not $stdout.Contains($Marker) -or -not $stdout.Contains("PROBE_CLEANUP_COMPLETE") -or -not $inputVerified) {
            if ($stderr.Contains("PROBE_ABORTED")) {
                throw "Overlay input smoke requires an unlocked interactive desktop with the controlled fixture in foreground. No input is sent after a foreground guard fails."
            }
            throw "Overlay smoke '$Mode' failed with exit code $($process.ExitCode); expected $Marker and completed cleanup."
        }
    }
    finally { $process.Dispose() }
}

Push-Location $root
try {
    & $cargoPath build --locked --target $targetTriple -p app-ui --example overlay-probe -p overlay-win32 --example fixture --features app-ui/test-support,overlay-win32/test-support
    if ($LASTEXITCODE -ne 0) { throw "Overlay smoke build failed with exit code $LASTEXITCODE." }
    $examples = Join-Path $desktopTarget.TargetDirectory "$targetTriple\debug\examples"
    $fixture = Join-Path $examples "fixture.exe"
    $probe = Join-Path $examples "overlay-probe.exe"
    if ($Suite -in @("all", "presentation")) {
        Invoke-OverlayProbe -Mode "--presentation" -Marker "PROBE_CONTENT_INPUT_OK" -TimeoutSeconds 15
        Invoke-OverlayProbe -Mode "--caption" -Marker "OVERLAY_NATIVE_SMOKE_OK" -TimeoutSeconds 15
    }
    if ($Suite -in @("all", "margins")) {
        foreach ($mode in @("--margins", "--margins --interactive")) {
            Invoke-OverlayProbe -Mode $mode -Marker "PROBE_MARGINS_OK" -TimeoutSeconds 15
        }
    }
    if ($Suite -in @("all", "dpi")) {
        Invoke-OverlayProbe -Mode "--dpi" -Marker "PROBE_DPI_OK" -TimeoutSeconds 15
    }
    if ($Suite -in @("all", "lifecycle")) {
        Write-Host "==> overlay 100-cycle lifecycle/resource endurance (60s)"
        Invoke-OverlayProbe -Mode "--stress" -Marker "OVERLAY_NATIVE_STRESS_100_OK" -TimeoutSeconds 60
        foreach ($mode in @("--host-exit", "--owner-close", "--external-close")) {
            Write-Host "==> overlay native lifecycle $mode (15s)"
            Invoke-OverlayProbe -Mode $mode -Marker "OVERLAY_NATIVE_LIFECYCLE_OK" -TimeoutSeconds 15
        }
    }
    if ($Suite -in @("all", "input")) {
        Write-Host "==> overlay HUD real hit-testing and first frame (15s)"
        Invoke-OverlayProbe -Mode "" -Marker "OVERLAY_NATIVE_SMOKE_OK" -TimeoutSeconds 15
        Write-Host "==> overlay interactive content and switch to HUD (15s)"
        Invoke-OverlayProbe -Mode "--interactive" -Marker "PROBE_CONTENT_INPUT_OK" -TimeoutSeconds 15
    }
    if ($Suite -in @("all", "geometry")) {
        Write-Host "==> overlay native geometry, latency, and visibility (15s)"
        Invoke-OverlayProbe -Mode "--geometry" -Marker "PROBE_GEOMETRY_OK" -TimeoutSeconds 15
    }
    if ($Suite -in @("all", "fallback")) {
        Write-Host "==> overlay convergence with deliberately dropped WinEvents (15s)"
        Invoke-OverlayProbe -Mode "--fallback" -Marker "PROBE_FALLBACK_OK" -TimeoutSeconds 15
    }
    if ($Suite -in @("all", "components")) {
        Invoke-OverlayProbe -Mode "--components-preview" -Marker "PROBE_COMPONENTS_OK" -TimeoutSeconds 15
        Invoke-OverlayProbe -Mode "--components" -Marker "PROBE_COMPONENTS_OK" -TimeoutSeconds 15
    }
    if ($Suite -eq "ime") {
        Write-Host "==> ordinary preview real Chinese IME comparison (15s)"
        Invoke-OverlayProbe -Mode "--ime-preview" -Marker "PROBE_IME_PREVIEW_OK" -TimeoutSeconds 15
        Write-Host "==> overlay real Chinese IME composition, cancel and commit (15s)"
        Invoke-OverlayProbe -Mode "--ime" -Marker "PROBE_IME_OK" -TimeoutSeconds 15
    }
}
finally { Pop-Location }

Write-Host "Overlay $Suite smoke passed."
