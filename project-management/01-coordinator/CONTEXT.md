# project-management/01-coordinator

## Purpose
Reactive Tier — Agent #1 in `../pm-agent-architecture.md`. Tracks task status/ownership/deadlines, compiles status responses, flags overdue/blocked items, maintains the PM tool as source of truth.

## Contents
- `status_report.py` — reads the project export (`../data/raw`), excludes matched projects (`../data/reference/excluded-projects.csv` — perpetual-support placeholders and Proposal-type projects), and reports on every in-scope project (not just problem ones). Assigns a single `Health` label per project — Overdue > Stalled Intake > Stale > On Track > Closed, in that priority order when more than one condition applies — plus the underlying boolean flag columns for detail. Run with `python status_report.py` from this folder.
- `status_report.ps1` — PowerShell port of the same logic (currently reflects the pre-2026-07-08 exclusion schema and raw export filename — needs a matching update before relying on it again; not yet re-verified against the new `Project Search Results.csv` export or the Match Type exclusion schema).
- `workload_by_tech_lead.py` — a second, different-shaped report off the same project export: a headcount/capacity pivot of open projects per `Project Team Tech Lead`, broken out by collapsed Phase (Beginning / In Process / Closing / On Hold, per `../data/reference/status-phase-mapping.csv`) with a Total column and Grand Total row. Not a problem-flagging report like `status_report.py` — a "how loaded is each person" view. Run with `python workload_by_tech_lead.py` from this folder.
- `output/` — generated reports (gitignore-worthy/regenerable; not hand-edited). See `output/CONTEXT.md` for the full file list.

## 60/30/10 Breakdown
(see `../../PRINCIPLES.md` for the full principle)

- **Programmatic (60%)** — all of it. Overdue/stale/stalled-intake and phase-bucket assignment are objective date/status/lookup comparisons against constants and reference files; Health prioritization, sorting, pivoting, and report formatting are all deterministic.
- **Data-Driven (30%)** — reads `../data/raw` (the project export), `../data/reference/excluded-projects.csv` (human-maintained exclusion rules), and `../data/reference/status-phase-mapping.csv` (human-maintained Status→Phase lookup). No inference involved.
- **AI (10%)** — none currently. Both scripts turned out to be 100% Programmatic + Data-Driven, 0% AI, because every category here is an objective, rule-based definition rather than a judgment call.

## Notes
See architecture doc for full inputs/outputs/handoff spec. Everything specific to this role (scripts, notes, role-specific data) lives in this folder; only genuinely shared resources live at the `project-management/` root (see `../CONTEXT.md`).

Thresholds (`STALE_DAYS = 14`, `STALLED_INTAKE_DAYS = 30`) and the closed-status list are set as constants at the top of `status_report.py` — adjust there if the definition of "stale" or "stalled" needs to change. Rerun either script any time a fresh export lands in `../data/raw`.

**2026-07-08 revision:** the raw export changed from `Active Projects by Status.csv` to `Project Search Results.csv` (a narrower, cleaner column set — dropped the always-empty/always-Green fields, added `Project Team Tech Lead`). `excluded-projects.csv` was migrated from a flat Project-Number list to a `Match Type`/`Value` schema (mirroring `service-delivery/data/reference/excluded-ticket-sources.csv`) so it can express both curated per-project exclusions and category-wide rules — the immediate driver being "exclude all Project Type = Proposal projects from every report," which both scripts now apply.
