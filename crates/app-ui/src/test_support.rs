//! Shared initialization for deterministic GPUI component tests.

use gpui::TestAppContext;

/// Install the same gpui-component globals used by the production launcher.
///
/// Call this before creating a test window. Feature tests should then create
/// their real root Entity and assert through Actions, Events, and public state.
pub fn init_test_app(cx: &mut TestAppContext) {
    cx.update(gpui_component::init);
}
