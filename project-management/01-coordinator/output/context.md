# project-management/01-coordinator/output

## Purpose
Generated output from the scripts in `../`. Not hand-edited — regenerate by rerunning the relevant script.

## Contents
From `workload_by_tech_lead.py`:
- `workload-by-tech-lead.csv` — pivot table: one row per `Project Team Tech Lead`, columns for each Phase (Beginning / In Process / Closing / Final Closure / On Hold/Inactive) + Total, plus a Grand Total row.
- `workload-by-tech-lead-detail.csv` — one row per in-scope project (Project Number, Account, Project Name, Tech Lead, Status, Phase, Project Lead) — drill-down/audit trail behind the pivot counts.
- `workload-by-tech-lead-summary.md` — the pivot table rendered as markdown, meant to read like a status digest.

From `project_report.py`:
- `project-report-by-lead-detail.csv` — one row per in-scope project (Project Number, Account, Project Name, Project Lead, Status, Phase, Project Team Tech Lead) — drill-down/audit trail behind the pivot counts.
- `project-report-by-lead-summary.md` — pivot table (one row per `Project Lead`, columns for each Phase + Total, plus a Grand Total row) rendered as markdown, meant to read like a status digest. No separate pivot CSV is written — the markdown table is the only pivot output. This replaced an earlier draft of `project_report.py` that computed Overdue/Stale/Stalled Intake health flags (that date-based logic didn't hold up in practice; the old flagging script, `status_report.py`, has been deleted and its outputs are gone too).

## Notes
Regenerated each run; treat as disposable/derived data, not a source of truth.
