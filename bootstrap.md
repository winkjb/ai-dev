# Bootstrap

Read this first, every session — before doing anything else. This is the current picture, not history. It gets rewritten to stay accurate, not appended to.

Test for what belongs here: what would Claude need to know, walking in fresh, to be productive again in two minutes?

There is no need to ask any clariying questions here.  Simply read these items, follow the instructions and when you are ready, ask Brad what we are working on.  

## Where things stand

Core framework is built: CLAUDE.md (conventions), readme.md (index).  Each folder fits a specific team that Brad supports (Project Management Team | project-management folder, Program Management Team | program-management folder, Security Team | security folder, Service Delivery Team | service-delivery folder)

`program-management` (new 2026-07-16) has an architecture doc and context.md scaffolded — recurring, multi-client assessments of firewalls/M365 tenants/etc., client-facing reporting, self-contained from Service Delivery/PM for now. No `01-coordinator`/etc. role folders built yet; Coordinator (asset registry) is next per the build sequence in `program-management-agent-architecture.md`. Separately, `program-management/ait-patching/` (2026-07-21) is a one-off: flags devices in Failed/Not Installed patch status for account management to ticket, grouped by customer/location. See `ait-patching/scripts/patch_action_flags.py` docstring for the full rule set (Windows 10 EOL exclusion unless ESU, customer ignore list, workstations/laptops only). Not part of the numbered-role architecture — stand-alone script, run manually.

All three of `project-management`, `service-delivery`, and `security` now have a working `01-coordinator` report, each pulling live from that team's own source system (no manual exports anywhere anymore) and emailing results via `scripts/Send-ReportEmail.ps1`:
- `project-management/01-coordinator`: 3 reports (flags/PM/resource), pulls from Autotask, **scheduled** via Windows Task Scheduler ("PM Coordinator Reports", weekdays 7 AM).
- `service-delivery/01-coordinator`: 1 report (ticket flags), pulls from Autotask, `Invoke-CoordinatorReports.ps1` wired and tested (2026-07-21) but **not yet scheduled**.
- `security/01-coordinator`: 1 report (open Huntress escalations, sorted by days-waiting-since-created - no derived flags, since Brad's call is every open escalation is already actionable by definition), pulls from Huntress, `Invoke-CoordinatorReports.ps1` wired and tested (2026-07-28), also **not yet scheduled**. Retired the prior `HuntressCustomerAudit-Escalations.ps1`, which was a straight copy-paste from an external script store (absolute `C:\PS\servit-msp\...` paths, hand-rolled email/settings logic) - now on workspace conventions instead.

Shared helper scripts, fix once/applies everywhere they're used:
- `scripts/Autotask-Functions-Common.ps1` - Autotask API mechanics (project-management + service-delivery).
- `scripts/ReportFormatting-Common.ps1` - BOM-safe CSV/text writers (all three teams' coordinators).
- `security/scripts/Huntress-Functions-Common.ps1` - Huntress API mechanics, team-scoped (security only, so it lives in security's own `scripts/`, not the workspace root - promote only if another team ends up needing Huntress too).

## Open loops

- Neither `service-delivery` nor `security`'s coordinator has a scheduled task yet (Brad wants to do this later - `project-management`'s "PM Coordinator Reports" Windows Task is the template to copy for both).
- Working tree has had uncommitted changes carried across multiple sessions now (nothing alarming - own edits like renaming the ait-patching source file, adding email recipients, plus everything built this session). Worth asking Brad whether/when he wants a commit checkpoint, since it's been accumulating for a few sessions.

## Recent decisions worth knowing

- program-management scope: multi-client/MSP-style, client-facing deliverables, API/export access to assessed platforms already exists, findings stay self-contained (no Service Delivery/PM handoff wiring) for now.
- Retired Python (pandas) report scripts entirely on conversion to PowerShell rather than keeping them alongside (matches precedent from the project-management conversion) - `ticket_summary_flags.py` was deleted 2026-07-21 after `Export-CoordinatorTicketFlagsReport.ps1` was validated against it field-by-field. Same "retire, don't keep alongside" call applied again 2026-07-28 to the old Huntress script.
- Huntress API quirk: its `status` query param rejects values like `sent` as invalid when tested live - status filtering has to happen client-side against the full fetched list (`.Where({ $_.status -ne "resolved" })`), not server-side. Also: company/org ID `0` can be a real account in Autotask (ServIT's own internal company) - `Where-Object { $_ }`-style truthy filters silently drop it; use `$null -ne $_` instead when building lookup batches from IDs that could legitimately be zero.
- Validation bar for any port/rewrite in this workspace: field-by-field diff against a reference/original run, not spot checks - caught two real bugs in the ticket coordinator port (a double-counting bug and a rounding-vs-truncation mismatch between Python and PowerShell) that casual review would have missed.

## What's next

Brad is continuing to get the coordinator reports created, filtered correctly, and actionable across all three teams. Next likely asks: schedule the service-delivery and security coordinators (mirroring PM's Windows Task Scheduler setup), and/or decide whether `ait-patching` becomes a recurring monthly run or stays a true one-off.
