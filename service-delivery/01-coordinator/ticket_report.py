"""
Coordinator status report (service-delivery ticket data).

This is the service-delivery team's Coordinator role (folder renamed from
01-ticket-dispatch to 01-coordinator for cross-project naming consistency
with project-management/01-coordinator - same functional pattern, separate
domain-specific implementation, per the architecture doc's overlap table).

Reads the ticket export and reports on every in-scope ticket, not just
problem ones. Each ticket gets a computed Health label:
  - Critical Unassigned: Priority 1 (Critical) with no tech assigned (worst)
  - Stalled Intake: sitting in the "New" queue at all (should have moved to
    a real work queue by now), or Dispatched in any other queue (a tech
    hasn't acknowledged/accepted the handoff yet) - a workflow/routing
    problem, not a time-based one, so no age threshold applies
  - Stale: no logged activity in STALE_DAYS+ days, based on the real
    Last Activity Time column (replaces an earlier "Neglected" flag that
    had to approximate this from status + ticket age, before Last Activity
    Time was available in the export - 2026-07-08)
  - Waiting External: blocked on the customer or a vendor, not on us
  - Unassigned: no tech assigned, doesn't already fall into the above
  - Active: has a tech assigned and isn't stuck in any of the above states

Note: the source export's "Due" field is NOT a live SLA clock - it's a
static ~24 hour first-response timer set once at ticket creation, so
"Due < now" is true for the majority of the queue regardless of ticket age
and isn't a meaningful signal on its own. Health is computed from Last
Activity Time + status/queue instead (mirrors how project-management's
Coordinator had to compute Health independently of the source's own
unreliable status field).

Excludes tickets matching any rule in ../data/reference/excluded-ticket-sources.csv.
Each row is a Queue+Source+Resource rule where a blank cell is a wildcard
(matches anything) and non-blank cells must ALL match (AND) for that row; a
ticket is excluded if ANY row matches (OR across rows) - e.g. a row with
only Queue set excludes that whole queue regardless of source, while a row
with both Queue and Source set (e.g. Audit & Compliance + Recurring) only
excludes that combination. Queue and Source match exactly; Resource matches
as a case-insensitive substring, since the Resources field can hold
multiple assignees (e.g. "Saeed, Kamran (primary) | Decaria, David") - a
Queue+Resource rule excludes tickets in that queue where the named
resource is assigned, even alongside other assignees. Added to support
excluding queues worked jointly by internal techs and named customer
contacts, where only the customer-resource tickets should be dropped.

Also labels every in-scope ticket with a Ticket Origin (Human-Generated /
System-Generated / Unclassified) via ../data/reference/source-classification.csv,
a Source lookup - kept separate from the exclusion list because these
tickets stay in scope (e.g. a system-generated monitoring ticket still
needs a human to review it, it's just not a dispatch-noise exclusion).

Usage:
    python ticket_report.py

Reads:  ../data/raw/Ticket Search Results.csv
        ../data/reference/excluded-ticket-sources.csv
        ../data/reference/source-classification.csv
Writes: ./output/ticket-dispatch-report.csv   (every in-scope ticket)
        ./output/ticket-dispatch-summary.md
"""

