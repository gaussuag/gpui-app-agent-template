[CmdletBinding()]
param(
    [ValidateSet("all", "contract", "scope", "protected", "adapters")]
    [string]$Suite = "all",

    [string]$CaseName = "",

    [ValidateSet("declared", "reverse")]
    [string]$Order = "declared"
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
$createdFixtureDirectories = [System.Collections.Generic.List[string]]::new()
$createdFixtureFiles = [System.Collections.Generic.List[string]]::new()
$repositoryGovernancePolicy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100
$fullProfileName = [string]$repositoryGovernancePolicy.repository_profile
$fullRequiredChecks = @($repositoryGovernancePolicy.checks.profiles.$fullProfileName.required_checks)

function Invoke-ECFixtureFactory {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("contract", "scope", "protected", "adapters")]
        [string]$Family
    )

    switch ($Family) {
        "contract" { return New-ECContractFixture }
        "scope" { return New-ECScopeFixture }
        "protected" { return New-ECProtectedFixture }
        "adapters" { return New-ECAdapterFixture }
    }
}

function Invoke-WithECFixture {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("contract", "scope", "protected", "adapters")]
        [string]$Family,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $fixture = $null
    try {
        $fixture = Invoke-ECFixtureFactory -Family $Family
        & $Action $fixture
    }
    finally {
        if ($null -ne $fixture) {
            Remove-ECFixture -Fixture $fixture
        }
    }
}

function New-ECPolicyCase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("contract", "scope", "protected", "adapters")]
        [string]$Family,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    return [pscustomobject]@{
        Family = $Family
        Name = $Name
        Action = $Action
    }
}

function Assert-ECPolicyCaseRegistry {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Cases)

    $duplicate = @($Cases |
        Group-Object -Property { "$($_.Family)$([char]31)$($_.Name)" } -CaseSensitive |
        Where-Object { $_.Count -gt 1 } |
        Select-Object -First 1)
    if ($duplicate.Count -gt 0) {
        $case = $duplicate[0].Group[0]
        throw "Case registry contains duplicate Family+Name '$($case.Family)/$($case.Name)'."
    }
}

