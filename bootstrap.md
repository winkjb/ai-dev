# Bootstrap

Read this first, every session — before doing anything else. This is the current picture, not history. It gets rewritten to stay accurate, not appended to.

Test for what belongs here: what would Claude need to know, walking in fresh, to be productive again in two minutes?

There is no need to ask any clariying questions here.  Simply read these items, follow the instructions and when you are ready, ask Brad what we are working on.

## Where things stand

Core framework is built: CLAUDE.md (conventions), readme.md (index). Each folder fits a specific team Brad supports (Project Management | `project-management`, Program Management | `program-management`, Security | `security`, Service Delivery | `service-delivery`).

**project-management / service-delivery / security** each have a working `01-coordinator` report pulling live from that team's own source system (no manual exports) and emailing via `scripts/Send-ReportEmail.ps1`:
- `project-management/01-coordinator`: 3 reports (flags/PM/resource), Autotask, scheduled weekdays 7 AM ("PM Coordinator Reports").
- `service-delivery/01-coordinator`: 1 report (ticket flags), Autotask, wired but not yet scheduled.
- `security/01-coordinator`: 4 reports (Huntress escalations, Huntress incidents, RocketCyber threats, SentinelOne threats) in one run, emailing bwinklesky/ghuelsmann/kterza@servit.net. Scheduled Friday weekly, confirmed firing in production.

**Shared workspace-wide scripts** (`scripts/`, `Functions-<Platform>-Common.ps1` convention): Autotask, VA (core helpers - `Import-Settings`, `Send-Results`, `Test-Directory`, `Map-Customer`), Huntress, M365 (Graph), FortiGate, RocketCyber, SentinelOne, `ReportFormatting-Common.ps1` (BOM-safe CSV/text writers), `Functions-Formatting-Common.ps1` (`Export-Utf8NoBomCsv` - handles empty result sets correctly, fixed 2026-08-17, used by 21 files across all 4 teams, decided to leave in place everywhere rather than revert to plain `Export-Csv`).

**Central dispatcher** (`scripts/Invoke-ScheduledScripts.ps1`) - one Task Scheduler trigger reads `data/input/ScriptManifest.csv` + `ScriptRunState.json` to decide what's due: timing guard (rejects runs outside expected-time window, default 7 AM ±15 min, `-SkipTimingGuard` bypasses), no same-day dedup by design (`-Force` covers legitimate re-runs), relative manifest paths resolve against repo root, `-DelaySeconds` (default 30) between scripts, monthly log rotation (`scripts/Remove-OldLogs.ps1`, 12-month retention). `-FrequencyFilter "Monthly-End"` param + `scripts/Invoke-ScheduledScripts-MonthlyEnd.ps1` entry point exist for a second midnight trigger (default/unfiltered runs exclude `Monthly-End`; a filtered run touches only it) - **still needs a human to actually register that as a second Windows Task Scheduler trigger (~00:05 daily)**, alongside the existing "Virtual Administrator Tasks - Daily" trigger.
Known gotcha: `$PSScriptRoot` is unreliable inside a **parameter default value** when launched via `powershell.exe -File` (how Task Scheduler runs things) - resolve paths in the script body instead. Still unfixed (flagged only) in `ait-networking/scripts/fortigate/Invoke-FortiGateDiscovery.ps1` if that's still live.

`data/input/ScriptManifest.csv` currently has: `PM-Invoke-CoordinatorReports`, `SD-Invoke-CoordinatorReports` (Daily), `Remove-OldLogs` (Monthly), and Katz's `Invoke-Audits-Monthly`/`-Quarterly` (`DayOfMonth=14`) + `Invoke-Audits-MonthlyEnd` (`Frequency=Monthly-End`, `DayOfMonth=1`).

**program-management/ait-patching** - one-off script (`patch_action_flags.py`), not part of the numbered-role architecture, run manually. Open decision: keep as one-off or make recurring.

