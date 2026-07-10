# project-management/01-coordinator

## Purpose
Reactive Tier — Agent #1 in `../pm-agent-architecture.md`. Tracks task status/ownership/deadlines, compiles status responses, flags overdue/blocked items, maintains the PM tool as source of truth.

## Contents
- `workload_by_tech_lead.py` — a headcount/capacity pivot of open projects per `Project Team Tech Lead`, broken out by collapsed Phase (Beginning / In Process / Closing / Final Closure / On Hold/Inactive, per `../data/reference/status-phase-mapping.csv`) with a Total column and Grand Total row. A "how loaded is each person" view, not a problem-flagging report. Run with `python workload_by_tech_lead.py` from this folder.
- `project_report.py` — same phase-pivot shape as `workload_by_tech_lead.py`, but grouped by `Project Lead` instead of `Project Team Tech Lead` — a per-lead status-mix view. Unlike `workload_by_tech_lead.py`, the pivot isn't also written as its own CSV — only the per-project detail CSV and the markdown summary (which contains the pivot table) are written. Replaced an earlier draft that computed Overdue/Stale/Stalled Intake health flags from Start/End Date and Last Activity Time; that date-based logic didn't hold up in practice, so it was dropped in favor of this simpler phase-mix view. Run with `python project_report.py` from this folder.
- `output/` — generated reports (gitignore-worthy/regenerable; not hand-edited). See `output/context.md` for the full file list.

## 60/30/10 Breakdown
(see `../../principles.md` for the full principle)

- **Programmatic (60%)** — all of it. Phase-bucket assignment is an objective status/lookup comparison against a reference file; sorting, pivoting, and report formatting are all deterministic.
- **Data-Driven (30%)** — reads `../data/raw` (the project export), `../data/reference/excluded-projects.csv` (human-maintained exclusion rules), and `../data/reference/status-phase-mapping.csv` (human-maintained Status→Phase lookup). No inference involved.
- **AI (10%)** — none currently. Both remaining scripts turned out to be 100% Programmatic + Data-Driven, 0% AI, because every category here is an objective, rule-based definition rather than a judgment call.

## Notes
See architecture doc for full inputs/outputs/handoff spec. Everything specific to this role (scripts, notes, role-specific data) lives in this folder; only genuinely shared resources live at the `project-management/` root (see `../context.md`).

Rerun either script any time a fresh export lands in `../data/raw`.

**2026-07-09 revision:** `status-phase-mapping.csv` was refined — `V-Pending Complete` stays its own `Closing` phase, but the three `V-To Be Billed/*` statuses were split out into a new `Final Closure` phase, and `On Hold` + `Inactive` were merged into one `On Hold/Inactive` phase. `workload_by_tech_lead.py`'s `PHASE_ORDER` was updated to match (it would otherwise have silently dropped those projects from its pivot). `status_report.py` (Overdue/Stale/Stalled Intake health-flag logic) was deleted as unreliable; `project_report.py` was rebuilt as the phase-pivot-by-Project-Lead shape described above. A replacement for the deleted health-flag/issue-snapshot report is still to be designed. (Note: a `status_report.ps1` PowerShell port was previously documented here but never actually existed in the repo — that was a documentation error, now corrected.)

**2026-07-08 revision:** the raw export changed from `Active Projects by Status.csv` to `Project Search Results.csv` (a narrower, cleaner column set — dropped the always-empty/always-Green fields, added `Project Team Tech Lead`). `excluded-projects.csv` was migrated from a flat Project-Number list to a `Match Type`/`Value` schema (mirroring `service-delivery/data/reference/excluded-ticket-sources.csv`) so it can express both curated per-project exclusions and category-wide rules — the immediate driver being "exclude all Project Type = Proposal projects from every report," which both scripts now apply.
