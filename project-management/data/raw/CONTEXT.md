# project-management/data/raw

## Purpose
Unmodified data exports — the actual system-of-record data, dropped in as-is, not hand-edited.

## Contents
- `Project Search Results.csv` — Autotask project export read by `../../01-coordinator/status_report.py` and `../../01-coordinator/workload_by_tech_lead.py`. Replaced the older `Active Projects by Status.csv` export on 2026-07-08 (narrower column set, added `Project Team Tech Lead`).

## Notes
Re-export and drop the replacement file in here to refresh; the filename is what the coordinator scripts read (see `../../01-coordinator/context.md` for the full revision history).
