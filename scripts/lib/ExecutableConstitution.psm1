Set-StrictMode -Version Latest

function Read-ECJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Invalid JSON at ${Path}: $($_.Exception.Message)"
    }
}

function ConvertTo-ECNormalizedRepoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowGlob
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains([char]0)) {
        throw "Repository paths must be non-empty and cannot contain NUL."
    }

    $normalized = $Path.Replace('\', '/')
    if (
        $normalized.StartsWith('/') -or
        $normalized.StartsWith('//') -or
        $normalized -match '^[A-Za-z]:' -or
        [IO.Path]::IsPathFullyQualified($Path)
    ) {
        throw "Repository paths must be relative; absolute, drive, UNC, and device paths are rejected: $Path"
    }
    if ($normalized.Contains(':')) {
        throw "Repository paths cannot contain a Windows drive or stream separator: $Path"
    }

    $segments = @($normalized -split '/')
    $invalidSegments = @($segments | Where-Object { $_ -in @('', '.', '..') })
    if ($segments.Count -eq 0 -or $invalidSegments.Count -gt 0) {
        throw "Repository paths cannot contain empty, current-directory, or parent-directory segments: $Path"
    }
    if (-not $AllowGlob -and $normalized.IndexOfAny([char[]]@('*', '?', '[', ']')) -ge 0) {
        throw "Concrete repository paths cannot contain glob metacharacters: $Path"
    }
    if ($AllowGlob) {
        if ($normalized.IndexOfAny([char[]]@('[', ']')) -ge 0) {
            throw "Repository globs support only '*' and '?' metacharacters: $Path"
        }
        if ($normalized -in @('*', '**', '**/*')) {
            throw "Root-wide catch-all globs are not allowed: $Path"
        }
    }

    return $normalized
}

function ConvertTo-ECGlobRegex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Glob)

    $normalized = ConvertTo-ECNormalizedRepoPath -Path $Glob -AllowGlob
    $builder = [Text.StringBuilder]::new('^')
    for ($index = 0; $index -lt $normalized.Length; $index++) {
        $character = $normalized[$index]
        if ($character -eq '*') {
            $isDouble = $index + 1 -lt $normalized.Length -and $normalized[$index + 1] -eq '*'
            if ($isDouble) {
                $index++
                if ($index + 1 -lt $normalized.Length -and $normalized[$index + 1] -eq '/') {
                    $index++
                    $null = $builder.Append('(?:.*/)?')
                }
                else {
                    $null = $builder.Append('.*')
                }
            }
            else {
                $null = $builder.Append('[^/]*')
            }
        }
        elseif ($character -eq '?') {
            $null = $builder.Append('[^/]')
        }
        else {
            $null = $builder.Append([Regex]::Escape([string]$character))
        }
    }
    $null = $builder.Append('$')
    return $builder.ToString()
}

function Test-ECRepoGlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Glob
    )

    $normalizedPath = ConvertTo-ECNormalizedRepoPath -Path $Path
    $regex = ConvertTo-ECGlobRegex -Glob $Glob
    return [Regex]::IsMatch(
        $normalizedPath,
        $regex,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Invoke-ECGitRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add([IO.Path]::GetFullPath($RepositoryRoot))
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Git did not start.'
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $standardOutput.GetAwaiter().GetResult()
        $errorOutput = $standardError.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed with exit code $($process.ExitCode): $($errorOutput.Trim())"
        }
        return $output
    }
    finally {
        $process.Dispose()
    }
}

function ConvertFrom-ECNameStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Raw,
        [Parameter(Mandatory = $true)][string]$Source
    )

    if ([string]::IsNullOrEmpty($Raw)) {
        return
    }

    $tokens = @($Raw.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries))
    $index = 0
    while ($index -lt $tokens.Count) {
        $status = $tokens[$index]
        $index++
        if ($status -match '^(R|C)\d*$') {
            if ($index + 1 -ge $tokens.Count) {
                throw "Malformed git name-status output for $Source."
            }
            $oldPath = ConvertTo-ECNormalizedRepoPath -Path $tokens[$index]
            $newPath = ConvertTo-ECNormalizedRepoPath -Path $tokens[$index + 1]
            $index += 2
            [pscustomobject]@{ Path = $oldPath; Status = "$status-old"; Source = $Source }
            [pscustomobject]@{ Path = $newPath; Status = "$status-new"; Source = $Source }
            continue
        }
        if ($index -ge $tokens.Count) {
            throw "Malformed git name-status output for $Source."
        }
        $path = ConvertTo-ECNormalizedRepoPath -Path $tokens[$index]
        $index++
        [pscustomobject]@{ Path = $path; Status = $status; Source = $Source }
    }
}

