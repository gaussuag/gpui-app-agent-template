[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TaskStartRevision,
    [string]$HeadRevision = "HEAD",
    [string]$ChangeSpecPath = "",
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
elseif (-not [IO.Path]::IsPathRooted($PolicyPath)) {
    $PolicyPath = Join-Path $root $PolicyPath
}
& (Join-Path $PSScriptRoot "check-policy.ps1") `
    -RepositoryRoot $root `
    -PolicyPath $PolicyPath | Out-Null

$contractArguments = @{
    RepositoryRoot = $root
    TaskStartRevision = $TaskStartRevision
    HeadRevision = $HeadRevision
    PolicyPath = $PolicyPath
    AllowDraft = $AllowDraft
}
if (-not [string]::IsNullOrWhiteSpace($ChangeSpecPath)) {
    $contractArguments.ChangeSpecPath = $ChangeSpecPath
}
$contract = Resolve-ECChangeContract @contractArguments
$changes = @(Get-ECChangedPaths `
    -RepositoryRoot $root `
    -TaskStartRevision $contract.EffectiveTaskStartRevision `
    -HeadRevision $contract.HeadRevision)

$matches = [Collections.Generic.List[object]]::new()
foreach ($change in $changes) {
    foreach ($group in $contract.Policy.protected_paths) {
        $groupMatches = @($group.globs | Where-Object {
            Test-ECRepoGlob -Path $change.Path -Glob $_
        })
        if ($groupMatches.Count -eq 0) {
            continue
        }

        $match = [pscustomobject]@{
            Path = $change.Path
            GroupId = [string]$group.id
            MatchedGlobs = @($groupMatches)
            AllowedLanes = @($group.allowed_lanes)
        }
        $matches.Add($match)
        if ($contract.Spec.lane -notin @($group.allowed_lanes)) {
            throw "Protected path '$($change.Path)' belongs to group '$($group.id)'; lane '$($contract.Spec.lane)' is not allowed. Allowed lanes: $(@($group.allowed_lanes) -join ', ')."
        }
    }
}

if ($matches.Count -gt 0 -and -not $contract.Spec.protected_change) {
    throw "ChangeSpec '$($contract.Spec.change_id)' changes protected paths but protected_change is false."
}

Write-Host "Protected path classification passed: $($contract.Spec.change_id) matches=$($matches.Count) lifecycle=$($contract.Lifecycle) outcome=$($contract.Outcome)"
if ($PassThru) {
    return [pscustomobject]@{
        Spec = $contract.Spec
        Policy = $contract.Policy
        Outcome = $contract.Outcome
        Changes = $changes
        Matches = @($matches)
        ChangeSpecPath = $contract.ChangeSpecPath
        EffectiveTaskStartRevision = $contract.EffectiveTaskStartRevision
        HeadRevision = $contract.HeadRevision
        Lifecycle = $contract.Lifecycle
    }
}
