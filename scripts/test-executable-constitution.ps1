[CmdletBinding()]
param(
    [ValidateSet("all", "contract", "scope", "protected", "adapters")]
    [string]$Suite = "all"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$policyChecker = Join-Path $PSScriptRoot "check-policy.ps1"
$changeSpecChecker = Join-Path $PSScriptRoot "check-change-spec.ps1"
$scopeChecker = Join-Path $PSScriptRoot "check-scope.ps1"
$protectedChecker = Join-Path $PSScriptRoot "check-protected-paths.ps1"
$newChangeGenerator = Join-Path $PSScriptRoot "new-change.ps1"
$commitMessageChecker = Join-Path $PSScriptRoot "check-commit-message.ps1"
$passed = 0
$failed = 0
$contractTaskStartRevision = ""
$repositoryGovernancePolicy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100
$fullProfileName = [string]$repositoryGovernancePolicy.repository_profile
$fullRequiredChecks = @($repositoryGovernancePolicy.checks.profiles.$fullProfileName.required_checks)

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
        [bool]$ChangesDependencies = $false,
        [string]$TaskStartRevision = $(
            if (-not [string]::IsNullOrWhiteSpace($script:contractTaskStartRevision)) {
                $script:contractTaskStartRevision
            }
            else {
                (& git -C $repositoryRoot rev-parse HEAD).Trim()
            }
        ),
        [string[]]$AllowedPaths = @("scripts/**"),
        [string[]]$ForbiddenPaths = @("crates/**"),
        [string[]]$ExpectedCrates = @(),
        [int]$NewCrates = 0,
        [int]$DependencyManifestFiles = 0,
        [int]$NewManifests = 0,
        [int]$ProtectedFiles = $(if ($ProtectedChange) { 10 } else { 0 }),
        [int]$WorkflowFiles = 0
    )

    return [ordered]@{
        schema_version = "0.2"
        change_id = "EC-TEST-CONTRACT"
        title = "Exercise the change contract"
        state = "ready"
        lane = $Lane
        change_kind = if ($Lane -eq "governance") { "governance" } elseif ($Lane -eq "bot") { "dependency" } else { "fix" }
        task_start_revision = $TaskStartRevision
        intent = [ordered]@{
            outcome = "The validator accepts only a closed, reviewable change contract."
            recovery = "Reject invalid input without modifying repository state."
        }
        scope = [ordered]@{
            allowed_paths = $AllowedPaths
            forbidden_paths = $ForbiddenPaths
            expected_crates = $ExpectedCrates
        }
        budgets = [ordered]@{
            new_crates = $NewCrates
            dependency_manifest_files = $DependencyManifestFiles
            new_manifests = $NewManifests
            new_unsafe_boundaries = 0
            protected_files = $ProtectedFiles
            workflow_files = $WorkflowFiles
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

function Invoke-FixtureGit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture Git command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return $output
}

if ($Suite -in @("all", "contract")) {
    Invoke-PolicyCase "repository governance policy is structurally valid" {
        & $policyChecker
    }

    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("gpui-contract-" + [Guid]::NewGuid().ToString("N"))
    try {
        foreach ($directory in @(".agentinfra\changes", ".agentinfra\schemas")) {
            New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Destination (Join-Path $fixtureRoot ".agentinfra\policy.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\policy.schema.json") -Destination (Join-Path $fixtureRoot ".agentinfra\schemas\policy.schema.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\change-spec.schema.json") -Destination (Join-Path $fixtureRoot ".agentinfra\schemas\change-spec.schema.json")
        $null = Invoke-FixtureGit -Root $fixtureRoot -Arguments @("init", "--quiet")
        $null = Invoke-FixtureGit -Root $fixtureRoot -Arguments @("config", "user.name", "Executable Constitution Tests")
        $null = Invoke-FixtureGit -Root $fixtureRoot -Arguments @("config", "user.email", "ec-tests@example.invalid")
        $null = Invoke-FixtureGit -Root $fixtureRoot -Arguments @("config", "core.autocrlf", "false")
        $null = Invoke-FixtureGit -Root $fixtureRoot -Arguments @("add", ".")
        $null = Invoke-FixtureGit -Root $fixtureRoot -Arguments @("commit", "--quiet", "-m", "test: contract baseline")
        $script:contractTaskStartRevision = @(Invoke-FixtureGit -Root $fixtureRoot -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()

        $specPath = Join-Path $fixtureRoot ".agentinfra\changes\EC-TEST-CONTRACT.json"
        $transientContractSpecPath = "$fixtureRoot-focused.json"
        $policyFixturePath = Join-Path $fixtureRoot "policy.json"

        Invoke-PolicyCase "governance policy cannot carry arbitrary commands" {
            $policy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $policy | Add-Member -NotePropertyName "commands" -NotePropertyValue @("untrusted")
            Write-FixtureJson -Path $policyFixturePath -Value $policy
            Assert-PolicyRejected {
                & $policyChecker -RepositoryRoot $fixtureRoot -PolicyPath $policyFixturePath
            } "schema|additional|commands"
        }

        Invoke-PolicyCase "protected path group identifiers are unique" {
            $policy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $policy.protected_paths = @($policy.protected_paths) + @($policy.protected_paths[0])
            Write-FixtureJson -Path $policyFixturePath -Value $policy
            Assert-PolicyRejected {
                & $policyChecker -RepositoryRoot $fixtureRoot -PolicyPath $policyFixturePath
            } "duplicate protected path group"
        }

        Invoke-PolicyCase "valid governance ChangeSpec is review-required" {
            Write-FixtureJson -Path $specPath -Value (New-ChangeSpecFixture)
            $result = & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $fixtureRoot -PassThru
            if ($result.Outcome -ne "review_required") {
                throw "Governance ChangeSpec returned '$($result.Outcome)' instead of review_required."
            }
        }

        Invoke-PolicyCase "ChangeSpec cannot carry arbitrary commands" {
            $spec = New-ChangeSpecFixture
            $spec.commands = @("Invoke-Expression 'untrusted'")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $fixtureRoot
            } "schema|additional|commands"
        }

        Invoke-PolicyCase "focused ChangeSpec rejects dependency impact" {
            $spec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -ChangesDependencies $true
            Write-FixtureJson -Path $transientContractSpecPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $transientContractSpecPath -RepositoryRoot $fixtureRoot
            } "focused.*dependency|dependency.*focused"
        }

        Invoke-PolicyCase "ChangeSpec required checks match its profile" {
            $spec = New-ChangeSpecFixture -RequiredChecks @("change-spec")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $fixtureRoot
            } "required checks|profile"
        }

        Invoke-PolicyCase "ChangeSpec paths reject escape and root catch-all forms" {
            foreach ($invalidPath in @("../escape", "C:\absolute", "\\server\share", "**/*")) {
                $spec = New-ChangeSpecFixture
                $spec.scope.allowed_paths = @($invalidPath)
                Write-FixtureJson -Path $specPath -Value $spec
                Assert-PolicyRejected {
                    & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $fixtureRoot
                } "relative|parent-directory|catch-all|absolute|drive|UNC|device"
            }
        }

        Invoke-PolicyCase "transient lane cannot persist its ChangeSpec in the repository" {
            $spec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $specPath -RepositoryRoot $fixtureRoot
            } "transient.*outside|outside.*transient"
        }

        Invoke-PolicyCase "committed lane requires the repository ChangeSpec directory" {
            Write-FixtureJson -Path $transientContractSpecPath -Value (New-ChangeSpecFixture)
            Assert-PolicyRejected {
                & $changeSpecChecker -ChangeSpecPath $transientContractSpecPath -RepositoryRoot $fixtureRoot
            } "committed.*\.agentinfra/changes|\.agentinfra/changes.*committed"
        }
    }
    finally {
        $script:contractTaskStartRevision = ""
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
        if ($null -ne $transientContractSpecPath -and (Test-Path -LiteralPath $transientContractSpecPath)) {
            Remove-Item -LiteralPath $transientContractSpecPath -Force
        }
    }
}

