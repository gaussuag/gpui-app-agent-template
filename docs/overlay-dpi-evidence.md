# Runtime DPI synchronization evidence

Date: 2026-09-22. Scope: changing system scaling with Overlay attached to Settings.

## Failure and fix

The user reproduced 100% → 150% and back: waiting did not update Overlay;
dragging the host did. Diagnostics confirmed native DPI was already 144 while
GPUI still reported scale 1.0; in reverse, native DPI was 96 while GPUI retained
scale 1.5. A subsequent move changed scale but could retain a stale logical viewport.

The locked Windows GPUI backend updates its scale during WM_DPICHANGED and
relies on the suggested-rectangle positioning to produce WM_SIZE. An unchanged
rectangle need not produce that notification. The adapter now remembers the DPI
message, forwards it unchanged, and then sends its own window a size notification
using the current client rectangle after host positioning completes. This runs
on the creating thread outside GPUI borrows. It changes neither host state nor
system DPI and introduces no worker or geometry adjustment.

## Verification

- Native protocol regression failed before the fix: requested scale 1.0 but
  observed 2.0. With the fix, 96 → 144 → 96 produced scales 1.0 → 1.5 → 1.0
  and matching logical viewports, with a 500 ms deadline per transition.
- The deadline includes synchronous message handling; an observation after the
  deadline cannot pass. Hidden fixtures abort rather than report a product failure.
- The focused regression passed after removal of temporary diagnostics; workers,
  hooks and bindings returned to zero and fixture/probe cleanup completed.
- Real user test passed: attached to Settings, 100% → 150% → 100%, no dragging;
  Overlay adapted during the system window's own adaptation.
- Diagnostic evidence from that run showed native 1076×1294 at scale 1.5 with
  logical viewport 717.3333×862.6667, then native/logical 716×862 at scale 1.0.
- Strict workspace Clippy passed. Temporary instrumentation is absent from
  delivered code. Unified repository/generated regression remains deferred at
  the user's request.

Run `scripts/smoke-overlay.ps1 -Suite dpi` on an unlocked desktop. This controlled
message test complements the real manual test; it does not certify system DPI
changes by itself or cover negative-coordinate display placement.
