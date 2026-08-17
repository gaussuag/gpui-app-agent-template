[CmdletBinding()]
param(
    [ValidateSet("all", "contract", "scope", "protected", "adapters")]
    [string]$Suite = "all"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$policyChecker = Join-Path $PSScriptRoot "check-policy.ps1"
$changeSpecChecker = Join-Path $PSScriptRoot "check-change-spec.ps1"
$passed = 0
$failed = 0

function Invoke-PolicyCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host "==> $Name"
    try {
        & $Action
        $script:passed++
        Write-Host "PASS: $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL: $Name`n$($_ | Out-String)"
    }
}

function Assert-PolicyRejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $rejected = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $rejected = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected rejection matching '$Pattern', got: $($_.Exception.Message)"
        }
    }
    if (-not $rejected) {
        throw "Expected policy rejection matching '$Pattern'."
    }
}

function Write-FixtureJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function New-ChangeSpecFixture {
    param(
        [string]$Lane = "governance",
        [string]$Profile = "governance",
        [string[]]$RequiredChecks = @(
            "change-spec",
            "scope",
            "protected-paths",
            "policy",
            "executable-constitution-self-tests",
            "repository-full-gate"
        ),
        [bool]$ProtectedChange = $true,
        [bool]$ChangesDependencies = $false
    )

    return [ordered]@{
        schema_version = "0.2"
        change_id = "EC-TEST-CONTRACT"
        title = "Exercise the change contract"
        state = "ready"
        lane = $Lane
        change_kind = if ($Lane -eq "governance") { "governance" } elseif ($Lane -eq "bot") { "dependency" } else { "fix" }
        task_start_revision = (& git -C $repositoryRoot rev-parse HEAD).Trim()
        intent = [ordered]@{
            outcome = "The validator accepts only a closed, reviewable change contract."
            recovery = "Reject invalid input without modifying repository state."
        }
        scope = [ordered]@{
            allowed_paths = @("scripts/**")
            forbidden_paths = @("crates/**")
            expected_crates = @()
        }
        budgets = [ordered]@{
            new_crates = 0
            dependency_manifest_files = 0
            new_manifests = 0
            new_unsafe_boundaries = 0
            protected_files = if ($ProtectedChange) { 10 } else { 0 }
            workflow_files = 0
            public_architecture_layers = 0
        }
        architecture = [ordered]@{
            changes_owner_or_dependency_direction = $false
            changes_async_or_resource_lifecycle = $false
            changes_platform_boundary = $false
            changes_dependencies = $ChangesDependencies
            changes_protocol_or_persistence = $false
            changes_privacy_or_sensitive_data = $false
            changes_unsafe_boundary = $false
            changes_public_architecture_layers = $false
            adr_paths = @()
        }
        verification = [ordered]@{
            profile = $Profile
            required_checks = $RequiredChecks
        }
        protected_change = $ProtectedChange
        residual_risks = @("Remote trust is outside this fixture.")
        owner_decisions = @()
        exclusions = @("No product code changes.")
    }
}

if ($Suite -in @("all", "contract")) {
    Invoke-PolicyCase "repository governance policy is structurally valid" {
        & $policyChecker
    }

    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("gpui-contract-" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $specPath = Join-Path $fixtureRoot "change-spec.json"
        $policyFixturePath = Join-Path $fixtureRoot "policy.json"

        Invoke-PolicyCase "governance policy cannot carry arbitrary commands" {
            $policy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $policy | Add-Member -NotePropertyName "commands" -NotePropertyValue @("untrusted")
            Write-FixtureJson -Path $policyFixturePath -Value $policy
            Assert-PolicyRejected {
                & $policyChecker -RepositoryRoot $repositoryRoot -PolicyPath $policyFixturePath
            } "schema|additional|commands"
        }

        Invoke-PolicyCase "protected path group identifiers are unique" {
            $policy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $policy.protected_paths = @($policy.protected_paths) + @($policy.protected_paths[0])
            Write-FixtureJson -Path $policyFixturePath -Value $policy
            Assert-PolicyRejected {
                & $policyChecker -RepositoryRoot $repositoryRoot -PolicyPath $policyFixturePath
            } "duplicate protected path group"
        }

        Invoke-PolicyCase "valid governance ChangeSpec is review-required" {
            Write-FixtureJson -Path $specPath -Value (New-ChangeSpecFixture)
            $result = & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $repositoryRoot -PassThru
            if ($result.Outcome -ne "review_required") {
                throw "Governance ChangeSpec returned '$($result.Outcome)' instead of review_required."
            }
        }

        Invoke-PolicyCase "ChangeSpec cannot carry arbitrary commands" {
            $spec = New-ChangeSpecFixture
            $spec.commands = @("Invoke-Expression 'untrusted'")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $repositoryRoot
            } "schema|additional|commands"
        }

        Invoke-PolicyCase "focused ChangeSpec rejects dependency impact" {
            $spec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -ChangesDependencies $true
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $repositoryRoot
            } "focused.*dependency|dependency.*focused"
        }

        Invoke-PolicyCase "ChangeSpec required checks match its profile" {
            $spec = New-ChangeSpecFixture -RequiredChecks @("change-spec")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $repositoryRoot
            } "required checks|profile"
        }
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
}

Write-Host "Executable Constitution self-tests: passed=$passed failed=$failed"
if ($failed -gt 0) {
    throw "$failed executable Constitution self-test(s) failed."
}