function Invoke-IsolatedPolicyCase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("contract", "scope", "protected", "adapters")]
        [string]$Family,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host "==> $Name"
    $fixture = $null
    $failure = ""
    try {
        $fixture = Invoke-ECFixtureFactory -Family $Family

        # Compatibility aliases are local to this invocation. Cases receive the
        # fixture explicitly and never observe state created by another case.
        $fixtureRoot = $fixture.Root
        $specPath = $fixture.SpecPath
        $transientContractSpecPath = $fixture.TransientSpecPath
        $policyFixturePath = Join-Path $fixture.Root "policy.json"
        $scopeRoot = $fixture.Root
        $scopeBase = $fixture.TaskStartRevision
        $scopeSpecPath = $fixture.SpecPath
        $scopeCommittedSpecPath = $fixture.CommittedSpecPath
        $protectedRoot = $fixture.Root
        $protectedBase = $fixture.TaskStartRevision
        $protectedSpecPath = $fixture.SpecPath
        $protectedCommittedSpecPath = $fixture.CommittedSpecPath
        $adapterRoot = $fixture.Root
        $adapterTaskStart = $fixture.TaskStartRevision

        & $Action $fixture
    }
    catch {
        $failure = $_ | Out-String
    }
    finally {
        if ($null -ne $fixture) {
            try {
                Remove-ECFixture -Fixture $fixture
            }
            catch {
                $cleanupFailure = $_ | Out-String
                $failure = if ([string]::IsNullOrWhiteSpace($failure)) {
                    $cleanupFailure
                }
                else {
                    "$failure`nFixture cleanup also failed:`n$cleanupFailure"
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($failure)) {
        $script:passed++
        Write-Host "PASS: $Name"
    }
    else {
        $script:failed++
        Write-Host "FAIL: $Name`n$failure"
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
        [Parameter(Mandatory = $true)][string]$TaskStartRevision,
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

function Assert-ECTemporaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Directory
    )

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture path is outside the system temporary directory: $fullPath"
    }
    if ($Directory) {
        $leaf = [IO.Path]::GetFileName($fullPath)
        if ($leaf -cnotmatch '^gpui-(contract|scope|protected|adapters)-[0-9a-f]{32}$') {
            throw "Fixture directory does not have an exact case-owned name: $fullPath"
        }
    }
    return $fullPath
}

function Add-ECFixtureFile {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = Assert-ECTemporaryPath -Path $Path
    if (-not $Fixture.ExtraPaths.Contains($fullPath)) {
        $Fixture.ExtraPaths.Add($fullPath)
    }
    if (-not $script:createdFixtureFiles.Contains($fullPath)) {
        $script:createdFixtureFiles.Add($fullPath)
    }
    return $fullPath
}

function Remove-ECFixture {
    param([Parameter(Mandatory = $true)]$Fixture)

    foreach ($path in @($Fixture.ExtraPaths)) {
        $exactPath = Assert-ECTemporaryPath -Path $path
        if (Test-Path -LiteralPath $exactPath) {
            Remove-Item -LiteralPath $exactPath -Force
        }
    }

    $exactRoot = Assert-ECTemporaryPath -Path $Fixture.Root -Directory
    if (Test-Path -LiteralPath $exactRoot) {
        Remove-Item -LiteralPath $exactRoot -Recurse -Force
    }
}

function Remove-ECContractFixture {
    param([Parameter(Mandatory = $true)]$Fixture)

    Remove-ECFixture -Fixture $Fixture
}

function New-ECFixtureBase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("contract", "scope", "protected", "adapters")]
        [string]$Family,
        [Parameter(Mandatory = $true)][string[]]$Directories,
        [Parameter(Mandatory = $true)][hashtable]$BaselineFiles,
        [Parameter(Mandatory = $true)][string]$CommitMessage
    )

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $root = [IO.Path]::GetFullPath((Join-Path $tempBase ("gpui-$Family-" + [Guid]::NewGuid().ToString("N"))))
    $fixture = [pscustomobject]@{
        Family = $Family
        Root = $root
        TaskStartRevision = ""
        SpecPath = ""
        CommittedSpecPath = ""
        TransientSpecPath = ""
        BotTransientSpecPath = ""
        ExtraPaths = [System.Collections.Generic.List[string]]::new()
    }
    $script:createdFixtureDirectories.Add($root)

    try {
        foreach ($directory in @(".agentinfra\changes", ".agentinfra\schemas") + $Directories) {
            New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Destination (Join-Path $root ".agentinfra\policy.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\policy.schema.json") -Destination (Join-Path $root ".agentinfra\schemas\policy.schema.json")
        Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agentinfra\schemas\change-spec.schema.json") -Destination (Join-Path $root ".agentinfra\schemas\change-spec.schema.json")
        foreach ($relativePath in $BaselineFiles.Keys) {
            $destination = Join-Path $root $relativePath
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [IO.File]::WriteAllText($destination, [string]$BaselineFiles[$relativePath], [Text.UTF8Encoding]::new($false))
        }

        $null = Invoke-FixtureGit -Root $root -Arguments @("init", "--quiet")
        $null = Invoke-FixtureGit -Root $root -Arguments @("config", "user.name", "Executable Constitution Tests")
        $null = Invoke-FixtureGit -Root $root -Arguments @("config", "user.email", "ec-tests@example.invalid")
        $null = Invoke-FixtureGit -Root $root -Arguments @("config", "core.autocrlf", "false")
        $null = Invoke-FixtureGit -Root $root -Arguments @("add", ".")
        $null = Invoke-FixtureGit -Root $root -Arguments @("commit", "--quiet", "-m", $CommitMessage)
        $fixture.TaskStartRevision = @(Invoke-FixtureGit -Root $root -Arguments @("rev-parse", "HEAD"))[-1].ToString().Trim()
        return $fixture
    }
    catch {
        Remove-ECFixture -Fixture $fixture
        throw
    }
}

