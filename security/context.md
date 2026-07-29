# security

## Purpose
Automation for the security team. First role in place (2026-07-28): a Coordinator that surfaces open Huntress escalations, mirroring the `project-management`/`service-delivery` Coordinator pattern. Broader scope (vulnerability tracking, compliance monitoring, incident response support) still pending definition.

## Contents
- `01-coordinator/` — `Export-CoordinatorEscalationsReport.ps1` (every open/non-resolved escalation, sorted by how long it's been waiting since created), `Invoke-CoordinatorReports.ps1` (unattended fetch+report+email, not yet scheduled).

Huntress settings and API function files live at the workspace root now, not under `security/` - Brad moved them 2026-07-29 (renamed to the `Functions-<Platform>-Common.ps1` naming convention alongside Autotask/VA, and to the root since Huntress is expected to be used by other folders later, not security-only): `data/reference/HuntressSettings.txt` (encrypted) + `data/reference/HuntressSettings.csv` (gitignored plaintext staging copy) and `scripts/Functions-Huntress-Common.ps1`.

## Notes
Unlike the project/ticket coordinators, there's no derived Health/flag logic here - every open Huntress escalation is already actionable by definition, so the report just surfaces detail (customer, severity, subject, days waiting) sorted worst-first, rather than computing flags.

Update this file further once additional workflows/agents for this team are defined (mirror the level of detail in `../project-management/pm-agent-architecture.md` if a similar architecture doc is warranted).
