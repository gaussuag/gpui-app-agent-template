# Code Agent readiness plan

## Record status

This file is the completed readiness delivery record audited on 2026-08-11,
not the live capability index or an open backlog. Its baseline, gaps, slices,
and completion evidence remain frozen to that audit. Current repository facts
are routed from `AGENTS.md`; current testing and product setup are defined in
`docs/testing-standard.md` and `docs/product-identity.md`.

Subsequent work added the GPUI headless suite, native first-frame/close smoke,
explicit last-window exit, and exact Windows manifest requirements. Commit
`e44f0a9 feat(repo): add in-place product initialization` then added Cargo-owned
product identity, Windows ICON/VERSIONINFO, transactional in-place setup, and a
generated-repository Release fixture. Those later capabilities supersede any
apparently current test counts or unrun-smoke statements in the historical
audit below.

## Scope and evidence

This plan turns the static findings in `report-awesome-gpui` into repository
controls for this template. The research inspected 18 fixed project commits and
separates source facts, repeated patterns, recommendations, and unverified
runtime claims. Its most relevant authoritative artifacts are:

- `final-summary.md`;
- `common-characteristics.md`;
- `gpui-architecture-patterns.md`;
- `anti-patterns-and-tradeoffs.md`;
- `agent-development-standard.md`;
- `AGENTS.draft.md`;
- every project report's section 8, "Agent maintainability".

The template baseline for this comparison is commit `f94f87a`: three crates,
the root `AGENTS.md`, architecture/dependency/Windows documents, one task
template, the canonical Windows gate, and the Git commit contract. Current
source, manifests, lockfile, and scripts remain authoritative over this plan.

## Readiness target

"Ready for a Code Agent" means an agent entering with no prior chat can:

1. find the authoritative instructions and the owner of the target behavior;
2. reconstruct success, failure, asynchronous, repaint, and shutdown paths
   before editing;
3. keep changes inside the declared crate and lifecycle boundaries;
4. model task, channel, native-handle, error, privacy, and capacity semantics;
5. select focused tests and the canonical repository gate;
6. distinguish executed evidence from configuration or intent;
7. leave an atomic, policy-compliant commit and a reviewable handoff.

This is supervised development readiness. It does not authorize autonomous
pushes, releases, destructive migrations, credential changes, or production
support claims.

## Baseline strengths at planning time

| Existing control | Status | Evidence in this repository |
|---|---|---|
| Single dependency direction | Implemented and mechanical | `docs/architecture.md`, exact workspace edge assertions in `scripts/check-architecture.ps1` |
| UI-free state machine | Implemented and tested | `crates/app-core/src/lib.rs` |
| Owned background task and stale-result gate | Implemented as a minimal example | `crates/app-ui/src/lib.rs` |
| Exact GPUI/component BOM | Implemented and mechanical | `Cargo.toml`, `Cargo.lock`, dependency check |
| Windows Tier 1 contract | Documented and compiled in CI | `docs/windows-platform.md`, `scripts/check.ps1` |
| Strict Rust lint baseline | Implemented | root workspace lints |
| One canonical local/CI gate | Implemented | `scripts/check.ps1`, Windows workflow |
| Evidence-oriented task specification | Implemented | `docs/agent-task-template.md`, lifecycle and ADR templates |
| Atomic commit contract | Implemented and mechanical | `docs/git-commit-policy.md`, commit hook and CI check |
| Scoped Agent navigation | Implemented and mechanically checked | root and five scoped `AGENTS.md` files, `scripts/check-agent-contract.ps1` |
| High-risk source review | Implemented as a fail-closed signal | `scripts/check-source-risks.ps1`, ADR-backed allowlist |

At that baseline, the template already constrained more than a minimal GPUI
sample. Its remaining readiness gap was mainly operational: important rules
were either absent, too compressed in the root file, or dependent on manual
memory.

## Evidence from all 18 reports

