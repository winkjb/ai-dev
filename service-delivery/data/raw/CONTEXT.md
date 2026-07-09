# service-delivery/data/raw

## Purpose
Unmodified data exports — the actual system-of-record data, dropped in as-is, not hand-edited.

## Contents
- `Ticket Search Results.csv` — PSA ticket export read by `../../01-coordinator/ticket_report.py`. Covers the full open-ticket queue (tickets, status, priority, queue, resources, created/due timestamps, and — as of 2026-07-08 — a real `Last Activity Time` column).
- `Ticket Search Results-yesterda.csv` — prior day's export, kept alongside the current one for day-over-day comparison.

## Notes
Re-export and drop the replacement file in here to refresh; the filename is what `ticket_report.py` reads (see `../../01-coordinator/context.md` for the full revision history).
