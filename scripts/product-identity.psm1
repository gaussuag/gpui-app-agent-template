Set-StrictMode -Version Latest

$script:TemplateBinaryName = "gpui-app-agent-template"
$script:TemplateDisplayName = "GPUI Agent Template"
$script:TemplateDescription = "A Windows-first Rust and GPUI desktop application."
$script:TemplatePublisher = "Unconfigured Publisher"
$script:TemplateIconSha256 = "B1269BC889FF840BF1664935BDB0C6F6A1BBF7564A7F87AE9B3E58E63C9E23CA"

function Assert-SingleLineValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match "[`r`n`0]") {
        throw "$Name must be a non-empty single-line value."
    }
}

function Assert-ProductSlug {
    param([Parameter(Mandatory = $true)][string]$ProductSlug)

    if ($ProductSlug.Length -gt 64 -or $ProductSlug -cnotmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$') {
        throw "ProductSlug must be 1-64 lowercase ASCII characters in kebab-case and start with a letter."
    }
}

function ConvertTo-ProductSlug {
    param([Parameter(Mandatory = $true)][string]$Value)

    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ($slug -match '^[0-9]') {
        $slug = "app-$slug"
    }
    if ($slug.Length -gt 64) {
        $slug = $slug.Substring(0, 64).TrimEnd('-')
    }
    Assert-ProductSlug -ProductSlug $slug
    return $slug
}

function ConvertTo-DisplayName {
    param([Parameter(Mandatory = $true)][string]$ProductSlug)

    Assert-ProductSlug -ProductSlug $ProductSlug
    $culture = [Globalization.CultureInfo]::InvariantCulture
    return (($ProductSlug -split '-') | ForEach-Object {
        $culture.TextInfo.ToTitleCase($_)
    }) -join ' '
}

function Get-SuggestedProductSlug {
    param([Parameter(Mandatory = $true)][string]$Root)

    $candidate = $null
    Push-Location $Root
    try {
        $remote = & git config --get remote.origin.url 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remote)) {
            $candidate = [IO.Path]::GetFileNameWithoutExtension($remote.Trim().TrimEnd('/'))
        }
    }
    finally {
        Pop-Location
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Split-Path -Leaf (Resolve-Path -LiteralPath $Root).Path
    }
    return ConvertTo-ProductSlug -Value $candidate
}

