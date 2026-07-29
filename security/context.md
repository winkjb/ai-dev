# security

## Purpose
Automation for the security team. First role in place (2026-07-28): a Coordinator that surfaces open Huntress escalations, mirroring the `project-management`/`service-delivery` Coordinator pattern. Broader scope (vulnerability tracking, compliance monitoring, incident response support) still pending definition.

## Contents
- `data/reference/` — settings (encrypted `HuntressSettings.txt` + a gitignored plaintext `.csv` staging copy, same pattern as `AutotaskSettings.txt`/`.csv` at the workspace root).
- `scripts/` — `Huntress-Functions-Common.ps1`, team-scoped shared Huntress API mechanics (auth, pagination), dot-sourced by role scripts. Team-specific per CLAUDE.md's root-`scripts/` convention - only promote to the workspace root if another team ends up needing Huntress too.
- `01-coordinator/` — `Export-CoordinatorEscalationsReport.ps1` (every open/non-resolved escalation, sorted by how long it's been waiting since created), `Invoke-CoordinatorReports.ps1` (unattended fetch+report+email, not yet scheduled).

## Notes
Unlike the project/ticket coordinators, there's no derived Health/flag logic here - every open Huntress escalation is already actionable by definition, so the report just surfaces detail (customer, severity, subject, days waiting) sorted worst-first, rather than computing flags.

Update this file further once additional workflows/agents for this team are defined (mirror the level of detail in `../project-management/pm-agent-architecture.md` if a similar architecture doc is warranted).
