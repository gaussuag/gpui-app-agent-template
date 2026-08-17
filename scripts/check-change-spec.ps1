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

$root = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $root ".agentinfra\policy.json"
}
if (-not [IO.Path]::IsPathRooted($ChangeSpecPath)) {
    $ChangeSpecPath = Join-Path $root $ChangeSpecPath
}
$schemaPath = Join-Path $root ".agentinfra\schemas\change-spec.schema.json"

& (Join-Path $PSScriptRoot "check-policy.ps1") -RepositoryRoot $root -PolicyPath $PolicyPath | Out-Null
foreach ($path in @($ChangeSpecPath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ChangeSpec input is missing: $path"
    }
}

try {
    $schemaResult = Test-Json -LiteralPath $ChangeSpecPath -SchemaFile $schemaPath -ErrorAction Stop
}
catch {
    throw "ChangeSpec does not match its schema: $($_.Exception.Message)"
}
if (-not $schemaResult) {
    throw "ChangeSpec does not match its schema."
}

$spec = Read-ECJsonFile -Path $ChangeSpecPath
$policy = Read-ECJsonFile -Path $PolicyPath
$relativeSpecPath = [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($ChangeSpecPath)).Replace('\', '/')
$specIsInsideRepository = (
    $relativeSpecPath -ne '..' -and
    -not $relativeSpecPath.StartsWith('../') -and
    -not [IO.Path]::IsPathRooted($relativeSpecPath)
)
if ($policy.lanes.($spec.lane).persistence -eq "transient" -and $specIsInsideRepository) {
    throw "Lane '$($spec.lane)' requires a transient ChangeSpec outside the repository."
}
if ($spec.state -eq "draft" -and -not $AllowDraft) {
    throw "Draft ChangeSpec '$($spec.change_id)' is not executable. Complete it and set state to ready."
}

& git -C $root cat-file -e "$($spec.task_start_revision)^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "task_start_revision is not an available commit: $($spec.task_start_revision)"
}

foreach ($glob in @($spec.scope.allowed_paths) + @($spec.scope.forbidden_paths)) {
    $null = ConvertTo-ECNormalizedRepoPath -Path $glob -AllowGlob
}
foreach ($adrPath in @($spec.architecture.adr_paths)) {
    $normalizedAdr = ConvertTo-ECNormalizedRepoPath -Path $adrPath
    if (-not $normalizedAdr.StartsWith("docs/decisions/", [StringComparison]::OrdinalIgnoreCase)) {
        throw "ADR paths must be repository-relative files under docs/decisions: $adrPath"
    }
}

$profileProperty = $policy.checks.profiles.PSObject.Properties[$spec.verification.profile]
if ($null -eq $profileProperty) {
    throw "Unknown verification profile '$($spec.verification.profile)'."
}
$profile = $profileProperty.Value
if ($spec.lane -notin @($profile.allowed_lanes)) {
    throw "Verification profile '$($spec.verification.profile)' does not allow lane '$($spec.lane)'."
}
if ($policy.repository_profile -notin @($profile.repository_profiles)) {
    throw "Verification profile '$($spec.verification.profile)' does not apply to '$($policy.repository_profile)' repositories."
}

$requiredDifference = @(Compare-Object `
    -ReferenceObject @($profile.required_checks | Sort-Object) `
    -DifferenceObject @($spec.verification.required_checks | Sort-Object))
if ($requiredDifference.Count -gt 0) {
    throw "ChangeSpec required checks must exactly match verification profile '$($spec.verification.profile)'."
}

$architectureFlags = @(
    "changes_owner_or_dependency_direction",
    "changes_async_or_resource_lifecycle",
    "changes_platform_boundary",
    "changes_dependencies",
    "changes_protocol_or_persistence",
    "changes_privacy_or_sensitive_data",
    "changes_unsafe_boundary",
    "changes_public_architecture_layers"
)
if ($spec.lane -eq "focused") {
    $enabledFlags = @($architectureFlags | Where-Object { $spec.architecture.$_ })
    if ($enabledFlags.Count -gt 0) {
        throw "A focused ChangeSpec cannot declare dependency, lifecycle, platform, protocol, privacy, unsafe, ownership, or public-architecture impact: $($enabledFlags -join ', ')."
    }
    $nonZeroBudgets = @($spec.budgets.PSObject.Properties | Where-Object { [int64]$_.Value -ne 0 })
    if ($nonZeroBudgets.Count -gt 0) {
        throw "A focused ChangeSpec must keep every expansion budget at zero."
    }
}

if ($spec.lane -ne "governance" -and $spec.protected_change) {
    throw "Only the governance lane may declare protected_change."
}
if ($spec.lane -eq "bot") {
    if ($spec.change_kind -ne "dependency" -or -not $spec.architecture.changes_dependencies) {
        throw "The bot lane is restricted to declared dependency changes."
    }
}

$requiresAdr = @(
    $spec.architecture.changes_owner_or_dependency_direction,
    $spec.architecture.changes_platform_boundary,
    $spec.architecture.changes_protocol_or_persistence,
    $spec.architecture.changes_unsafe_boundary
) -contains $true
if ($requiresAdr -and @($spec.architecture.adr_paths).Count -eq 0) {
    throw "The declared architecture impact requires at least one ADR path."
}

if ($spec.state -eq "ready" -and @($spec.owner_decisions | Where-Object { $_ -match '^(?i)blocking:' }).Count -gt 0) {
    throw "A ready ChangeSpec cannot retain a blocking owner decision."
}

$outcome = [string]$policy.lanes.($spec.lane).default_outcome
Write-Host "ChangeSpec contract passed: $($spec.change_id) [$($spec.lane)/$($spec.verification.profile)] outcome=$outcome"
if ($PassThru) {
    return [pscustomobject]@{
        Spec = $spec
        Policy = $policy
        Outcome = $outcome
        ChangeSpecPath = [IO.Path]::GetFullPath($ChangeSpecPath)
    }
}