function Get-ECChangedPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TaskStartRevision,
        [string]$HeadRevision = 'HEAD'
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $rawRecords = [Collections.Generic.List[object]]::new()
    $sources = @(
        @{ Name = 'committed'; Arguments = @('diff', '--name-status', '-z', '--find-renames', '--find-copies-harder', "$TaskStartRevision...$HeadRevision", '--') },
        @{ Name = 'staged'; Arguments = @('diff', '--cached', '--name-status', '-z', '--find-renames', '--find-copies-harder', '--') },
        @{ Name = 'working'; Arguments = @('diff', '--name-status', '-z', '--find-renames', '--find-copies-harder', '--') }
    )
    foreach ($source in $sources) {
        $raw = Invoke-ECGitRaw -RepositoryRoot $root -Arguments $source.Arguments
        foreach ($record in @(ConvertFrom-ECNameStatus -Raw $raw -Source $source.Name)) {
            $rawRecords.Add($record)
        }
    }

    $untracked = Invoke-ECGitRaw -RepositoryRoot $root -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    if (-not [string]::IsNullOrEmpty($untracked)) {
        foreach ($path in $untracked.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)) {
            $rawRecords.Add([pscustomobject]@{
                Path = ConvertTo-ECNormalizedRepoPath -Path $path
                Status = 'A'
                Source = 'untracked'
            })
        }
    }

    $byPath = @{}
    foreach ($record in $rawRecords) {
        if (-not $byPath.ContainsKey($record.Path)) {
            $byPath[$record.Path] = [pscustomobject]@{
                Path = $record.Path
                Statuses = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                Sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            }
        }
        $null = $byPath[$record.Path].Statuses.Add($record.Status)
        $null = $byPath[$record.Path].Sources.Add($record.Source)
    }

    foreach ($entry in @($byPath.Values | Sort-Object Path)) {
        [pscustomobject]@{
            Path = $entry.Path
            Statuses = @($entry.Statuses | Sort-Object)
            Sources = @($entry.Sources | Sort-Object)
        }
    }
}

