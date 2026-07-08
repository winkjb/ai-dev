# project-management/01-coordinator/output

## Purpose
Generated output from `../status_report.py`. Not hand-edited — regenerate by rerunning the script.

## Contents
From `status_report.py`:
- `coordinator-status-report.csv` — one row per in-scope project (including healthy/on-track and closed ones, not just problem projects), with a computed `Health` label (Overdue / Stalled Intake / Stale / On Track / Closed), the underlying boolean flag columns, and day counts.
- `coordinator-status-summary.md` — counts by Health category and a by-project-lead breakdown, meant to read like a status digest.

From `workload_by_tech_lead.py`:
- `workload-by-tech-lead.csv` — pivot table: one row per `Project Team Tech Lead`, columns for each Phase (Beginning / In Process / Closing / On Hold) + Total, plus a Grand Total row.
- `workload-by-tech-lead-detail.csv` — one row per in-scope project (Project Number, Account, Project Name, Tech Lead, Status, Phase, Project Lead) — drill-down/audit trail behind the pivot counts.
- `workload-by-tech-lead-summary.md` — the pivot table rendered as markdown, meant to read like a status digest.

## Notes
Regenerated each run; treat as disposable/derived data, not a source of truth.
