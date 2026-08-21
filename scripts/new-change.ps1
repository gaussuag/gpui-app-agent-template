[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ChangeId,
    [Parameter(Mandatory = $true)][string]$TaskStartRevision,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][ValidateSet("focused", "full", "governance", "bot")][string]$Lane,
    [Parameter(Mandatory = $true)][ValidateSet("feature", "fix", "dependency", "documentation", "governance")][string]$ChangeKind,
    [Parameter(Mandatory = $true)][string]$Outcome,
    [Parameter(Mandatory = $true)][string]$Recovery,
    [Parameter(Mandatory = $true)][string[]]$AllowedPaths,
    [Parameter(Mandatory = $true)][string[]]$Exclusions,
    [string[]]$ForbiddenPaths = @(),
    [string[]]$ExpectedCrates = @(),
    [string[]]$AdrPaths = @(),
    [string[]]$ResidualRisks = @(),
    [string[]]$OwnerDecisions = @(),
    [ValidateRange(0, [int]::MaxValue)][int]$NewCrates = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$DependencyManifestFiles = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$NewManifests = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$NewUnsafeBoundaries = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$ProtectedFiles = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$WorkflowFiles = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$PublicArchitectureLayers = 0,
    [switch]$ChangesOwnerOrDependencyDirection,
    [switch]$ChangesAsyncOrResourceLifecycle,
    [switch]$ChangesPlatformBoundary,
    [switch]$ChangesDependencies,
    [switch]$ChangesProtocolOrPersistence,
    [switch]$ChangesPrivacyOrSensitiveData,
    [switch]$ChangesUnsafeBoundary,
    [switch]$ChangesPublicArchitectureLayers,
    [string]$OutputPath = "",
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\ExecutableConstitution.psm1") -Force

function Test-IsInsideDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $relative = [IO.Path]::GetRelativePath(
        [IO.Path]::GetFullPath($Directory),
        [IO.Path]::GetFullPath($Candidate)
    ).Replace('\', '/')
    return $relative -ne '..' -and -not $relative.StartsWith('../') -and -not [IO.Path]::IsPathRooted($relative)
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$policyPath = Join-Path $root ".agentinfra\policy.json"
& (Join-Path $PSScriptRoot "check-policy.ps1") -RepositoryRoot $root -PolicyPath $policyPath | Out-Null
$policy = Read-ECJsonFile -Path $policyPath

$profileName = switch ($Lane) {
    "focused" { "focused" }
    "full" { [string]$policy.repository_profile }
    "governance" { "governance" }
    "bot" { "bot" }
}
$profile = $policy.checks.profiles.$profileName
if ($null -eq $profile) {
    throw "Policy does not define verification profile '$profileName'."
}

$taskStartRevision = $TaskStartRevision.Trim()
if ($taskStartRevision -notmatch '^[0-9a-fA-F]{40,64}$') {
    throw "TaskStartRevision must be a full commit id: $TaskStartRevision"
}
& git -C $root cat-file -e "$taskStartRevision^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "TaskStartRevision is not an available commit: $taskStartRevision"
}
$headRevision = @(& git -C $root rev-parse --verify "HEAD^{commit}" 2>$null)
if ($LASTEXITCODE -ne 0 -or $headRevision.Count -ne 1) {
    throw "Unable to resolve repository HEAD while validating TaskStartRevision."
}
$headRevision = $headRevision[0].Trim()
& git -C $root merge-base --is-ancestor $taskStartRevision $headRevision 2>$null
if ($LASTEXITCODE -eq 1) {
    throw "TaskStartRevision '$taskStartRevision' is not an ancestor of HEAD '$headRevision'."
}
if ($LASTEXITCODE -ne 0) {
    throw "Unable to validate TaskStartRevision '$taskStartRevision' against HEAD '$headRevision'."
}

$persistence = [string]$policy.lanes.$Lane.persistence
$committedDirectory = [IO.Path]::GetFullPath((Join-Path $root ".agentinfra\changes"))
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    if ($persistence -eq "committed") {
        $OutputPath = Join-Path $committedDirectory "$ChangeId.json"
    }
    else {
        $transientDirectory = Join-Path ([IO.Path]::GetTempPath()) "gpui-executable-constitution"
        $OutputPath = Join-Path $transientDirectory "$ChangeId-$([Guid]::NewGuid().ToString('N')).json"
    }
}
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $root $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

if ($persistence -eq "committed") {
    if ([IO.Path]::GetDirectoryName($OutputPath) -ne $committedDirectory) {
        throw "Lane '$Lane' requires a committed ChangeSpec directly under .agentinfra/changes."
    }
}
elseif (Test-IsInsideDirectory -Directory $root -Candidate $OutputPath) {
    throw "Lane '$Lane' requires a transient ChangeSpec outside the repository."
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Refusing to overwrite existing ChangeSpec: $OutputPath"
}

$spec = [ordered]@{
    schema_version = "0.2"
    change_id = $ChangeId
    title = $Title
    state = "draft"
    lane = $Lane
    change_kind = $ChangeKind
    task_start_revision = $taskStartRevision
    intent = [ordered]@{
        outcome = $Outcome
        recovery = $Recovery
    }
    scope = [ordered]@{
        allowed_paths = @($AllowedPaths)
        forbidden_paths = @($ForbiddenPaths)
        expected_crates = @($ExpectedCrates)
    }
    budgets = [ordered]@{
        new_crates = $NewCrates
        dependency_manifest_files = $DependencyManifestFiles
        new_manifests = $NewManifests
        new_unsafe_boundaries = $NewUnsafeBoundaries
        protected_files = $ProtectedFiles
        workflow_files = $WorkflowFiles
        public_architecture_layers = $PublicArchitectureLayers
    }
    architecture = [ordered]@{
        changes_owner_or_dependency_direction = [bool]$ChangesOwnerOrDependencyDirection
        changes_async_or_resource_lifecycle = [bool]$ChangesAsyncOrResourceLifecycle
        changes_platform_boundary = [bool]$ChangesPlatformBoundary
        changes_dependencies = [bool]$ChangesDependencies
        changes_protocol_or_persistence = [bool]$ChangesProtocolOrPersistence
        changes_privacy_or_sensitive_data = [bool]$ChangesPrivacyOrSensitiveData
        changes_unsafe_boundary = [bool]$ChangesUnsafeBoundary
        changes_public_architecture_layers = [bool]$ChangesPublicArchitectureLayers
        adr_paths = @($AdrPaths)
    }
    verification = [ordered]@{
        profile = $profileName
        required_checks = @($profile.required_checks)
    }
    protected_change = $Lane -eq "governance"
    residual_risks = @($ResidualRisks)
    owner_decisions = @($OwnerDecisions)
    exclusions = @($Exclusions)
}

$outputDirectory = [IO.Path]::GetDirectoryName($OutputPath)
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
try {
    $json = $spec | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($OutputPath, $json + "`n", [Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot "check-change-spec.ps1") `
        -TaskStartRevision $taskStartRevision `
        -ChangeSpecPath $OutputPath `
        -RepositoryRoot $root `
        -PolicyPath $policyPath `
        -AllowDraft | Out-Null
}
catch {
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    throw
}

$generated = Read-ECJsonFile -Path $OutputPath
Write-Host "Created $Lane ChangeSpec draft: $OutputPath"
if ($PassThru) {
    return [pscustomobject]@{
        Path = $OutputPath
        Persistence = $persistence
        TaskStartRevision = $taskStartRevision
        Spec = $generated
    }
}
