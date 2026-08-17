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

Write-Host "Protected path classification passed: $($contract.Spec.change_id) matches=$($matches.Count) outcome=$($contract.Outcome)"
if ($PassThru) {
    return [pscustomobject]@{
        Spec = $contract.Spec
        Policy = $contract.Policy
        Outcome = $contract.Outcome
        Changes = $changes
        Matches = @($matches)
        ChangeSpecPath = $contract.ChangeSpecPath
    }
}
