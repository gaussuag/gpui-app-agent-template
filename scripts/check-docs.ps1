[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$errors = [System.Collections.Generic.List[string]]::new()

function Get-MarkdownFiles {
    param([string]$Directory)

    Get-ChildItem -LiteralPath $Directory -File -Filter "*.md"
    foreach ($child in Get-ChildItem -LiteralPath $Directory -Directory -Force) {
        if ($child.Name -in @(".git", "target", "node_modules") -or
            ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            continue
        }
        Get-MarkdownFiles -Directory $child.FullName
    }
}

# Check local link targets, not a prescribed set of Agent documents.
# Fragment validity and remote URLs are outside this lightweight check.
$linkPattern = [regex]'!?\[[^\]]*\]\((?<target><[^>]+>|[^\s\)]+)'
foreach ($file in Get-MarkdownFiles -Directory $root) {
    $lines = @(Get-Content -LiteralPath $file.FullName)
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        foreach ($match in $linkPattern.Matches($lines[$lineIndex])) {
            $target = $match.Groups["target"].Value.Trim('<', '>')
            if ($target.StartsWith("#") -or $target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
                continue
            }
            $pathPart = ($target -split '[#?]', 2)[0]
            if ([string]::IsNullOrWhiteSpace($pathPart)) { continue }

            $decodedPath = [Uri]::UnescapeDataString($pathPart)
            $candidate = if ([IO.Path]::IsPathRooted($decodedPath)) {
                Join-Path $root $decodedPath.TrimStart('/', '\')
            }
            else {
                Join-Path $file.DirectoryName $decodedPath
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                $source = [IO.Path]::GetRelativePath($root, $file.FullName)
                $errors.Add("${source}:$($lineIndex + 1): missing local target '$target'")
            }
        }
    }
}

if ($errors.Count -gt 0) {
    throw "Documentation link check failed:`n$($errors -join "`n")"
}
Write-Host "Local Markdown link targets passed."