**program-management/soc-rocketcyber** / **soc-sentinelone** - `Export-RocketCyberThreats.ps1` / `Export-SentinelOneThreats.ps1`, collector-only (no Analyst, no email wrapper) by design, both live-validated against real accounts. SentinelOne rewritten for server-side filtering (`activeThreats__gt=0`, chunked by site) - 528 sites in ~9s. Note: the original SentinelOne script's direct email notification isn't replicated anywhere currently.

**program-management/ait-networking** (FortiGate) - `Functions-FortiGate-Common.ps1` centralizes auth/cert-bypass. Only the zero-hit policy/VIP audit is split into the Collector→Analyst→Orchestrator→wrapper shape (`Collect-FirewallPolicies.ps1` / `Compare-PolicyAudit-ZeroHits.ps1` / `Invoke-FirewallAudit-ZeroHits-Default.ps1`, multi-site orchestrator loops every subfolder of `data/reference/<CustomerDir>/`). `AdminAudit`, `SecurityProfiles`, `WanRedundancy` collectors still monolithic (raw pull + thresholds mixed, own duplicated boilerplate) - same split treatment applies when picked up. `AdminAudit` has a known permanent gap: `system/admin` API data requires full super_admin creds, not achievable via granted profile permissions - stays a manual GUI check. Org standards: HTTPS redirect **off**, admin port **8443**. Katz's `hq` site 403s (API key/trusted-host permission gap on that firewall, not a script bug); `harbourpost` fully live-verified. `WanRedundancy` collector not yet validated live (field names unconfirmed). Flagged fix not yet built: `Compare-PolicyAudit-ZeroHits.ps1` should only flag *enabled* zero-hit policies, not disabled ones (Status field already collected, not split on).

