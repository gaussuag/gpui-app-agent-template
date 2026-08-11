[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SourceRoot = "",
    [string]$AllowlistPath = ""
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path $RepositoryRoot "crates"
}
if ([string]::IsNullOrWhiteSpace($AllowlistPath)) {
    $AllowlistPath = Join-Path $RepositoryRoot "docs\agent-risk-allowlist.txt"
}

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Source risk check failed: source root does not exist: $SourceRoot"
}
if (-not (Test-Path -LiteralPath $AllowlistPath -PathType Leaf)) {
    throw "Source risk check failed: allowlist does not exist: $AllowlistPath"
}

$riskPatterns = @(
    [pscustomobject]@{ Id = "detached-task"; Pattern = '\.detach\s*\(' },
    [pscustomobject]@{ Id = "unbounded-channel"; Pattern = '\b(?:unbounded|unbounded_channel)\s*\(' },
    [pscustomobject]@{ Id = "blocking-bridge"; Pattern = '\b(?:block_on|send_blocking|recv_blocking)\s*\(' },
    [pscustomobject]@{ Id = "thread-sleep"; Pattern = '\b(?:std::)?thread::sleep\s*\(' },
    [pscustomobject]@{ Id = "process-exit"; Pattern = '\b(?:std::)?process::exit\s*\(' }
)

$findings = [System.Collections.Generic.List[object]]::new()
$sourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter "*.rs"
foreach ($file in $sourceFiles) {
    foreach ($risk in $riskPatterns) {
        foreach ($match in @(Select-String -LiteralPath $file.FullName -Pattern $risk.Pattern)) {
            $relativePath = $file.FullName.Substring($RepositoryRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            $findings.Add([pscustomobject]@{
                Path = $relativePath
                Risk = $risk.Id
                Line = $match.LineNumber
            })
        }
    }
}

$allowlist = @{}
$allowlistLines = @(Get-Content -LiteralPath $AllowlistPath)
for ($lineIndex = 0; $lineIndex -lt $allowlistLines.Count; $lineIndex++) {
    $line = $allowlistLines[$lineIndex].Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
        continue
    }

    $parts = @($line -split '\|')
    if ($parts.Count -ne 3) {
        throw "Source risk allowlist line $($lineIndex + 1) must be path|risk-id|adr-path."
    }
    $relativePath = $parts[0].Trim().Replace('\', '/')
    $riskId = $parts[1].Trim()
    $adrPath = $parts[2].Trim().Replace('\', '/')
    $knownRisk = $riskPatterns.Id -contains $riskId
    if (-not $knownRisk) {
        throw "Source risk allowlist line $($lineIndex + 1) uses unknown risk id '$riskId'."
    }

    $key = "$($relativePath.ToLowerInvariant())|$riskId"
    if ($allowlist.ContainsKey($key)) {
        throw "Source risk allowlist contains a duplicate entry for $relativePath and $riskId."
    }

    $adrFullPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $adrPath))
    $rootPrefix = $RepositoryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $adrFullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Source risk allowlist ADR escapes the repository: $adrPath"
    }
    if (-not (Test-Path -LiteralPath $adrFullPath -PathType Leaf)) {
        throw "Source risk allowlist ADR does not exist: $adrPath"
    }
    $adrText = Get-Content -Raw -LiteralPath $adrFullPath
    if ($adrText -notmatch '(?im)^- Status:\s*accepted\s*$') {
        throw "Source risk allowlist ADR must have accepted status: $adrPath"
    }

    $allowlist[$key] = [pscustomobject]@{
        Path = $relativePath
        Risk = $riskId
        Adr = $adrPath
    }
}

$errors = [System.Collections.Generic.List[string]]::new()
foreach ($finding in $findings) {
    $key = "$($finding.Path.ToLowerInvariant())|$($finding.Risk)"
    if (-not $allowlist.ContainsKey($key)) {
        $errors.Add("$($finding.Path):$($finding.Line) [$($finding.Risk)] needs an accepted ADR and allowlist entry")
    }
}
foreach ($entry in $allowlist.Values) {
    $matched = $findings | Where-Object {
        $_.Path -ieq $entry.Path -and $_.Risk -eq $entry.Risk
    }
    if (-not $matched) {
        $errors.Add("stale source-risk allowlist entry: $($entry.Path)|$($entry.Risk)|$($entry.Adr)")
    }
}

if ($errors.Count -gt 0) {
    $details = $errors | Sort-Object -Unique | ForEach-Object { "- $_" }
    throw "Source risk check failed:`n$($details -join "`n")"
}

Write-Host "Source risk checks passed ($($findings.Count) reviewed finding(s))."
