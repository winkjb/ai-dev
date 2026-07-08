# service-delivery/04-planner

## Purpose
Proactive Tier — Agent #4 in `../support-service-delivery-agent-architecture.md` (named "Planner" for consistency with `project-management/04-planner`, which does the same functional job — proactive forecasting against constraints — against a different data domain). Balances tech time between reactive ticket work and project/PM work; ensures on-call coverage; forecasts queue depth against available capacity.

## Contents
(empty — to be populated)

## Notes
This folder was renamed from `04-scheduling-capacity` to `04-planner` (2026-07-08) purely for cross-project naming consistency — **the implementation stays separate and domain-specific**, not shared code. Per the architecture doc's "Where This Overlaps With the PM Architecture" table, Planner/Scheduling-Capacity was deliberately classified as "similar pattern, different constraints (dependencies vs. SLA clocks) — likely separate instances," unlike the four roles flagged as "strong candidate to share."

Known conflict point per architecture doc: a capacity gap this agent flags may actually be a skillset gap in disguise — see Resource Allocation (`../07-resource-allocation`) and the Orchestrator's conflict-resolution rule for this.