| Project | Agent-maintainability lesson applied here |
|---|---|
| Zed | Keep the root entry small, route to non-obvious GPUI traps, and put repeatable rules in lint/tests rather than an ever-growing prompt [ZED-E033][ZED-E034]. |
| DBFlux | Use one canonical rule source; duplicated agent documents and architecture prose drift from storage and code facts [DBFLUX-E032][DBFLUX-E040]. |
| GitComet | Document the complete message/reducer/effect/completion protocol and generated inputs; a callback-only edit misses half the chain [GITCOMET-E003][GITCOMET-E025]. |
| Codux | Give the root an owner/host matrix and prevent a local desktop change from leaking into another host or shared core [CODUX-E002][CODUX-E023]. |
| Pulsar-Native | Validate documented paths and symbols; a large topic library marked "generated" still drifts without checks [PULSAR-E017][PULSAR-E020]. |
| onetcli | Prefer accurate, short rules over context overload, stale hard limits, and mandatory external skills with no fallback [ONETCLI-E021]. |
| Hummingbird | Make receiver-close, runtime ownership, and application shutdown executable contracts, especially around raw threads [HUMMINGBIRD-E020][HUMMINGBIRD-E022]. |
| tty7 | Distinguish maintenance instructions from product-operation skills and record GUI/daemon lifetime differences explicitly [TTY7-E012][TTY7-E024]. |
| Termy | Put owner, validation, and forbidden dependencies next to each crate and enforce boundaries mechanically [TERMY-E003][TERMY-E024]. |
| PicoForge | Provide a short real entry path and check it against source; prose that names old modules is harmful [PICOFORGE-E023][PICOFORGE-E024]. |
| gpui-component | Route component changes through public API, state, story/docs, tests, and the exact GPUI revision; commands in docs are not proof [GPUICOMP-E003][GPUICOMP-E025]. |
| Monocurl | Name parallel execution paths and inventory Entity tasks, native threads, channels, and GPU resources together [MONOCURL-E019][MONOCURL-E024]. |
| nohrs | A standard, portable `AGENTS.md` entry must resolve on Windows and must not describe a future architecture as current [NOHRS-E023][NOHRS-E024]. |
| zqlz | Generate tool-specific aliases from one canonical contract and add local instructions at complex ownership boundaries [ZQLZ-E023][ZQLZ-E024]. |
| Ropy | Show both directions of the main pipeline, record shutdown ownership, and identify sensitive persisted payloads [ROPY-E014][ROPY-E017][ROPY-E021]. |
| Zedis | Keep toolchain, dependency baseline, and canonical validation command in one machine-readable source [ZEDIS-E003][ZEDIS-E024]. |
| Vleer | Make implicit Global/lock/channel/thread owners explicit; small file count does not make lifecycle discoverable [VLEER-E020][VLEER-E024]. |
| OpenLogi | Agent docs must match real I/O ownership, and long-lived GUI/IPC tasks need a named owner rather than process-exit cleanup [OPENLOGI-E005][OPENLOGI-E011][OPENLOGI-E020]. |

## Gap analysis

### G1: The entry contract does not define the complete work loop

The root file names important invariants but does not require the agent to map
the current call chain, dependency revision, adjacent implementation, failure
path, or shutdown path before editing. This leaves the GitComet/onetcli failure
shape: a locally plausible handler change that misses a second path.

**Change:** keep root `AGENTS.md` short, add a conditional pointer to an agent
workflow, and make reconnaissance and evidence completion criteria explicit.

### G2: Ownership rules are not colocated with crates

All rules currently live at the root. An agent in `app-core`, `app-ui`,
`desktop`, `scripts`, or `.github` receives no local owner, allowed dependency,
forbidden dependency, or focused validation contract.

**Change:** add scoped `AGENTS.md` files for those five boundaries. Each local
file contains only facts and traps unique to that subtree; root rules remain
the single general source.

### G3: Lifecycle evidence is too shallow

The architecture ledger has owner/start/stop/failure columns but omits request
identity, deadline, join/flush, late-resource cleanup, channel close, and owner
drop. The task template does not require the ledger for asynchronous work.

**Change:** define a full lifecycle ledger template and require it whenever a
task adds or changes a Task, Subscription, worker, process, channel, watcher,
socket, device, native handle, or temporary artifact.

### G4: Channel, refresh, and data budgets are absent

The current contract says resources need owners but says nothing about whether
a channel carries replaceable state, reliable commands, or a high-frequency
stream. It also lacks acquisition, resident-memory, conversion, queue, and
visible-render limits. Research repeatedly found that virtual rendering alone
did not bound upstream memory [ZQLZ-E019][NOHRS-E006].

