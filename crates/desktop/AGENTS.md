# Process and product identity

Keep this crate thin: executable target, product metadata, ICON/VERSIONINFO,
process startup flags and the UI launcher. Domain state and GPUI rendering
belong in their respective crates.

For identity/build changes read [product identity](../../docs/product-identity.md).
GPUI owns application manifest resource ID 1; `build.rs` embeds only icon and
VERSIONINFO. Preserve release console ownership unless the spec changes it.

For native APIs or exit changes read [Windows](../../docs/windows-platform.md).
Verify startup and exit through the native smoke, and generated products when
identity or build integration changes.
