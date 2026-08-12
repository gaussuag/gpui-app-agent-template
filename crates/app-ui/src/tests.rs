use app_core::{Snapshot, WorkStatus};
use gpui::{Modifiers, TestAppContext, VisualTestContext};

use super::{Increment, Reset, RunWork, TemplateView, test_support};

fn test_window(cx: &mut TestAppContext) -> (gpui::Entity<TemplateView>, &mut VisualTestContext) {
    test_support::init_test_app(cx);
    cx.add_window_view(|window, cx| {
        let view = TemplateView::new(cx);
        window.focus(&view.focus_handle);
        view
    })
}

fn snapshot(view: &gpui::Entity<TemplateView>, cx: &VisualTestContext) -> Snapshot {
    view.read_with(cx, |view, _| view.state.snapshot())
}

#[gpui::test]
fn increment_action_updates_the_owned_state(cx: &mut TestAppContext) {
    let (view, cx) = test_window(cx);

    cx.dispatch_action(Increment);

    assert_eq!(snapshot(&view, cx).counter, 1);
}

#[gpui::test]
fn increment_button_routes_through_the_same_action(cx: &mut TestAppContext) {
    let (view, cx) = test_window(cx);
    let Some(bounds) = cx.debug_bounds("increment-button") else {
        panic!("increment button must expose a stable test selector");
    };

    cx.simulate_click(bounds.center(), Modifiers::default());

    assert_eq!(snapshot(&view, cx).counter, 1);
}

#[gpui::test]
fn background_action_commits_after_the_executor_drains(cx: &mut TestAppContext) {
    let (view, cx) = test_window(cx);

    cx.update(|window, app| window.dispatch_action(Box::new(RunWork), app));
    assert!(matches!(
        snapshot(&view, cx).work_status,
        WorkStatus::Running { revision: 1 }
    ));

    cx.run_until_parked();

    assert!(matches!(
        snapshot(&view, cx).work_status,
        WorkStatus::Succeeded { revision: 1, .. }
    ));
}

#[gpui::test]
fn reset_cancels_owned_work_before_a_late_completion(cx: &mut TestAppContext) {
    let (view, cx) = test_window(cx);

    cx.update(|window, app| {
        window.dispatch_action(Box::new(RunWork), app);
        window.dispatch_action(Box::new(Reset), app);
    });
    cx.run_until_parked();

    assert_eq!(snapshot(&view, cx).work_status, WorkStatus::Idle);
}

#[gpui::test]
fn removing_the_window_releases_the_view_and_owned_task(cx: &mut TestAppContext) {
    let (view, cx) = test_window(cx);
    let weak_view = view.downgrade();

    cx.update(|window, app| window.dispatch_action(Box::new(RunWork), app));
    drop(view);

    cx.update(|window, _| window.remove_window());
    cx.run_until_parked();
    assert!(weak_view.upgrade().is_none());
}
