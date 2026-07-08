"""
Workload by Tech Lead report.

Reads the project export and reports how many open projects each
Project Team Tech Lead is currently carrying, broken out by phase and
totaled - a headcount/capacity view, not a problem-flagging view (that's
status_report.py's job).

Phase is a collapsed grouping of the raw Status field, defined in
../data/reference/status-phase-mapping.csv:
  - Beginning:   New, I-*, II-*      (not yet in active execution)
  - In Process:  III-*, IV-*         (active execution / customer signoff)
  - Closing:     V-*                 (wrapping up / pending complete)
  - On Hold:     On Hold             (paused, not tied to a specific phase)

Excludes projects matched in ../data/reference/excluded-projects.csv
(same file/logic as status_report.py) - notably Project Type = Proposal,
since proposals aren't real assigned work and would badly distort a
per-person workload count.

Usage:
    python workload_by_tech_lead.py

Reads:  ../data/raw/Project Search Results.csv
        ../data/reference/excluded-projects.csv
        ../data/reference/status-phase-mapping.csv
Writes: ./output/workload-by-tech-lead.csv          (pivot: tech lead x phase + total)
        ./output/workload-by-tech-lead-detail.csv   (every in-scope project, one row each)
        ./output/workload-by-tech-lead-summary.md
"""

import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config -----------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Project Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-projects.csv")
PHASE_MAPPING = Path("../data/reference/status-phase-mapping.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_PIVOT = OUTPUT_DIR / "workload-by-tech-lead.csv"
OUTPUT_DETAIL = OUTPUT_DIR / "workload-by-tech-lead-detail.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "workload-by-tech-lead-summary.md"

PHASE_ORDER = ["Beginning", "In Process", "Closing", "On Hold"]
NO_TECH_LEAD_LABEL = "(No Tech Lead Listed)"
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
    df["Project Team Tech Lead"] = df["Project Team Tech Lead"].fillna(NO_TECH_LEAD_LABEL)
    return df


def build_pivot(df):
    phase_cols = PHASE_ORDER + (
        [UNKNOWN_PHASE_LABEL] if (df["Phase"] == UNKNOWN_PHASE_LABEL).any() else []
    )
    pivot = (
        df.groupby("Project Team Tech Lead")["Phase"]
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

    # Pivot CSV, with a Grand Total row appended.
    grand_total = pivot.sum(axis=0)
    grand_total.name = "Grand Total"
    pivot_with_total = pd.concat([pivot, grand_total.to_frame().T])
    pivot_with_total.to_csv(OUTPUT_PIVOT)

    # Detail CSV - one row per in-scope project, for drill-down/audit.
    detail_cols = [
        "Project Number", "Account", "Project Name", "Project Team Tech Lead",
        "Status", "Phase", "Project Lead",
    ]
    df[detail_cols].sort_values(["Project Team Tech Lead", "Phase"]).to_csv(
        OUTPUT_DETAIL, index=False
    )

    lines = []
    lines.append(f"# Workload by Tech Lead - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append(
        f"Excluded {excluded_count} project(s) - perpetual-support placeholders and/or "
        f"Proposal-type projects (see ../data/reference/excluded-projects.csv)."
    )
    lines.append("")
    lines.append(f"Total in-scope open projects: {len(df)}")
    lines.append("")
    lines.append("## By Tech Lead")
    lines.append("")
    header = "| Tech Lead | " + " | ".join(phase_cols) + " | Total |"
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
    print(f"Tech leads: {len(pivot)}")
    print(f"Wrote {OUTPUT_PIVOT}, {OUTPUT_DETAIL}, and {OUTPUT_SUMMARY}")


if __name__ == "__main__":
    main()
