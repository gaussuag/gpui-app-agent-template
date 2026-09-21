//! Shared initialization for deterministic GPUI Kit tests.

use gpui_kit::TestAppContext;

/// Install the same GPUI Kit globals used by the production launcher.
///
/// Call this before creating a test window. Feature tests should then create
/// their real root Entity and assert through Actions, Events, and public state.
pub fn init_test_app(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
}
