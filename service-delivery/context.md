# service-delivery

## Purpose
Automation for technical support / service delivery — reactive ticket handling (dispatch, client comms, intake) and proactive pattern detection/capacity planning (scheduling, analysis, risk, resourcing), as laid out in `support-service-delivery-agent-architecture.md`.

## Contents
- `support-service-delivery-agent-architecture.md` — multi-agent design doc: agent roles, triggers, inputs/outputs, handoffs, build sequence, and where this overlaps with the PM architecture.
- `data/` — shared source-of-truth data this team's agents read/write against (ticketing/PSA export, known-issue library, SLA terms, skillset matrix).
- `scripts/` — **shared/cross-role scripts only** (e.g. a common notify script). Not where role-specific automation lives.
- `01-coordinator/`, `02-client-communication/`, `03-intake-triage/`, `04-planner/`, `05-analyst/`, `06-risk-compliance/`, `07-resource-allocation/`, `08-orchestrator/` — one folder per agent role (numbered per the architecture doc), each self-contained: scripts, notes, and any role-specific data for that agent live here. `01-coordinator` and `04-planner` are named to match `project-management`'s equivalent roles for cross-project consistency (same functional pattern, separate domain-specific implementation — see those folders' context.md for why).

## Notes
Only genuinely cross-role resources live at this root level (`data/`, `scripts/`). Anything specific to one agent's job belongs inside that agent's numbered folder — see workspace `CLAUDE.md` for the role-folder convention.

The architecture doc flags several roles (Client Communication, Intake/Triage, Risk/Compliance, Resource Allocation) as strong candidates to *share* an implementation with the equivalent `project-management/` role rather than building two separate versions — worth deciding before either gets built out, since retrofitting a shared agent after two diverge is more work than designing for it up front. Coordinator/Planner are explicitly NOT in that category — they're named consistently but stay separate implementations (different data/constraints).
