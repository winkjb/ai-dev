# project-management

## Purpose
Automation for the project management team — reactive coordination (status, client comms, intake) and proactive planning (scheduling, risk, resourcing), as laid out in `pm-agent-architecture.md`.

## Contents
- `pm-agent-architecture.md` — multi-agent design doc: agent roles, triggers, inputs/outputs, handoffs, and build sequence.
- `data/` — shared source-of-truth data this team's agents read/write against (project tracker, SOW library, resource/skillset data, historical metrics).
- `scripts/` — **shared/cross-role scripts only** (e.g. a common notify script). Not where role-specific automation lives.
- `01-coordinator/`, `02-client-communication/`, `03-intake-triage/`, `04-planner/`, `05-analyst/`, `06-risk-compliance/`, `07-resource-allocation/`, `08-orchestrator/` — one folder per agent role (numbered per the architecture doc), each self-contained: scripts, notes, and any role-specific data for that agent live here.

## Notes
Source of truth for PM data is the PM tool (Autotask, via API). Agents should read/write that layer rather than each other's outputs directly, except where a direct handoff is explicitly defined in the architecture doc.

Only genuinely cross-role resources live at this root level (`data/`, `scripts/`). Anything specific to one agent's job belongs inside that agent's numbered folder — see workspace `CLAUDE.md` for the role-folder convention.
