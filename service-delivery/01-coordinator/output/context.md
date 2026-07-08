# service-delivery/01-coordinator/output

## Purpose
Generated output from `../ticket_report.py`. Not hand-edited — regenerate by rerunning the script.

## Contents
- `ticket-dispatch-report.csv` — one row per in-scope ticket (including healthy/active ones, not just problem tickets), with a computed `Health` label (the single highest-priority flag that applies — Critical Unassigned / Stalled Intake / Stale / Waiting External / Unassigned / Active), an `All Flags` column (every condition that's true for that ticket, comma-separated), a `Ticket Origin` column (Human-Generated / System-Generated / Unclassified, added 2026-07-08), the underlying boolean flag columns, ticket age in days, and days since last activity.
- `ticket-dispatch-summary.md` — counts by Health category and a by-queue breakdown, meant to read like a status digest.

## Notes
Regenerated each run; treat as disposable/derived data, not a source of truth.
