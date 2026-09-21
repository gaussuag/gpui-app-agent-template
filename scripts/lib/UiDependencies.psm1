# Validate Cargo metadata separately from process invocation so policy fixtures
# exercise the same graph rules as the architecture gate.
function Assert-UiDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Metadata)

    $kitNames = @("gpui-kit", "gpui-base", "gpui-component", "gpui-component-macros", "gpui-kit-assets")
    $snapshotNames = @($Metadata.packages | Where-Object { $_.name -like "gpui-pre*" } | ForEach-Object name)
    $required = @($kitNames + $snapshotNames + @("gpui-pre", "gpui-pre-platform", "gpui-pre-windows", "gpui-pre-macros") | Sort-Object -Unique)
    $byName = @{}
    foreach ($name in $required) {
        $packages = @($Metadata.packages | Where-Object name -eq $name)
        if ($packages.Count -ne 1) {
            throw "UI dependency identity violation: expected one $name package, found $($packages.Count)."
        }
        if ([string]$packages[0].source -notlike "registry+*") {
            throw "UI dependency source violation: $name must resolve from a registry."
        }
        $byName[$name] = $packages[0]
    }
    foreach ($package in $Metadata.packages) {
        if ($package.name -match '^gpui($|[-_])' -and $package.name -notin $required) {
            throw "UI dependency identity violation: legacy GPUI package $($package.name); use the Kit stack."
        }
    }
    foreach ($name in $kitNames) {
        if ($byName[$name].version -ne $byName["gpui-kit"].version) {
            throw "UI dependency identity violation: Kit layer versions must match gpui-kit ($name)."
        }
    }
    foreach ($name in $snapshotNames) {
        # The renamed reqwest fork keeps reqwest's version, not Zed's snapshot version.
        if ($name -ne "gpui-pre-reqwest" -and $byName[$name].version -ne $byName["gpui-pre"].version) {
            throw "UI dependency identity violation: GPUI snapshot versions must match ($name)."
        }
    }
    $reviewedSnapshot = [string]$Metadata.metadata."ui-bom"."gpui-pre"
    if ($reviewedSnapshot -notmatch '^\d+\.\d+\.\d+$' -or $byName["gpui-pre"].version -ne $reviewedSnapshot) {
        throw "UI dependency identity violation: gpui-pre must match the reviewed snapshot in workspace.metadata.ui-bom."
    }
    $gpuiNodes = @($Metadata.resolve.nodes | Where-Object id -eq $byName["gpui-pre"].id)
    if ($gpuiNodes.Count -ne 1 -or $gpuiNodes[0].features -notcontains "windows-manifest") {
        throw "Windows manifest ownership violation: resolved gpui-pre must enable windows-manifest."
    }

    $ui = $null
    foreach ($name in @("app-core", "app-ui", "desktop")) {
        $members = @($Metadata.packages | Where-Object { $_.name -eq $name -and $_.id -in $Metadata.workspace_members })
        if ($members.Count -ne 1) {
            throw "UI architecture violation: expected one workspace $name."
        }
        $member = $members[0]
        foreach ($dependency in $member.dependencies) {
            if ($dependency.name -match '^gpui($|[-_])' -and ($name -ne "app-ui" -or $dependency.name -ne "gpui-kit")) {
                throw "UI architecture violation: $name dependency $($dependency.name) bypasses the app-ui Kit facade."
            }
        }
        if ($name -eq "app-ui") { $ui = $member }
    }
    $runtime = @($ui.dependencies | Where-Object { $_.name -eq "gpui-kit" -and $null -eq $_.kind })
    if ($runtime.Count -ne 1 -or $runtime[0].features -notcontains "component" -or $runtime[0].features -notcontains "assets") {
        throw "UI architecture violation: app-ui runtime must enable gpui-kit component and assets."
    }
    if ($ui.features."test-support" -notcontains "gpui-kit/test-support") {
        throw "Test architecture violation: app-ui test-support must enable gpui-kit/test-support."
    }
    $tests = @($ui.dependencies | Where-Object { $_.name -eq "gpui-kit" -and $_.kind -eq "dev" })
    if ($tests.Count -ne 1 -or $tests[0].features -notcontains "test-support") {
        throw "Test architecture violation: app-ui needs one Kit dev dependency with test-support."
    }
}

Export-ModuleMember -Function Assert-UiDependencies
