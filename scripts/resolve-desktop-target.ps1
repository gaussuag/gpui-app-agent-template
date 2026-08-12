[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force

$identity = Get-ProductIdentity -Root $root
[pscustomobject]@{
    PackageName = $identity.PackageName
    BinaryName = $identity.BinaryName
    TargetDirectory = $identity.TargetDirectory
}
