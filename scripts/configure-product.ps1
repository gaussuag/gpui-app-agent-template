[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$DisplayName,
    [string]$Description,
    [string]$Publisher,
    [string]$IconPath,
    [ValidateSet("Development", "Release")]
    [string]$Profile = "Development",
    [switch]$SkipFullCheck
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force

if (-not $PSBoundParameters.ContainsKey("DisplayName") -and
    -not $PSBoundParameters.ContainsKey("Description") -and
    -not $PSBoundParameters.ContainsKey("Publisher") -and
    -not $PSBoundParameters.ContainsKey("IconPath") -and
    -not $PSBoundParameters.ContainsKey("Profile")) {
    throw "Pass at least one mutable identity field or an explicit Profile."
}

Assert-CleanWorktree -Root $root
$current = Get-ProductIdentity -Root $root
$defaults = Get-TemplateIdentityDefaults
if ($current.BinaryName -eq $defaults.BinaryName) {
    throw "Initialize the repository with init-project.ps1 before configuring product identity."
}

$nextDisplayName = if ($PSBoundParameters.ContainsKey("DisplayName")) { $DisplayName } else { $current.ProductName }
$nextDescription = if ($PSBoundParameters.ContainsKey("Description")) { $Description } else { $current.Description }
$nextPublisher = if ($PSBoundParameters.ContainsKey("Publisher")) { $Publisher } else { $current.CompanyName }
$year = [DateTime]::UtcNow.Year
$nextCopyright = if ($PSBoundParameters.ContainsKey("Publisher")) {
    "Copyright (c) $year $nextPublisher"
}
else {
    $current.LegalCopyright
}
foreach ($pair in @(
    @{ Name = "DisplayName"; Value = $nextDisplayName },
    @{ Name = "Description"; Value = $nextDescription },
    @{ Name = "Publisher"; Value = $nextPublisher }
)) {
    Assert-SingleLineValue -Name $pair.Name -Value $pair.Value
}

Write-Host "Product configuration plan for immutable binary '$($current.BinaryName)':"
Write-Host "  display:    $nextDisplayName"
Write-Host "  description:$nextDescription"
Write-Host "  publisher:  $nextPublisher"
Write-Host "  profile:    $Profile"
if ($IconPath) {
    Write-Host "  icon:       $((Resolve-Path -LiteralPath $IconPath).Path)"
}

if (-not $PSCmdlet.ShouldProcess($root, "configure mutable product identity")) {
    return
}

Set-ProductIdentityFiles `
    -Root $root `
    -DisplayName $nextDisplayName `
    -Description $nextDescription `
    -Publisher $nextPublisher `
    -LegalCopyright $nextCopyright `
    -IconPath $IconPath `
    -Profile $Profile

& (Join-Path $PSScriptRoot "check-product.ps1") -Profile $Profile
if (-not $SkipFullCheck) {
    & (Join-Path $PSScriptRoot "check.ps1")
}

Write-Host "Product configuration completed. Review and commit the identity changes."