if ($Suite -in @("all", "scope")) {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $scopeRoot = [IO.Path]::GetFullPath((Join-Path $tempBase ("gpui-scope-" + [Guid]::NewGuid().ToString("N"))))
    $scopeSpecPath = $null
    try {
        New-Item -ItemType Directory -Path $scopeRoot | Out-Null
        foreach ($directory in @(".agentinfra\changes", ".agentinfra\schemas", "src", "other")) {
            New-Item -ItemType Directory -Path (Join-Path $scopeRoot $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Destination (Join-Path $scopeRoot ".agentinfra\policy.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\policy.schema.json") -Destination (Join-Path $scopeRoot ".agentinfra\schemas\policy.schema.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\change-spec.schema.json") -Destination (Join-Path $scopeRoot ".agentinfra\schemas\change-spec.schema.json")
        foreach ($fixtureFile in @("allowed", "delete", "rename", "move-out", "copy-source")) {
            [IO.File]::WriteAllText(
                (Join-Path $scopeRoot "src\$fixtureFile.txt"),
                "$fixtureFile baseline`n",
                [Text.UTF8Encoding]::new($false)
            )
        }
        [IO.File]::WriteAllText(
            (Join-Path $scopeRoot "Cargo.toml"),
            "[workspace]`nmembers = []`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText((Join-Path $scopeRoot "other\blocked.txt"), "blocked baseline`n", [Text.UTF8Encoding]::new($false))

        $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("init", "--quiet")
        $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("config", "user.name", "Executable Constitution Tests")
        $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("config", "user.email", "ec-tests@example.invalid")
        $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("config", "core.autocrlf", "false")
        $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("add", ".")
        $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("commit", "--quiet", "-m", "test: baseline")
        $scopeBase = @(Invoke-FixtureGit -Root $scopeRoot -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
        $scopeSpecPath = Join-Path $tempBase ("gpui-scope-spec-" + [Guid]::NewGuid().ToString("N") + ".json")
        $scopeCommittedSpecPath = Join-Path $scopeRoot ".agentinfra\changes\EC-TEST-SCOPE.json"

        Invoke-PolicyCase "allowed modified path passes scope" {
            $spec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $scopeBase `
                -AllowedPaths @("src/**") `
                -ForbiddenPaths @("other/**")
            Write-FixtureJson -Path $scopeSpecPath -Value $spec
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\allowed.txt"), "changed`n", [Text.UTF8Encoding]::new($false))
            & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "allowed added path passes scope" {
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\added.txt"), "added`n", [Text.UTF8Encoding]::new($false))
            & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "allowed deleted path passes scope" {
            Remove-Item -LiteralPath (Join-Path $scopeRoot "src\delete.txt")
            & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "rename endpoints inside scope pass" {
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("mv", "src/rename.txt", "src/renamed.txt")
            & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "rename destination outside scope is rejected" {
            try {
                $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("mv", "src/move-out.txt", "other/moved.txt")
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
                } "other/moved\.txt|forbidden|outside"
            }
            finally {
                if (Test-Path -LiteralPath (Join-Path $scopeRoot "other\moved.txt")) {
                    $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("mv", "other/moved.txt", "src/move-out.txt")
                }
            }
        }

        Invoke-PolicyCase "copy endpoints inside scope are reported" {
            Copy-Item -LiteralPath (Join-Path $scopeRoot "src\copy-source.txt") -Destination (Join-Path $scopeRoot "src\copied.txt")
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("add", "src/copied.txt")
            $result = & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            $copyPaths = @($result.Changes | Where-Object { $_.Path -in @("src/copy-source.txt", "src/copied.txt") })
            if ($copyPaths.Count -ne 2) {
                throw "Expected both copy endpoints; got: $(@($result.Changes.Path) -join ', ')"
            }
        }

        Invoke-PolicyCase "copy destination outside scope is rejected" {
            $outsideCopy = Join-Path $scopeRoot "other\copied.txt"
            try {
                Copy-Item -LiteralPath (Join-Path $scopeRoot "src\copy-source.txt") -Destination $outsideCopy
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
                } "other/copied\.txt|forbidden|outside"
            }
            finally {
                if (Test-Path -LiteralPath $outsideCopy) {
                    Remove-Item -LiteralPath $outsideCopy
                }
            }
        }

        Invoke-PolicyCase "untracked path outside scope is rejected" {
            $outsideUntracked = Join-Path $scopeRoot "other\untracked.txt"
            try {
                [IO.File]::WriteAllText($outsideUntracked, "untracked`n", [Text.UTF8Encoding]::new($false))
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
                } "other/untracked\.txt|forbidden|outside"
            }
            finally {
                if (Test-Path -LiteralPath $outsideUntracked) {
                    Remove-Item -LiteralPath $outsideUntracked
                }
            }
        }

        Invoke-PolicyCase "staged and unstaged paths are both reported" {
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\staged.txt"), "staged`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("add", "src/staged.txt")
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\allowed.txt"), "unstaged again`n", [Text.UTF8Encoding]::new($false))
            $result = & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            $staged = @($result.Changes | Where-Object { $_.Path -eq "src/staged.txt" -and "staged" -in $_.Sources })
            $unstaged = @($result.Changes | Where-Object { $_.Path -eq "src/allowed.txt" -and "working" -in $_.Sources })
            if ($staged.Count -ne 1 -or $unstaged.Count -ne 1) {
                throw "Expected distinct staged and working-tree evidence."
            }
        }

        Invoke-PolicyCase "scope matching is Windows-case-insensitive" {
            $caseSpec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $scopeBase `
                -AllowedPaths @("SRC/**") `
                -ForbiddenPaths @("OTHER/**")
            Write-FixtureJson -Path $scopeSpecPath -Value $caseSpec
            & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "changed crate must be declared in expected_crates" {
            $unexpectedCrate = Join-Path $scopeRoot "crates\unexpected"
            try {
                New-Item -ItemType Directory -Path (Join-Path $unexpectedCrate "src") -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $unexpectedCrate "src\lib.rs"), "pub fn unexpected() {}`n", [Text.UTF8Encoding]::new($false))
                $crateSpec = New-ChangeSpecFixture `
                    -Lane "focused" `
                    -Profile "focused" `
                    -RequiredChecks @("change-spec", "scope", "protected-paths") `
                    -ProtectedChange $false `
                    -TaskStartRevision $scopeBase `
                    -AllowedPaths @("src/**", "crates/**") `
                    -ForbiddenPaths @("other/**")
                Write-FixtureJson -Path $scopeSpecPath -Value $crateSpec
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
                } "unexpected|expected_crates"
            }
            finally {
                if (Test-Path -LiteralPath $unexpectedCrate) {
                    Remove-Item -LiteralPath $unexpectedCrate -Recurse -Force
                }
            }
        }

        Invoke-PolicyCase "new crate cannot exceed a zero expansion budget" {
            $newCrate = Join-Path $scopeRoot "crates\new-crate"
            try {
                New-Item -ItemType Directory -Path $newCrate -Force | Out-Null
                [IO.File]::WriteAllText(
                    (Join-Path $newCrate "Cargo.toml"),
                    "[package]`nname = `"new-crate`"`nversion = `"0.1.0`"`n",
                    [Text.UTF8Encoding]::new($false)
                )
                $budgetSpec = New-ChangeSpecFixture `
                    -Lane "full" `
                    -Profile $fullProfileName `
                    -RequiredChecks $fullRequiredChecks `
                    -ProtectedChange $false `
                    -ChangesDependencies $true `
                    -TaskStartRevision $scopeBase `
                    -AllowedPaths @("src/**", "crates/**") `
                    -ForbiddenPaths @("other/**") `
                    -ExpectedCrates @("new-crate")
                Write-FixtureJson -Path $scopeCommittedSpecPath -Value $budgetSpec
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot
                } "new_crates|budget"
            }
            finally {
                if (Test-Path -LiteralPath $newCrate) {
                    Remove-Item -LiteralPath $newCrate -Recurse -Force
                }
            }
        }

        Invoke-PolicyCase "dependency manifest cannot exceed a zero file budget" {
            [IO.File]::WriteAllText(
                (Join-Path $scopeRoot "Cargo.toml"),
                "[workspace]`nmembers = []`nresolver = `"2`"`n",
                [Text.UTF8Encoding]::new($false)
            )
            $dependencySpec = New-ChangeSpecFixture `
                -Lane "full" `
                -Profile $fullProfileName `
                -RequiredChecks $fullRequiredChecks `
                -ProtectedChange $false `
                -ChangesDependencies $true `
                -TaskStartRevision $scopeBase `
                -AllowedPaths @("Cargo.toml", "src/**") `
                -ForbiddenPaths @("other/**")
            Write-FixtureJson -Path $scopeCommittedSpecPath -Value $dependencySpec
            Assert-PolicyRejected {
                & $scopeChecker -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot
            } "dependency_manifest_files|budget"
        }

        Invoke-PolicyCase "declared dependency manifest budget passes" {
            $dependencySpec = New-ChangeSpecFixture `
                -Lane "full" `
                -Profile $fullProfileName `
                -RequiredChecks $fullRequiredChecks `
                -ProtectedChange $false `
                -ChangesDependencies $true `
                -TaskStartRevision $scopeBase `
                -AllowedPaths @("Cargo.toml", "src/**") `
                -ForbiddenPaths @("other/**") `
                -DependencyManifestFiles 1
            Write-FixtureJson -Path $scopeCommittedSpecPath -Value $dependencySpec
            $result = & $scopeChecker -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -PassThru
            if ($result.ActualBudgets.dependency_manifest_files -ne 1) {
                throw "Expected one changed dependency manifest, got $($result.ActualBudgets.dependency_manifest_files)."
            }
        }

        Invoke-PolicyCase "new manifest cannot exceed a zero expansion budget" {
            $newManifestDirectory = Join-Path $scopeRoot "tools\extra"
            try {
                New-Item -ItemType Directory -Path $newManifestDirectory -Force | Out-Null
                [IO.File]::WriteAllText(
                    (Join-Path $newManifestDirectory "Cargo.toml"),
                    "[package]`nname = `"extra`"`nversion = `"0.1.0`"`n",
                    [Text.UTF8Encoding]::new($false)
                )
                $manifestSpec = New-ChangeSpecFixture `
                    -Lane "full" `
                    -Profile $fullProfileName `
                    -RequiredChecks $fullRequiredChecks `
                    -ProtectedChange $false `
                    -ChangesDependencies $true `
                    -TaskStartRevision $scopeBase `
                    -AllowedPaths @("Cargo.toml", "src/**", "tools/**") `
                    -ForbiddenPaths @("other/**") `
                    -DependencyManifestFiles 1
                Write-FixtureJson -Path $scopeCommittedSpecPath -Value $manifestSpec
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot
                } "new_manifests|budget"
            }
            finally {
                if (Test-Path -LiteralPath (Join-Path $scopeRoot "tools")) {
                    Remove-Item -LiteralPath (Join-Path $scopeRoot "tools") -Recurse -Force
                }
            }
        }

        Invoke-PolicyCase "workflow file cannot exceed a zero expansion budget" {
            $workflowDirectory = Join-Path $scopeRoot ".github\workflows"
            try {
                New-Item -ItemType Directory -Path $workflowDirectory -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $workflowDirectory "new.yml"), "name: fixture`n", [Text.UTF8Encoding]::new($false))
                $workflowSpec = New-ChangeSpecFixture `
                    -ChangesDependencies $true `
                    -TaskStartRevision $scopeBase `
                    -AllowedPaths @("Cargo.toml", "src/**", ".github/workflows/**") `
                    -ForbiddenPaths @("other/**") `
                    -DependencyManifestFiles 1
                Write-FixtureJson -Path $scopeCommittedSpecPath -Value $workflowSpec
                Assert-PolicyRejected {
                    & $scopeChecker -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot
                } "workflow_files|budget"
            }
            finally {
                if (Test-Path -LiteralPath (Join-Path $scopeRoot ".github")) {
                    Remove-Item -LiteralPath (Join-Path $scopeRoot ".github") -Recurse -Force
                }
            }
        }

        Invoke-PolicyCase "bot scope cannot widen beyond dependency policy" {
            $botSpec = New-ChangeSpecFixture `
                -Lane "bot" `
                -Profile "bot" `
                -RequiredChecks @("change-spec", "scope", "protected-paths", "repository-full-gate") `
                -ProtectedChange $false `
                -ChangesDependencies $true `
                -TaskStartRevision $scopeBase `
                -AllowedPaths @("Cargo.toml", "src/**") `
                -ForbiddenPaths @("other/**") `
                -DependencyManifestFiles 1
            Write-FixtureJson -Path $scopeSpecPath -Value $botSpec
            Assert-PolicyRejected {
                & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
            } "Bot path 'src/|bot.*dependency policy|dependency policy.*src/"
        }

        Invoke-PolicyCase "bot scope permits only declared dependency files" {
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("add", "--all")
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("commit", "--quiet", "-m", "test: prepare bot baseline")
            $botBase = @(Invoke-FixtureGit -Root $scopeRoot -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            [IO.File]::WriteAllText(
                (Join-Path $scopeRoot "Cargo.toml"),
                "[workspace]`nmembers = []`nresolver = `"2`"`nexclude = []`n",
                [Text.UTF8Encoding]::new($false)
            )
            $botSpec = New-ChangeSpecFixture `
                -Lane "bot" `
                -Profile "bot" `
                -RequiredChecks @("change-spec", "scope", "protected-paths", "repository-full-gate") `
                -ProtectedChange $false `
                -ChangesDependencies $true `
                -TaskStartRevision $botBase `
                -AllowedPaths @("Cargo.toml") `
                -ForbiddenPaths @("src/**", ".github/workflows/**") `
                -DependencyManifestFiles 1
            Write-FixtureJson -Path $scopeSpecPath -Value $botSpec
            & $scopeChecker -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }
    }
    finally {
        if (Test-Path -LiteralPath $scopeRoot) {
            $resolvedScopeRoot = (Resolve-Path -LiteralPath $scopeRoot).Path
            if (-not $resolvedScopeRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove scope fixture outside the system temporary directory: $resolvedScopeRoot"
            }
            Remove-Item -LiteralPath $resolvedScopeRoot -Recurse -Force
        }
        if ($null -ne $scopeSpecPath -and (Test-Path -LiteralPath $scopeSpecPath)) {
            Remove-Item -LiteralPath $scopeSpecPath -Force
        }
    }
}

if ($Suite -in @("all", "protected")) {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $protectedRoot = [IO.Path]::GetFullPath((Join-Path $tempBase ("gpui-protected-" + [Guid]::NewGuid().ToString("N"))))
    $protectedSpecPath = $null
    try {
        foreach ($directory in @(".agentinfra\changes", ".agentinfra\schemas", ".github\workflows", "scripts")) {
            New-Item -ItemType Directory -Path (Join-Path $protectedRoot $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Destination (Join-Path $protectedRoot ".agentinfra\policy.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\policy.schema.json") -Destination (Join-Path $protectedRoot ".agentinfra\schemas\policy.schema.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\change-spec.schema.json") -Destination (Join-Path $protectedRoot ".agentinfra\schemas\change-spec.schema.json")
        [IO.File]::WriteAllText((Join-Path $protectedRoot "scripts\check.ps1"), "Write-Host 'baseline'`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $protectedRoot ".github\workflows\ci.yml"), "name: baseline`n", [Text.UTF8Encoding]::new($false))

        $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("init", "--quiet")
        $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("config", "user.name", "Executable Constitution Tests")
        $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("config", "user.email", "ec-tests@example.invalid")
        $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("config", "core.autocrlf", "false")
        $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("add", ".")
        $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("commit", "--quiet", "-m", "test: protected baseline")
        $protectedBase = @(Invoke-FixtureGit -Root $protectedRoot -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
        $protectedSpecPath = Join-Path $tempBase ("gpui-protected-spec-" + [Guid]::NewGuid().ToString("N") + ".json")
        $protectedCommittedSpecPath = Join-Path $protectedRoot ".agentinfra\changes\EC-TEST-PROTECTED.json"

        Invoke-PolicyCase "focused lane cannot change an acceptance control" {
            $spec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1") `
                -ForbiddenPaths @("src/**")
            Write-FixtureJson -Path $protectedSpecPath -Value $spec
            [IO.File]::WriteAllText((Join-Path $protectedRoot "scripts\check.ps1"), "Write-Host 'changed'`n", [Text.UTF8Encoding]::new($false))
            Assert-PolicyRejected {
                & $protectedChecker -ChangeSpecPath $protectedSpecPath -RepositoryRoot $protectedRoot
            } "Protected path 'scripts/check\.ps1'.*acceptance-controls.*governance"
        }

        Invoke-PolicyCase "full lane cannot change an acceptance control" {
            $spec = New-ChangeSpecFixture `
                -Lane "full" `
                -Profile $fullProfileName `
                -RequiredChecks $fullRequiredChecks `
                -ProtectedChange $false `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 1
            Write-FixtureJson -Path $protectedCommittedSpecPath -Value $spec
            Assert-PolicyRejected {
                & $protectedChecker -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot
            } "Protected path 'scripts/check\.ps1'.*acceptance-controls.*governance"
        }

        Invoke-PolicyCase "governance protected change remains review-required" {
            $spec = New-ChangeSpecFixture `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 1
            Write-FixtureJson -Path $protectedCommittedSpecPath -Value $spec
            $result = & $protectedChecker -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -PassThru
            if ($result.Outcome -ne "review_required") {
                throw "Expected review_required, got '$($result.Outcome)'."
            }
            if (@($result.Matches | Where-Object { $_.GroupId -eq "acceptance-controls" }).Count -ne 1) {
                throw "Expected scripts/check.ps1 to be classified as acceptance-controls."
            }
        }

        Invoke-PolicyCase "hosted workflow is classified as remote trust" {
            [IO.File]::WriteAllText((Join-Path $protectedRoot ".github\workflows\ci.yml"), "name: changed fixture`n", [Text.UTF8Encoding]::new($false))
            $spec = New-ChangeSpecFixture `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1", ".github/workflows/**") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 2 `
                -WorkflowFiles 1
            Write-FixtureJson -Path $protectedCommittedSpecPath -Value $spec
            $result = & $protectedChecker -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -PassThru
            $workflowMatches = @($result.Matches | Where-Object {
                $_.Path -eq ".github/workflows/ci.yml" -and $_.GroupId -eq "remote-trust"
            })
            if ($workflowMatches.Count -ne 1 -or $result.Outcome -ne "review_required") {
                throw "Expected one review-required remote-trust classification for the hosted workflow."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $protectedRoot) {
            $resolvedProtectedRoot = (Resolve-Path -LiteralPath $protectedRoot).Path
            if (-not $resolvedProtectedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove protected-path fixture outside the system temporary directory: $resolvedProtectedRoot"
            }
            Remove-Item -LiteralPath $resolvedProtectedRoot -Recurse -Force
        }
        if ($null -ne $protectedSpecPath -and (Test-Path -LiteralPath $protectedSpecPath)) {
            Remove-Item -LiteralPath $protectedSpecPath -Force
        }
    }
}

if ($Suite -in @("all", "adapters")) {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $adapterRoot = [IO.Path]::GetFullPath((Join-Path $tempBase ("gpui-adapters-" + [Guid]::NewGuid().ToString("N"))))
    try {
        foreach ($directory in @(".agentinfra\changes", ".agentinfra\schemas", "src")) {
            New-Item -ItemType Directory -Path (Join-Path $adapterRoot $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Destination (Join-Path $adapterRoot ".agentinfra\policy.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\policy.schema.json") -Destination (Join-Path $adapterRoot ".agentinfra\schemas\policy.schema.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\change-spec.schema.json") -Destination (Join-Path $adapterRoot ".agentinfra\schemas\change-spec.schema.json")
        [IO.File]::WriteAllText((Join-Path $adapterRoot "src\lib.rs"), "pub fn fixture() {}`n", [Text.UTF8Encoding]::new($false))

        $null = Invoke-FixtureGit -Root $adapterRoot -Arguments @("init", "--quiet")
        $null = Invoke-FixtureGit -Root $adapterRoot -Arguments @("config", "user.name", "Executable Constitution Tests")
        $null = Invoke-FixtureGit -Root $adapterRoot -Arguments @("config", "user.email", "ec-tests@example.invalid")
        $null = Invoke-FixtureGit -Root $adapterRoot -Arguments @("config", "core.autocrlf", "false")
        $null = Invoke-FixtureGit -Root $adapterRoot -Arguments @("add", ".")
        $null = Invoke-FixtureGit -Root $adapterRoot -Arguments @("commit", "--quiet", "-m", "test: adapter baseline")

        Invoke-PolicyCase "full ChangeSpec generator uses committed repository profile" {
            $result = & $newChangeGenerator `
                -ChangeId "EC-ADAPTER-FULL" `
                -Title "Exercise the full adapter" `
                -Lane "full" `
                -ChangeKind "feature" `
                -Outcome "Produce a closed draft for a full template change." `
                -Recovery "Delete the draft before implementation." `
                -AllowedPaths @("src/**") `
                -Exclusions @("No dependency or platform changes.") `
                -RepositoryRoot $adapterRoot `
                -PassThru
            $expectedPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot ".agentinfra\changes\EC-ADAPTER-FULL.json"))
            if ($result.Path -ne $expectedPath -or $result.Spec.state -ne "draft" -or $result.Spec.verification.profile -ne $fullProfileName) {
                throw "Full generator did not produce the expected committed repository-profile draft."
            }
            & $changeSpecChecker -ChangeSpecPath $result.Path -RepositoryRoot $adapterRoot -AllowDraft | Out-Null
        }

        Invoke-PolicyCase "focused ChangeSpec generator uses transient location" {
            $result = $null
            try {
                $result = & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-FOCUSED" `
                    -Title "Exercise the focused adapter" `
                    -Lane "focused" `
                    -ChangeKind "fix" `
                    -Outcome "Produce a transient focused draft." `
                    -Recovery "Delete the transient draft." `
                    -AllowedPaths @("src/lib.rs") `
                    -Exclusions @("No architecture changes.") `
                    -RepositoryRoot $adapterRoot `
                    -PassThru
                $relative = [IO.Path]::GetRelativePath($adapterRoot, $result.Path).Replace('\', '/')
                if ($relative -ne '..' -and -not $relative.StartsWith('../') -and -not [IO.Path]::IsPathRooted($relative)) {
                    throw "Focused generator persisted its ChangeSpec inside the repository."
                }
                if ($result.Persistence -ne "transient" -or $result.Spec.verification.profile -ne "focused") {
                    throw "Focused generator did not derive transient/focused policy values."
                }
                & $changeSpecChecker -ChangeSpecPath $result.Path -RepositoryRoot $adapterRoot -AllowDraft | Out-Null
            }
            finally {
                if ($null -ne $result -and (Test-Path -LiteralPath $result.Path)) {
                    Remove-Item -LiteralPath $result.Path -Force
                }
            }
        }

        Invoke-PolicyCase "transient generator rejects a repository output path" {
            Assert-PolicyRejected {
                & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-BAD-PATH" `
                    -Title "Reject a persistent focused draft" `
                    -Lane "focused" `
                    -ChangeKind "fix" `
                    -Outcome "Reject the invalid location." `
                    -Recovery "No file should be created." `
                    -AllowedPaths @("src/lib.rs") `
                    -Exclusions @("No implementation changes.") `
                    -OutputPath ".agentinfra/changes/EC-ADAPTER-BAD-PATH.json" `
                    -RepositoryRoot $adapterRoot
            } "transient.*outside|outside.*transient"
        }

        Invoke-PolicyCase "bot ChangeSpec generator derives dependency contract" {
            $result = $null
            try {
                $result = & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-BOT" `
                    -Title "Exercise the bot adapter" `
                    -Lane "bot" `
                    -ChangeKind "dependency" `
                    -Outcome "Produce a constrained dependency draft." `
                    -Recovery "Delete the transient draft." `
                    -AllowedPaths @("Cargo.lock") `
                    -Exclusions @("No source or workflow changes.") `
                    -ChangesDependencies `
                    -RepositoryRoot $adapterRoot `
                    -PassThru
                if ($result.Persistence -ne "transient" -or $result.Spec.verification.profile -ne "bot") {
                    throw "Bot generator did not derive transient/bot policy values."
                }
                & $changeSpecChecker -ChangeSpecPath $result.Path -RepositoryRoot $adapterRoot -AllowDraft | Out-Null
            }
            finally {
                if ($null -ne $result -and (Test-Path -LiteralPath $result.Path)) {
                    Remove-Item -LiteralPath $result.Path -Force
                }
            }
        }

        Invoke-PolicyCase "missing required verification resolves to not_run" {
            Import-Module (Join-Path $repositoryRoot "scripts\lib\ExecutableConstitution.psm1") -Force
            $policy = Get-Content -LiteralPath (Join-Path $adapterRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $result = Resolve-ECVerificationStatus `
                -Policy $policy `
                -RequiredChecks @("scope", "repository-full-gate") `
                -Results @([pscustomobject]@{ check = "scope"; status = "passed" })
            if ($result.Status -ne "not_run" -or $result.Passing) {
                throw "Missing required checks must resolve to a non-passing not_run status."
            }
        }

        Invoke-PolicyCase "only passed verification statuses can pass" {
            Import-Module (Join-Path $repositoryRoot "scripts\lib\ExecutableConstitution.psm1") -Force
            $policy = Get-Content -LiteralPath (Join-Path $adapterRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            foreach ($status in @("failed", "skipped", "environment_failure", "policy_rejected", "review_required")) {
                $result = Resolve-ECVerificationStatus `
                    -Policy $policy `
                    -RequiredChecks @("scope") `
                    -Results @([pscustomobject]@{ check = "scope"; status = $status })
                if ($result.Passing -or $result.Status -ne $status) {
                    throw "Status '$status' was not preserved as a non-passing result."
                }
            }

            $passedResult = Resolve-ECVerificationStatus `
                -Policy $policy `
                -RequiredChecks @("scope", "protected-paths") `
                -Results @(
                    [pscustomobject]@{ check = "scope"; status = "passed" },
                    [pscustomobject]@{ check = "protected-paths"; status = "passed" }
                )
            if (-not $passedResult.Passing -or $passedResult.Status -ne "passed") {
                throw "All required passed checks should resolve to passed."
            }
        }

        Invoke-PolicyCase "governance outcome cannot be promoted by green checks" {
            Import-Module (Join-Path $repositoryRoot "scripts\lib\ExecutableConstitution.psm1") -Force
            $policy = Get-Content -LiteralPath (Join-Path $adapterRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $result = Resolve-ECVerificationStatus `
                -Policy $policy `
                -RequiredChecks @("scope") `
                -Results @([pscustomobject]@{ check = "scope"; status = "passed" }) `
                -ContractOutcome "review_required"
            if ($result.Passing -or $result.Status -ne "review_required") {
                throw "Governance outcome must remain review_required after green checks."
            }
        }

        Invoke-PolicyCase "dependency bot message requires explicit bot mode" {
            $botMessage = "Bump serde from 1.0.203 to 1.0.204"
            Assert-PolicyRejected {
                & $commitMessageChecker -Message $botMessage
            } "subject|body|blank line"
            & $commitMessageChecker -Message $botMessage -Bot
        }
    }
    finally {
        if (Test-Path -LiteralPath $adapterRoot) {
            $resolvedAdapterRoot = (Resolve-Path -LiteralPath $adapterRoot).Path
            if (-not $resolvedAdapterRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove adapter fixture outside the system temporary directory: $resolvedAdapterRoot"
            }
            Remove-Item -LiteralPath $resolvedAdapterRoot -Recurse -Force
        }
    }
}

Write-Host "Executable Constitution self-tests: passed=$passed failed=$failed"
if ($failed -gt 0) {
    throw "$failed executable Constitution self-test(s) failed."
}
