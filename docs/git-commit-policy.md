# Git commit policy

Commits are review and recovery units. Each commit leaves the repository in a
coherent state and explains why the change exists, what it changes, and what
evidence was collected.

## Message format

Use this format for every human-authored commit:

```text
type(scope): imperative summary

Why:
- reason the repository needs this change

What:
- concrete behavior or contract changed

Evidence:
- `exact command` - pass
```

The three body sections are required. When a check is not applicable or cannot
run, record `Not run - <reason>` instead of implying success.

### Types

| Type | Use for |
|---|---|
| `feat` | User- or maintainer-visible capability |
| `fix` | Defect correction |
| `refactor` | Behavior-preserving code structure change |
| `perf` | Measured performance change |
| `test` | Test-only change |
| `docs` | Documentation-only behavior or policy |
| `build` | Build system, dependency, or packaging change |
| `ci` | Continuous-integration change |
| `chore` | Repository maintenance not covered above |
| `revert` | Reversal of an earlier commit |

Scopes use lowercase kebab-case. Prefer `core`, `ui`, `desktop`, `windows`,
`deps`, `agent`, `docs`, `repo`, or `ci`; introduce a product-domain scope when
it names the owner more precisely.

### Subject rules

- Keep the entire subject at 72 characters or fewer.
- Describe one completed change in imperative language.
- Start the summary with a lowercase word and omit the trailing period.
- Use `!` before `:` only for a breaking contract and add a `BREAKING CHANGE:`
  paragraph after the required sections.
- Reserve `Merge ...` subjects for Git-generated merge commits. `WIP`,
  `fixup!`, and `squash!` commits do not enter shared history.

## Atomicity

A commit has one reason to revert. Keep these changes separate unless one
cannot be correct without the other:

- feature behavior and opportunistic refactoring;
- dependency upgrades and product behavior;
- generated output and unrelated handwritten changes;
- policy design and later policy-driven implementation.

Tests and documentation that prove the same behavior belong with its code.
Every commit must pass the smallest relevant checks; commits intended for
shared history must leave the full repository gate capable of passing.

## Authoring procedure

1. Inspect `git status` and preserve changes not created for the current task.
2. Stage explicit paths, then review `git diff --cached`.
3. Run the relevant focused checks and record their exact result.
4. Write the message with `Why`, `What`, and `Evidence` sections.
5. Validate it with `scripts/check-commit-message.ps1` or the repository hook.
6. Do not push, rewrite, or combine commits unless the task explicitly includes
   that operation.

Install the local hook once per clone:

```powershell
.\scripts\install-git-hooks.ps1
```

CI validates every non-merge commit introduced by a pull request or push. The
hook is an early local signal; CI remains authoritative.
