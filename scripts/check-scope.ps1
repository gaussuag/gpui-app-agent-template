[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ChangeSpecPath,
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PolicyPath = "",
    [switch]$AllowDraft,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\ExecutableConstitution.psm1") -Force

function Test-PathMatchesAnyGlob {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Globs
    )

    foreach ($glob in $Globs) {
        if (Test-ECRepoGlob -Path $Path -Glob ([string]$glob)) {
            return $true
        }
    }
    return $false
}

function Test-ChangeAddsPath {
    param([Parameter(Mandatory = $true)]$Change)

    return @($Change.Statuses | Where-Object { $_ -match '^(?:A|[RC]\d+-new)$' }).Count -gt 0
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$contractArguments = @{
    ChangeSpecPath = $ChangeSpecPath
    RepositoryRoot = $root
    AllowDraft = $AllowDraft
    PassThru = $true
}
if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) {
    $contractArguments.PolicyPath = $PolicyPath
}
$contract = & (Join-Path $PSScriptRoot "check-change-spec.ps1") @contractArguments
$changes = @(Get-ECChangedPaths `
    -RepositoryRoot $root `
    -TaskStartRevision $contract.Spec.task_start_revision)

$specPath = [IO.Path]::GetFullPath($contract.ChangeSpecPath)
$specRelativePath = $null
$relativeCandidate = [IO.Path]::GetRelativePath($root, $specPath).Replace('\', '/')
if (-not $relativeCandidate.StartsWith('../') -and $relativeCandidate -ne '..') {
    $specRelativePath = ConvertTo-ECNormalizedRepoPath -Path $relativeCandidate
}

foreach ($change in $changes) {
    if ($contract.Spec.lane -eq "bot") {
        $botForbidden = @($contract.Policy.bot.forbidden_paths | Where-Object {
            Test-ECRepoGlob -Path $change.Path -Glob $_
        })
        if ($botForbidden.Count -gt 0) {
            throw "Bot path '$($change.Path)' is forbidden by dependency policy pattern '$($botForbidden[0])'."
        }
        $botAllowed = @($contract.Policy.bot.allowed_paths | Where-Object {
            Test-ECRepoGlob -Path $change.Path -Glob $_
        })
        if ($botAllowed.Count -eq 0) {
            throw "Bot path '$($change.Path)' is outside the dependency policy allowlist."
        }
    }

    $forbidden = @($contract.Spec.scope.forbidden_paths | Where-Object {
        Test-ECRepoGlob -Path $change.Path -Glob $_
    })
    if ($forbidden.Count -gt 0) {
        throw "Changed path '$($change.Path)' is forbidden by ChangeSpec pattern '$($forbidden[0])'."
    }

    $allowed = $change.Path -eq $specRelativePath -or @($contract.Spec.scope.allowed_paths | Where-Object {
        Test-ECRepoGlob -Path $change.Path -Glob $_
    }).Count -gt 0
    if (-not $allowed) {
        throw "Changed path '$($change.Path)' is outside the declared ChangeSpec allowed_paths."
    }

    if ($change.Path -match '^crates/([^/]+)(?:/|$)') {
        $crateName = $Matches[1]
        if ($crateName -notin @($contract.Spec.scope.expected_crates)) {
            throw "Changed crate '$crateName' from path '$($change.Path)' is missing from ChangeSpec expected_crates."
        }
    }
}

$protectedGlobs = @($contract.Policy.protected_paths | ForEach-Object { @($_.globs) })
$actualBudgets = [ordered]@{
    new_crates = @($changes | Where-Object {
        (Test-ChangeAddsPath -Change $_) -and
            (Test-PathMatchesAnyGlob -Path $_.Path -Globs @($contract.Policy.budget_indicators.new_crate_manifests))
    }).Count
    dependency_manifest_files = @($changes | Where-Object {
        Test-PathMatchesAnyGlob -Path $_.Path -Globs @($contract.Policy.budget_indicators.dependency_manifest_files)
    }).Count
    new_manifests = @($changes | Where-Object {
        (Test-ChangeAddsPath -Change $_) -and
            (Test-PathMatchesAnyGlob -Path $_.Path -Globs @($contract.Policy.budget_indicators.new_manifests))
    }).Count
    new_unsafe_boundaries = if ($contract.Spec.architecture.changes_unsafe_boundary) { 1 } else { 0 }
    protected_files = @($changes | Where-Object {
        Test-PathMatchesAnyGlob -Path $_.Path -Globs $protectedGlobs
    }).Count
    workflow_files = @($changes | Where-Object {
        Test-PathMatchesAnyGlob -Path $_.Path -Globs @($contract.Policy.budget_indicators.workflow_files)
    }).Count
    public_architecture_layers = if ($contract.Spec.architecture.changes_public_architecture_layers) { 1 } else { 0 }
}

if ($actualBudgets.dependency_manifest_files -gt 0 -and -not $contract.Spec.architecture.changes_dependencies) {
    throw "Dependency manifest files changed, but architecture.changes_dependencies is false."
}
foreach ($budget in $contract.Spec.budgets.PSObject.Properties) {
    $actual = [int64]$actualBudgets[$budget.Name]
    $declared = [int64]$budget.Value
    if ($actual -gt $declared) {
        throw "ChangeSpec budget '$($budget.Name)' exceeded: actual=$actual declared=$declared."
    }
}

Write-Host "Change scope passed: $($contract.Spec.change_id) paths=$($changes.Count) outcome=$($contract.Outcome)"
if ($PassThru) {
    return [pscustomobject]@{
        Spec = $contract.Spec
        Policy = $contract.Policy
        Outcome = $contract.Outcome
        Changes = $changes
        ActualBudgets = [pscustomobject]$actualBudgets
        ChangeSpecPath = $contract.ChangeSpecPath
    }
}
