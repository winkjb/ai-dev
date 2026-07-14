import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config -----------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Project Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-projects.csv")
PHASE_MAPPING = Path("../data/reference/status-phase-mapping.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_DETAIL = OUTPUT_DIR / "coordinator-project-pm-detail.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "coordinator-project-pm-summary.md"
OUTPUT_SUMMARY_CSV = OUTPUT_DIR / "coordinator-project-pm-summary.csv"

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
    return df


def fill_no_lead_label(df):
    df = df.copy()
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

    # Detail CSV - one row per in-scope project, for drill-down/audit.
    detail_cols = [
        "Project Number", "Account", "Project Name", "Project Lead",
        "Status", "Phase", "Project Team Tech Lead", "Last Activity Time",
    ]
    df[detail_cols].sort_values(["Project Lead", "Phase"]).to_csv(
        OUTPUT_DETAIL, index=False
    )

    totals = pivot.sum(axis=0)

    # CSV equivalent of the markdown summary table, Total row included.
    summary_csv = pivot.reset_index()
    total_row = pd.DataFrame([{
        "Project Lead": "Total",
        **{col: int(totals[col]) for col in phase_cols},
        "Total": int(totals["Total"]),
    }])
    pd.concat([summary_csv, total_row], ignore_index=True).to_csv(
        OUTPUT_SUMMARY_CSV, index=False
    )

    lines = []
    lines.append(f"# Project Management Coordinator Report (By Project Manager) - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append("## Executive Summary")
    lines.append("")
    lines.append(f"Project(s) excluded: {excluded_count} (see ../data/reference/excluded-projects.csv).")
    lines.append("")
    lines.append(f"Project(s) analyzed: {len(df)}")
    lines.append("")
    for col in phase_cols:
        lines.append(f"- {col}: {int(totals[col])}")
    lines.append("")
    lines.append("## Projects By Project Manager")
    lines.append("")
    header = "| Project Lead | " + " | ".join(phase_cols) + " | Total |"
    lines.append(header)
    lines.append("|" + "---|" * (len(phase_cols) + 2))
    for lead, row in pivot.iterrows():
        vals = " | ".join(str(row[c]) for c in phase_cols)
        lines.append(f"| {lead} | {vals} | {row['Total']} |")
    total_vals = " | ".join(str(int(totals[c])) for c in phase_cols)
    lines.append(f"| **Total** | {total_vals} | {int(totals['Total'])} |")
    lines.append("")
    lines.append(f"Summary (CSV): {OUTPUT_SUMMARY_CSV.name}  ")
    lines.append(f"Per-project detail: {OUTPUT_DETAIL.name}")

    OUTPUT_SUMMARY.write_text("\n".join(lines))


def main():
    df, excluded, phase_map = load_data()
    df, excluded_count = apply_exclusions(df, excluded)
    df = add_phase(df, phase_map)
    df = fill_no_lead_label(df)

    pivot, phase_cols = build_pivot(df)
    write_outputs(df, pivot, phase_cols, excluded_count)

    print(f"Projects analyzed: {len(df)} (excluded {excluded_count} project(s))")
    print(f"Wrote {OUTPUT_DETAIL}, {OUTPUT_SUMMARY}, and {OUTPUT_SUMMARY_CSV}")


if __name__ == "__main__":
    main()
