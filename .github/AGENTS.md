# GitHub automation owner contract

This file extends [the repository contract](../AGENTS.md) for workflows,
Dependabot, issue forms, and review templates.

## Boundaries

- Keep permissions least-privilege and pin third-party Actions to immutable
  commit SHAs with a readable release comment where available.
- Windows x64 MSVC is the required CI tier. Workflows call repository scripts so
  local and CI definitions of done remain identical.
- Required CI executes the explicit `app-ui` GPUI headless suite and Windows
  process smoke. It must not rely on a workspace default that can omit either.
- Required CI also executes the copied generated-product fixture; the template
  gate alone does not prove initialization or renamed artifact behavior.
- Fetch only the Git history required by commit-policy checks. Do not add secrets
  or write permissions to untrusted pull-request execution.
- Templates collect evidence and link to canonical standards; they do not copy
  normative rules that would drift.
- A job marked optional or allowed to fail states the platform/product tier and
  cannot be reported as a successful required gate.

Workflow changes require syntax review, the relevant local script execution,
and explicit acknowledgement that local execution does not prove the hosted
GitHub job passed.
