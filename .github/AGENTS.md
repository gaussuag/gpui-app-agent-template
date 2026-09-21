# GitHub automation

Pin third-party Actions to immutable SHAs and keep permissions read-only unless
the task requires more. Untrusted pull requests receive no secrets or write
access.

Windows x64 MSVC CI calls repository scripts: `check.ps1` includes GPUI tests
and native smoke; `test-generated-project.ps1` additionally verifies template
output. Keep local and hosted checks aligned.

PR templates collect outcome, verification and an acceptance path. They do not
require duplicate specs or commit-message ceremonies. Report hosted execution
separately from local validation.
