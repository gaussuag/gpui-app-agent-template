[CmdletBinding()]
param(
    [string]$CommitRange
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$validator = Join-Path $PSScriptRoot "check-commit-message.ps1"

Push-Location $root
try {
    if ([string]::IsNullOrWhiteSpace($CommitRange)) {
        if ($env:GITHUB_EVENT_NAME -eq "pull_request" -and $env:GITHUB_BASE_REF) {
            $CommitRange = "origin/$($env:GITHUB_BASE_REF)..HEAD"
        }
        elseif ($env:GITHUB_EVENT_BEFORE -and $env:GITHUB_EVENT_BEFORE -notmatch '^0+$') {
            $CommitRange = "$($env:GITHUB_EVENT_BEFORE)..HEAD"
        }
    }

    if ([string]::IsNullOrWhiteSpace($CommitRange)) {
        $commits = @(& git rev-parse HEAD)
    }
    else {
        $commits = @(& git rev-list --reverse $CommitRange)
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve commit range '$CommitRange'."
    }
    if ($commits.Count -eq 0) {
        Write-Host "No commits require message validation."
        exit 0
    }

    foreach ($commit in $commits) {
        $parents = @(& git show -s --format=%P $commit) -join ""
        if (($parents -split '\s+' | Where-Object { $_ }).Count -gt 1) {
            Write-Host "Skipping generated merge commit $commit."
            continue
        }

        $message = (@(& git show -s --format=%B $commit) -join "`n").TrimEnd()
        & $validator -Message $message
        if ($LASTEXITCODE -ne 0) {
            throw "Commit message validation failed for $commit."
        }
    }
}
finally {
    Pop-Location
}

Write-Host "Commit message checks passed."