**Change:** add channel and capacity sections to the normative standard and task
template. Default to bounded/coalesced protocols; document any exception.

### G5: Error, cancellation, and privacy rules are not operational

The root requires typed visible errors, but the task template does not ask how
each `Result` reaches recovery UI, what cancellation means, what partial output
is cleaned up, or what data may enter logs and diagnostics.

**Change:** require typed async states, recovery actions, redaction review,
cancellation checkpoints, and late-resource compensation in the standard and
acceptance matrix. Keep the demo's infallible CPU task identified as a minimal
example rather than pretending it proves I/O failure handling.

### G6: Shutdown is a prose concern, not a task gate

The repository has no product resources that need a full coordinator yet, but
future work has no mandatory trigger for designing one. Multiple report risks
came from close, Quit, Drop, and process exit taking different paths.

**Change:** require agents to enumerate all applicable exit entries and to add
an idempotent shutdown state machine before introducing a resource that must
flush, join, or outlive a window. Do not add a speculative coordinator before
such a resource exists.

### G7: Test requirements do not cover the observed failure classes

Current tests cover pure success, reset, and stale results. The task template
mentions failure and cancellation but not channel full/disconnect, close/quit,
late resource cleanup, migration, platform fallback, or deterministic
executor/clock seams.

**Change:** add a chain-by-scenario test matrix. Only applicable rows are
required, but every omitted row needs a reason. Tests remain at stable module
interfaces.

### G8: Documentation integrity is unverified

The repository currently has accurate, small documents, but there is no gate
for broken local links, missing scoped instruction files, or a root pointer
that no longer reaches its target. Drift was the most repeated Agent-specific
counterexample across the reports.

**Change:** add a repository contract check for required documents, scoped
instruction entry points, local Markdown links, and key authoritative pointers.

### G9: High-risk concurrency shapes are only manually reviewed

Strict Rust lints catch panic-oriented shortcuts but do not flag detached tasks,
unbounded channels, blocking bridges, foreground sleeps, or direct process
exit. These shapes dominated the lifecycle counterexamples.

**Change:** add a narrow source-risk gate for those constructs. A legitimate
exception names its owner and ADR in a machine-readable allowlist; the gate
does not claim to prove render purity or lifecycle correctness.

### G10: Review and handoff evidence is incomplete

The PR template records the full gate and lifecycle at a high level, but not
the reconstructed chain, exact executed/unexecuted checks, data/privacy review,
platform tier, dependency identity, or commit grouping.

**Change:** align the task and PR templates with the same evidence model. Avoid
copying normative rules into both; templates ask questions and link to the one
standard.

## Implementation slices

Each slice is an atomic commit under `docs/git-commit-policy.md`.

### S0: Git history contract — complete

- Commit: `f94f87a chore(repo): enforce git commit contract`.
- Defines message semantics, atomicity, local validation, and CI range checks.

### S1: Operating contract and scoped navigation — complete

- Commit: `08cc2aa docs(agent): establish scoped operating contracts`.

- Add one detailed `docs/agent-development-standard.md` as the normative rule
  source, adapted to this actual architecture and Windows/BOM baseline.
- Add `docs/agent-workflow.md` as the ordered task recipe.
- Refactor root `AGENTS.md` into high-signal always-read steps and conditional
  pointers.
- Add local `AGENTS.md` files for `app-core`, `app-ui`, `desktop`, `scripts`,
  and `.github`.

**Done when:** a new agent can identify owner, forbidden dependencies, required
context, and focused checks from every writable project boundary without
reading unrelated rules.

### S2: Task, lifecycle, decision, and review evidence — complete

- Commit: `b8079a2 docs(agent): add lifecycle and review evidence`.

- Expand `docs/agent-task-template.md` with source facts, current chain,
  lifecycle/channel/data/error/privacy fields, scenario matrix, exclusions,
  and exact evidence.
- Add reusable lifecycle-ledger and ADR templates.
- Define ADR triggers for owner, dependency direction, protocol/persistence,
  shutdown, platform tier, unsafe boundary, fork, and high-risk exceptions.
- Update the PR template, README, architecture, and contributing pointers.

