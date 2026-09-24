[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$fixture = Join-Path $tempBase ('check-routing-' + [Guid]::NewGuid().ToString('N'))
try {
    $scripts = Join-Path $fixture 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'check.ps1') -Destination $scripts
    $stub = @'
param($Profile, $ArtifactPath, $Suite, [switch]$SkipBuild)
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
Add-Content -LiteralPath (Join-Path $PSScriptRoot '../calls.txt') -Value "$name|$Suite"
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "../fail-$name")) { throw "injected $name failure" }
'@
    foreach ($name in @('check-product', 'check-architecture', 'test', 'check-docs', 'test-docs',
        'test-check-routing', 'test-product-identity', 'test-ui-dependencies', 'smoke', 'smoke-overlay')) {
        Set-Content -LiteralPath (Join-Path $scripts "$name.ps1") -Value $stub
    }
    Set-Content -LiteralPath (Join-Path $scripts 'resolve-cargo.ps1') -Value '(Join-Path $PSScriptRoot "cargo-stub.ps1")'
    Set-Content -LiteralPath (Join-Path $scripts 'resolve-desktop-target.ps1') -Value '[pscustomobject]@{TargetDirectory=$PSScriptRoot; BinaryName="fixture"}'
    Set-Content -LiteralPath (Join-Path $scripts 'cargo-stub.ps1') -Value @'
Add-Content -LiteralPath (Join-Path $PSScriptRoot '../calls.txt') -Value "cargo|$($args[0])"
$global:LASTEXITCODE = if (Test-Path (Join-Path $PSScriptRoot '../fail-cargo')) { 9 } else { 0 }
'@
    $log = Join-Path $fixture 'calls.txt'
    $gate = Join-Path $scripts 'check.ps1'
    function Assert-Calls([string[]]$Expected) {
        $actual = @(Get-Content -LiteralPath $log)
        if (($actual -join ',') -cne ($Expected -join ',')) {
            throw "Wrong dispatch. Expected $($Expected -join ','); got $($actual -join ',')"
        }
        Clear-Content -LiteralPath $log
    }
    # Docs must work without even resolving a toolchain.
    Rename-Item -LiteralPath (Join-Path $scripts 'resolve-cargo.ps1') -NewName 'resolve-cargo.saved'
    & $gate -Group docs
    Assert-Calls @('check-docs|')
    Rename-Item -LiteralPath (Join-Path $scripts 'resolve-cargo.saved') -NewName 'resolve-cargo.ps1'
    & $gate -Group build,startup,build
    Assert-Calls @('cargo|build', 'check-product|', 'smoke|')
    & $gate -Group tests,tests
    Assert-Calls @('test|all')
    # Exercise the actual hosted group selection; desktop scripts must not run.
    $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.github/workflows/ci.yml') -Raw
    if ($workflow -notmatch 'run: \.\\scripts\\check\.ps1 -Group ([a-z,]+)') {
        throw 'Hosted workflow must explicitly select desktop-independent check groups.'
    }
    $hostedGroups = $Matches[1].Split(',')
    $hostedCalls = @('check-product|', 'cargo|fmt', 'cargo|clippy', 'check-architecture|',
        'test|all', 'check-docs|', 'test-docs|', 'test-check-routing|',
        'test-product-identity|', 'test-ui-dependencies|', 'cargo|build', 'check-product|')
    & $gate -Group $hostedGroups
    Assert-Calls $hostedCalls
    if ($workflow -notmatch '(?m)^\s*run: \.\\scripts\\test-generated-project\.ps1 -SkipGui\s*$') {
        throw 'Hosted generated-product checks must omit GUI acceptance.'
    }
    foreach ($guiOption in @('FullRegression', 'IncludeIme')) {
        $options = @{ SkipGui = $true; $guiOption = $true }
        $rejected = $false
        try { & (Join-Path $PSScriptRoot 'test-generated-project.ps1') @options } catch {
            if ($_.Exception.Message -notlike '*SkipGui cannot be combined*') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "SkipGui silently discarded $guiOption." }
    }
    Set-Content -LiteralPath (Join-Path $fixture 'fail-test') -Value 'fail'
    $rejected = $false
    try { & $gate -Group $hostedGroups } catch {
        if ($_.Exception.Message -notlike '*injected test failure*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Hosted checks accepted failing headless tests.' }
    Assert-Calls @('check-product|', 'cargo|fmt', 'cargo|clippy', 'check-architecture|', 'test|all')
    Remove-Item -LiteralPath (Join-Path $fixture 'fail-test')
    & $gate -Group overlay -IncludeIme
    Assert-Calls @('smoke-overlay|', 'smoke-overlay|ime')
    & $gate
    Assert-Calls @('check-product|', 'cargo|fmt', 'cargo|clippy', 'check-architecture|',
        'test|all', 'check-docs|', 'test-docs|', 'test-check-routing|',
        'test-product-identity|', 'test-ui-dependencies|', 'cargo|build', 'check-product|',
        'smoke|', 'smoke-overlay|')
    $rejected = $false
    try { & $gate -Group docs -IncludeIme } catch {
        if ($_.Exception.Message -notlike '*IncludeIme requires*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Invalid IME selection was accepted.' }
    $rejected = $false
    try { & $gate -Group @() } catch {
        if ($_.FullyQualifiedErrorId -notlike 'ParameterArgumentValidationError*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Empty check selection was accepted.' }
    Set-Content -LiteralPath (Join-Path $fixture 'fail-cargo') -Value 'fail'
    $rejected = $false
    try { & $gate -Group build,startup } catch {
        if ($_.Exception.Message -notlike '*failed with exit code 9*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Native command failure was accepted.' }
    Assert-Calls @('cargo|build')
    Set-Content -LiteralPath (Join-Path $fixture 'fail-check-docs') -Value 'fail'
    $rejected = $false
    try { & $gate -Group docs,validators } catch {
        if ($_.Exception.Message -notlike '*injected check-docs failure*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Script failure was accepted.' }
    Assert-Calls @('check-docs|')
} finally {
    $global:LASTEXITCODE = $previousExitCode
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing cleanup outside temporary directory.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host 'Check routing, prerequisite deduplication and failure propagation passed.'
