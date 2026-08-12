[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$commitChecker = Join-Path $PSScriptRoot "check-commit-message.ps1"
$riskChecker = Join-Path $PSScriptRoot "check-source-risks.ps1"

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Case
    )

    $rejected = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Policy self-test failed: expected rejection for $Case."
    }
}

$validMessage = @'
test(policy): exercise validator contracts

Why:
- prevent silent parser regressions

What:
- run positive and negative fixtures

Evidence:
- deterministic local fixture
'@
& $commitChecker -Message $validMessage | Out-Null

Assert-Rejected -Case "uppercase commit summary" -Action {
    & $commitChecker -Message ($validMessage -replace 'exercise', 'Exercise')
}
Assert-Rejected -Case "missing commit Evidence section" -Action {
    & $commitChecker -Message ($validMessage -replace '(?ms)\nEvidence:.*$', '')
}
Assert-Rejected -Case "breaking commit without a breaking paragraph" -Action {
    & $commitChecker -Message ($validMessage -replace '^test\(policy\):', 'test(policy)!:')
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("gpui-agent-policy-" + [Guid]::NewGuid().ToString("N"))
$fixtureSource = Join-Path $fixtureRoot "crates\sample\src"
$fixtureDocs = Join-Path $fixtureRoot "docs\decisions"
$fixtureAllowlist = Join-Path $fixtureRoot "docs\agent-risk-allowlist.txt"
try {
    New-Item -ItemType Directory -Path $fixtureSource, $fixtureDocs -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureSource "lib.rs") -Value "pub fn safe() {}" -Encoding utf8
    Set-Content -LiteralPath $fixtureAllowlist -Value "# path|risk-id|adr-path" -Encoding utf8
    & $riskChecker -RepositoryRoot $fixtureRoot -SourceRoot (Join-Path $fixtureRoot "crates") -AllowlistPath $fixtureAllowlist | Out-Null

    Set-Content -LiteralPath (Join-Path $fixtureSource "lib.rs") -Value "pub fn risky(task: gpui::Task<()>) { task.detach(); }" -Encoding utf8
    Assert-Rejected -Case "unreviewed detached task" -Action {
        & $riskChecker -RepositoryRoot $fixtureRoot -SourceRoot (Join-Path $fixtureRoot "crates") -AllowlistPath $fixtureAllowlist
    }

    $adrPath = Join-Path $fixtureDocs "0001-detached-task.md"
    Set-Content -LiteralPath $adrPath -Value "# Decision`n`n- Status: accepted" -Encoding utf8
    Set-Content -LiteralPath $fixtureAllowlist -Value "crates/sample/src/lib.rs|detached-task|docs/decisions/0001-detached-task.md" -Encoding utf8
    & $riskChecker -RepositoryRoot $fixtureRoot -SourceRoot (Join-Path $fixtureRoot "crates") -AllowlistPath $fixtureAllowlist | Out-Null

    Set-Content -LiteralPath (Join-Path $fixtureSource "lib.rs") -Value "pub fn safe_again() {}" -Encoding utf8
    Assert-Rejected -Case "stale source-risk exception" -Action {
        & $riskChecker -RepositoryRoot $fixtureRoot -SourceRoot (Join-Path $fixtureRoot "crates") -AllowlistPath $fixtureAllowlist
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Host "Commit and source-risk policy self-tests passed."
& (Join-Path $PSScriptRoot "test-product-identity.ps1")
