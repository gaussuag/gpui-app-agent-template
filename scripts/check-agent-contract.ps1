[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$requiredFiles = @(
    "AGENTS.md",
    "crates/app-core/AGENTS.md",
    "crates/app-ui/AGENTS.md",
    "crates/desktop/AGENTS.md",
    "scripts/AGENTS.md",
    ".github/AGENTS.md",
    "docs/agent-workflow.md",
    "docs/agent-development-standard.md",
    "docs/agent-task-template.md",
    "docs/architecture.md",
    "docs/dependency-policy.md",
    "docs/windows-platform.md",
    "docs/git-commit-policy.md",
    "docs/decisions/README.md",
    "docs/templates/adr.md",
    "docs/templates/lifecycle-ledger.md",
    "docs/agent-risk-allowlist.txt"
)

$errors = [System.Collections.Generic.List[string]]::new()
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath))) {
        $errors.Add("required Agent contract file is missing: $relativePath")
    }
}

$rootContractPath = Join-Path $root "AGENTS.md"
if (Test-Path -LiteralPath $rootContractPath) {
    $rootContract = Get-Content -Raw -LiteralPath $rootContractPath
    foreach ($pointer in @(
        "docs/agent-workflow.md",
        "docs/agent-development-standard.md",
        "docs/agent-task-template.md",
        "docs/architecture.md",
        "docs/dependency-policy.md",
        "docs/windows-platform.md",
        "docs/git-commit-policy.md",
        "docs/decisions/README.md",
        "scripts/check.ps1"
    )) {
        if (-not $rootContract.Contains($pointer)) {
            $errors.Add("root AGENTS.md must route Agents to $pointer")
        }
    }
}

$markdownFiles = Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.md" |
    Where-Object {
        $_.FullName -notmatch '[\\/](\.git|target)[\\/]'
    }
$linkPattern = [regex]'!?\[[^\]]*\]\((?<target><[^>]+>|[^\s\)]+)'

foreach ($file in $markdownFiles) {
    $lines = @(Get-Content -LiteralPath $file.FullName)
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        foreach ($match in $linkPattern.Matches($lines[$lineIndex])) {
            $target = $match.Groups["target"].Value.Trim('<', '>')
            if (
                [string]::IsNullOrWhiteSpace($target) -or
                $target.StartsWith("#") -or
                $target -match '^[A-Za-z][A-Za-z0-9+.-]*:'
            ) {
                continue
            }

            $pathPart = ($target -split '[#?]', 2)[0]
            if ([string]::IsNullOrWhiteSpace($pathPart)) {
                continue
            }

            $decodedPath = [Uri]::UnescapeDataString($pathPart)
            $candidate = if ([IO.Path]::IsPathRooted($decodedPath)) {
                Join-Path $root $decodedPath.TrimStart('/', '\')
            }
            else {
                Join-Path $file.DirectoryName $decodedPath
            }

            if (-not (Test-Path -LiteralPath $candidate)) {
                $source = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
                $errors.Add("broken local Markdown link at ${source}:$($lineIndex + 1): $target")
            }
        }
    }
}

if ($errors.Count -gt 0) {
    $details = $errors | Sort-Object -Unique | ForEach-Object { "- $_" }
    throw "Agent contract check failed:`n$($details -join "`n")"
}

Write-Host "Agent entry, scoped instruction, and Markdown link checks passed."
