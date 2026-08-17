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
    "Resolve-ECVerificationStatus",
    "Test-ECRepoGlob"
)
