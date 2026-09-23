[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$checker = Join-Path $PSScriptRoot "../tools/check-docs.ps1"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$fixtureRoot = Join-Path $tempBase ("foundation-docs-" + [Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot "docs"), (Join-Path $fixtureRoot "target") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureRoot "docs\a b.md") -Value "# Target"
    $validLinks = @'
[relative](docs/a%20b.md#target)
[rooted](/docs/a%20b.md)
[spaces](<docs/a b.md>)
[remote](https://example.invalid/unqueried)
[fragment](#local)
'@
    Set-Content -LiteralPath (Join-Path $fixtureRoot "README.md") -Value $validLinks
    Set-Content -LiteralPath (Join-Path $fixtureRoot "target\generated.md") -Value '[ignored](missing.md)'
    # A product may remove all Agent guidance and still have valid documentation.
    & $checker -RepositoryRoot $fixtureRoot | Out-Null

    Add-Content -LiteralPath (Join-Path $fixtureRoot "README.md") -Value '[broken](docs/missing.md)'
    $rejected = $false
    try { & $checker -RepositoryRoot $fixtureRoot | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*missing local target 'docs/missing.md'*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Documentation checker accepted a broken local link." }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove documentation fixture outside the temporary directory."
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
Write-Host "Documentation link positive and negative tests passed."
