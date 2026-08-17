[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PolicyPath = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\ExecutableConstitution.psm1") -Force

$root = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $root ".agentinfra\policy.json"
}
$schemaPath = Join-Path $root ".agentinfra\schemas\policy.schema.json"

foreach ($path in @($PolicyPath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Governance policy input is missing: $path"
    }
}

try {
    $schemaResult = Test-Json -LiteralPath $PolicyPath -SchemaFile $schemaPath -ErrorAction Stop
}
catch {
    throw "Governance policy does not match its schema: $($_.Exception.Message)"
}
if (-not $schemaResult) {
    throw "Governance policy does not match its schema."
}

$policy = Read-ECJsonFile -Path $PolicyPath
$registeredChecks = @($policy.checks.registry)
foreach ($profileProperty in $policy.checks.profiles.PSObject.Properties) {
    foreach ($check in @($profileProperty.Value.required_checks)) {
        if ($check -notin $registeredChecks) {
            throw "Verification profile '$($profileProperty.Name)' references unregistered check '$check'."
        }
    }
}

$duplicateProtectedGroup = @($policy.protected_paths |
    Group-Object -Property id |
    Where-Object { $_.Count -gt 1 } |
    Select-Object -First 1)
if ($duplicateProtectedGroup.Count -gt 0) {
    throw "Governance policy contains duplicate protected path group '$($duplicateProtectedGroup[0].Name)'."
}

foreach ($group in @($policy.protected_paths)) {
    foreach ($glob in @($group.globs)) {
        $null = ConvertTo-ECNormalizedRepoPath -Path $glob -AllowGlob
    }
}
foreach ($property in $policy.budget_indicators.PSObject.Properties) {
    foreach ($glob in @($property.Value)) {
        $null = ConvertTo-ECNormalizedRepoPath -Path $glob -AllowGlob
    }
}
foreach ($property in $policy.bot.PSObject.Properties) {
    foreach ($glob in @($property.Value)) {
        $null = ConvertTo-ECNormalizedRepoPath -Path $glob -AllowGlob
    }
}

if ($policy.lanes.governance.default_outcome -ne "review_required") {
    throw "The governance lane must always default to review_required."
}
if (@($policy.passing_statuses).Count -ne 1 -or $policy.passing_statuses[0] -ne "passed") {
    throw "Only the literal 'passed' status may satisfy a required check."
}

Write-Host "Executable Constitution policy passed schema and semantic checks ($($policy.repository_profile))."
