# service-delivery/08-orchestrator

## Purpose
Cross-cutting coordinator — final section in `../support-service-delivery-agent-architecture.md`. Routes between agents; resolves conflicts; decides what surfaces to a human.

## Contents
(empty — to be populated)

## Notes
**Key difference from the PM Orchestrator:** ticket volume is high and individual-ticket stakes are usually low, so this Orchestrator should auto-resolve at the individual-ticket level (routine assignment, routine status updates) and reserve human escalation for pattern-level or compliance-level findings — a single ticket rarely needs a human in the loop; forty tickets pointing at the same firewall bug does.

Per the architecture doc's build sequence, wire this in as real pattern-vs-individual-ticket escalation decisions start appearing, not speculatively up front.