import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config -----------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Ticket Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-ticket-sources.csv")
SOURCE_CLASSIFICATION = Path("../data/reference/source-classification.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_CSV = OUTPUT_DIR / "coordinator-ticket-report.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "coordinator-ticket-summary.md"

STALE_DAYS = 7

# Statuses meaning "blocked on someone outside the team"
WAITING_STATUSES = {
    "Waiting Customer", "Waiting Vendor", "Waiting CI Update",
    "Waiting Return", "Waiting*",
}

INTAKE_QUEUE = "New"
DISPATCHED_STATUS = "Dispatched"


def load_data():
    df = pd.read_csv(RAW_EXPORT, encoding="utf-8-sig")
    excluded = pd.read_csv(EXCLUDED_LIST, encoding="utf-8-sig")
    classification = pd.read_csv(SOURCE_CLASSIFICATION, encoding="utf-8-sig")
    return df, excluded, classification


def _blank(value):
    return pd.isna(value) or str(value).strip() == ""


def apply_exclusions(df, excluded):
    mask = pd.Series(False, index=df.index)
    for _, rule in excluded.iterrows():
        rule_mask = pd.Series(True, index=df.index)
        if not _blank(rule["Queue"]):
            rule_mask &= df["Queue"] == rule["Queue"]
        if not _blank(rule["Source"]):
            rule_mask &= df["Source"] == rule["Source"]
        if "Resource" in rule.index and not _blank(rule["Resource"]):
            rule_mask &= df["Resources"].fillna("").str.contains(
                rule["Resource"], case=False, regex=False
            )
        mask |= rule_mask
    return df[~mask].copy(), int(mask.sum())


def classify_origin(df, classification):
    df = df.copy()
    lookup = dict(zip(classification["Source"], classification["Classification"]))
    df["Ticket Origin"] = df["Source"].apply(
        lambda source: "Unclassified" if _blank(source) else lookup.get(source, "Unclassified")
    )
    return df


DATE_FORMAT = "%m/%d/%Y %I:%M %p"


def clean(df):
    df["Created"] = pd.to_datetime(df["Created"], format=DATE_FORMAT, errors="coerce")
    df["Due"] = pd.to_datetime(df["Due"], format=DATE_FORMAT, errors="coerce")
    df["Last Activity Time"] = pd.to_datetime(df["Last Activity Time"], format=DATE_FORMAT, errors="coerce")
    return df


def flag(df, now):
    df = df.copy()
    df["Age Days"] = ((now - df["Created"]).dt.total_seconds() / 86400).round(1)
    df["Days Since Last Activity"] = (
        (now - df["Last Activity Time"]).dt.total_seconds() / 86400
    ).apply(lambda x: int(x) if pd.notna(x) else None)

    unassigned = df["Resources"].isna()
    critical = df["Priority"] == "1 (Critical)"
    waiting = df["Status"].isin(WAITING_STATUSES)
    stalled_intake = (df["Queue"] == INTAKE_QUEUE) | (
        (df["Status"] == DISPATCHED_STATUS) & (df["Queue"] != INTAKE_QUEUE)
    )
    stale = df["Days Since Last Activity"].notna() & (
        df["Days Since Last Activity"] > STALE_DAYS
    )

    critical_unassigned = critical & unassigned

    df["Flag: Critical Unassigned"] = critical_unassigned
    df["Flag: Stalled Intake"] = stalled_intake
    df["Flag: Stale"] = stale
    df["Flag: Waiting External"] = waiting
    df["Flag: Unassigned"] = unassigned

    # Single-label health, worst condition wins - priority order per
    # 2026-07-08 decision: Critical Unassigned > Stalled Intake > Stale >
    # Waiting External > Unassigned > Active.
    def health(row_name):
        if critical_unassigned.loc[row_name]:
            return "Critical Unassigned"
        if stalled_intake.loc[row_name]:
            return "Stalled Intake"
        if stale.loc[row_name]:
            return "Stale"
        if waiting.loc[row_name]:
            return "Waiting External"
        if unassigned.loc[row_name]:
            return "Unassigned"
        return "Active"

    df["Health"] = [health(i) for i in df.index]

    # Full picture, not just the winning flag - every tripped condition,
    # in priority order. "Unassigned" is suppressed whenever "Critical
    # Unassigned" is also present, since that flag requires unassigned=True
    # by construction and listing both would just be redundant.
    flag_cols_in_order = [
        ("Critical Unassigned", critical_unassigned),
        ("Stalled Intake", stalled_intake),
        ("Stale", stale),
        ("Waiting External", waiting),
        ("Unassigned", unassigned),
    ]

    def all_flags(row_name):
        names = [name for name, mask in flag_cols_in_order if mask.loc[row_name]]
        if "Critical Unassigned" in names and "Unassigned" in names:
            names.remove("Unassigned")
        return ", ".join(names) if names else "Active"

    df["All Flags"] = [all_flags(i) for i in df.index]
    return df


def write_outputs(df, now, excluded_count):
    OUTPUT_DIR.mkdir(exist_ok=True)

    cols = [
        "Ticket Number", "Account", "Title", "Queue", "Source", "Ticket Origin", "Priority", "Status", "Health", "All Flags",
        "Resources", "Created", "Due", "Last Activity Time", "Age Days", "Days Since Last Activity",
        "Flag: Critical Unassigned", "Flag: Stalled Intake", "Flag: Stale",
        "Flag: Waiting External", "Flag: Unassigned",
    ]
    health_order = {
        "Critical Unassigned": 0, "Stalled Intake": 1, "Stale": 2,
        "Waiting External": 3, "Unassigned": 4, "Active": 5,
    }
    df = df.copy()
    df["_sort"] = df["Health"].map(health_order)
    ordered = df.sort_values(["_sort", "Days Since Last Activity"], ascending=[True, False])
    ordered[cols].to_csv(OUTPUT_CSV, index=False)

    counts = df["Health"].value_counts()
    n = {k: int(counts.get(k, 0)) for k in health_order}

    by_queue = (
        df[df["Health"] != "Active"]
        .groupby("Queue")["Health"]
        .value_counts()
        .unstack(fill_value=0)
        .astype(int)
    )
    for col in health_order:
        if col not in by_queue.columns:
            by_queue[col] = 0
    by_queue = by_queue[[c for c in health_order if c != "Active"]]
    by_queue["Total Flagged"] = by_queue.sum(axis=1)
    by_queue = by_queue.sort_values("Total Flagged", ascending=False)

    lines = []
    lines.append(f"# Service Delivery Coordinator Report (Tickets) - {now.strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append(
        f"Excluded {excluded_count} automated-monitoring / out-of-scope-queue ticket(s) from "
        f"analysis (see ../data/reference/excluded-ticket-sources.csv)."
    )
    lines.append("")
    lines.append(f"- Critical Unassigned: {n['Critical Unassigned']}")
    lines.append(f"- Stalled Intake (New queue, or Dispatched elsewhere): {n['Stalled Intake']}")
    lines.append(f"- Stale (no activity {STALE_DAYS}+ days): {n['Stale']}")
    lines.append(f"- Waiting External (customer/vendor): {n['Waiting External']}")
    lines.append(f"- Unassigned (other): {n['Unassigned']}")
    lines.append(f"- Active: {n['Active']}")
    lines.append(f"- Total in scope: {len(df)}")
    lines.append("")
    lines.append("## By Queue (flagged tickets only, sorted worst first)")
    lines.append("")
    health_cols = [c for c in health_order if c != "Active"]
    header = "| Queue | " + " | ".join(health_cols) + " | Total Flagged |"
    lines.append(header)
    lines.append("|" + "---|" * (len(health_cols) + 2))
    for queue, row in by_queue.head(15).iterrows():
        queue_display = str(queue).replace("|", "\\|")
        vals = " | ".join(str(row[c]) for c in health_cols)
        lines.append(f"| {queue_display} | {vals} | {row['Total Flagged']} |")
    lines.append("")
    lines.append(f"Full detail (every in-scope ticket, not just flagged ones): {OUTPUT_CSV.name}")

    OUTPUT_SUMMARY.write_text("\n".join(lines))

    return n


def main():
    df, excluded, classification = load_data()
    df, excluded_count = apply_exclusions(df, excluded)
    df = clean(df)
    df = classify_origin(df, classification)
    now = pd.Timestamp(datetime.now())

    df = flag(df, now)
    n = write_outputs(df, now, excluded_count)

    print(f"Tickets analyzed: {len(df)} (excluded {excluded_count} ticket(s))")
    print(
        f"Critical Unassigned: {n['Critical Unassigned']} | Stalled Intake: {n['Stalled Intake']} "
        f"| Stale: {n['Stale']} | Waiting External: {n['Waiting External']} "
        f"| Unassigned: {n['Unassigned']} | Active: {n['Active']}"
    )
    print(f"Wrote {OUTPUT_CSV} and {OUTPUT_SUMMARY}")


if __name__ == "__main__":
    main()
