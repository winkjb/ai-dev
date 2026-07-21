# program-management

## Purpose
Automation for the program management function — recurring, ongoing technical assessments of infrastructure across the supported client book (firewalls, Microsoft tenants, and other managed platforms), as laid out in `program-management-agent-architecture.md`. Assessments are client-facing (scorecard/QBR-style reporting) as well as internal.

## Contents
- `program-management-agent-architecture.md` — multi-agent design doc: agent roles, triggers, inputs/outputs, handoffs, and build sequence.
- `<offering>/` (e.g. `ait-networking/`) — one top-level folder per offering being program-managed. Each offering owns its own `data/` (raw collector output + reference/settings, per-client subfolders) and role folders for offering-specific work (Collector, Analyst — the roles whose logic is genuinely platform-specific and can't be shared across offerings).
- `ait-patching/` (2026-07-21) — a one-off, not part of the numbered-role architecture: flags devices sitting in Failed/Not Installed patch status (from a monthly patch export) for account management to open tickets against, grouped by customer/location. Business rules (Windows 10 EOL exclusion unless the customer has ESU, a customer ignore list, workstations/laptops only) are documented in `ait-patching/scripts/patch_action_flags.py`'s docstring. Run manually, not scheduled.
- `01-coordinator/`, `02-client-communication/`, `07-orchestrator/` — (not yet created) roles that stay shared at this root level rather than duplicated per offering, since they need a cross-offering view: one asset registry, one client-facing report covering everything a client is assessed on, one escalation point.

## Notes
Structure pivoted 2026-07-17 from "flat, numbered role folders at the program-management root" to "offering-first": each offering (networking devices, email security, etc.) has fundamentally different collection/evaluation logic, so it gets its own top-level folder rather than forcing every offering through identical role machinery. Coordinator/Client Communication/Orchestrator remain shared at the program-management root since those need to reason across offerings, not just one.

Scope is multi-client (MSP-style): assessments run per client, per device/tenant, and roll up into a book-of-business view. API/export access to assessed platforms (firewall vendor APIs, M365 Graph/Secure Score) already exists.

Findings stay self-contained within program-management for now. Handing a confirmed violation off to Service Delivery (ticket) or a large remediation effort to Project Management (new project) is a known future integration — see the Orchestrator section of the architecture doc — not wired up yet.
