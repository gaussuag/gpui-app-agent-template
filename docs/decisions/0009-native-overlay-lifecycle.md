# ADR 0009: Native overlay boundary and coordinated exit

The [overlay spec](../overlay-gpui-spec.md) requires an ordinary GPUI content
entity to follow an external Windows client area without owning that host.
`app-ui::overlay` owns the real Kit Root, content lifetime, session state and
GPUI window. A separate `overlay-win32` crate owns native facts and operations;
only `overlay/native_bridge.rs` calls it. All FFI and native test helpers live
under the adapter's `windows` directory, with a narrow unsafe lint exception.
Business views therefore use the same components and actions in either window
container, and the locked GPUI dependencies require no fork.

A session owns one event-pump worker and a bounded latest-snapshot slot, with
host identity and sequence checks before foreground commits. Native window
operations run outside GPUI update borrows: a native resize can synchronously
reenter GPUI. An opaque, thread-affine binding borrows our window handle and
invalidates itself on native destruction; it never destroys the host or owns
GPUI window destruction.

Closing hides and unbinds the native window, signals the tracker, removes the
GPUI window, then joins the tracker on a background executor. Closed is emitted
only after that cleanup finishes. Handles retain terminal diagnostics without
retaining business content; dropping the last handle does not close a session.
Cleanup taking over two seconds reports a failure while continuing to wait.

This extends [ADR 0002](0002-last-window-exit.md): GPUI uses explicit quit mode,
and the last-window policy calls the overlay `prepare_quit` coordinator before
`cx.quit()`. Otherwise the Windows backend can exit as soon as the final HWND
disappears, abandoning the worker join. The application retains the coordinator
until cleanup completes; no UI-thread join or process kill is a normal exit path.

The native first-frame/input smoke keeps a 15-second process deadline. The
separate 100-cycle endurance test has a 60-second total deadline because it
includes creating 100 GPUI renderers; each cycle still requires completed
cleanup and native resource counts back at baseline. Actual verification and
remaining visual/DPI evidence are recorded in the
[implementation progress](../overlay-implementation-progress.md).
