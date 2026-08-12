[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Template", "Development", "Release")]
    [string]$Profile,
    [string]$ArtifactPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force

function Assert-Equal {
    param([string]$Name, [string]$Actual, [string]$Expected)
    if ($Actual -cne $Expected) {
        throw "Product identity mismatch for ${Name}: expected '$Expected', found '$Actual'."
    }
}

function Find-MtExe {
    $command = Get-Command mt.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (-not (Test-Path -LiteralPath $kitsRoot)) {
        throw "Windows SDK mt.exe was not found. Install the Windows SDK required by docs/windows-platform.md."
    }
    $matches = @(Get-ChildItem -LiteralPath $kitsRoot -Recurse -Filter mt.exe -File |
        Where-Object { $_.Directory.Name -eq "x64" } |
        Sort-Object FullName -Descending)
    if ($matches.Count -eq 0) {
        throw "Windows SDK mt.exe was not found under $kitsRoot."
    }
    return $matches[0].FullName
}

function Assert-ArtifactIdentity {
    param([Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][string]$Path)

    $resolvedArtifact = (Resolve-Path -LiteralPath $Path).Path
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedArtifact)
    Assert-Equal -Name "PE ProductName" -Actual $versionInfo.ProductName -Expected $Identity.ProductName
    Assert-Equal -Name "PE CompanyName" -Actual $versionInfo.CompanyName -Expected $Identity.CompanyName
    Assert-Equal -Name "PE FileDescription" -Actual $versionInfo.FileDescription -Expected $Identity.Description
    Assert-Equal -Name "PE OriginalFilename" -Actual $versionInfo.OriginalFilename -Expected $Identity.OriginalFilename
    Assert-Equal -Name "PE LegalCopyright" -Actual $versionInfo.LegalCopyright -Expected $Identity.LegalCopyright
    Assert-Equal -Name "PE FileVersion" -Actual $versionInfo.FileVersion -Expected $Identity.Version
    Assert-Equal -Name "PE ProductVersion" -Actual $versionInfo.ProductVersion -Expected $Identity.Version

    if (-not ("TemplateProductResource.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @'
namespace TemplateProductResource {
    using System;
    using System.Runtime.InteropServices;
    public static class NativeMethods {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
    }
}
'@
    }
    $iconCount = [TemplateProductResource.NativeMethods]::ExtractIconEx(
        $resolvedArtifact,
        -1,
        $null,
        $null,
        0
    )
    if ($iconCount -lt 1) {
        throw "Windows artifact has no extractable icon: $resolvedArtifact"
    }

    $manifestPath = [IO.Path]::GetTempFileName()
    try {
        $mt = Find-MtExe
        & $mt -nologo "-inputresource:$resolvedArtifact;#1" "-out:$manifestPath"
        if ($LASTEXITCODE -ne 0) {
            throw "mt.exe could not extract application manifest resource ID 1."
        }
        [xml]$manifest = [IO.File]::ReadAllText($manifestPath)
        $dpiAware = $manifest.SelectSingleNode("//*[local-name()='dpiAware']")
        if ($null -eq $dpiAware -or $dpiAware.InnerText -ne "true") {
            throw "Application manifest resource ID 1 must declare dpiAware=true."
        }
        $dpiAwareness = $manifest.SelectSingleNode("//*[local-name()='dpiAwareness']")
        if ($null -eq $dpiAwareness -or $dpiAwareness.InnerText -ne "PerMonitorV2") {
            throw "Application manifest resource ID 1 must declare dpiAwareness=PerMonitorV2."
        }
        $commonControls = $manifest.SelectSingleNode("//*[local-name()='assemblyIdentity' and @name='Microsoft.Windows.Common-Controls']")
        if ($null -eq $commonControls -or $commonControls.version -ne "6.0.0.0") {
            throw "Application manifest resource ID 1 must declare Common Controls v6."
        }
    }
    finally {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
}

$identity = Get-ProductIdentity -Root $root
$defaults = Get-TemplateIdentityDefaults
Assert-Equal -Name "OriginalFilename" -Actual $identity.OriginalFilename -Expected "$($identity.BinaryName).exe"
Assert-Equal -Name "InternalName" -Actual $identity.InternalName -Expected $identity.BinaryName

if (-not (Test-Path -LiteralPath $identity.IconPath -PathType Leaf)) {
    throw "Product icon is missing: $($identity.IconPath)"
}
$iconBytes = [IO.File]::ReadAllBytes($identity.IconPath)
if ($iconBytes.Length -lt 22 -or [BitConverter]::ToUInt16($iconBytes, 2) -ne 1 -or [BitConverter]::ToUInt16($iconBytes, 4) -lt 1) {
    throw "Product icon is not a structurally valid ICO file: $($identity.IconPath)"
}
$iconHash = (Get-FileHash -LiteralPath $identity.IconPath -Algorithm SHA256).Hash

$readme = [IO.File]::ReadAllText((Join-Path $root "README.md"))
if (-not $readme.StartsWith("# $($identity.ProductName)`r`n") -and -not $readme.StartsWith("# $($identity.ProductName)`n")) {
    throw "README heading must match ProductName '$($identity.ProductName)'."
}
$summaryPattern = [regex]::Escape("<!-- product-summary:start -->") + '\s*' + [regex]::Escape($identity.Description) + '\s*' + [regex]::Escape("<!-- product-summary:end -->")
if ($readme -notmatch $summaryPattern) {
    throw "README product summary must match the desktop package description."
}
$license = [IO.File]::ReadAllText((Join-Path $root "LICENSE"))
if (-not $license.Contains($identity.LegalCopyright)) {
    throw "LICENSE must contain the configured LegalCopyright value."
}

switch ($Profile) {
    "Template" {
        Assert-Equal -Name "template binary" -Actual $identity.BinaryName -Expected $defaults.BinaryName
        Assert-Equal -Name "template display" -Actual $identity.ProductName -Expected $defaults.DisplayName
        Assert-Equal -Name "template description" -Actual $identity.Description -Expected $defaults.Description
        Assert-Equal -Name "template publisher" -Actual $identity.CompanyName -Expected $defaults.Publisher
        Assert-Equal -Name "template icon" -Actual $iconHash -Expected $defaults.IconSha256
    }
    "Development" {
        if ($identity.BinaryName -eq $defaults.BinaryName -or $identity.ProductName -eq $defaults.DisplayName) {
            throw "Development identity still contains a template product sentinel. Run scripts/init-project.ps1."
        }
    }
    "Release" {
        if ($identity.BinaryName -eq $defaults.BinaryName -or $identity.ProductName -eq $defaults.DisplayName) {
            throw "Release identity still contains a template product sentinel."
        }
        if ($identity.CompanyName -eq $defaults.Publisher) {
            throw "Release identity still uses the unconfigured publisher placeholder."
        }
        if ($iconHash -eq $defaults.IconSha256) {
            throw "Release identity still uses the neutral template icon."
        }
    }
}

if ($ArtifactPath) {
    Assert-ArtifactIdentity -Identity $identity -Path $ArtifactPath
}

Write-Host "$Profile product identity checks passed."
