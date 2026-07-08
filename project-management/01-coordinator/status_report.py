"""
Coordinator status report.

Reads the project export and reports on every in-scope project, not just
problem ones. Each project gets a computed Health label:
  - Overdue: end date has passed but the project isn't closed (worst)
  - Stalled Intake: sitting in "New" status for STALLED_INTAKE_DAYS+ days
  - Stale: no logged activity in STALE_DAYS+ days
  - Closed: in a closed status (not evaluated against the above)
  - On Track: open, none of the above triggered

Note: the source export's own "Project Status" field (Green/Yellow/Red) is
not a reliable signal - in practice it's Green on every row regardless of
actual health, so Health here is computed independently from dates/activity,
not read from that field. (That field isn't even present in the current
export - see below.)

Excludes projects matched in ../data/reference/excluded-projects.csv, which
supports two kinds of rules (Match Type column):
  - Project Number: specific perpetual "never-ending support" placeholders
    that aren't real time-bound projects
  - Project Type: category-wide rules, e.g. "Proposal" - proposals aren't
    real committed projects and should be excluded from every report that
    reads this data (added 2026-07-08)

Usage:
    python status_report.py

Reads:  ../data/raw/Project Search Results.csv
        ../data/reference/excluded-projects.csv
Writes: ./output/coordinator-status-report.csv   (every in-scope project)
        ./output/coordinator-status-summary.md
"""

import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config ---------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Project Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-projects.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_CSV = OUTPUT_DIR / "coordinator-status-report.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "coordinator-status-summary.md"

STALE_DAYS = 14
STALLED_INTAKE_DAYS = 30

# Statuses treated as "closed" - not subject to the health checks below
CLOSED_STATUSES = ["V-Pending Complete", "V-To Be Billled/Closed", "Inactive"]


def load_data():
    df = pd.read_csv(RAW_EXPORT, encoding="utf-8-sig")
    excluded = pd.read_csv(EXCLUDED_LIST, encoding="utf-8-sig")
    return df, excluded


def apply_exclusions(df, excluded):
    excl_numbers = set(excluded.loc[excluded["Match Type"] == "Project Number", "Value"])
    excl_types = set(excluded.loc[excluded["Match Type"] == "Project Type", "Value"])
    mask = df["Project Number"].isin(excl_numbers) | df["Project Type"].isin(excl_types)
    return df[~mask].copy(), int(mask.sum())


def clean(df):
    df["Start Date"] = pd.to_datetime(df["Start Date"], format="%m/%d/%Y", errors="coerce")
    df["End Date"] = pd.to_datetime(df["End Date"], format="%m/%d/%Y", errors="coerce")
    df["Last Activity Time"] = pd.to_datetime(
        df["Last Activity Time"], format="%m/%d/%Y %I:%M %p", errors="coerce"
    )
    df["% Complete - Task"] = (
        df["% Complete - Task"].astype(str).str.rstrip("%").astype(float)
    )
    df["% Complete - Hours"] = (
        df["% Complete - Hours"].astype(str).str.replace(",", "").str.rstrip("%").astype(float)
    )
    return df


def flag(df, today):
    is_open = ~df["Status"].isin(CLOSED_STATUSES)

    overdue = is_open & (df["End Date"] < today)
    stale = is_open & ((today - df["Last Activity Time"]).dt.days > STALE_DAYS)
    stalled_intake = (
        is_open
        & (df["Status"] == "New")
        & ((today - df["Start Date"]).dt.days > STALLED_INTAKE_DAYS)
    )

    df = df.copy()
    df["Flag: Overdue"] = overdue
    df["Flag: Stale"] = stale
    df["Flag: Stalled Intake"] = stalled_intake
    df["Days Past End Date"] = (today - df["End Date"]).dt.days.where(overdue)
    df["Days Since Last Activity"] = (today - df["Last Activity Time"]).dt.days
    df["Days In New Status"] = (today - df["Start Date"]).dt.days.where(stalled_intake)

    open_mask = is_open

    def health(row_is_open, row_overdue, row_stalled, row_stale):
        if not row_is_open:
            return "Closed"
        if row_overdue:
            return "Overdue"
        if row_stalled:
            return "Stalled Intake"
        if row_stale:
            return "Stale"
        return "On Track"

    df["Health"] = [
        health(o, x, y, z)
        for o, x, y, z in zip(open_mask, overdue, stalled_intake, stale)
    ]

    flagged = df[overdue | stale | stalled_intake].copy()
    return df, flagged


