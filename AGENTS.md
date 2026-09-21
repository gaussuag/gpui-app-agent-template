# Working in this template

Implement the developer's spec or technical plan using the current repository.
The spec owns intended behavior; source, manifests and `Cargo.lock` establish
current implementation facts. Resolve a conflict instead of silently changing
the requested outcome.

## Development loop

1. Read the spec, `git status`, the affected implementation and adjacent tests.
   Preserve existing user changes. Read the nearest scoped `AGENTS.md`.
2. Apply [the workflow](docs/agent-workflow.md) and
   [implementation rules](docs/agent-development-standard.md). Reuse the supplied
   spec; keep only unresolved questions and a short implementation plan in task
   context. Ask when a decision changes product behavior or authorized scope.
3. Implement a small working path, compile early, and test the changed behavior
   using [the testing guide](docs/testing-standard.md).
4. Review the diff, run the applicable checks, and deliver local commits unless
   the user requests uncommitted work. Provide a runnable acceptance path,
   actual verification results and remaining limitations.

## Load when relevant

- Ownership, module boundaries, or shutdown: [architecture](docs/architecture.md).
- UI dependencies, features, Rust toolchain, or lockfile:
  [dependency policy](docs/dependency-policy.md).
- Native APIs, windows, platform behavior, or packaging:
  [Windows guide](docs/windows-platform.md).
- Product names, binary, icons, resources, or initialization:
  [product identity](docs/product-identity.md).
- A lasting cross-cutting technical choice: [decisions](docs/decisions/README.md).

Ordinary implementation choices and fixes within the spec are autonomous.
Changing acceptance criteria, deleting user data, pushing, publishing, and
rewriting history require the corresponding user authorization. Report changes
to tests or checkers that alter what is accepted; preserve the underlying
requirement and prove the replacement.
