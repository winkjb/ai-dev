# service-delivery/data

## Purpose
Shared data store for service-delivery automation — the common source of truth referenced by the agents described in `../support-service-delivery-agent-architecture.md`.

## Contents
- `raw/` — unmodified data exports. Currently: `Ticket Search Results.csv`, a PSA ticket export covering the full open-ticket queue (tickets, status, priority, queue, resources, created/due timestamps, and — as of 2026-07-08 — a real `Last Activity Time` column). Re-export and drop in here to refresh; the filename is what `01-coordinator/ticket_report.py` reads.
- `reference/` — small, human-maintained lookup files. `excluded-ticket-sources.csv` (noise sources/out-of-scope queues to exclude — see its own CONTEXT.md).

Expected data over time (per the architecture doc's Data Layer), not yet available:
- Known-issue library (including vendor bug tracking — e.g. FortiOS bug IDs)
- Contract/SLA terms by tier
- Tech skillset matrix + certifications
- On-call rotation and combined reactive/project calendar
- Historical ticket data (for Analyst pattern baselines)

## Notes
Use relative paths only when referencing files here from scripts (see workspace `CLAUDE.md`).