function Get-WorkspaceMetadata {
    param([Parameter(Mandatory = $true)][string]$Root)

    $cargoPath = & (Join-Path $Root "scripts\resolve-cargo.ps1")
    Push-Location $Root
    try {
        $metadataJson = & $cargoPath metadata --locked --no-deps --format-version 1
        if ($LASTEXITCODE -ne 0) {
            throw "cargo metadata failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
    return $metadataJson | ConvertFrom-Json
}

function Get-ProductIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $metadata = Get-WorkspaceMetadata -Root $resolvedRoot
    $packages = @($metadata.packages | Where-Object {
        $_.name -eq "desktop" -and $_.id -in $metadata.workspace_members
    })
    if ($packages.Count -ne 1) {
        throw "Product identity requires exactly one workspace package named desktop."
    }

    $binaryTargets = @($packages[0].targets | Where-Object { $_.kind -contains "bin" })
    if ($binaryTargets.Count -ne 1) {
        throw "Product identity requires desktop to expose exactly one binary target; found $($binaryTargets.Count)."
    }

    $resource = $packages[0].metadata.winresource
    if ($null -eq $resource) {
        throw "desktop Cargo.toml is missing [package.metadata.winresource]."
    }

    $identity = [pscustomobject]@{
        Root = $resolvedRoot
        TargetDirectory = [string]$metadata.target_directory
        PackageName = $packages[0].name
        BinaryName = [string]$binaryTargets[0].name
        Description = [string]$packages[0].description
        Version = [string]$packages[0].version
        ProductName = [string]$resource.ProductName
        CompanyName = [string]$resource.CompanyName
        LegalCopyright = [string]$resource.LegalCopyright
        OriginalFilename = [string]$resource.OriginalFilename
        InternalName = [string]$resource.InternalName
        IconPath = Join-Path $resolvedRoot "crates\desktop\resources\windows\app.ico"
    }

    foreach ($field in @("BinaryName", "Description", "ProductName", "CompanyName", "LegalCopyright", "OriginalFilename", "InternalName")) {
        Assert-SingleLineValue -Name $field -Value $identity.$field
    }
    Assert-ProductSlug -ProductSlug $identity.BinaryName
    return $identity
}

function Assert-CleanWorktree {
    param([Parameter(Mandatory = $true)][string]$Root)

    Push-Location $Root
    try {
        $inside = & git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0 -or $inside -ne "true") {
            throw "Product configuration requires a Git worktree so changes remain reviewable."
        }
        $status = @(& git status --porcelain=v1 --untracked-files=all)
        if ($LASTEXITCODE -ne 0) {
            throw "git status failed while checking the worktree."
        }
        if ($status.Count -gt 0) {
            throw "Product configuration requires a clean worktree. Commit or stash current changes first.`n$($status -join "`n")"
        }
    }
    finally {
        Pop-Location
    }
}

function ConvertTo-TomlStringContent {
    param([Parameter(Mandatory = $true)][string]$Value)

    Assert-SingleLineValue -Name "TOML identity value" -Value $Value
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t')
}

function Set-RegexValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Field
    )

    $text = [IO.File]::ReadAllText($Path)
    $regex = [regex]::new($Pattern)
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Field assignment in $Path; found $($matches.Count)."
    }
    $replacement = ConvertTo-TomlStringContent -Value $Value
    $updated = $regex.Replace(
        $text,
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $match.Groups["prefix"].Value + '"' + $replacement + '"'
        }
    )
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Set-LiteralBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Field
    )

    $text = [IO.File]::ReadAllText($Path)
    $regex = [regex]::new($Pattern)
    if ($regex.Matches($text).Count -ne 1) {
        throw "Expected exactly one $Field in $Path."
    }
    $updated = $regex.Replace($text, [Text.RegularExpressions.MatchEvaluator]{ param($match) $Replacement })
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Set-ProductIdentityFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$ProductSlug,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Publisher,
        [Parameter(Mandatory = $true)][string]$LegalCopyright,
        [string]$IconPath,
        [ValidateSet("Template", "Development", "Release")][string]$Profile = "Development"
    )

    foreach ($pair in @(
        @{ Name = "DisplayName"; Value = $DisplayName },
        @{ Name = "Description"; Value = $Description },
        @{ Name = "Publisher"; Value = $Publisher },
        @{ Name = "LegalCopyright"; Value = $LegalCopyright }
    )) {
        Assert-SingleLineValue -Name $pair.Name -Value $pair.Value
    }
    if ($ProductSlug) {
        Assert-ProductSlug -ProductSlug $ProductSlug
    }

    $resolvedIcon = $null
    if ($IconPath) {
        $resolvedIcon = (Resolve-Path -LiteralPath $IconPath).Path
        if ([IO.Path]::GetExtension($resolvedIcon) -cne ".ico") {
            throw "IconPath must point to an .ico file."
        }
        $iconBytes = [IO.File]::ReadAllBytes($resolvedIcon)
        if ($iconBytes.Length -lt 22 -or [BitConverter]::ToUInt16($iconBytes, 2) -ne 1 -or [BitConverter]::ToUInt16($iconBytes, 4) -lt 1) {
            throw "IconPath is not a structurally valid ICO file: $resolvedIcon"
        }
    }

    $manifestPath = Join-Path $Root "crates\desktop\Cargo.toml"
    $readmePath = Join-Path $Root "README.md"
    $licensePath = Join-Path $Root "LICENSE"
    $checkPath = Join-Path $Root "scripts\check.ps1"
    $destination = Join-Path $Root "crates\desktop\resources\windows\app.ico"
    $textPaths = @($manifestPath, $readmePath, $licensePath, $checkPath)
    $originalText = @{}
    foreach ($path in $textPaths) {
        $originalText[$path] = [IO.File]::ReadAllText($path)
    }
    $originalIcon = [IO.File]::ReadAllBytes($destination)

    try {
        if ($ProductSlug) {
            Set-RegexValue -Path $manifestPath -Pattern '(?ms)(?<prefix>\[\[bin\]\]\s*\r?\nname\s*=\s*)"(?:\\.|[^"])*"' -Value $ProductSlug -Field "desktop binary name"
            Set-RegexValue -Path $manifestPath -Pattern '(?m)^(?<prefix>OriginalFilename\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value "$ProductSlug.exe" -Field "OriginalFilename"
            Set-RegexValue -Path $manifestPath -Pattern '(?m)^(?<prefix>InternalName\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value $ProductSlug -Field "InternalName"
        }
        Set-RegexValue -Path $manifestPath -Pattern '(?m)^(?<prefix>description\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value $Description -Field "package description"
        Set-RegexValue -Path $manifestPath -Pattern '(?m)^(?<prefix>ProductName\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value $DisplayName -Field "ProductName"
        Set-RegexValue -Path $manifestPath -Pattern '(?m)^(?<prefix>CompanyName\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value $Publisher -Field "CompanyName"
        Set-RegexValue -Path $manifestPath -Pattern '(?m)^(?<prefix>LegalCopyright\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value $LegalCopyright -Field "LegalCopyright"

        Set-LiteralBlock -Path $readmePath -Pattern '(?m)^# .+$' -Replacement "# $DisplayName" -Field "README product heading"
        $summary = "<!-- product-summary:start -->`r`n$Description`r`n<!-- product-summary:end -->"
        Set-LiteralBlock -Path $readmePath -Pattern '(?ms)<!-- product-summary:start -->.*?<!-- product-summary:end -->' -Replacement $summary -Field "README product summary"
        Set-LiteralBlock -Path $licensePath -Pattern '(?m)^Copyright \(c\) .+$' -Replacement $LegalCopyright -Field "LICENSE copyright"
        Set-RegexValue -Path $checkPath -Pattern '(?m)^(?<prefix>\$productProfile\s*=\s*)"(?:\\.|[^"])*"\s*$' -Value $Profile -Field "canonical product profile"

        if ($resolvedIcon -and -not [string]::Equals($resolvedIcon, $destination, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $resolvedIcon -Destination $destination -Force
        }
    }
    catch {
        foreach ($path in $textPaths) {
            [IO.File]::WriteAllText($path, $originalText[$path], [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllBytes($destination, $originalIcon)
        throw
    }
}

function Get-TemplateIdentityDefaults {
    return [pscustomobject]@{
        BinaryName = $script:TemplateBinaryName
        DisplayName = $script:TemplateDisplayName
        Description = $script:TemplateDescription
        Publisher = $script:TemplatePublisher
        IconSha256 = $script:TemplateIconSha256
    }
}

Export-ModuleMember -Function @(
    "Assert-CleanWorktree",
    "Assert-ProductSlug",
    "Assert-SingleLineValue",
    "ConvertTo-DisplayName",
    "ConvertTo-ProductSlug",
    "Get-ProductIdentity",
    "Get-SuggestedProductSlug",
    "Get-TemplateIdentityDefaults",
    "Set-ProductIdentityFiles"
)
