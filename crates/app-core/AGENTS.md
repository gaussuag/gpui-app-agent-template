# Domain implementation

Keep `app-core` independent of GPUI, native APIs, external I/O and executors.
It owns domain state, typed commands/effects and request revisions. Effects
describe work for adapters; they do not perform it.

Test transitions through stable interfaces such as `dispatch` and `snapshot`.
A replaced or cancelled request must not commit a late result. Add real adapter
seams only when required by a varying production dependency and its tests.

Focused check: `scripts/test.ps1 -Suite core`.
