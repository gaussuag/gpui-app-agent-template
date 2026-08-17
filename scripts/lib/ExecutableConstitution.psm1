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
    if ($segments.Count -eq 0 -or $segments | Where-Object { $_ -in @('', '.', '..') }) {
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

Export-ModuleMember -Function @(
    "ConvertTo-ECNormalizedRepoPath",
    "Read-ECJsonFile"
)
