# Repository scripts

Keep local and CI verification in `check.ps1`; use focused scripts during
development. `test.ps1` must include GPUI Kit `test-support`, and native smoke
must be bounded and self-closing.

Resolve paths from `$PSScriptRoot`, use the Cargo resolver, stop on errors and
check native exit codes. Report environment failures separately from code
failures. Checkers should explain the offending input and expected behavior.
Test changed validators with accepted and rejected inputs.

Product edits stay allowlisted and rollback-safe. Test initialization and
reconfiguration in the isolated generated-project fixture, including Unicode
and spaced paths. Fixtures must not modify user Git configuration or data.

Keep automated checks focused on observable correctness. Documentation links
may be validated without prescribing which guidance files a product must keep.