**program-management/ait-m365** (Katz) - 20 audits, all in the Collector→Analyst→`Invoke-<Audit>-Default.ps1`→`katz/<cadence>/Invoke-<Audit>.ps1` shape; 18 have a real Analyst, 2 (`LogAudit-UserActivities`/`LogAudit-UserSignIns`) are Collector-only raw log exports by design (future idea, not built: an Analyst for CA-bypass/bad-actor detection or failed-vs-success sign-in rollup). Naming is fully consistent workspace-wide (2026-08-17 rename pass). `Map-Customer` (in `Functions-VA-Common.ps1`, workspace-shared) reads root-level `data/reference/CustomerMap.csv` (`Directory`/`SharepointFolder`/`FromAddress` columns). The `-ListCandidateUpns` two-pass scoping pattern (Analyst computes the real candidate list first, Collector's mailbox-purpose pull is scoped to just those UPNs) is used by `UserAccessAudit-Disable`, `MailboxAudit-LicensedShared`, `UserAudit-LicensedDisabled`; `UserAudit-Hr` stays intentionally full-tenant.

Emailing is consolidated into **one digest per customer per cadence** (`monthly`/`monthly-end`/`quarterly`, lowercase folders under `katz/`) via `scripts/Invoke-Audits-Default.ps1` + `katz/Invoke-Audits-Monthly/-MonthlyEnd/-Quarterly.ps1` - only CSVs with actual rows get attached; a per-customer-per-audit wrapper can still declare `$AdditionalToAddresses` for a side-email with just that audit's CSV, in addition to the main digest. Only Katz is onboarded onto this cadence-folder shape so far; a second customer or a one-off "personalized audit" wrapper hasn't been tried yet.

**Power Automate integration (2026-08-22)**: the digest email body ends with this block, at the very bottom, below all other text (Power Automate expects it there) - only on emails that actually carry results, not the "no findings" body:
```
##############################<br>
Source: Virtual Administrator<br>
Customer Folder: $SpFolder<br>
##############################<br>
```
This is digest-only by Brad's explicit call - the per-audit side-emails to `$AdditionalToAddresses` don't get it.

**Too-large attachment handling (2026-08-22, real bug fixed)**: the two log audits' `-Default.ps1` orchestrators used to skip their 30MB size check entirely in digest mode (returned the bare CSV path before the check ever ran). Fixed: size is computed before branching on `-SkipEmail`; digest mode returns `{CsvPath, TooLarge, SizeMB}`. When `TooLarge`, `Invoke-Audits-Default.ps1` skips attaching and adds a body line containing the literal substring `"too large"` (the key Power Automate searches for) plus the local file path - still counts toward the findings tally and still gets the trigger block. **Live-tested by Brad 2026-08-22**: Monthly-End digest ran end-to-end, all attachments landed in SharePoint as expected, and the too-large path fired correctly against an artificially-lowered threshold. Power Automate side updated to match - awaiting final confirmation.

## Open loops

- **ait-m365**: `Monthly` (8 audits) and `Quarterly` (10 audits) digests not yet run live end-to-end - only `Monthly-End` has been (twice, including today's too-large test).
- **ait-m365**: only temp-groups, admin-group, and CA-group-members have had a real logic diff-review against their original retired scripts; the other 17 have only been confirmed to run without erroring.
- **ait-m365**: standalone (non-digest) `Invoke-<Audit>-Default.ps1` runs still attach a header-only CSV on a zero-finding result - only the digest path got the empty-findings guard.
- **ait-m365**: second-customer onboarding (own `monthly`/`monthly-end`/`quarterly` folders, cadence may differ from Katz's) not yet tried; same for a one-off "personalized audit" wrapper.
- **Dispatcher**: `Invoke-ScheduledScripts-MonthlyEnd.ps1` still needs to be registered as an actual second Windows Task Scheduler trigger (~00:05 daily) - human-at-keyboard step.
- **FortiGate**: `Compare-PolicyAudit-ZeroHits.ps1` needs to split active-vs-inactive zero-hit findings by `Status`. Only 1 of 4 collectors (`Collect-FirewallPolicies.ps1`) is split into the Collector/Analyst shape - `AdminAudit`/`SecurityProfiles`/`WanRedundancy` still monolithic. Katz's `hq` site 403s (permission gap, not a script bug) - `WanRedundancy` still needs a live validation run.
- `ait-patching`: decide recurring monthly run vs. staying a true one-off.

## Recent decisions worth knowing

- program-management scope: multi-client/MSP-style, client-facing, API/export access already exists, findings stay self-contained (no Service Delivery/PM handoff) for now.
- Retire-don't-keep-alongside: every legacy script converted to workspace conventions gets deleted, not kept as a parallel copy, once its replacement is validated field-by-field.
- Huntress API: `status` query param filtering is unreliable server-side - filter client-side instead. Also, org/company ID `0` can be a real account (ServIT's own) - use `$null -ne $_` rather than truthy filters when building ID-based lookup batches.
- Validation bar for any port/rewrite: field-by-field diff against a reference/original run, not spot checks - this has caught real bugs every time it's been applied.
- PowerShell gotcha: array-splat (`@array`) binds positionally only - use a hashtable splat (`@hash`) for named/switch parameters in manifest `Arguments` or similar.
- `Export-Utf8NoBomCsv` usage is settled (2026-08-17) - leave it everywhere currently used, don't revert ait-m365's internal `data/raw/*.csv` files to plain `Export-Csv`. Not an open question.
- Orchestrator/wrapper switch-plumbing (2026-08-18): don't thread every Analyst switch up through the orchestrator into the customer wrapper preemptively - add a param to one wrapper+orchestrator pair only when a second customer actually needs a different value; prefer a data-driven per-customer override (matching `CustomerMap.csv`/exclusion-CSV precedent) if the need recurs across customers.

## What's next

Brad is continuing to validate the ait-m365 digest/Power Automate integration live (today's fixes are tested but awaiting final confirmation). Next up there: run the `Monthly` and `Quarterly` digests live end-to-end, onboard a second customer onto the cadence-folder shape, and keep working through the deep logic diff-review of the remaining 17 audits. Elsewhere: pick up the FortiGate Collector/Analyst split for the 3 remaining collectors, register the Monthly-End midnight Task Scheduler trigger, and decide whether `ait-patching` becomes recurring.
