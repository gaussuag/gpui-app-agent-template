[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$fixture = Join-Path $tempBase ('foundation standalone ' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    # Copy only the foundation: no root scripts, Cargo files or project docs.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../agent-foundation') -Destination $fixture -Recurse
    $standalone = Join-Path $fixture 'agent-foundation'
    & (Join-Path $standalone 'tools/check-docs.ps1') -RepositoryRoot $standalone
    & (Join-Path $standalone 'tests/test-docs.ps1')
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing cleanup outside temporary directory.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host 'Standalone foundation and unrelated document fixture passed.'
