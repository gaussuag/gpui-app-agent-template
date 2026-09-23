[CmdletBinding()]
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "../agent-foundation/tools/check-docs.ps1") -RepositoryRoot $RepositoryRoot