**Done when:** every non-trivial task has a checkable place to record the
research-mandated facts without duplicating the standard.

### S3: Mechanical repository contract — complete

- Commit: `13c0852 ci(agent): enforce repository contracts`.

- Add local Markdown-link and required-entry checks.
- Add a high-risk source-pattern check and ADR-backed allowlist.
- Strengthen dependency graph assertions for all three crates.
- Run the new checks from `scripts/check.ps1` and therefore Windows CI.

**Done when:** deleting a scoped instruction, breaking a local documentation
link, reversing a crate dependency, introducing a second UI package identity,
or adding an unreviewed high-risk construct makes the canonical gate fail with
an actionable message.

### S4: Completion audit — complete

- Validate every commit introduced after `be2c445`.
- Run formatter, Clippy, tests, architecture/Agent checks, and the explicit
  Windows MSVC build.
- Audit this plan item by item against the final tree and record intentional
  limits.

**Done when:** all readiness criteria below have direct current-state evidence,
the worktree is clean, and unverified runtime behavior remains labelled as
unverified.

## 2026-08-11 completion audit

Audit date: 2026-08-11. The implementation consists of five atomic commits
after baseline `be2c445`, in the S0-S3 order recorded above plus
`a33182c docs(agent): record readiness gap analysis`; this document update is
the separate completion-audit commit.

Evidence collected for that audit:

- all commits in `be2c445..HEAD` pass `scripts/check-commits.ps1`;
- `scripts/check.ps1` passes rustfmt, Clippy, five tests, Agent/document/source-
  risk contracts, policy fixtures, exact workspace dependency checks, registry
  UI identity checks, and the explicit Windows MSVC build;
- the policy fixtures prove both acceptance and rejection for commit messages,
  unreviewed risky source, accepted ADR exceptions, and stale exceptions;
- the current source-risk baseline contains zero allowlisted findings;
- local Markdown links, required entry files, root routing pointers, and the
  three-crate dependency graph are checked by the same script CI invokes.

Limits recorded by that audit:

- no manual GUI smoke was rerun because these slices change repository
  contracts and automation, not runtime UI behavior;
- packaging/signing, performance, and accessibility were not run and are not
  implied by the Windows compile;
- the sample still has no real filesystem/network/database/device I/O, so it
  does not claim a production shutdown coordinator or I/O recovery proof;
- the source-risk scan is a narrow review trigger, not semantic proof of render
  purity, cancellation correctness, or bounded memory;
- no push, release, migration, credential change, or branch-protection change
  was performed.

## Readiness completion criteria

- [x] Root instructions route every task to the correct conditional reference.
- [x] Every maintained code/automation boundary has a scoped owner contract.
- [x] One normative standard covers state ownership, render, async, lifecycle,
      channels, capacity, errors, privacy, platform, dependencies, tests, and
      evidence without competing copies.
- [x] Non-trivial work is required to use a task record containing the current
      success, failure, stale/cancel, repaint, and shutdown chain as applicable.
- [x] Every current long-lived resource has a complete lifecycle ledger row.
- [x] Every future channel and large-data path is required to declare capacity
      and overflow semantics before implementation.
- [x] ADR triggers and a reusable decision template exist.
- [x] Documentation entry points and local links are checked mechanically.
- [x] High-risk concurrency/process constructs fail closed unless an ADR-backed
      exception is present.
- [x] Local and CI gates use the same scripts and exact dependency graph.
- [x] Commit messages and commit grouping follow the repository contract.
- [x] The final handoff contract reports each check separately and identifies unrun
      smoke, packaging, performance, accessibility, and real I/O validation.

## Explicit non-goals

- Building a second-directory project-generator CLI or packaging/signing
  pipeline. The later in-place initializer keeps GitHub Template as the single
  template source and does not contradict this boundary.
- Adding speculative filesystem, network, database, device, runtime, or plugin
  abstractions before two real adapters exist.
- Claiming a generic shutdown coordinator is implemented before the product has
  resources that require it.
- Copying all 18 reports into permanent Agent context.
- Generating separate rule copies for individual Agent brands.
- Allowing an Agent to push, publish, migrate user data, or change secrets
  without task-specific authority.
- Treating static checks as proof of Windows runtime behavior, performance,
  accessibility, packaging, or production support.
