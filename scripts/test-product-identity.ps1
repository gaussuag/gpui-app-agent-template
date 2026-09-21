[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force

function Assert-Rejected {
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Case)
    try {
        & $Action | Out-Null
    }
    catch {
        return
    }
    throw "Product identity self-test expected rejection for $Case."
}

$slug = ConvertTo-ProductSlug -Value "Invoice Studio Desktop"
if ($slug -ne "invoice-studio-desktop") {
    throw "Product slug normalization returned '$slug'."
}
if ((ConvertTo-DisplayName -ProductSlug $slug) -ne "Invoice Studio Desktop") {
    throw "Display-name suggestion did not preserve slug words."
}
Assert-Rejected -Case "uppercase product slug" -Action {
    Assert-ProductSlug -ProductSlug "Invoice-Studio"
}
Assert-Rejected -Case "unsafe product slug punctuation" -Action {
    Assert-ProductSlug -ProductSlug "invoice/studio"
}
Assert-Rejected -Case "multiline identity field" -Action {
    Assert-SingleLineValue -Name "ProductName" -Value "Invoice`nStudio"
}

$manifestXml = @'
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
  <dependency><dependentAssembly>
    <assemblyIdentity name="Microsoft.Windows.Common-Controls" version="6.0.0.0" />
  </dependentAssembly></dependency>
</assembly>
'@
Assert-WindowsManifest -Manifest ([xml]$manifestXml)
Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('true/pm', 'true'))
Assert-Rejected -Case "DPI unaware manifest" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('true/pm', 'false'))
}
Assert-Rejected -Case "missing DPI declaration" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('dpiAware ', 'missing ').Replace('</dpiAware>', '</missing>'))
}
Assert-Rejected -Case "missing PerMonitorV2" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('PerMonitorV2', 'System'))
}
Assert-Rejected -Case "old Common Controls" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('6.0.0.0', '5.0.0.0'))
}
Assert-Rejected -Case "missing Common Controls" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('Microsoft.Windows.Common-Controls', 'Other.Controls'))
}

$checkText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "check.ps1"))
$profileMatch = [regex]::Match($checkText, '(?m)^\$productProfile\s*=\s*"(?<profile>Template|Development|Release)"\s*$')
if (-not $profileMatch.Success) {
    throw "Could not resolve the canonical product profile from scripts/check.ps1."
}
$profile = $profileMatch.Groups["profile"].Value
& (Join-Path $PSScriptRoot "check-product.ps1") -Profile $profile | Out-Null
$wrongProfile = if ($profile -eq "Template") { "Release" } else { "Template" }
Assert-Rejected -Case "$wrongProfile policy against a $profile repository" -Action {
    & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $wrongProfile
}


# Exercise identity edits without a repository-governance file. Use real source
# inputs but no Cargo build or mutation of the current checkout.
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$fixtureRoot = Join-Path $tempBase ("gpui-identity-" + [Guid]::NewGuid().ToString("N"))
$fixtureFiles = @(
    "crates\desktop\Cargo.toml", "README.md", "LICENSE", "scripts\check.ps1",
    "crates\desktop\resources\windows\app.ico"
)
try {
    foreach ($relativePath in $fixtureFiles) {
        $destination = Join-Path $fixtureRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $relativePath) -Destination $destination
    }
    $identityArguments = @{
        Root = $fixtureRoot
        ProductSlug = "fixture-product"
        DisplayName = "Fixture Product"
        Description = "Identity fixture."
        Publisher = "Fixture Publisher"
        LegalCopyright = "Copyright (c) 2026 Fixture Publisher"
        Profile = "Development"
    }
    Set-ProductIdentityFiles @identityArguments
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot "crates\desktop\Cargo.toml")
    $fixtureCheck = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot "scripts\check.ps1")
    if ($manifest -notmatch '(?m)^name = "fixture-product"$' -or
        $manifest -notmatch '(?m)^ProductName = "Fixture Product"$' -or
        $fixtureCheck -notmatch '(?m)^\$productProfile = "Development"\r?$') {
        throw "Identity edit without governance files did not update product fields and check profile."
    }

    # An invalid target document fails after manifest edits have begun. Verify
    # that all allowlisted files are restored by the existing rollback path.
    Set-Content -LiteralPath (Join-Path $fixtureRoot "README.md") -Value "Missing product heading and markers."
    $before = @{}
    foreach ($relativePath in $fixtureFiles) {
        $before[$relativePath] = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixtureRoot $relativePath)))
    }
    $identityArguments.DisplayName = "Changed Product"
    Assert-Rejected -Case "missing README identity block" -Action {
        Set-ProductIdentityFiles @identityArguments
    }
    foreach ($relativePath in $fixtureFiles) {
        $after = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixtureRoot $relativePath)))
        if ($after -cne $before[$relativePath]) { throw "Identity rollback changed $relativePath." }
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove identity fixture outside the temporary directory."
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

Write-Host "Product identity validation and rollback tests passed."
