# project-management/data/reference

## Purpose
Small, manually maintained lookup/reference files that scripts read to adjust behavior — as opposed to `../raw`, which holds unmodified data exports.

## Contents
- `excluded-projects.csv` — projects/categories to exclude from every project-management report. Columns: `Match Type` (`Project Number` or `Project Type`), `Value`, `Reason`, `Date Added`. Two kinds of rule:
  - `Project Number` rows — specific perpetual "never-ending support" placeholders (e.g. "Ongoing Support" contracts) that aren't real time-bound projects.
  - `Project Type` rows — category-wide rules, e.g. `Value = Proposal` (added 2026-07-08) — proposals aren't real committed/assigned work and would distort any status or workload report.
- `status-phase-mapping.csv` — maps each raw `Status` value to a collapsed `Phase` bucket (Beginning / In Process / Closing / On Hold), used by `../../01-coordinator/workload_by_tech_lead.py`. Added 2026-07-08 per the user's collapsing rule: New/I/II → Beginning, III/IV → In Process, V → Closing, On Hold → On Hold (its own bucket).

## Notes
Update `excluded-projects.csv` as new perpetual-support placeholder projects are identified — confirmed with the user directly, since this isn't reliably inferable from naming patterns alone (see the false positives ruled out on 2026-07-06: AIT/SOC agreement and onboarding projects were considered but excluded from this list since they're finite, not perpetual).

The `Match Type`/`Value` schema mirrors `service-delivery/data/reference/excluded-ticket-sources.csv` deliberately — same pattern (curated exclusions + category-wide rules in one file) reused across both projects.

If a new Status value ever shows up in the raw export that isn't in `status-phase-mapping.csv`, `workload_by_tech_lead.py` buckets it as "Unknown Phase" and prints a warning rather than failing — add the new Status/Phase pair here when that happens.