function New-ECContractFixture {
    $fixture = New-ECFixtureBase `
        -Family "contract" `
        -Directories @("scripts", "other", "src") `
        -BaselineFiles @{
            "scripts\check.ps1" = "Write-Host 'baseline'`n"
            "other\outside.txt" = "baseline`n"
            "src\working.txt" = "baseline`n"
        } `
        -CommitMessage "test: contract baseline"
    try {
        $fixture.SpecPath = Join-Path $fixture.Root ".agentinfra\changes\EC-TEST-CONTRACT.json"
        $fixture.CommittedSpecPath = $fixture.SpecPath
        $fixture.TransientSpecPath = Add-ECFixtureFile -Fixture $fixture -Path "$($fixture.Root)-focused.json"
        $fixture.BotTransientSpecPath = Add-ECFixtureFile -Fixture $fixture -Path "$($fixture.Root)-bot.json"
        return $fixture
    }
    catch {
        Remove-ECFixture -Fixture $fixture
        throw
    }
}

function New-ECScopeFixture {
    $fixture = New-ECFixtureBase `
        -Family "scope" `
        -Directories @("src", "other") `
        -BaselineFiles @{
            "src\allowed.txt" = "allowed baseline`n"
            "src\delete.txt" = "delete baseline`n"
            "src\rename.txt" = "rename baseline`n"
            "src\move-out.txt" = "move-out baseline`n"
            "src\copy-source.txt" = "copy-source baseline`n"
            "Cargo.toml" = "[workspace]`nmembers = []`n"
            "other\blocked.txt" = "blocked baseline`n"
        } `
        -CommitMessage "test: scope baseline"
    try {
        $fixture.SpecPath = Add-ECFixtureFile -Fixture $fixture -Path "$($fixture.Root)-spec.json"
        $fixture.CommittedSpecPath = Join-Path $fixture.Root ".agentinfra\changes\EC-TEST-SCOPE.json"
        Write-FixtureJson -Path $fixture.SpecPath -Value (New-ChangeSpecFixture `
            -TaskStartRevision $fixture.TaskStartRevision `
            -Lane "focused" `
            -Profile "focused" `
            -RequiredChecks @("change-spec", "scope", "protected-paths") `
            -ProtectedChange $false `
            -AllowedPaths @("src/**") `
            -ForbiddenPaths @("other/**"))
        return $fixture
    }
    catch {
        Remove-ECFixture -Fixture $fixture
        throw
    }
}

