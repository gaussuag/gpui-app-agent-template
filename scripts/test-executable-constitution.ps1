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
        [string]$ChangeId = "EC-TEST-CONTRACT",
        [ValidateSet("draft", "ready")][string]$State = "ready",
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
        change_id = $ChangeId
        title = "Exercise the change contract"
        state = $State
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

function Remove-ECContractFixture {
    param([Parameter(Mandatory = $true)]$Fixture)

    if (-not (Test-Path -LiteralPath $Fixture.Root)) {
        return
    }

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedRoot = (Resolve-Path -LiteralPath $Fixture.Root).Path
    $leaf = [IO.Path]::GetFileName($resolvedRoot)
    if (
        -not $resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('gpui-contract-', [StringComparison]::Ordinal)
    ) {
        throw "Refusing to remove contract fixture outside its exact temporary path: $resolvedRoot"
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}

function New-ECContractFixture {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $root = [IO.Path]::GetFullPath((Join-Path $tempBase ("gpui-contract-" + [Guid]::NewGuid().ToString("N"))))
    $fixture = [pscustomobject]@{
        Root = $root
        TaskStartRevision = ""
        SpecPath = Join-Path $root ".agentinfra\changes\EC-TEST-CONTRACT.json"
    }

    try {
        foreach ($directory in @(".agentinfra\changes", ".agentinfra\schemas", "scripts", "other", "src")) {
            New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Destination (Join-Path $root ".agentinfra\policy.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\policy.schema.json") -Destination (Join-Path $root ".agentinfra\schemas\policy.schema.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\change-spec.schema.json") -Destination (Join-Path $root ".agentinfra\schemas\change-spec.schema.json")
        [IO.File]::WriteAllText((Join-Path $root "scripts\check.ps1"), "Write-Host 'baseline'`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root "other\outside.txt"), "baseline`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root "src\working.txt"), "baseline`n", [Text.UTF8Encoding]::new($false))

        $null = Invoke-FixtureGit -Root $root -Arguments @("init", "--quiet")
        $null = Invoke-FixtureGit -Root $root -Arguments @("config", "user.name", "Executable Constitution Tests")
        $null = Invoke-FixtureGit -Root $root -Arguments @("config", "user.email", "ec-tests@example.invalid")
        $null = Invoke-FixtureGit -Root $root -Arguments @("config", "core.autocrlf", "false")
        $null = Invoke-FixtureGit -Root $root -Arguments @("add", ".")
        $null = Invoke-FixtureGit -Root $root -Arguments @("commit", "--quiet", "-m", "test: contract baseline")
        $fixture.TaskStartRevision = @(Invoke-FixtureGit -Root $root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
        return $fixture
    }
    catch {
        Remove-ECContractFixture -Fixture $fixture
        throw
    }
}

function Add-ECFixtureContractCommit {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)]$Spec,
        [string]$Path = "",
        [string]$Message = "test: add contract"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = $Fixture.SpecPath
    }
    Write-FixtureJson -Path $Path -Value $Spec
    $relativePath = [IO.Path]::GetRelativePath($Fixture.Root, $Path).Replace('\', '/')
    $null = Invoke-FixtureGit -Root $Fixture.Root -Arguments @("add", "--", $relativePath)
    $null = Invoke-FixtureGit -Root $Fixture.Root -Arguments @("commit", "--quiet", "-m", $Message)
    return @(Invoke-FixtureGit -Root $Fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
}

if ($Suite -in @("all", "contract")) {
    Invoke-PolicyCase "repository governance policy is structurally valid" {
        & $policyChecker
    }

    Invoke-PolicyCase "public acceptance adapters require an independent task start" {
        foreach ($commandPath in @($changeSpecChecker, $scopeChecker, $protectedChecker)) {
            $parameter = (Get-Command $commandPath).Parameters["TaskStartRevision"]
            $mandatory = @($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory
            })
            if ($mandatory.Count -ne 1) {
                throw "TaskStartRevision is not mandatory for $commandPath."
            }
        }
    }

    Invoke-PolicyCase "external task start rejects retroactive ordinary paths" {
        $fixture = New-ECContractFixture
        try {
            [IO.File]::WriteAllText((Join-Path $fixture.Root "other\outside.txt"), "retroactive ordinary change`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "other/outside.txt")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add retroactive ordinary path")
            $advancedStart = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            Write-FixtureJson -Path $fixture.SpecPath -Value (New-ChangeSpecFixture `
                -TaskStartRevision $advancedStart `
                -AllowedPaths @("other/outside.txt"))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add late contract")

            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "declared.*task-start|task-start.*match"
            Assert-PolicyRejected {
                & $scopeChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "declared.*task-start|task-start.*match"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "external task start rejects retroactive protected paths" {
        $fixture = New-ECContractFixture
        try {
            [IO.File]::WriteAllText((Join-Path $fixture.Root "scripts\check.ps1"), "Write-Host 'retroactive protected change'`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "scripts/check.ps1")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add retroactive protected path")
            $advancedStart = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            Write-FixtureJson -Path $fixture.SpecPath -Value (New-ChangeSpecFixture `
                -TaskStartRevision $advancedStart `
                -AllowedPaths @("scripts/check.ps1") `
                -ProtectedFiles 1)
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add late contract")

            Assert-PolicyRejected {
                & $scopeChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "declared.*task-start|task-start.*match"
            Assert-PolicyRejected {
                & $protectedChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "declared.*task-start|task-start.*match"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "final rejects an untracked committed ChangeSpec" {
        $fixture = New-ECContractFixture
        try {
            Write-FixtureJson -Path $fixture.SpecPath -Value (New-ChangeSpecFixture `
                -Lane "full" `
                -Profile $fullProfileName `
                -RequiredChecks $fullRequiredChecks `
                -ProtectedChange $false `
                -TaskStartRevision $fixture.TaskStartRevision)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "untracked|committed|final"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "final resolves the unique committed ChangeSpec from the original task start" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            $result = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -RepositoryRoot $fixture.Root `
                -PassThru
            if (
                $result.Lifecycle -ne "final" -or
                $result.Outcome -ne "review_required" -or
                $result.ChangeSpecPath -ne $fixture.SpecPath -or
                $result.EffectiveTaskStartRevision -ne $fixture.TaskStartRevision
            ) {
                throw "Unique committed contract did not preserve final lifecycle, path, outcome, and effective task start."
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "later Spec edit cannot advance the declared task start" {
        $fixture = New-ECContractFixture
        try {
            $spec = New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision
            $null = Add-ECFixtureContractCommit -Fixture $fixture -Spec $spec
            [IO.File]::WriteAllText((Join-Path $fixture.Root "src\committed.txt"), "committed`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "src/committed.txt")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add task work")
            $advancedStart = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            $spec.task_start_revision = $advancedStart
            Write-FixtureJson -Path $fixture.SpecPath -Value $spec
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: advance declared start")

            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "declared.*task-start|task-start.*match|remain unchanged"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "unavailable independent task start fails closed" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision ("0" * 40) `
                    -RepositoryRoot $fixture.Root
            } "not an available commit|task-start"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "non-ancestor independent task start fails closed" {
        $fixture = New-ECContractFixture
        try {
            $tree = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD^{tree}"))[-1].ToString().Trim()
            $unrelated = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit-tree", $tree, "-m", "test: unrelated task start"))[-1].ToString().Trim()
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $unrelated)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $unrelated `
                    -RepositoryRoot $fixture.Root
            } "not an ancestor"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "effective task range includes committed staged unstaged and untracked paths" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -AllowedPaths @("src/**"))
            [IO.File]::WriteAllText((Join-Path $fixture.Root "src\committed.txt"), "committed`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "src/committed.txt")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add committed path")
            [IO.File]::WriteAllText((Join-Path $fixture.Root "src\staged.txt"), "staged`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "src/staged.txt")
            [IO.File]::WriteAllText((Join-Path $fixture.Root "src\working.txt"), "working`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $fixture.Root "src\untracked.txt"), "untracked`n", [Text.UTF8Encoding]::new($false))

            $result = & $scopeChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -RepositoryRoot $fixture.Root `
                -PassThru
            $expectations = @{
                "src/committed.txt" = "committed"
                "src/staged.txt" = "staged"
                "src/working.txt" = "working"
                "src/untracked.txt" = "untracked"
            }
            foreach ($path in $expectations.Keys) {
                $match = @($result.Changes | Where-Object {
                    $_.Path -eq $path -and $expectations[$path] -in @($_.Sources)
                })
                if ($match.Count -ne 1) {
                    throw "Expected exactly one '$path' change from '$($expectations[$path])'."
                }
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "later updates to the same committed Spec preserve provenance" {
        $fixture = New-ECContractFixture
        try {
            $spec = New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision
            $null = Add-ECFixtureContractCommit -Fixture $fixture -Spec $spec
            $spec.residual_risks = @("Candidate-local checks still require independent review.")
            Write-FixtureJson -Path $fixture.SpecPath -Value $spec
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: update contract evidence")
            $result = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -RepositoryRoot $fixture.Root `
                -PassThru
            if ($result.Lifecycle -ne "final" -or $result.EffectiveTaskStartRevision -ne $fixture.TaskStartRevision) {
                throw "Later same-Spec update lost final lifecycle or effective task start."
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "staged-only committed Spec is authoring but never final" {
        $fixture = New-ECContractFixture
        try {
            Write-FixtureJson -Path $fixture.SpecPath -Value (New-ChangeSpecFixture `
                -Lane "full" `
                -Profile $fullProfileName `
                -RequiredChecks $fullRequiredChecks `
                -ProtectedChange $false `
                -TaskStartRevision $fixture.TaskStartRevision)
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "staged-only|final"

            $authoring = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -ChangeSpecPath $fixture.SpecPath `
                -RepositoryRoot $fixture.Root `
                -AllowDraft `
                -PassThru
            if ($authoring.Lifecycle -ne "authoring" -or $authoring.Outcome -ne "authoring") {
                throw "Staged-only committed Spec produced final-equivalent semantics."
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "dirty committed Spec is authoring but never final" {
        $fixture = New-ECContractFixture
        try {
            $spec = New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision
            $null = Add-ECFixtureContractCommit -Fixture $fixture -Spec $spec
            $spec.residual_risks = @("Uncommitted authoring update.")
            Write-FixtureJson -Path $fixture.SpecPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "unstaged|differences|final"

            $authoring = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -RepositoryRoot $fixture.Root `
                -AllowDraft `
                -PassThru
            if ($authoring.Lifecycle -ne "authoring" -or $authoring.Outcome -ne "authoring") {
                throw "Dirty committed Spec produced final-equivalent semantics."
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "committed draft Spec is authoring but never final" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture `
                    -State "draft" `
                    -TaskStartRevision $fixture.TaskStartRevision)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "Draft ChangeSpec|ready"

            $authoring = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -RepositoryRoot $fixture.Root `
                -AllowDraft `
                -PassThru
            if ($authoring.Lifecycle -ne "authoring" -or $authoring.Outcome -ne "authoring") {
                throw "Committed draft Spec produced final-equivalent semantics."
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "duplicate committed Specs are rejected before caller selection" {
        $fixture = New-ECContractFixture
        try {
            $duplicatePath = Join-Path $fixture.Root ".agentinfra\changes\EC-TEST-DUPLICATE.json"
            Write-FixtureJson -Path $fixture.SpecPath -Value (New-ChangeSpecFixture `
                -TaskStartRevision $fixture.TaskStartRevision)
            Write-FixtureJson -Path $duplicatePath -Value (New-ChangeSpecFixture `
                -ChangeId "EC-TEST-DUPLICATE" `
                -TaskStartRevision $fixture.TaskStartRevision)
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json", ".agentinfra/changes/EC-TEST-DUPLICATE.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add duplicate contracts")
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $fixture.SpecPath `
                    -RepositoryRoot $fixture.Root
            } "ambiguous|duplicate"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "committed and untracked Specs cannot coexist" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            $untrackedPath = Join-Path $fixture.Root ".agentinfra\changes\EC-TEST-UNTRACKED.json"
            Write-FixtureJson -Path $untrackedPath -Value (New-ChangeSpecFixture `
                -ChangeId "EC-TEST-UNTRACKED" `
                -TaskStartRevision $fixture.TaskStartRevision)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "ambiguous|untracked"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "modifying a historical Spec is a wrong-range contract" {
        $fixture = New-ECContractFixture
        try {
            $spec = New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision
            $null = Add-ECFixtureContractCommit -Fixture $fixture -Spec $spec -Message "test: add historical contract"
            $newTaskStart = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            $spec.task_start_revision = $newTaskStart
            $spec.residual_risks = @("Modified during a later task.")
            Write-FixtureJson -Path $fixture.SpecPath -Value $spec
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: modify historical contract")
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $newTaskStart `
                    -RepositoryRoot $fixture.Root
            } "first Add|task range|earlier history"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "deleted committed Spec cannot become final" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("rm", ".agentinfra/changes/EC-TEST-CONTRACT.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: delete contract")
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "deleted|missing|final net diff"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "renamed committed Spec cannot become final" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("mv", ".agentinfra/changes/EC-TEST-CONTRACT.json", ".agentinfra/changes/EC-TEST-RENAMED.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: rename contract")
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "ambiguous|rename|history"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "copied committed Spec cannot become final" {
        $fixture = New-ECContractFixture
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            Copy-Item `
                -LiteralPath $fixture.SpecPath `
                -Destination (Join-Path $fixture.Root ".agentinfra\changes\EC-TEST-COPIED.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", ".agentinfra/changes/EC-TEST-COPIED.json")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: copy contract")
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "ambiguous|copy|history"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "committed Spec filename must match change id" {
        $fixture = New-ECContractFixture
        try {
            $wrongPath = Join-Path $fixture.Root ".agentinfra\changes\EC-WRONG-NAME.json"
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision) `
                -Path $wrongPath
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "filename.*change_id|expected.*EC-TEST-CONTRACT"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "caller cannot select a permissive historical Spec" {
        $fixture = New-ECContractFixture
        try {
            $permissivePath = Join-Path $fixture.Root ".agentinfra\changes\EC-PERMISSIVE.json"
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture `
                    -ChangeId "EC-PERMISSIVE" `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -AllowedPaths @("**/*.txt")) `
                -Path $permissivePath `
                -Message "test: add historical permissive contract"
            $newTaskStart = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            $authoritativePath = Join-Path $fixture.Root ".agentinfra\changes\EC-AUTHORITATIVE.json"
            $authoritativeSpec = New-ChangeSpecFixture `
                -ChangeId "EC-AUTHORITATIVE" `
                -TaskStartRevision $newTaskStart `
                -AllowedPaths @("src/**")
            $authoritativeSpec.title = "Resolve the narrow authoritative contract"
            $authoritativeSpec.intent.outcome = "Only the automatically resolved task contract controls acceptance."
            $authoritativeSpec.intent.recovery = "Reject every caller-selected historical contract."
            $authoritativeSpec.scope.allowed_paths = @(1..40 | ForEach-Object { "src/area-$_/**" })
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec $authoritativeSpec `
                -Path $authoritativePath `
                -Message "test: add authoritative contract"
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $newTaskStart `
                    -ChangeSpecPath $permissivePath `
                    -RepositoryRoot $fixture.Root
            } "does not match automatically resolved|caller"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "transient Spec task start must match independent input" {
        $fixture = New-ECContractFixture
        $transientPath = "$($fixture.Root)-focused.json"
        try {
            [IO.File]::WriteAllText((Join-Path $fixture.Root "src\committed.txt"), "committed`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "src/committed.txt")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: advance fixture head")
            $advancedStart = @(Invoke-FixtureGit -Root $fixture.Root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
            Write-FixtureJson -Path $transientPath -Value (New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $advancedStart `
                -AllowedPaths @("src/**") `
                -ForbiddenPaths @())
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $transientPath `
                    -RepositoryRoot $fixture.Root
            } "declared.*task-start|task-start.*match"
        }
        finally {
            if (Test-Path -LiteralPath $transientPath) {
                Remove-Item -LiteralPath $transientPath -Force
            }
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "focused and bot lanes accept ready external transient Specs" {
        $fixture = New-ECContractFixture
        $focusedPath = "$($fixture.Root)-focused.json"
        $botPath = "$($fixture.Root)-bot.json"
        try {
            Write-FixtureJson -Path $focusedPath -Value (New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $fixture.TaskStartRevision `
                -AllowedPaths @("src/**") `
                -ForbiddenPaths @())
            $focused = & $scopeChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -ChangeSpecPath $focusedPath `
                -RepositoryRoot $fixture.Root `
                -PassThru
            if ($focused.Lifecycle -ne "final" -or $focused.Outcome -ne "eligible") {
                throw "Ready focused transient contract did not resolve as final/eligible."
            }

            Write-FixtureJson -Path $botPath -Value (New-ChangeSpecFixture `
                -Lane "bot" `
                -Profile "bot" `
                -RequiredChecks @("change-spec", "scope", "protected-paths", "repository-full-gate") `
                -ProtectedChange $false `
                -ChangesDependencies $true `
                -TaskStartRevision $fixture.TaskStartRevision `
                -AllowedPaths @("Cargo.toml") `
                -ForbiddenPaths @("src/**") `
                -DependencyManifestFiles 1)
            $bot = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -ChangeSpecPath $botPath `
                -RepositoryRoot $fixture.Root `
                -PassThru
            if ($bot.Lifecycle -ne "final" -or $bot.Outcome -ne "eligible") {
                throw "Ready bot transient contract did not resolve as final/eligible."
            }
        }
        finally {
            foreach ($path in @($focusedPath, $botPath)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    Invoke-PolicyCase "transient lane rejects a committed-lifecycle Spec candidate" {
        $fixture = New-ECContractFixture
        $transientPath = "$($fixture.Root)-focused.json"
        try {
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision)
            Write-FixtureJson -Path $transientPath -Value (New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $fixture.TaskStartRevision `
                -AllowedPaths @("src/**") `
                -ForbiddenPaths @())
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $transientPath `
                    -RepositoryRoot $fixture.Root
            } "does not match automatically resolved|transient.*committed"
        }
        finally {
            if (Test-Path -LiteralPath $transientPath) {
                Remove-Item -LiteralPath $transientPath -Force
            }
            Remove-ECContractFixture -Fixture $fixture
        }
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

        Invoke-PolicyCase "valid untracked governance ChangeSpec is authoring-only" {
            Write-FixtureJson -Path $specPath -Value (New-ChangeSpecFixture)
            $result = & $changeSpecChecker `
                -TaskStartRevision $script:contractTaskStartRevision `
                -ChangeSpecPath $specPath `
                -RepositoryRoot $fixtureRoot `
                -AllowDraft `
                -PassThru
            if ($result.Lifecycle -ne "authoring" -or $result.Outcome -ne "authoring") {
                throw "Untracked Governance ChangeSpec returned final-equivalent semantics."
            }
        }

        Invoke-PolicyCase "ChangeSpec cannot carry arbitrary commands" {
            $spec = New-ChangeSpecFixture
            $spec.commands = @("Invoke-Expression 'untrusted'")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $script:contractTaskStartRevision `
                    -ChangeSpecPath $specPath `
                    -RepositoryRoot $fixtureRoot `
                    -AllowDraft
            } "schema|additional|commands"
        }

        Invoke-PolicyCase "focused ChangeSpec rejects dependency impact" {
            if (Test-Path -LiteralPath $specPath) {
                Remove-Item -LiteralPath $specPath -Force
            }
            $spec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -ChangesDependencies $true
            Write-FixtureJson -Path $transientContractSpecPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $script:contractTaskStartRevision `
                    -ChangeSpecPath $transientContractSpecPath `
                    -RepositoryRoot $fixtureRoot
            } "focused.*dependency|dependency.*focused"
        }

        Invoke-PolicyCase "ChangeSpec required checks match its profile" {
            $spec = New-ChangeSpecFixture -RequiredChecks @("change-spec")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $script:contractTaskStartRevision `
                    -ChangeSpecPath $specPath `
                    -RepositoryRoot $fixtureRoot `
                    -AllowDraft
            } "required checks|profile"
        }

        Invoke-PolicyCase "ChangeSpec paths reject escape and root catch-all forms" {
            foreach ($invalidPath in @("../escape", "C:\absolute", "\\server\share", "**/*")) {
                $spec = New-ChangeSpecFixture
                $spec.scope.allowed_paths = @($invalidPath)
                Write-FixtureJson -Path $specPath -Value $spec
                Assert-PolicyRejected {
                    & $changeSpecChecker `
                        -TaskStartRevision $script:contractTaskStartRevision `
                        -ChangeSpecPath $specPath `
                        -RepositoryRoot $fixtureRoot `
                        -AllowDraft
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
                & $changeSpecChecker `
                    -TaskStartRevision $script:contractTaskStartRevision `
                    -ChangeSpecPath $specPath `
                    -RepositoryRoot $fixtureRoot `
                    -AllowDraft
            } "transient.*outside|outside.*transient"
        }

        Invoke-PolicyCase "committed lane requires the repository ChangeSpec directory" {
            if (Test-Path -LiteralPath $specPath) {
                Remove-Item -LiteralPath $specPath -Force
            }
            Write-FixtureJson -Path $transientContractSpecPath -Value (New-ChangeSpecFixture)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $script:contractTaskStartRevision `
                    -ChangeSpecPath $transientContractSpecPath `
                    -RepositoryRoot $fixtureRoot
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
            & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "allowed added path passes scope" {
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\added.txt"), "added`n", [Text.UTF8Encoding]::new($false))
            & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "allowed deleted path passes scope" {
            Remove-Item -LiteralPath (Join-Path $scopeRoot "src\delete.txt")
            & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "rename endpoints inside scope pass" {
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("mv", "src/rename.txt", "src/renamed.txt")
            & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
        }

        Invoke-PolicyCase "rename destination outside scope is rejected" {
            try {
                $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("mv", "src/move-out.txt", "other/moved.txt")
                Assert-PolicyRejected {
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
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
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
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
            & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -AllowDraft
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
                & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -AllowDraft
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
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -AllowDraft -PassThru
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
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -AllowDraft
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
                    & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -AllowDraft
                } "workflow_files|budget"
            }
            finally {
                if (Test-Path -LiteralPath (Join-Path $scopeRoot ".github")) {
                    Remove-Item -LiteralPath (Join-Path $scopeRoot ".github") -Recurse -Force
                }
            }
        }

        Invoke-PolicyCase "bot scope cannot widen beyond dependency policy" {
            if (Test-Path -LiteralPath $scopeCommittedSpecPath) {
                Remove-Item -LiteralPath $scopeCommittedSpecPath -Force
            }
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
                & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
            & $scopeChecker -TaskStartRevision $botBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot
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
                & $protectedChecker -TaskStartRevision $protectedBase -ChangeSpecPath $protectedSpecPath -RepositoryRoot $protectedRoot
            } "Protected path 'scripts/check\.ps1'.*acceptance-controls.*governance"
        }

        Invoke-PolicyCase "full lane cannot change an acceptance control" {
            $spec = New-ChangeSpecFixture `
                -ChangeId "EC-TEST-PROTECTED" `
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
                & $protectedChecker -TaskStartRevision $protectedBase -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -AllowDraft
            } "Protected path 'scripts/check\.ps1'.*acceptance-controls.*governance"
        }

        Invoke-PolicyCase "governance protected change remains review-required" {
            $spec = New-ChangeSpecFixture `
                -ChangeId "EC-TEST-PROTECTED" `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 1
            Write-FixtureJson -Path $protectedCommittedSpecPath -Value $spec
            $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("add", ".agentinfra/changes/EC-TEST-PROTECTED.json")
            $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("commit", "--quiet", "-m", "test: add governance contract")
            $result = & $protectedChecker -TaskStartRevision $protectedBase -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -PassThru
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
                -ChangeId "EC-TEST-PROTECTED" `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1", ".github/workflows/**") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 2 `
                -WorkflowFiles 1
            Write-FixtureJson -Path $protectedCommittedSpecPath -Value $spec
            $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("add", ".agentinfra/changes/EC-TEST-PROTECTED.json")
            $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("commit", "--quiet", "-m", "test: expand governance contract")
            $result = & $protectedChecker -TaskStartRevision $protectedBase -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -PassThru
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
        $adapterTaskStart = @(Invoke-FixtureGit -Root $adapterRoot -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()

        Invoke-PolicyCase "full ChangeSpec generator uses committed repository profile" {
            $result = & $newChangeGenerator `
                -ChangeId "EC-ADAPTER-FULL" `
                -TaskStartRevision $adapterTaskStart `
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
            if (
                $result.Path -ne $expectedPath -or
                $result.Spec.state -ne "draft" -or
                $result.Spec.verification.profile -ne $fullProfileName -or
                $result.TaskStartRevision -ne $adapterTaskStart
            ) {
                throw "Full generator did not produce the expected committed repository-profile draft."
            }
            & $changeSpecChecker -TaskStartRevision $adapterTaskStart -ChangeSpecPath $result.Path -RepositoryRoot $adapterRoot -AllowDraft | Out-Null
            Remove-Item -LiteralPath $result.Path -Force
        }

        Invoke-PolicyCase "focused ChangeSpec generator uses transient location" {
            $result = $null
            try {
                $result = & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-FOCUSED" `
                    -TaskStartRevision $adapterTaskStart `
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
                & $changeSpecChecker -TaskStartRevision $adapterTaskStart -ChangeSpecPath $result.Path -RepositoryRoot $adapterRoot -AllowDraft | Out-Null
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
                    -TaskStartRevision $adapterTaskStart `
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

        Invoke-PolicyCase "ChangeSpec generator requires an explicit task start" {
            $parameter = (Get-Command $newChangeGenerator).Parameters["TaskStartRevision"]
            $mandatory = @($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory
            })
            if ($mandatory.Count -ne 1) {
                throw "TaskStartRevision is not a mandatory generator input."
            }
        }

        Invoke-PolicyCase "ChangeSpec generator rejects unavailable and non-ancestor starts" {
            Assert-PolicyRejected {
                & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-MISSING-START" `
                    -TaskStartRevision ("0" * 40) `
                    -Title "Reject an unavailable start" `
                    -Lane "focused" `
                    -ChangeKind "fix" `
                    -Outcome "Reject unavailable provenance." `
                    -Recovery "Do not create a draft." `
                    -AllowedPaths @("src/lib.rs") `
                    -Exclusions @("No implementation changes.") `
                    -RepositoryRoot $adapterRoot
            } "not an available commit"

            $tree = @(Invoke-FixtureGit -Root $adapterRoot -Arguments @("rev-parse", "HEAD^{tree}"))[-1].ToString().Trim()
            $unrelated = @(Invoke-FixtureGit -Root $adapterRoot -Arguments @("commit-tree", $tree, "-m", "test: unrelated generator start"))[-1].ToString().Trim()
            Assert-PolicyRejected {
                & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-NON-ANCESTOR" `
                    -TaskStartRevision $unrelated `
                    -Title "Reject a non-ancestor start" `
                    -Lane "focused" `
                    -ChangeKind "fix" `
                    -Outcome "Reject unrelated provenance." `
                    -Recovery "Do not create a draft." `
                    -AllowedPaths @("src/lib.rs") `
                    -Exclusions @("No implementation changes.") `
                    -RepositoryRoot $adapterRoot
            } "not an ancestor"
        }

        Invoke-PolicyCase "bot ChangeSpec generator derives dependency contract" {
            $result = $null
            try {
                $result = & $newChangeGenerator `
                    -ChangeId "EC-ADAPTER-BOT" `
                    -TaskStartRevision $adapterTaskStart `
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
                & $changeSpecChecker -TaskStartRevision $adapterTaskStart -ChangeSpecPath $result.Path -RepositoryRoot $adapterRoot -AllowDraft | Out-Null
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
