# scripts owner contract

This file extends [the repository contract](../AGENTS.md) for repository
automation.

## Owner

`scripts` owns the canonical PowerShell run, validation, architecture, Agent,
and Git-policy entry points used locally and by CI.

## Boundaries

- Keep `scripts/check.ps1` the single full quality gate; CI calls it instead of
  duplicating Cargo flags.
- Make checks fail closed with an actionable rule, offending path/symbol, and
  remediation. Do not downgrade a failure to preserve a green build.
- Resolve paths from `$PSScriptRoot`, use the pinned Cargo resolver, set
  `$ErrorActionPreference = "Stop"`, and check native command exit codes.
- Keep checks deterministic and non-interactive. A network, credential, GUI, or
  signing requirement belongs in a separately reported dynamic step.
- Add a positive and negative self-test for parsers or policy validators. Avoid
  tests that mutate the user's Git configuration or working files.

For script changes, run the changed script directly and then
`scripts/check.ps1`. Record sandbox/permission failures separately from code
failures.
