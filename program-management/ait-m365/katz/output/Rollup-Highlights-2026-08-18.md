# Katz M365 Audit Rollup — Highlights

**Date:** 2026-08-18
**Source audits:** Admin Group Membership, Temp Groups, Mailbox Size, Conditional Access Policies, User Access (Disable), Licensed+Disabled Users, Temp Users
**Status:** Prototype — these six audits have been verified to run correctly against real Katz data, but most haven't yet had a deep logic review against the original scripts (see `bootstrap.md`). Treat as a first pass, not a final finding set.

---

## The highlights that matter most

**One account shows up as a problem in three separate audits.** `bwadmin@pineywoodsfl.onmicrosoft.com` ("Bit-Wizards Administrator") is:
- A **disabled** account that's still a **Global Administrator**
- Still **licensed** (Azure AD Premium P2, M365 Business Basic, Power Automate Free) — flagged separately by the Licensed+Disabled audit as "Reclaim license"
- Flagged for **overlapping permissions** (holds more than one privileged role)
- Its last logon was 20 days ago, so this isn't an ancient leftover — it went disabled recently while still fully provisioned

**MFA enforcement has a real gap.** The "Enable MFA - All Users" Conditional Access policy is enabled and enforced — but it **explicitly excludes** `Bit-Wizards Administrator` and `exchangeadmin`. `exchangeadmin` is an *active* Exchange Administrator (logged in 67 days ago) with no MFA requirement covering it at all. This only became visible by reading the CA policy audit and the admin-group audit side by side.

**Half of Katz's Conditional Access policies aren't actually enforcing anything.** 10 of 20 policies are in `enabledForReportingButNotEnforced` (report-only) mode — including Device Compliance, Geo-IP Fencing, Modern Authentication enforcement, and admin session/portal restrictions. They're logging what *would* happen, not blocking it.

**A second dormant admin account, still active.** `admin@pineywoodsfl.onmicrosoft.com` ("Pineywoods Office 365 Administrator") is an *enabled* Global Administrator with no interactive logon in **1,288 days** (3.5+ years) — flagged independently by both the admin-group audit and the access-disable audit.

---

## Admin Group Membership (`GroupAudit-Admins.csv`)

8 findings across 5 privileged roles (Exchange Administrator, Global Administrator, Global Reader, User Administrator):

| Account | Role | Issue |
|---|---|---|
| Bit-Wizards Administrator | Global Administrator | Disabled, licensed, overlapping permissions |
| MITS Admin | Global Administrator | Disabled, no logon ever recorded |
| Pineywoods Office 365 Administrator | Global Administrator | Active, but 1,288 days since last logon |
| BW Migrate | Global Reader **and** User Administrator | Disabled, no logon recorded, escalated-looking account name — leftover migration account with access in two roles |
| Alex LymandriveLLC | Global Reader | 537 days since last logon, name doesn't look like a dedicated admin account |
| exchangeadmin, ServIT | Exchange Administrator, Global Administrator | Clean — active, no issues |
| Nuvolex ManageX Platform App1 | Global Administrator | Service principal, not evaluable (expected) |

## Temp Groups (`GroupAudit-Temp.csv`)

2 groups matching temp/test naming, both old: **Test** (1,392 days old) and **Testing springfield** (1,813 days old). Low-stakes hygiene cleanup.

## Mailbox Size (`MailboxAudit-Size.csv`)

**Clean.** 121 mailboxes evaluated, 0 over the 75% storage threshold.

## Conditional Access Policies (`PolicyAudit-CA.csv`)

20 policies total:
- **5 enabled/enforced**: MFA - All Users, MFA - bwadmin, SSL VPN Access, Block Outside US (geo-fencing), Microsoft-managed risky-sign-in MFA
- **10 report-only** (not enforcing): Device Compliance, Geo-IP Fencing, Modern Authentication, both Persistent-Browser-Session policies, Sign-In Frequency, Block Interactive Logins (Service Accounts), Restrict Admin Portal Access, MFA for Admin Portal access, and one personal-travel exception (Brian Katz - Montreal)
- **5 disabled**: 3 personal-travel exceptions (Costa Rica, Cayman, BVI), "Allow Specific Countries" (unused/vestigial), and a Microsoft-managed per-user-MFA policy

Geo-fencing is already partially in place ("Block Outside US" is enforced), which is worth knowing given the kind of distributed-attack pattern we looked at on another customer's export this session — but the dedicated "Enforce Geo-IP Fencing" policy is still report-only, not blocking.

## Aged / At-Risk User Access

**User Access - Disable candidates** (`UserAudit-AccessDisable.csv`) — 18 users flagged, no successful/non-interactive logon in 180+ days (or ever):
- Several external guest (`#EXT#`) accounts that appear to be long-stale vendor/partner access
- `admin@pineywoodsfl.onmicrosoft.com` (the same dormant Global Administrator flagged above) and `admin@katzcapital.com` ("Receptionist", 500 days inactive)
- `test1@katzcapital.com` — also flagged separately below as a temp-named account

**Licensed + Disabled** (`UserAudit-LicensedAndDisabled.csv`) — 1 finding: `bwadmin@pineywoodsfl.onmicrosoft.com`, same account as the admin-group finding above, flagged here for the license-waste angle specifically.

**Temp Users** (`UserAudit-Temp.csv`) — 1 finding: `test1@katzcapital.com`, an enabled test-named account, 230 days old.

---

*This rollup was assembled by hand from each audit's latest output CSV in `02-analyst/output/katz/` - not yet an automated report. If this is useful, next steps would be scripting the rollup itself, deciding a real recipient/audience for it, and getting these audits scheduled so the data stays current.*
