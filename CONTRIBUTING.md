# Contributing

Use a focused branch and keep each change aligned with one stated behavior.
Install the repository hooks once per clone:

```powershell
.\scripts\install-git-hooks.ps1
```

Every commit follows [the Git commit policy](docs/git-commit-policy.md). Keep
dependency upgrades, feature behavior, and opportunistic refactors in separate
commits.

Before opening a pull request:

1. Explain the user-visible outcome and failure behavior.
2. Fill [the task specification](docs/agent-task-template.md) for runtime or
   multi-module work.
3. Follow [the automated testing standard](docs/testing-standard.md): record the
   test seam and expected red result, then update tests in the same behavior
   change.
4. Update the lifecycle inventory and an ADR when their documented triggers
   apply.
5. Run the focused `scripts/test.ps1` suite, then `scripts/check.ps1`, from
   Windows PowerShell.
6. Include exact verification and unrun dynamic checks in the pull request.

Dependency upgrades follow `docs/dependency-policy.md` and must not be mixed
with feature work.
