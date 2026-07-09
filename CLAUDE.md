# ai-dev Workspace

This directory is used as a development environment for business automation projects.

## Conventions

### The 60/30/10 Principle
**[PRINCIPLES.md](PRINCIPLES.md) — read this first.**

Default to this ordering when designing any automation in this workspace: 60% programmatic (deterministic code), 30% data-driven (files/config/lookups), 10% AI (credit: John Elder). This is a design bias/ordering preference, not a literal ratio to calculate per project — reach for a rule first, then a file, and bring in AI only when a task genuinely requires judgment or prose generation. `PRINCIPLES.md` covers the full breakdown, the rationale (cost, consistency, hallucination, auditability), and the decision tree for classifying a task.

Each role's `CONTEXT.md` should include a **60/30/10 Breakdown** section documenting which of its tasks are Programmatic, Data-Driven, or AI — see `project-management/01-coordinator/CONTEXT.md` for the first worked example.

### CONTEXT.md Files
Every folder in this workspace should contain a `CONTEXT.md` file that describes the purpose of that folder, what it contains, and any relevant notes. This helps Claude (and collaborators) quickly orient to what's in each directory without having to read every file.

### log.md Files

To be prepared.

### Relative Paths Only
All code and apps created in this workspace must use **relative paths**, never static/absolute paths. This ensures portability — workflows, scripts, and apps should work regardless of where the workspace is cloned or moved on any machine.

Bad: `C:\GitHub\directory\data\file.csv`
Good: `./data/file.csv` or `../data/file.csv`

### Role/Agent Folder Naming
Within a project's root directory (not nested under `scripts/`), each individual agent role gets its own top-level folder, prefixed with a two-digit number reflecting its order in that project's process/workflow — not alphabetical order, not build order.

Format: `NN-role-name` (e.g. `01-coordinator`, `02-client-communication`, `03-intake-triage`). Everything specific to that role — scripts, notes, role-specific data — lives inside its own numbered folder, so a role's automation is self-contained in one place rather than scattered by file type.

Reserve the project root's own folders (`data/`, `scripts/`, etc.) for resources genuinely shared/joint across roles — e.g. `data/` for the common source-of-truth data, `scripts/` for cross-role utilities like a shared notify script. If something only serves one role, it belongs in that role's folder, not the shared one.

The intended order should already be established by that project's architecture doc (e.g. `project-management/pm-agent-architecture.md` lays out Coordinator through Resource Allocation as Reactive/Proactive tier agents, with the Orchestrator — folder `08` — as the cross-cutting agent that routes between them). Reuse those numbers rather than re-deriving a new order. If a project has no architecture doc yet, define the process order first, then number folders to match.

### Shared Data Layer vs. Role-Owned Output
Two valid patterns exist for where a role's generated output lives, and the right one depends on whether that output is consumed by other roles or is a terminal deliverable:

- **Shared pipeline (`data/{raw,aggregated,analyzed,reports}`)** — use when the project is really one continuous pipeline, where each stage's output is meaningful input to the next and/or read by several downstream consumers. Here, "which stage of the pipeline" matters more than "which role produced it." Example: a security project where raw findings get aggregated, aggregated gets analyzed, and analysis becomes a report — multiple things may need to read each stage.
- **Role-owned output (`NN-role-name/output/`)** — use when each role is doing a genuinely distinct job off common source data, and outputs aren't really chained between roles. Example: `project-management/`, where Coordinator's status flags and Analyst's variance report are different concerns, not sequential stages of one pipeline. Shared `data/` there holds only the common source-of-truth and reference lookups (`data/raw/`, `data/reference/`) — not role output.

If a role's output does turn out to be a documented input to another role (per that project's architecture doc), the consuming role's script can usually just read the producing role's `output/` folder directly via a relative path — no need to promote it into a shared `data/` folder unless three or more roles depend on it, or ownership of producing it is genuinely ambiguous.

Don't force both projects into the same pattern for consistency's sake — pick per-project based on whether the workflow is one shared pipeline or a set of semi-independent roles.

### CHANGELOG.md Maintenance

To be prepared.

### BOOTSTRAP.md Maintenance

To be prepared.