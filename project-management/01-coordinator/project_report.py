"""
Project report by Project Lead.

Reads the project export and reports how many in-scope projects each
Project Lead is currently carrying, broken out by phase and totaled - a
capacity/status-mix view grouped by Project Lead, mirroring
workload_by_tech_lead.py's structure (which groups the same data by
Project Team Tech Lead instead).

This replaces an earlier version of this script that computed
Overdue/Stale/Stalled Intake health flags from Start/End Date and Last
Activity Time. That date-based logic turned out not to hold up in
practice, so it's been dropped in favor of this simpler phase-mix view.
(The old flagging script, status_report.py, has been deleted; a
replacement issue/health-snapshot report is still to be designed.)

Phase is a collapsed grouping of the raw Status field, defined in
../data/reference/status-phase-mapping.csv:
  - Beginning:      New, I-*, II-*                    (not yet in active execution)
  - In Process:     III-*, IV-*                        (active execution / customer signoff)
  - Closing:        V-Pending Complete                  (wrapping up)
  - Final Closure:  V-To Be Billed/*                    (awaiting billing)
  - On Hold/Inactive: On Hold, Inactive

Excludes projects matched in ../data/reference/excluded-projects.csv
(same file/logic as workload_by_tech_lead.py) - notably Project Type =
Proposal, since proposals aren't real assigned work and would distort a
per-person project count.

Usage:
    python project_report.py

Reads:  ../data/raw/Project Search Results.csv
        ../data/reference/excluded-projects.csv
        ../data/reference/status-phase-mapping.csv
Writes: ./output/project-report-by-lead-detail.csv   (every in-scope project, one row each)
        ./output/project-report-by-lead-summary.md   (pivot table: project lead x phase + total)
"""

import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config -----------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Project Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-projects.csv")
PHASE_MAPPING = Path("../data/reference/status-phase-mapping.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_DETAIL = OUTPUT_DIR / "project-report-by-lead-detail.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "project-report-by-lead-summary.md"

PHASE_ORDER = ["Beginning", "In Process", "Closing", "Final Closure", "On Hold/Inactive"]
NO_LEAD_LABEL = "(No Project Lead Listed)"
UNKNOWN_PHASE_LABEL = "Unknown Phase"


def load_data():
    df = pd.read_csv(RAW_EXPORT, encoding="utf-8-sig")
    excluded = pd.read_csv(EXCLUDED_LIST, encoding="utf-8-sig")
    phase_map = pd.read_csv(PHASE_MAPPING, encoding="utf-8-sig")
    return df, excluded, phase_map


def apply_exclusions(df, excluded):
    excl_numbers = set(excluded.loc[excluded["Match Type"] == "Project Number", "Value"])
    excl_types = set(excluded.loc[excluded["Match Type"] == "Project Type", "Value"])
    mask = df["Project Number"].isin(excl_numbers) | df["Project Type"].isin(excl_types)
    return df[~mask].copy(), int(mask.sum())


def add_phase(df, phase_map):
    df = df.copy()
    lookup = dict(zip(phase_map["Status"], phase_map["Phase"]))
    unmapped = sorted(set(df["Status"]) - set(lookup))
    if unmapped:
        print(
            f"WARNING: {len(unmapped)} status value(s) not in status-phase-mapping.csv, "
            f"bucketed as '{UNKNOWN_PHASE_LABEL}': {unmapped}"
        )
    df["Phase"] = df["Status"].map(lookup).fillna(UNKNOWN_PHASE_LABEL)
    df["Project Lead"] = df["Project Lead"].fillna(NO_LEAD_LABEL)
    return df


def build_pivot(df):
    phase_cols = PHASE_ORDER + (
        [UNKNOWN_PHASE_LABEL] if (df["Phase"] == UNKNOWN_PHASE_LABEL).any() else []
    )
    pivot = (
        df.groupby("Project Lead")["Phase"]
        .value_counts()
        .unstack(fill_value=0)
    )
    for col in phase_cols:
        if col not in pivot.columns:
            pivot[col] = 0
    pivot = pivot[phase_cols].astype(int)
    pivot["Total"] = pivot.sum(axis=1)
    pivot = pivot.sort_values("Total", ascending=False)
    return pivot, phase_cols


def write_outputs(df, pivot, phase_cols, excluded_count):
    OUTPUT_DIR.mkdir(exist_ok=True)

    grand_total = pivot.sum(axis=0)
    grand_total.name = "Grand Total"

    # Detail CSV - one row per in-scope project, for drill-down/audit.
    detail_cols = [
        "Project Number", "Account", "Project Name", "Project Lead",
        "Status", "Phase", "Project Team Tech Lead",
    ]
    df[detail_cols].sort_values(["Project Lead", "Phase"]).to_csv(
        OUTPUT_DETAIL, index=False
    )

    lines = []
    lines.append(f"# Project Report by Lead - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append(
        f"Excluded {excluded_count} project(s) - perpetual-support placeholders and/or "
        f"Proposal-type projects (see ../data/reference/excluded-projects.csv)."
    )
    lines.append("")
    lines.append(f"Total in-scope projects: {len(df)}")
    lines.append("")
    lines.append("## By Project Lead")
    lines.append("")
    header = "| Project Lead | " + " | ".join(phase_cols) + " | Total |"
    lines.append(header)
    lines.append("|" + "---|" * (len(phase_cols) + 2))
    for lead, row in pivot.iterrows():
        vals = " | ".join(str(row[c]) for c in phase_cols)
        lines.append(f"| {lead} | {vals} | {row['Total']} |")
    total_vals = " | ".join(str(int(grand_total[c])) for c in phase_cols)
    lines.append(f"| **Grand Total** | {total_vals} | {int(grand_total['Total'])} |")
    lines.append("")
    lines.append(f"Per-project detail: {OUTPUT_DETAIL.name}")

    OUTPUT_SUMMARY.write_text("\n".join(lines))


def main():
    df, excluded, phase_map = load_data()
    df, excluded_count = apply_exclusions(df, excluded)
    df = add_phase(df, phase_map)

    pivot, phase_cols = build_pivot(df)
    write_outputs(df, pivot, phase_cols, excluded_count)

    print(f"Projects analyzed: {len(df)} (excluded {excluded_count} project(s))")
    print(f"Project Leads: {len(pivot)}")
    print(f"Wrote {OUTPUT_DETAIL} and {OUTPUT_SUMMARY}")


if __name__ == "__main__":
    main()
