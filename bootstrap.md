# Bootstrap

Read this first, every session — before doing anything else. This is the current picture, not history. It gets rewritten to stay accurate, not appended to.

Test for what belongs here: what would Claude need to know, walking in fresh, to be productive again in two minutes?

There is no need to ask any clariying questions here.  Simply read these items, follow the instructions and when you are ready, ask Brad what we are working on.  

## Where things stand

Core framework is built: CLAUDE.md (conventions), readme.md (index).  Each folder fits a specific team that Brad supports (Project Management Team | project-management folder, Program Management Team | program-management folder, Security Team | security folder, Service Delivery Team | service-delivery folder)

`program-management` (new 2026-07-16) has an architecture doc and context.md scaffolded — recurring, multi-client assessments of firewalls/M365 tenants/etc., client-facing reporting, self-contained from Service Delivery/PM for now. No `01-coordinator`/etc. role folders built yet; Coordinator (asset registry) is next per the build sequence in `program-management-agent-architecture.md`. Separately, `program-management/ait-patching/` (2026-07-21) is a one-off: flags devices in Failed/Not Installed patch status for account management to ticket, grouped by customer/location. See `ait-patching/scripts/patch_action_flags.py` docstring for the full rule set (Windows 10 EOL exclusion unless ESU, customer ignore list, workstations/laptops only). Not part of the numbered-role architecture — stand-alone script, run manually.

Both `project-management` and `service-delivery`'s `01-coordinator` reports are now fully PowerShell, pulling live from Autotask (no more manual UI exports) and emailing results via `scripts/Send-ReportEmail.ps1`:
- `project-management/01-coordinator`: 3 reports (flags/PM/resource), scheduled via Windows Task Scheduler ("PM Coordinator Reports", weekdays 7 AM).
- `service-delivery/01-coordinator`: 1 report (ticket flags), `Invoke-CoordinatorReports.ps1` wired and tested (2026-07-21) but **not yet scheduled** - Brad wants to set the scheduled task up later.

Both teams' report scripts share `scripts/Autotask-Functions-Common.ps1` (API mechanics) and `scripts/ReportFormatting-Common.ps1` (BOM-safe CSV/text writers) - fix once, applies to both.

## Open loops

- Service-delivery coordinator scheduled task not yet created (Brad wants to do this later - see `project-management`'s "PM Coordinator Reports" Windows Task as the template to copy).

## Recent decisions worth knowing

- program-management scope: multi-client/MSP-style, client-facing deliverables, API/export access to assessed platforms already exists, findings stay self-contained (no Service Delivery/PM handoff wiring) for now.
- Retired Python (pandas) report scripts entirely on conversion to PowerShell rather than keeping them alongside (matches precedent from the project-management conversion) - `ticket_summary_flags.py` was deleted 2026-07-21 after `Export-CoordinatorTicketFlagsReport.ps1` was validated against it field-by-field.

## What's next

Brad is continuing to get the initial coordinator reports created, filtered out correctly and actionable. Next likely ask: schedule the service-delivery coordinator (mirroring PM's Windows Task Scheduler setup), and/or decide whether `ait-patching` becomes a recurring monthly run or stays a true one-off.