def write_outputs(df, today, excluded_count):
    OUTPUT_DIR.mkdir(exist_ok=True)

    cols = [
        "Project Number", "Account", "Project Name", "Status", "Health", "Project Lead",
        "Project Team Tech Lead", "Start Date", "End Date", "Last Activity Time",
        "Flag: Overdue", "Flag: Stale", "Flag: Stalled Intake",
        "Days Past End Date", "Days Since Last Activity", "Days In New Status",
    ]
    health_order = {"Overdue": 0, "Stalled Intake": 1, "Stale": 2, "On Track": 3, "Closed": 4}
    df = df.copy()
    df["_sort"] = df["Health"].map(health_order)
    ordered = df.sort_values(["_sort", "End Date"])
    ordered[cols].to_csv(OUTPUT_CSV, index=False)

    counts = df["Health"].value_counts()
    overdue_n = int(counts.get("Overdue", 0))
    stalled_n = int(counts.get("Stalled Intake", 0))
    stale_n = int(counts.get("Stale", 0))
    on_track_n = int(counts.get("On Track", 0))
    closed_n = int(counts.get("Closed", 0))

    by_lead = (
        df[df["Health"] != "Closed"]
        .groupby("Project Lead")["Health"]
        .value_counts()
        .unstack(fill_value=0)
        .astype(int)
    )
    for col in ["Overdue", "Stalled Intake", "Stale", "On Track"]:
        if col not in by_lead.columns:
            by_lead[col] = 0
    by_lead = by_lead[["Overdue", "Stalled Intake", "Stale", "On Track"]]

    lines = []
    lines.append(f"# Coordinator Status Report - {today.date()}")
    lines.append("")
    lines.append(
        f"Excluded {excluded_count} project(s) from analysis - perpetual-support placeholders "
        f"and/or Proposal-type projects (see ../data/reference/excluded-projects.csv)."
    )
    lines.append("")
    lines.append(f"- On Track: {on_track_n}")
    lines.append(f"- Overdue (past end date, still open): {overdue_n}")
    lines.append(f"- Stalled intake ('New' {STALLED_INTAKE_DAYS}+ days): {stalled_n}")
    lines.append(f"- Stale (no activity {STALE_DAYS}+ days): {stale_n}")
    lines.append(f"- Closed: {closed_n}")
    lines.append(f"- Total in scope: {len(df)}")
    lines.append("")
    lines.append("## By Project Lead (open projects only)")
    lines.append("")
    lines.append("| Project Lead | Overdue | Stalled Intake | Stale | On Track |")
    lines.append("|---|---|---|---|---|")
    for lead, row in by_lead.iterrows():
        lines.append(
            f"| {lead} | {row['Overdue']} | {row['Stalled Intake']} | {row['Stale']} | {row['On Track']} |"
        )
    lines.append("")
    lines.append(f"Full detail (every in-scope project, not just flagged ones): {OUTPUT_CSV.name}")

    OUTPUT_SUMMARY.write_text("\n".join(lines))

    return overdue_n, stale_n, stalled_n, on_track_n, closed_n


def main():
    df, excluded = load_data()
    df, excluded_count = apply_exclusions(df, excluded)

    df = clean(df)
    today = pd.Timestamp(datetime.now().date())

    df, flagged = flag(df, today)
    overdue_n, stale_n, stalled_n, on_track_n, closed_n = write_outputs(df, today, excluded_count)

    print(f"Projects analyzed: {len(df)} (excluded {excluded_count} project(s))")
    print(
        f"Overdue: {overdue_n} | Stalled intake: {stalled_n} | Stale: {stale_n} "
        f"| On Track: {on_track_n} | Closed: {closed_n}"
    )
    print(f"Wrote {OUTPUT_CSV} and {OUTPUT_SUMMARY}")


if __name__ == "__main__":
    main()
