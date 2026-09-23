# Agent foundation

Portable engineering guidance and stateless development tools. This directory
owns no application code, product configuration, dependency lockfile, task
history or generated artifacts. It can be copied or later pinned as a submodule.
Its documents and tools have no dependency on the containing repository.

## Adopt in an application or component repository

Keep a root `AGENTS.md` with two explicit instructions:

```text
Read agent-foundation/BASE-AGENTS.md when entering this project.
Read the project's own map for owners, commands and acceptance requirements.
```

Replace the second line with the actual local document path. That project map
names source owners, locked toolchain/dependencies, test commands and any task
spec or progress record relevant to the requested work. It can be an existing
README; no new configuration schema is required.

A nested agent file is not automatically applied to its parent project. Tools
without automatic `AGENTS.md` loading should be given the root entry explicitly.
Keep the foundation text linked, rather than copying it into agent-specific files.
User instructions govern authorized scope; project rules supply concrete stack
constraints. Surface genuine conflicts instead of silently weakening acceptance.

## Tools

PowerShell 7 is required for these tools; the guidance is language-independent.

```powershell
./agent-foundation/tools/check-docs.ps1 -RepositoryRoot <project-directory>
./agent-foundation/tests/test-docs.ps1
```

The link checker reads local Markdown link targets, accepts an explicit project
root, and never writes to the project. It skips `.git`, `target`, `node_modules`
and directory reparse points. It does not validate remote links, fragments or
full Markdown syntax. Its tests create isolated temporary fixtures and clean up
only those fixtures. Project wrappers can provide a default root.

## Maintain or extract

Keep all foundation links relative and internal. Put stack-specific commands,
dependency policies and runtime contracts in the consuming project. Verify a
foundation tool from a copied standalone directory against an unrelated fixture
before claiming portability. Update the pinned foundation version and affected
project integration together; directory presence does not install toolchains or
inherit build configuration. Extraction must preserve the root entry's pointers.
