# GitHub automation

Pin third-party Actions to immutable SHAs and keep permissions read-only unless
the task requires more. Untrusted pull requests receive no secrets or write
access.

Windows x64 MSVC CI selects desktop-independent groups from `check.ps1` and
uses `test-generated-project.ps1 -SkipGui` for template output. Real-window
startup and Overlay input tests are local acceptance on an unlocked Windows
desktop. See `docs/testing-standard.md` for coverage and acceptance commands.

PR templates collect outcome, verification and an acceptance path. They do not
require duplicate specs or commit-message ceremonies. Report hosted execution
separately from local validation.
