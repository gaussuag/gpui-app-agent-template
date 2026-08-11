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
2. Update tests at the affected module interface.
3. Run `scripts/check.ps1` from Windows PowerShell.
4. Update architecture or dependency records when an invariant changes.
5. Include verification results in the pull request description.

Dependency upgrades follow `docs/dependency-policy.md` and must not be mixed
with feature work.
