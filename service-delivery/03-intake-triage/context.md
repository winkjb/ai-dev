# service-delivery/03-intake-triage

## Purpose
Reactive Tier — Agent #3 in `../support-service-delivery-agent-architecture.md`. Classifies incoming ticket severity, checks against the known-issue library (e.g. vendor bug pattern matches) before a ticket reaches a tech, and routes to Dispatch.

## Contents
(empty — to be populated)

## Notes
Flagged as the **build-sequence priority #1** in the architecture doc, given the current FortiGate/known-issue situation — catching pattern matches at intake beats catching them after 40 tickets. Also flagged as a **strong candidate to share** with `project-management/03-intake-triage` (same scoping/routing logic, different intake source).