function New-ECProtectedFixture {
    $fixture = New-ECFixtureBase `
        -Family "protected" `
        -Directories @(".github\workflows", "scripts") `
        -BaselineFiles @{
            "scripts\check.ps1" = "Write-Host 'baseline'`n"
            ".github\workflows\ci.yml" = "name: baseline`n"
        } `
        -CommitMessage "test: protected baseline"
    try {
        $fixture.SpecPath = Add-ECFixtureFile -Fixture $fixture -Path "$($fixture.Root)-spec.json"
        $fixture.CommittedSpecPath = Join-Path $fixture.Root ".agentinfra\changes\EC-TEST-PROTECTED.json"
        return $fixture
    }
    catch {
        Remove-ECFixture -Fixture $fixture
        throw
    }
}

function New-ECAdapterFixture {
    $fixture = New-ECFixtureBase `
        -Family "adapters" `
        -Directories @("src") `
        -BaselineFiles @{ "src\lib.rs" = "pub fn fixture() {}`n" } `
        -CommitMessage "test: adapter baseline"
    try {
        $fixture.SpecPath = Join-Path $fixture.Root ".agentinfra\changes\EC-ADAPTER-FULL.json"
        $fixture.CommittedSpecPath = $fixture.SpecPath
        return $fixture
    }
    catch {
        Remove-ECFixture -Fixture $fixture
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

function Assert-ChangedPaths {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Expected
    )

    $actual = @($Result.Changes | ForEach-Object { [string]$_.Path } | Sort-Object -Unique)
    $expectedPaths = @($Expected | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedPaths -DifferenceObject $actual -CaseSensitive)
    if ($difference.Count -gt 0) {
        throw "Changed path set mismatch. Expected=[$($expectedPaths -join ', ')] Actual=[$($actual -join ', ')]"
    }
}

function Assert-RecordedFixtureCleanup {
    $remainingDirectories = @($script:createdFixtureDirectories | Where-Object { Test-Path -LiteralPath $_ })
    $remainingFiles = @($script:createdFixtureFiles | Where-Object { Test-Path -LiteralPath $_ })
    if ($remainingDirectories.Count -gt 0 -or $remainingFiles.Count -gt 0) {
        throw "Recorded fixture cleanup failed. Directories=[$($remainingDirectories -join ', ')] Files=[$($remainingFiles -join ', ')]"
    }
    Write-Host "Fixture cleanup passed: directories=$($script:createdFixtureDirectories.Count) files=$($script:createdFixtureFiles.Count) remaining=0"
}

$caseRegistry = @(
    New-ECPolicyCase -Family "contract" -Name "repository governance policy is structurally valid" -Action { param($fixture)
        & $policyChecker
    }

    New-ECPolicyCase -Family "contract" -Name "public acceptance adapters require an independent task start" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "case registry rejects duplicate family and name" -Action { param($fixture)
        $duplicates = @(
            New-ECPolicyCase -Family "scope" -Name "duplicate case" -Action {}
            New-ECPolicyCase -Family "scope" -Name "duplicate case" -Action {}
        )
        Assert-PolicyRejected {
            Assert-ECPolicyCaseRegistry -Cases $duplicates
        } "duplicate Family\+Name 'scope/duplicate case'"
    }

    New-ECPolicyCase -Family "contract" -Name "external task start rejects retroactive ordinary paths" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "external task start rejects retroactive protected paths" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "final rejects an untracked committed ChangeSpec" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "final resolves the unique committed ChangeSpec from the original task start" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "historical head revision cannot borrow the current checkout" -Action { param($fixture)
        try {
            $spec = New-ChangeSpecFixture `
                -State "draft" `
                -TaskStartRevision $fixture.TaskStartRevision
            $draftRevision = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec $spec `
                -Message "test: add draft contract"
            $spec.state = "ready"
            $currentRevision = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec $spec `
                -Message "test: complete contract"

            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -HeadRevision $draftRevision `
                    -RepositoryRoot $fixture.Root
            } "Head revision.*current checkout|current checkout.*Head revision"

            $result = & $changeSpecChecker `
                -TaskStartRevision $fixture.TaskStartRevision `
                -HeadRevision $currentRevision `
                -RepositoryRoot $fixture.Root `
                -PassThru
            if (
                $result.Lifecycle -ne "final" -or
                $result.HeadRevision -ne $currentRevision
            ) {
                throw "Explicit full current HEAD did not resolve the final contract."
            }
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    New-ECPolicyCase -Family "contract" -Name "first contract Add must immediately follow the task start" -Action { param($fixture)
        try {
            [IO.File]::WriteAllText(
                (Join-Path $fixture.Root "src\ordinary.txt"),
                "ordinary implementation before contract`n",
                [Text.UTF8Encoding]::new($false)
            )
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("add", "src/ordinary.txt")
            $null = Invoke-FixtureGit -Root $fixture.Root -Arguments @("commit", "--quiet", "-m", "test: add ordinary implementation")
            $null = Add-ECFixtureContractCommit `
                -Fixture $fixture `
                -Spec (New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision) `
                -Message "test: add late contract"

            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -RepositoryRoot $fixture.Root
            } "first Add commit.*effective task-start.*only parent"
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    New-ECPolicyCase -Family "contract" -Name "later Spec edit cannot advance the declared task start" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "unavailable independent task start fails closed" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "non-ancestor independent task start fails closed" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "effective task range includes committed staged unstaged and untracked paths" -Action { param($fixture)
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
            Assert-ChangedPaths -Result $result -Expected @(
                ".agentinfra/changes/EC-TEST-CONTRACT.json",
                "src/committed.txt",
                "src/staged.txt",
                "src/untracked.txt",
                "src/working.txt"
            )
        }
        finally {
            Remove-ECContractFixture -Fixture $fixture
        }
    }

    New-ECPolicyCase -Family "contract" -Name "later updates to the same committed Spec preserve provenance" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "staged-only committed Spec is authoring but never final" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "dirty committed Spec is authoring but never final" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "committed draft Spec is authoring but never final" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "duplicate committed Specs are rejected before caller selection" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "committed and untracked Specs cannot coexist" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "modifying a historical Spec is a wrong-range contract" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "deleted committed Spec cannot become final" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "renamed committed Spec cannot become final" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "copied committed Spec cannot become final" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "committed Spec filename must match change id" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "caller cannot select a permissive historical Spec" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "transient Spec task start must match independent input" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "focused and bot lanes accept ready external transient Specs" -Action { param($fixture)
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

    New-ECPolicyCase -Family "contract" -Name "transient lane rejects a committed-lifecycle Spec candidate" -Action { param($fixture)
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

        New-ECPolicyCase -Family "contract" -Name "governance policy cannot carry arbitrary commands" -Action { param($fixture)
            $policy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $policy | Add-Member -NotePropertyName "commands" -NotePropertyValue @("untrusted")
            Write-FixtureJson -Path $policyFixturePath -Value $policy
            Assert-PolicyRejected {
                & $policyChecker -RepositoryRoot $fixtureRoot -PolicyPath $policyFixturePath
            } "schema|additional|commands"
        }

        New-ECPolicyCase -Family "contract" -Name "protected path group identifiers are unique" -Action { param($fixture)
            $policy = Get-Content -LiteralPath (Join-Path $repositoryRoot ".agentinfra\policy.json") -Raw |
                ConvertFrom-Json -Depth 100
            $policy.protected_paths = @($policy.protected_paths) + @($policy.protected_paths[0])
            Write-FixtureJson -Path $policyFixturePath -Value $policy
            Assert-PolicyRejected {
                & $policyChecker -RepositoryRoot $fixtureRoot -PolicyPath $policyFixturePath
            } "duplicate protected path group"
        }

        New-ECPolicyCase -Family "contract" -Name "valid untracked governance ChangeSpec is authoring-only" -Action { param($fixture)
            Write-FixtureJson -Path $specPath -Value (New-ChangeSpecFixture `
                -TaskStartRevision $fixture.TaskStartRevision)
            $result = & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                -ChangeSpecPath $specPath `
                -RepositoryRoot $fixtureRoot `
                -AllowDraft `
                -PassThru
            if ($result.Lifecycle -ne "authoring" -or $result.Outcome -ne "authoring") {
                throw "Untracked Governance ChangeSpec returned final-equivalent semantics."
            }
        }

        New-ECPolicyCase -Family "contract" -Name "ChangeSpec cannot carry arbitrary commands" -Action { param($fixture)
            $spec = New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision
            $spec.commands = @("Invoke-Expression 'untrusted'")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $specPath `
                    -RepositoryRoot $fixtureRoot `
                    -AllowDraft
            } "schema|additional|commands"
        }

        New-ECPolicyCase -Family "contract" -Name "focused ChangeSpec rejects dependency impact" -Action { param($fixture)
            if (Test-Path -LiteralPath $specPath) {
                Remove-Item -LiteralPath $specPath -Force
            }
            $spec = New-ChangeSpecFixture `
                -TaskStartRevision $fixture.TaskStartRevision `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -ChangesDependencies $true
            Write-FixtureJson -Path $transientContractSpecPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $transientContractSpecPath `
                    -RepositoryRoot $fixtureRoot
            } "focused.*dependency|dependency.*focused"
        }

        New-ECPolicyCase -Family "contract" -Name "ChangeSpec required checks match its profile" -Action { param($fixture)
            $spec = New-ChangeSpecFixture `
                -TaskStartRevision $fixture.TaskStartRevision `
                -RequiredChecks @("change-spec")
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $specPath `
                    -RepositoryRoot $fixtureRoot `
                    -AllowDraft
            } "required checks|profile"
        }

        New-ECPolicyCase -Family "contract" -Name "ChangeSpec paths reject escape and root catch-all forms" -Action { param($fixture)
            foreach ($invalidPath in @("../escape", "C:\absolute", "\\server\share", "**/*")) {
                $spec = New-ChangeSpecFixture -TaskStartRevision $fixture.TaskStartRevision
                $spec.scope.allowed_paths = @($invalidPath)
                Write-FixtureJson -Path $specPath -Value $spec
                Assert-PolicyRejected {
                    & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                        -ChangeSpecPath $specPath `
                        -RepositoryRoot $fixtureRoot `
                        -AllowDraft
                } "relative|parent-directory|catch-all|absolute|drive|UNC|device"
            }
        }

        New-ECPolicyCase -Family "contract" -Name "transient lane cannot persist its ChangeSpec in the repository" -Action { param($fixture)
            $spec = New-ChangeSpecFixture `
                -TaskStartRevision $fixture.TaskStartRevision `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false
            Write-FixtureJson -Path $specPath -Value $spec
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $specPath `
                    -RepositoryRoot $fixtureRoot `
                    -AllowDraft
            } "transient.*outside|outside.*transient"
        }

        New-ECPolicyCase -Family "contract" -Name "committed lane requires the repository ChangeSpec directory" -Action { param($fixture)
            if (Test-Path -LiteralPath $specPath) {
                Remove-Item -LiteralPath $specPath -Force
            }
            Write-FixtureJson -Path $transientContractSpecPath -Value (New-ChangeSpecFixture `
                -TaskStartRevision $fixture.TaskStartRevision)
            Assert-PolicyRejected {
                & $changeSpecChecker `
                    -TaskStartRevision $fixture.TaskStartRevision `
                    -ChangeSpecPath $transientContractSpecPath `
                    -RepositoryRoot $fixtureRoot
            } "committed.*\.agentinfra/changes|\.agentinfra/changes.*committed"
        }

        New-ECPolicyCase -Family "scope" -Name "allowed modified path passes scope" -Action { param($fixture)
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
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("src/allowed.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "allowed added path passes scope" -Action { param($fixture)
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\added.txt"), "added`n", [Text.UTF8Encoding]::new($false))
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("src/added.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "allowed deleted path passes scope" -Action { param($fixture)
            Remove-Item -LiteralPath (Join-Path $scopeRoot "src\delete.txt")
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("src/delete.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "rename endpoints inside scope pass" -Action { param($fixture)
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("mv", "src/rename.txt", "src/renamed.txt")
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("src/rename.txt", "src/renamed.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "rename destination outside scope is rejected" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "copy endpoints inside scope are reported" -Action { param($fixture)
            Copy-Item -LiteralPath (Join-Path $scopeRoot "src\copy-source.txt") -Destination (Join-Path $scopeRoot "src\copied.txt")
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("add", "src/copied.txt")
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("src/copy-source.txt", "src/copied.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "copy destination outside scope is rejected" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "untracked path outside scope is rejected" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "staged and unstaged paths are both reported" -Action { param($fixture)
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\staged.txt"), "staged`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-FixtureGit -Root $scopeRoot -Arguments @("add", "src/staged.txt")
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\allowed.txt"), "unstaged again`n", [Text.UTF8Encoding]::new($false))
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            $staged = @($result.Changes | Where-Object { $_.Path -eq "src/staged.txt" -and "staged" -in $_.Sources })
            $unstaged = @($result.Changes | Where-Object { $_.Path -eq "src/allowed.txt" -and "working" -in $_.Sources })
            if ($staged.Count -ne 1 -or $unstaged.Count -ne 1) {
                throw "Expected distinct staged and working-tree evidence."
            }
            Assert-ChangedPaths -Result $result -Expected @("src/allowed.txt", "src/staged.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "scope matching is Windows-case-insensitive" -Action { param($fixture)
            $caseSpec = New-ChangeSpecFixture `
                -Lane "focused" `
                -Profile "focused" `
                -RequiredChecks @("change-spec", "scope", "protected-paths") `
                -ProtectedChange $false `
                -TaskStartRevision $scopeBase `
                -AllowedPaths @("SRC/**") `
                -ForbiddenPaths @("OTHER/**")
            Write-FixtureJson -Path $scopeSpecPath -Value $caseSpec
            [IO.File]::WriteAllText((Join-Path $scopeRoot "src\allowed.txt"), "case-insensitive change`n", [Text.UTF8Encoding]::new($false))
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("src/allowed.txt")
        }

        New-ECPolicyCase -Family "scope" -Name "changed crate must be declared in expected_crates" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "new crate cannot exceed a zero expansion budget" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "dependency manifest cannot exceed a zero file budget" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "declared dependency manifest budget passes" -Action { param($fixture)
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
                -ForbiddenPaths @("other/**") `
                -DependencyManifestFiles 1
            Write-FixtureJson -Path $scopeCommittedSpecPath -Value $dependencySpec
            $result = & $scopeChecker -TaskStartRevision $scopeBase -ChangeSpecPath $scopeCommittedSpecPath -RepositoryRoot $scopeRoot -AllowDraft -PassThru
            if ($result.ActualBudgets.dependency_manifest_files -ne 1) {
                throw "Expected one changed dependency manifest, got $($result.ActualBudgets.dependency_manifest_files)."
            }
            Assert-ChangedPaths -Result $result -Expected @(
                ".agentinfra/changes/EC-TEST-SCOPE.json",
                "Cargo.toml"
            )
        }

        New-ECPolicyCase -Family "scope" -Name "new manifest cannot exceed a zero expansion budget" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "workflow file cannot exceed a zero expansion budget" -Action { param($fixture)
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

        New-ECPolicyCase -Family "scope" -Name "bot scope cannot widen beyond dependency policy" -Action { param($fixture)
            if (Test-Path -LiteralPath $scopeCommittedSpecPath) {
                Remove-Item -LiteralPath $scopeCommittedSpecPath -Force
            }
            [IO.File]::WriteAllText(
                (Join-Path $scopeRoot "src\allowed.txt"),
                "bot must reject this source change`n",
                [Text.UTF8Encoding]::new($false)
            )
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

        New-ECPolicyCase -Family "scope" -Name "bot scope permits only declared dependency files" -Action { param($fixture)
            $botBase = $scopeBase
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
            $result = & $scopeChecker -TaskStartRevision $botBase -ChangeSpecPath $scopeSpecPath -RepositoryRoot $scopeRoot -PassThru
            Assert-ChangedPaths -Result $result -Expected @("Cargo.toml")
        }

        New-ECPolicyCase -Family "scope" -Name "failed case cleanup preserves the next baseline" -Action { param($fixture)
            $observation = [pscustomobject]@{
                FailedRoot = ""
                NextRoot = ""
            }
            $intentionalFailureObserved = $false
            try {
                Invoke-WithECFixture -Family "scope" -Action {
                    param($failedFixture)
                    $observation.FailedRoot = $failedFixture.Root
                    [IO.File]::WriteAllText(
                        (Join-Path $failedFixture.Root "src\poison.txt"),
                        "must not survive`n",
                        [Text.UTF8Encoding]::new($false)
                    )
                    $null = Invoke-FixtureGit -Root $failedFixture.Root -Arguments @("add", "src/poison.txt")
                    throw "intentional isolated fixture failure"
                }
            }
            catch {
                if ($_.Exception.Message -notmatch "intentional isolated fixture failure") {
                    throw
                }
                $intentionalFailureObserved = $true
            }
            if (-not $intentionalFailureObserved -or (Test-Path -LiteralPath $observation.FailedRoot)) {
                throw "The intentionally failing fixture was not removed before the next case fixture."
            }

            Invoke-WithECFixture -Family "scope" -Action {
                param($nextFixture)
                $observation.NextRoot = $nextFixture.Root
                $status = @(Invoke-FixtureGit -Root $nextFixture.Root -Arguments @("status", "--porcelain"))
                $baseline = Get-Content -LiteralPath (Join-Path $nextFixture.Root "src\allowed.txt") -Raw
                if ($status.Count -ne 0 -or $baseline -ne "allowed baseline`n" -or (Test-Path -LiteralPath (Join-Path $nextFixture.Root "src\poison.txt"))) {
                    throw "The fixture following an intentional failure did not receive a fresh baseline."
                }
            }
            if ($observation.NextRoot -eq $observation.FailedRoot -or (Test-Path -LiteralPath $observation.NextRoot)) {
                throw "The next fixture was reused or was not removed after its assertion."
            }
        }

        New-ECPolicyCase -Family "protected" -Name "focused lane cannot change an acceptance control" -Action { param($fixture)
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

        New-ECPolicyCase -Family "protected" -Name "full lane cannot change an acceptance control" -Action { param($fixture)
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
            [IO.File]::WriteAllText((Join-Path $protectedRoot "scripts\check.ps1"), "Write-Host 'full lane change'`n", [Text.UTF8Encoding]::new($false))
            Assert-PolicyRejected {
                & $protectedChecker -TaskStartRevision $protectedBase -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -AllowDraft
            } "Protected path 'scripts/check\.ps1'.*acceptance-controls.*governance"
        }

        New-ECPolicyCase -Family "protected" -Name "governance protected change remains review-required" -Action { param($fixture)
            $spec = New-ChangeSpecFixture `
                -ChangeId "EC-TEST-PROTECTED" `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 1
            Write-FixtureJson -Path $protectedCommittedSpecPath -Value $spec
            $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("add", ".agentinfra/changes/EC-TEST-PROTECTED.json")
            $null = Invoke-FixtureGit -Root $protectedRoot -Arguments @("commit", "--quiet", "-m", "test: add governance contract")
            [IO.File]::WriteAllText((Join-Path $protectedRoot "scripts\check.ps1"), "Write-Host 'governance change'`n", [Text.UTF8Encoding]::new($false))
            $result = & $protectedChecker -TaskStartRevision $protectedBase -ChangeSpecPath $protectedCommittedSpecPath -RepositoryRoot $protectedRoot -PassThru
            if ($result.Outcome -ne "review_required") {
                throw "Expected review_required, got '$($result.Outcome)'."
            }
            if (@($result.Matches | Where-Object { $_.GroupId -eq "acceptance-controls" }).Count -ne 1) {
                throw "Expected scripts/check.ps1 to be classified as acceptance-controls."
            }
            Assert-ChangedPaths -Result $result -Expected @(
                ".agentinfra/changes/EC-TEST-PROTECTED.json",
                "scripts/check.ps1"
            )
        }

        New-ECPolicyCase -Family "protected" -Name "hosted workflow is classified as remote trust" -Action { param($fixture)
            [IO.File]::WriteAllText((Join-Path $protectedRoot ".github\workflows\ci.yml"), "name: changed fixture`n", [Text.UTF8Encoding]::new($false))
            $spec = New-ChangeSpecFixture `
                -ChangeId "EC-TEST-PROTECTED" `
                -TaskStartRevision $protectedBase `
                -AllowedPaths @("scripts/check.ps1", ".github/workflows/**") `
                -ForbiddenPaths @("src/**") `
                -ProtectedFiles 1 `
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
            Assert-ChangedPaths -Result $result -Expected @(
                ".agentinfra/changes/EC-TEST-PROTECTED.json",
                ".github/workflows/ci.yml"
            )
        }

        New-ECPolicyCase -Family "adapters" -Name "full ChangeSpec generator uses committed repository profile" -Action { param($fixture)
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

        New-ECPolicyCase -Family "adapters" -Name "focused ChangeSpec generator uses transient location" -Action { param($fixture)
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
                $null = Add-ECFixtureFile -Fixture $fixture -Path $result.Path
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

        New-ECPolicyCase -Family "adapters" -Name "transient generator rejects a repository output path" -Action { param($fixture)
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

        New-ECPolicyCase -Family "adapters" -Name "ChangeSpec generator requires an explicit task start" -Action { param($fixture)
            $parameter = (Get-Command $newChangeGenerator).Parameters["TaskStartRevision"]
            $mandatory = @($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory
            })
            if ($mandatory.Count -ne 1) {
                throw "TaskStartRevision is not a mandatory generator input."
            }
        }

        New-ECPolicyCase -Family "adapters" -Name "ChangeSpec generator rejects unavailable and non-ancestor starts" -Action { param($fixture)
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

        New-ECPolicyCase -Family "adapters" -Name "bot ChangeSpec generator derives dependency contract" -Action { param($fixture)
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
                $null = Add-ECFixtureFile -Fixture $fixture -Path $result.Path
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

        New-ECPolicyCase -Family "adapters" -Name "missing required verification resolves to not_run" -Action { param($fixture)
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

        New-ECPolicyCase -Family "adapters" -Name "only passed verification statuses can pass" -Action { param($fixture)
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

        New-ECPolicyCase -Family "adapters" -Name "governance outcome cannot be promoted by green checks" -Action { param($fixture)
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

        New-ECPolicyCase -Family "adapters" -Name "dependency bot message requires explicit bot mode" -Action { param($fixture)
            $botMessage = "Bump serde from 1.0.203 to 1.0.204"
            Assert-PolicyRejected {
                & $commitMessageChecker -Message $botMessage
            } "subject|body|blank line"
            & $commitMessageChecker -Message $botMessage -Bot
        }
)

Assert-ECPolicyCaseRegistry -Cases $caseRegistry
$selectedCases = @($caseRegistry | Where-Object {
    ($Suite -eq "all" -or $_.Family -ceq $Suite) -and
    ([string]::IsNullOrWhiteSpace($CaseName) -or $_.Name -ceq $CaseName)
})
if ($selectedCases.Count -eq 0) {
    $failed++
    Write-Host "FAIL: no exact case named '$CaseName' exists in suite '$Suite'."
}
else {
    if ($Order -eq "reverse") {
        [array]::Reverse($selectedCases)
    }
    foreach ($case in $selectedCases) {
        Invoke-IsolatedPolicyCase `
            -Family ([string]$case.Family) `
            -Name ([string]$case.Name) `
            -Action ([scriptblock]$case.Action)
    }
}
try {
    Assert-RecordedFixtureCleanup
}
catch {
    $failed++
    Write-Host "FAIL: fixture cleanup audit`n$($_ | Out-String)"
}

Write-Host "Executable Constitution self-tests: passed=$passed failed=$failed order=$Order"
if ($failed -gt 0) {
    throw "$failed executable Constitution self-test(s) failed."
}
