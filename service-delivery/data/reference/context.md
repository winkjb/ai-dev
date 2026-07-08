# service-delivery/data/reference

## Purpose
Small, manually maintained lookup/reference files that scripts read to adjust behavior — as opposed to `../raw`, which holds unmodified data exports.

## Contents
- `excluded-ticket-sources.csv` — Queue+Source rules for tickets to drop entirely from `../../01-coordinator` (ticket dispatch) analysis. Columns: Queue, Source, Reason, Date Added. A blank Queue or Source cell is a wildcard (matches anything); non-blank cells in the same row must ALL match (AND) for that row to apply, and a ticket is excluded if ANY row matches (OR across rows). This lets one row express either a simple single-column rule (e.g. Queue=Test Queue, Source blank → drop the whole queue) or a compound rule (e.g. Queue=Audit & Compliance, Source=Recurring → only drop that queue+source combination, not the whole queue).
  - Customer-facing / test queues that are out of scope for this analysis entirely (Diverzify Enhancement Requests, Diverzify Application Support, Customer Taskfire, Fencing Supply Group, MRP Depot Ticket Queue, RMF Application Support, Test Queue).
  - Recurring compliance/continuity-check tickets in Audit & Compliance / Business Continuity queues specifically (added 2026-07-08) — not real dispatch work, unlike other Recurring-source tickets elsewhere in the queue.
- `source-classification.csv` — Source → `Human-Generated` / `System-Generated` / `Unclassified` lookup, read by `../../01-coordinator/ticket_report.py` to populate the `Ticket Origin` column (added 2026-07-08). Unlike the exclusion list, these tickets stay in scope — this just flags which ones came from an automated tool (Nable, Auvik, RocketCyber, Solarwinds, Monitoring Alert, etc.) so a system-generated ticket still gets reviewed rather than silently excluded. Blank Source and any value not present in this file (currently just the literal `Other` source) map to `Unclassified` rather than guessing.

## Notes
Monitoring-tool sources (Nable, Auvik, RocketCyber, Solarwinds, Monitoring Alert) were previously hard-excluded from analysis entirely; as of 2026-07-08 that changed — they're back in scope and instead labeled `System-Generated` via `source-classification.csv`, since those tickets still need human review, they just aren't human-reported.

"Recurring" source tickets in general (scheduled/recurring maintenance work) were considered but NOT excluded, since that's still real work someone has to do, unlike a raw monitoring ping — except the specific Audit & Compliance / Business Continuity + Recurring combination above, which is. Revisit either judgment call if it turns out to be wrong. Update these files as new noise sources/queues/classifications are identified — confirmed with the user directly, same approach as `project-management/data/reference/excluded-projects.csv`.