function Resolve-ECCommitRevision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        $resolved = (Invoke-ECGitRaw `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @('rev-parse', '--verify', "$Revision^{commit}")).Trim()
    }
    catch {
        throw "$Label is not an available commit: $Revision"
    }
    if ($resolved -notmatch '^[0-9a-fA-F]{40,64}$') {
        throw "$Label did not resolve to a full commit id: $Revision"
    }
    return $resolved
}

function Get-ECRepositoryPathInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $relative = [IO.Path]::GetRelativePath($root, $fullPath).Replace('\', '/')
    $isInside = (
        $relative -ne '..' -and
        -not $relative.StartsWith('../') -and
        -not [IO.Path]::IsPathRooted($relative)
    )
    return [pscustomobject]@{
        FullPath = $fullPath
        IsInside = $isInside
        RelativePath = if ($isInside) {
            ConvertTo-ECNormalizedRepoPath -Path $relative
        }
        else {
            $null
        }
    }
}

function Test-ECChangeSpecRepoPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path -match '^\.agentinfra/changes/[^/]+\.json$'
}

function Get-ECNameStatusRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $raw = Invoke-ECGitRaw -RepositoryRoot $RepositoryRoot -Arguments $Arguments
    return @(ConvertFrom-ECNameStatus -Raw $raw -Source $Source)
}

function Get-ECCommitPathHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TaskStartRevision,
        [Parameter(Mandatory = $true)][string]$HeadRevision
    )

    $rawCommits = Invoke-ECGitRaw `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @('rev-list', '--reverse', "$TaskStartRevision..$HeadRevision")
    $commits = @($rawCommits -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($commit in $commits) {
        $parentLine = (Invoke-ECGitRaw `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @('rev-list', '--parents', '-n', '1', $commit)).Trim()
        $parentParts = @($parentLine -split ' ' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $parents = if ($parentParts.Count -gt 1) { @($parentParts[1..($parentParts.Count - 1)]) } else { @() }
        $records = @(Get-ECNameStatusRecords `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @(
                'diff-tree',
                '--root',
                '--no-commit-id',
                '--name-status',
                '-r',
                '-z',
                '--find-renames',
                '--find-copies-harder',
                $commit,
                '--'
            ) `
            -Source 'history')
        foreach ($record in $records) {
            [pscustomobject]@{
                Commit = $commit
                Parents = @($parents)
                Path = $record.Path
                Status = $record.Status
                Source = 'history'
            }
        }
    }
}

function Test-ECGitPathAtRevision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        $null = Invoke-ECGitRaw `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @('cat-file', '-e', "${Revision}:$Path")
        return $true
    }
    catch {
        return $false
    }
}

function Test-ECGitTrackedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        $null = Invoke-ECGitRaw `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @('ls-files', '--error-unmatch', '--', $Path)
        return $true
    }
    catch {
        return $false
    }
}

function Test-ECChangeSpecDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ChangeSpecPath,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][string]$EffectiveTaskStartRevision,
        [switch]$AllowDraft
    )

    $schemaPath = Join-Path $RepositoryRoot '.agentinfra\schemas\change-spec.schema.json'
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
        throw 'ChangeSpec does not match its schema.'
    }

    $spec = Read-ECJsonFile -Path $ChangeSpecPath
    if (
        -not [string]::Equals(
            [string]$spec.task_start_revision,
            $EffectiveTaskStartRevision,
            [StringComparison]::Ordinal
        )
    ) {
        throw "ChangeSpec declared task-start '$($spec.task_start_revision)' must exactly match independent task-start '$EffectiveTaskStartRevision'."
    }
    if ($spec.state -eq 'draft' -and -not $AllowDraft) {
        throw "Draft ChangeSpec '$($spec.change_id)' is not executable. Complete it and set state to ready."
    }

    foreach ($glob in @($spec.scope.allowed_paths) + @($spec.scope.forbidden_paths)) {
        $null = ConvertTo-ECNormalizedRepoPath -Path $glob -AllowGlob
    }
    foreach ($adrPath in @($spec.architecture.adr_paths)) {
        $normalizedAdr = ConvertTo-ECNormalizedRepoPath -Path $adrPath
        if (-not $normalizedAdr.StartsWith('docs/decisions/', [StringComparison]::OrdinalIgnoreCase)) {
            throw "ADR paths must be repository-relative files under docs/decisions: $adrPath"
        }
    }

    $profileProperty = $Policy.checks.profiles.PSObject.Properties[$spec.verification.profile]
    if ($null -eq $profileProperty) {
        throw "Unknown verification profile '$($spec.verification.profile)'."
    }
    $profile = $profileProperty.Value
    if ($spec.lane -notin @($profile.allowed_lanes)) {
        throw "Verification profile '$($spec.verification.profile)' does not allow lane '$($spec.lane)'."
    }
    if ($Policy.repository_profile -notin @($profile.repository_profiles)) {
        throw "Verification profile '$($spec.verification.profile)' does not apply to '$($Policy.repository_profile)' repositories."
    }

    $requiredDifference = @(Compare-Object `
        -ReferenceObject @($profile.required_checks | Sort-Object) `
        -DifferenceObject @($spec.verification.required_checks | Sort-Object))
    if ($requiredDifference.Count -gt 0) {
        throw "ChangeSpec required checks must exactly match verification profile '$($spec.verification.profile)'."
    }

    $architectureFlags = @(
        'changes_owner_or_dependency_direction',
        'changes_async_or_resource_lifecycle',
        'changes_platform_boundary',
        'changes_dependencies',
        'changes_protocol_or_persistence',
        'changes_privacy_or_sensitive_data',
        'changes_unsafe_boundary',
        'changes_public_architecture_layers'
    )
    if ($spec.lane -eq 'focused') {
        $enabledFlags = @($architectureFlags | Where-Object { $spec.architecture.$_ })
        if ($enabledFlags.Count -gt 0) {
            throw "A focused ChangeSpec cannot declare dependency, lifecycle, platform, protocol, privacy, unsafe, ownership, or public-architecture impact: $($enabledFlags -join ', ')."
        }
        $nonZeroBudgets = @($spec.budgets.PSObject.Properties | Where-Object { [int64]$_.Value -ne 0 })
        if ($nonZeroBudgets.Count -gt 0) {
            throw 'A focused ChangeSpec must keep every expansion budget at zero.'
        }
    }

    if ($spec.lane -ne 'governance' -and $spec.protected_change) {
        throw 'Only the governance lane may declare protected_change.'
    }
    if ($spec.lane -eq 'bot') {
        if ($spec.change_kind -ne 'dependency' -or -not $spec.architecture.changes_dependencies) {
            throw 'The bot lane is restricted to declared dependency changes.'
        }
    }

    $requiresAdr = @(
        $spec.architecture.changes_owner_or_dependency_direction,
        $spec.architecture.changes_platform_boundary,
        $spec.architecture.changes_protocol_or_persistence,
        $spec.architecture.changes_unsafe_boundary
    ) -contains $true
    if ($requiresAdr -and @($spec.architecture.adr_paths).Count -eq 0) {
        throw 'The declared architecture impact requires at least one ADR path.'
    }
    if ($spec.state -eq 'ready' -and @($spec.owner_decisions | Where-Object { $_ -match '^(?i)blocking:' }).Count -gt 0) {
        throw 'A ready ChangeSpec cannot retain a blocking owner decision.'
    }

    return $spec
}

function Resolve-ECChangeContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TaskStartRevision,
        [string]$HeadRevision = 'HEAD',
        [string]$ChangeSpecPath = '',
        [string]$PolicyPath = '',
        [switch]$AllowDraft
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $effectiveTaskStart = $TaskStartRevision.Trim()
    if ($effectiveTaskStart -notmatch '^[0-9a-fA-F]{40,64}$') {
        throw "Independent task-start must be a full commit id: $TaskStartRevision"
    }
    $resolvedTaskStart = Resolve-ECCommitRevision `
        -RepositoryRoot $root `
        -Revision $effectiveTaskStart `
        -Label 'Independent task-start'
    $resolvedHead = Resolve-ECCommitRevision `
        -RepositoryRoot $root `
        -Revision $HeadRevision `
        -Label 'Head revision'
    $currentHead = Resolve-ECCommitRevision `
        -RepositoryRoot $root `
        -Revision 'HEAD' `
        -Label 'Current checkout HEAD'
    if (-not [string]::Equals($resolvedHead, $currentHead, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Head revision '$resolvedHead' must equal current checkout HEAD '$currentHead'; check out the requested revision before local acceptance."
    }
    try {
        $mergeBase = (Invoke-ECGitRaw `
            -RepositoryRoot $root `
            -Arguments @('merge-base', $resolvedTaskStart, $resolvedHead)).Trim()
    }
    catch {
        throw "Independent task-start '$effectiveTaskStart' is not an ancestor of head '$resolvedHead'."
    }
    if (-not [string]::Equals($mergeBase, $resolvedTaskStart, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Independent task-start '$effectiveTaskStart' is not an ancestor of head '$resolvedHead'."
    }

    if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
        $PolicyPath = Join-Path $root '.agentinfra\policy.json'
    }
    elseif (-not [IO.Path]::IsPathRooted($PolicyPath)) {
        $PolicyPath = Join-Path $root $PolicyPath
    }
    $policy = Read-ECJsonFile -Path ([IO.Path]::GetFullPath($PolicyPath))

    $history = @(Get-ECCommitPathHistory `
        -RepositoryRoot $root `
        -TaskStartRevision $resolvedTaskStart `
        -HeadRevision $resolvedHead)
    $net = @(Get-ECNameStatusRecords `
        -RepositoryRoot $root `
        -Arguments @('diff', '--name-status', '-z', '--find-renames', '--find-copies-harder', "$resolvedTaskStart..$resolvedHead", '--') `
        -Source 'committed-net')
    $staged = @(Get-ECNameStatusRecords `
        -RepositoryRoot $root `
        -Arguments @('diff', '--cached', '--name-status', '-z', '--find-renames', '--find-copies-harder', '--') `
        -Source 'staged')
    $working = @(Get-ECNameStatusRecords `
        -RepositoryRoot $root `
        -Arguments @('diff', '--name-status', '-z', '--find-renames', '--find-copies-harder', '--') `
        -Source 'working')
    $untracked = [Collections.Generic.List[object]]::new()
    $rawUntracked = Invoke-ECGitRaw -RepositoryRoot $root -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    if (-not [string]::IsNullOrEmpty($rawUntracked)) {
        foreach ($path in $rawUntracked.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)) {
            $untracked.Add([pscustomobject]@{
                Path = ConvertTo-ECNormalizedRepoPath -Path $path
                Status = 'A'
                Source = 'untracked'
            })
        }
    }

    $historySpecs = @($history | Where-Object { Test-ECChangeSpecRepoPath -Path $_.Path })
    $netSpecs = @($net | Where-Object { Test-ECChangeSpecRepoPath -Path $_.Path })
    $stagedSpecs = @($staged | Where-Object { Test-ECChangeSpecRepoPath -Path $_.Path })
    $workingSpecs = @($working | Where-Object { Test-ECChangeSpecRepoPath -Path $_.Path })
    $untrackedSpecs = @($untracked | Where-Object { Test-ECChangeSpecRepoPath -Path $_.Path })
    $historySpecPaths = @($historySpecs | ForEach-Object { $_.Path })
    $netSpecPaths = @($netSpecs | ForEach-Object { $_.Path })
    $stagedSpecPaths = @($stagedSpecs | ForEach-Object { $_.Path })
    $workingSpecPaths = @($workingSpecs | ForEach-Object { $_.Path })
    $untrackedSpecPaths = @($untrackedSpecs | ForEach-Object { $_.Path })
    $rangeSpecPaths = @((@($historySpecPaths) + @($netSpecPaths)) | Sort-Object -Unique)
    $uncommittedSpecPaths = @((@($stagedSpecPaths) + @($workingSpecPaths) + @($untrackedSpecPaths)) | Sort-Object -Unique)
    $allRepoSpecPaths = @((@($rangeSpecPaths) + @($uncommittedSpecPaths)) | Sort-Object -Unique)

    if ($allRepoSpecPaths.Count -gt 1) {
        throw "Task range contains ambiguous ChangeSpec paths: $($allRepoSpecPaths -join ', ')."
    }

    $assertedPathInfo = $null
    if (-not [string]::IsNullOrWhiteSpace($ChangeSpecPath)) {
        if (-not [IO.Path]::IsPathRooted($ChangeSpecPath)) {
            $ChangeSpecPath = Join-Path $root $ChangeSpecPath
        }
        $assertedPathInfo = Get-ECRepositoryPathInfo -RepositoryRoot $root -Path $ChangeSpecPath
    }

    $candidatePath = $null
    $candidateRelativePath = $null
    $lifecycle = 'final'
    $committedLifecycle = $rangeSpecPaths.Count -eq 1
    if ($committedLifecycle) {
        $candidateRelativePath = $rangeSpecPaths[0]
        $candidatePath = [IO.Path]::GetFullPath((Join-Path $root $candidateRelativePath))
        if (
            $null -ne $assertedPathInfo -and
            -not [string]::Equals($assertedPathInfo.FullPath, $candidatePath, [StringComparison]::OrdinalIgnoreCase)
        ) {
            throw "Caller ChangeSpec path '$($assertedPathInfo.FullPath)' does not match automatically resolved contract '$candidatePath'."
        }
        if ($uncommittedSpecPaths.Count -gt 0) {
            if (-not $AllowDraft) {
                throw "Final committed ChangeSpec '$candidateRelativePath' has staged, unstaged, or untracked differences."
            }
            $lifecycle = 'authoring'
        }
    }
    else {
        if ($null -eq $assertedPathInfo) {
            throw 'No ChangeSpec was resolved from the task range; transient or authoring validation requires ChangeSpecPath.'
        }
        $candidatePath = $assertedPathInfo.FullPath
        $candidateRelativePath = $assertedPathInfo.RelativePath
        if ($assertedPathInfo.IsInside) {
            if (-not (Test-ECChangeSpecRepoPath -Path $candidateRelativePath)) {
                throw 'A committed-lifecycle ChangeSpec must be directly under .agentinfra/changes.'
            }
            if (
                $uncommittedSpecPaths.Count -ne 1 -or
                -not [string]::Equals($uncommittedSpecPaths[0], $candidateRelativePath, [StringComparison]::OrdinalIgnoreCase)
            ) {
                throw "No new authoring ChangeSpec was resolved at '$candidateRelativePath'."
            }
            if (Test-ECGitPathAtRevision -RepositoryRoot $root -Revision $resolvedHead -Path $candidateRelativePath) {
                throw "ChangeSpec '$candidateRelativePath' belongs to earlier history and was not added in this task range."
            }
            if (-not [string]::Equals($resolvedHead, $resolvedTaskStart, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'A Full/Governance authoring ChangeSpec must be created before any task commit.'
            }
            if (-not $AllowDraft) {
                throw "Final validation rejects untracked or staged-only committed ChangeSpec '$candidateRelativePath'."
            }
            $lifecycle = 'authoring'
        }
        elseif ($allRepoSpecPaths.Count -gt 0) {
            throw 'A transient ChangeSpec cannot be combined with a repository committed-lifecycle ChangeSpec.'
        }
    }

    $spec = Test-ECChangeSpecDocument `
        -RepositoryRoot $root `
        -ChangeSpecPath $candidatePath `
        -Policy $policy `
        -EffectiveTaskStartRevision $effectiveTaskStart `
        -AllowDraft:$AllowDraft
    if ($spec.state -eq 'draft') {
        $lifecycle = 'authoring'
    }
    $persistence = [string]$policy.lanes.($spec.lane).persistence
    if ($committedLifecycle -or ($null -ne $assertedPathInfo -and $assertedPathInfo.IsInside)) {
        if ($persistence -ne 'committed') {
            throw "Lane '$($spec.lane)' requires a transient ChangeSpec outside the repository."
        }
    }
    elseif ($persistence -ne 'transient') {
        throw "Lane '$($spec.lane)' requires a committed ChangeSpec directly under .agentinfra/changes."
    }

    if ($committedLifecycle) {
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            throw "Committed ChangeSpec is deleted from the worktree: $candidateRelativePath"
        }
        if (-not (Test-ECGitTrackedPath -RepositoryRoot $root -Path $candidateRelativePath)) {
            throw "Committed ChangeSpec is not Git tracked: $candidateRelativePath"
        }
        if (-not (Test-ECGitPathAtRevision -RepositoryRoot $root -Revision $resolvedHead -Path $candidateRelativePath)) {
            throw "Committed ChangeSpec is not present at head '$resolvedHead': $candidateRelativePath"
        }

        $historyForCandidate = @($historySpecs | Where-Object {
            [string]::Equals($_.Path, $candidateRelativePath, [StringComparison]::OrdinalIgnoreCase)
        })
        $invalidHistory = @($historyForCandidate | Where-Object { $_.Status -notin @('A', 'M') })
        if ($invalidHistory.Count -gt 0) {
            throw "Committed ChangeSpec history may only add then modify one path; found '$($invalidHistory[0].Status)' for '$candidateRelativePath'."
        }
        $addRecords = @($historyForCandidate | Where-Object { $_.Status -eq 'A' })
        if ($addRecords.Count -ne 1) {
            throw "Committed ChangeSpec '$candidateRelativePath' must have exactly one first Add commit in the task range."
        }
        $addParents = @($addRecords[0].Parents)
        if (
            $addParents.Count -ne 1 -or
            -not [string]::Equals($addParents[0], $resolvedTaskStart, [StringComparison]::OrdinalIgnoreCase)
        ) {
            throw "Committed ChangeSpec first Add commit must have effective task-start '$effectiveTaskStart' as its only parent."
        }
        $candidateNet = @($netSpecs | Where-Object {
            [string]::Equals($_.Path, $candidateRelativePath, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($candidateNet.Count -ne 1 -or $candidateNet[0].Status -ne 'A') {
            throw "Committed ChangeSpec '$candidateRelativePath' must remain a single added path in the final net diff."
        }

        $expectedFileName = "$($spec.change_id).json"
        if (-not [string]::Equals([IO.Path]::GetFileName($candidatePath), $expectedFileName, [StringComparison]::Ordinal)) {
            throw "ChangeSpec filename must equal <change_id>.json; expected '$expectedFileName'."
        }
        try {
            $initialSpec = (Invoke-ECGitRaw `
                -RepositoryRoot $root `
                -Arguments @('show', "$($addRecords[0].Commit):$candidateRelativePath")) |
                ConvertFrom-Json -Depth 100
        }
        catch {
            throw "Unable to parse ChangeSpec from first Add commit '$($addRecords[0].Commit)': $($_.Exception.Message)"
        }
        if (
            -not [string]::Equals([string]$initialSpec.change_id, [string]$spec.change_id, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$initialSpec.task_start_revision, [string]$spec.task_start_revision, [StringComparison]::Ordinal)
        ) {
            throw 'Committed ChangeSpec change_id and task_start_revision must remain unchanged after their first Add commit.'
        }
        if ($lifecycle -eq 'final' -and $spec.state -ne 'ready') {
            throw "Final committed ChangeSpec '$($spec.change_id)' must be ready."
        }
    }
    elseif ($null -ne $assertedPathInfo -and -not $assertedPathInfo.IsInside) {
        if ($persistence -ne 'transient') {
            throw "Lane '$($spec.lane)' requires a committed ChangeSpec directly under .agentinfra/changes."
        }
        if ($spec.state -eq 'draft') {
            $lifecycle = 'authoring'
        }
    }

    $outcome = if ($lifecycle -eq 'authoring') {
        'authoring'
    }
    else {
        [string]$policy.lanes.($spec.lane).default_outcome
    }
    return [pscustomobject]@{
        Spec = $spec
        Policy = $policy
        ChangeSpecPath = $candidatePath
        EffectiveTaskStartRevision = $effectiveTaskStart
        HeadRevision = $resolvedHead
        Lifecycle = $lifecycle
        Outcome = $outcome
    }
}

function Resolve-ECVerificationStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][string[]]$RequiredChecks,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Results,
        [ValidateSet('eligible', 'review_required')][string]$ContractOutcome = 'eligible'
    )

    $registeredChecks = @($Policy.checks.registry)
    $duplicateRequired = @($RequiredChecks | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -First 1)
    if ($duplicateRequired.Count -gt 0) {
        throw "Required check '$($duplicateRequired[0].Name)' is duplicated."
    }
    foreach ($requiredCheck in $RequiredChecks) {
        if ($requiredCheck -notin $registeredChecks) {
            throw "Required check '$requiredCheck' is not registered by policy."
        }
    }

    $byCheck = @{}
    foreach ($result in $Results) {
        $check = [string]$result.check
        $status = [string]$result.status
        if ([string]::IsNullOrWhiteSpace($check) -or $check -notin $registeredChecks) {
            throw "Verification result references unregistered check '$check'."
        }
        if ($status -notin @($Policy.result_statuses)) {
            throw "Verification result for '$check' has unknown status '$status'."
        }
        if ($byCheck.ContainsKey($check)) {
            throw "Verification results contain duplicate check '$check'."
        }
        $byCheck[$check] = $status
    }

    $normalizedResults = @($RequiredChecks | ForEach-Object {
        $status = if ($byCheck.ContainsKey($_)) { [string]$byCheck[$_] } else { 'not_run' }
        [pscustomobject]@{ check = $_; status = $status }
    })
    $nonPassing = @($normalizedResults | Where-Object {
        $_.status -notin @($Policy.passing_statuses)
    })
    $missing = @($normalizedResults | Where-Object { $_.status -eq 'not_run' } | ForEach-Object { $_.check })

    if ($ContractOutcome -eq 'review_required') {
        $status = 'review_required'
    }
    elseif ($nonPassing.Count -eq 0) {
        $status = 'passed'
    }
    else {
        $priority = @('policy_rejected', 'failed', 'environment_failure', 'review_required', 'not_run', 'skipped')
        $status = @($priority | Where-Object { $_ -in @($nonPassing.status) } | Select-Object -First 1)[0]
    }

    return [pscustomobject]@{
        Status = $status
        Passing = $status -in @($Policy.passing_statuses)
        Checks = $normalizedResults
        MissingChecks = $missing
        NonPassingChecks = @($nonPassing)
    }
}

Export-ModuleMember -Function @(
    "ConvertTo-ECNormalizedRepoPath",
    "Get-ECChangedPaths",
    "Read-ECJsonFile",
    "Resolve-ECChangeContract",
    "Resolve-ECVerificationStatus",
    "Test-ECRepoGlob"
)
