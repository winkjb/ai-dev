# service-delivery/02-client-communication

## Purpose
Reactive Tier — Agent #2 in `../support-service-delivery-agent-architecture.md`. Translates technical resolution detail (root cause, remediation steps) into client-readable status updates and resolution summaries.

## Contents
(empty — to be populated)

## Notes
Client-facing output should not auto-send without human review, at least initially (per architecture doc). Flagged in the architecture doc as a **strong candidate to share** with `project-management/02-client-communication` — same core function (technical → client-readable translation), just different data sources. Worth building as one shared agent rather than two before committing to a role-owned implementation here.
