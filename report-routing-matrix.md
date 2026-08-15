# Report Routing Matrix

Working draft (2026-08-10) — not a final decision. Rows are every report/script that currently emails someone (or will need to soon); columns are the five groups Brad named. `x` = proposed, `?` = genuinely unsure, blank = probably not relevant. "Current Recipients" is what's hardcoded in the script today, for reference while deciding what it *should* be.

Scope note: only reports with an actual email step are listed as "wired." The FortiGate suite and `ait-patching` are included because they'll need this same thinking soon, but nothing sends them anywhere yet.

## Wired today (has an email step)

| Report | Script | Current Recipients | SOC/Security | App Owner | Account Mgmt | Tech Support | Billing/Accounting | Notes |
|---|---|---|---|---|---|---|---|---|
| Security Coordinator (Huntress escalations) | `security/01-coordinator/Invoke-CoordinatorReports.ps1` | bwinklesky | x | | | | | Clean fit. |
| Service Delivery Coordinator (ticket flags) | `service-delivery/01-coordinator/Invoke-CoordinatorReports.ps1` | bwinklesky, rpardue, abradford | | | ? | x | | Ticket-queue health — Tech Support seems right; unsure if Account Mgmt should also see it. |
| Project Management Coordinator (flags/PM/resource) | `project-management/01-coordinator/Invoke-CoordinatorReports.ps1` | bwinklesky, tmarsili | | | ? | ? | | Doesn't map cleanly onto the 5 groups as-is — resource/project flags feel PM-team-internal, which isn't one of the named groups. Worth discussing whether PM needs its own lane. |
| Proofpoint Admins (admin account hygiene) | `email-proofpoint/Invoke-ProofpointReports.ps1` | bwinklesky | ? | x | | | | Admin-account hygiene is arguably a security concern too (same reasoning as the FortiGate admin audit) — SOC/Security as a possible cc. |
| Proofpoint Billables | `email-proofpoint/Invoke-BillableReports.ps1` | bwinklesky | | x | | | x | |
| PowerDMARC Billables | `email-powerdmarc/Invoke-BillableReports.ps1` | bwinklesky | | x | | | x | |
| Vipre Billables | `email-vipre/Export-BillableUsers.ps1` | bwinklesky, tmarsili, chart | | x | | | x | Only one with 3 recipients today — chart may already represent Billing/Accounting; worth confirming rather than assuming. |

## Not wired yet (will need routing decisions soon)

| Report | Script | Notes |
|---|---|---|
| SentinelOne Threats | `soc-sentinelone/Export-SentinelOneThreats.ps1` | Converted 2026-08-10, collector-only per Brad's call — no email wrapper yet. Almost certainly SOC/Security once built; original ad-hoc version emailed bwinklesky + tmarsili. |
| FortiGate Hit Counts / Security Profiles / Admin Audit / WAN Redundancy | `ait-networking/scripts/fortigate/*.ps1` | Four collectors built 2026-08-10, none wired to email/discovery-scheduling for notification yet. Likely SOC/Security + App Owner (whoever owns firewall/networking). |
| AIT Patching flags | `ait-patching/scripts/patch_action_flags.py` | Stand-alone, run manually per bootstrap.md — flags go to account management for ticketing per its docstring. Probably Account Mgmt, confirm. |

## Open questions for Brad

1. Does Project Management need its own lane beyond the 5 named groups, or does its routing belong under Tech Support / Account Mgmt as currently guessed?
2. Is "Application Owner" one person per app, or does it vary — and who owns which app today (Proofpoint, PowerDMARC, Vipre, SentinelOne, FortiGate/networking)?
3. Should Proofpoint Admins also cc SOC/Security, given the admin-hygiene parallel to the FortiGate admin audit?
