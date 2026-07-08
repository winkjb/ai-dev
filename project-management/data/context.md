# project-management/data

## Purpose
Shared data store for project-management automation — the common source of truth referenced by the agents described in `../pm-agent-architecture.md`.

## Contents
- `raw/` — unmodified data exports (currently: Autotask "Active Projects by Status" CSV export, pending a proper API/data-warehouse connection).
- `reference/` — small manually maintained lookup files, e.g. `excluded-projects.csv` (perpetual support placeholders to exclude from Coordinator analysis).

Expected data over time:
- Project tracker exports/cache (tasks, status, ownership)
- SOW/template library
- Change request tiering framework
- Technician/engineer availability + skillset matrix
- Historical project metrics (for baseline/variance analysis)

## Notes
Use relative paths only when referencing files here from scripts (see workspace `CLAUDE.md`).
