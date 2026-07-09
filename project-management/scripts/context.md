# project-management/scripts

## Purpose
**Shared/cross-role scripts only** — utilities used by more than one agent role (e.g. a shared notify script, common data-loading helpers). Role-specific automation does NOT live here.

Each agent role has its own top-level folder instead: `../01-coordinator/`, `../02-client-communication/`, `../03-intake-triage/`, `../04-planner/`, `../05-analyst/`, `../06-risk-compliance/`, `../07-resource-allocation/`, `../08-orchestrator/` (see `../context.md`).

## Contents
(empty — to be populated as shared utilities are identified)

## Notes
All scripts must use relative paths (e.g. `../data/...`), never absolute paths, per workspace `CLAUDE.md`. Before adding something here, confirm it's genuinely shared across roles — if it only serves one role, it belongs in that role's folder instead.
