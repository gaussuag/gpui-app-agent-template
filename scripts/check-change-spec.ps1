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

$resolveArguments = @{
    RepositoryRoot = $root
    TaskStartRevision = $TaskStartRevision
    HeadRevision = $HeadRevision
    PolicyPath = $PolicyPath
    AllowDraft = $AllowDraft
}
if (-not [string]::IsNullOrWhiteSpace($ChangeSpecPath)) {
    $resolveArguments.ChangeSpecPath = $ChangeSpecPath
}
$contract = Resolve-ECChangeContract @resolveArguments

Write-Host "ChangeSpec contract passed: $($contract.Spec.change_id) [$($contract.Spec.lane)/$($contract.Spec.verification.profile)] lifecycle=$($contract.Lifecycle) outcome=$($contract.Outcome)"
if ($PassThru) {
    return $contract
}
