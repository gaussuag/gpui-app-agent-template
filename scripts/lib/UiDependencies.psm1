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
    }
    foreach ($member in @($Metadata.packages | Where-Object { $_.id -in $Metadata.workspace_members })) {
        $name = $member.name
        foreach ($dependency in $member.dependencies) {
            if ($dependency.name -match '^gpui($|[-_])' -and ($name -ne "app-ui" -or $dependency.name -ne "gpui-kit")) {
                throw "UI architecture violation: $name dependency $($dependency.name) bypasses the app-ui Kit facade."
            }
            if ($dependency.name -match '^(windows|windows-sys|winapi)$' -and $name -ne 'overlay-win32') {
                throw "Native isolation violation: $name must not depend on $($dependency.name); use overlay-win32."
            }
            if ($name -eq 'overlay-win32' -and $dependency.name -in @('app-core', 'app-ui', 'desktop')) {
                throw "Native isolation violation: overlay-win32 must not depend on $($dependency.name)."
            }
            if ($name -eq 'app-core' -and $dependency.name -in @('overlay-win32', 'raw-window-handle')) {
                throw "Native isolation violation: app-core must not contain platform dependencies."
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

function Assert-OverlaySource {
    param([string]$RelativePath, [string]$Source)
    $relative = $RelativePath.Replace('\', '/')
    if ($relative -like 'crates/app-ui/src/*.rs') {
        if ($Source -match '\b(windows|windows_sys|winapi)::|\bWM_[A-Z_]+\b') {
            throw "Native source isolation violation: Win32 implementation in $relative."
        }
        if ($relative -ne 'crates/app-ui/src/overlay/native_bridge.rs' -and $Source -match '\b(overlay_win32|raw_window_handle)::') {
            throw "Native bridge isolation violation: adapter access in $relative."
        }
    }
    if ($relative -like 'crates/overlay-win32/*.rs' -and $relative -notlike 'crates/overlay-win32/src/windows/*') {
        $allowed = $Source
        if ($relative -eq 'crates/overlay-win32/src/lib.rs') {
            $allowed = $allowed -replace '#\[allow\(unsafe_code\)\]\s*mod windows;', 'mod windows;'
        }
        if ($allowed -match '\bunsafe\s*(\{|fn|extern|impl|trait)|#\s*!?\s*\[allow\s*\(unsafe_code') {
            throw "Unsafe isolation violation: unsafe is restricted to overlay-win32/src/windows ($relative)."
        }
    }
}

Export-ModuleMember -Function Assert-UiDependencies, Assert-OverlaySource
