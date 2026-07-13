import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config -----------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Project Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-projects.csv")
PHASE_MAPPING = Path("../data/reference/status-phase-mapping.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_DETAIL = OUTPUT_DIR / "coordinator-project-report.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "coordinator-project-summary.md"

PHASE_ORDER = ["Beginning", "In Process", "Closing", "Final Closure", "On Hold/Inactive"]
NO_LEAD_LABEL = "(No Project Lead Listed)"
UNKNOWN_PHASE_LABEL = "Unknown Phase"

STALE_DAYS = 14
STALE_DAYS_ON_HOLD = 21


def load_data():
    df = pd.read_csv(RAW_EXPORT, encoding="utf-8-sig")
    excluded = pd.read_csv(EXCLUDED_LIST, encoding="utf-8-sig")
    phase_map = pd.read_csv(PHASE_MAPPING, encoding="utf-8-sig")
    return df, excluded, phase_map


def _blank(value):
    return pd.isna(value) or str(value).strip() == ""


def apply_exclusions(df, excluded):
    excl_numbers = set(excluded.loc[excluded["Match Type"] == "Project Number", "Value"])
    excl_types = set(excluded.loc[excluded["Match Type"] == "Project Type", "Value"])
    mask = df["Project Number"].isin(excl_numbers) | df["Project Type"].isin(excl_types)
    return df[~mask].copy(), int(mask.sum())


def clean(df):
    df = df.copy()
    df["Last Activity Time"] = pd.to_datetime(
        df["Last Activity Time"], format="%m/%d/%Y %I:%M %p", errors="coerce"
    )
    return df


def flag(df, now):
    df = df.copy()
    df["Days Since Last Activity"] = (
        (now - df["Last Activity Time"]).dt.total_seconds() / 86400
    ).apply(lambda x: int(x) if pd.notna(x) else None)

    stale_threshold = pd.Series(STALE_DAYS, index=df.index)
    stale_threshold[df["Phase"] == "On Hold/Inactive"] = STALE_DAYS_ON_HOLD
    stale = df["Days Since Last Activity"].notna() & (
        df["Days Since Last Activity"] > stale_threshold
    )
    stalled_intake = (df["Status"] == "New") & stale
    no_lead = df["Project Lead"].apply(_blank) | df["Project Team Tech Lead"].apply(_blank)
    need_pcm = df["Phase"] == "Closing"

    df["Flag: Stalled Intake"] = stalled_intake
    df["Flag: Stale"] = stale
    df["Flag: No Lead(s)"] = no_lead
    df["Flag: Need PCM"] = need_pcm
    return df


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

    grand_total = pivot.sum(axis=0)
    grand_total.name = "Grand Total"

    # Detail CSV - one row per in-scope project, for drill-down/audit.
    detail_cols = [
        "Project Number", "Account", "Project Name", "Project Lead",
        "Status", "Phase", "Project Team Tech Lead",
        "Last Activity Time", "Days Since Last Activity",
        "Flag: Stalled Intake", "Flag: Stale", "Flag: No Lead(s)", "Flag: Need PCM",
    ]
    df[detail_cols].sort_values(["Project Lead", "Phase"]).to_csv(
        OUTPUT_DETAIL, index=False
    )

    flag_cols = ["Flag: Stalled Intake", "Flag: Stale", "Flag: No Lead(s)", "Flag: Need PCM"]
    flag_labels = [c.removeprefix("Flag: ") for c in flag_cols]
    flag_counts = {label: int(df[col].sum()) for col, label in zip(flag_cols, flag_labels)}

    # By Project Lead - flagged projects only. Flags aren't mutually exclusive
    # (a project can trip more than one), so "Total Flagged" counts distinct
    # flagged projects rather than summing the flag columns.
    flagged = df[df[flag_cols].any(axis=1)]
    by_lead = flagged.groupby("Project Lead")[flag_cols].sum().astype(int)
    by_lead.columns = flag_labels
    by_lead["Total Flagged"] = flagged.groupby("Project Lead").size()
    by_lead = by_lead.sort_values("Total Flagged", ascending=False)

    lines = []
    lines.append(f"# Project Management Coordinator Report (Projects) - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append("## Executive Summary")
    lines.append("")
    lines.append(f"Project(s) excluded: {excluded_count} - (see ../data/reference/excluded-projects.csv).")
    lines.append("")
    lines.append(f"Project(s) analyzed: {len(df)}")
    lines.append("")
    for label in flag_labels:
        lines.append(f"- {label}: {flag_counts[label]}")
    lines.append("")
    lines.append("## Flags by Project Lead")
    lines.append("")
    flag_header = "| Project Lead | " + " | ".join(flag_labels) + " | Total Flagged |"
    lines.append(flag_header)
    lines.append("|" + "---|" * (len(flag_labels) + 2))
    for lead, row in by_lead.iterrows():
        vals = " | ".join(str(row[c]) for c in flag_labels)
        lines.append(f"| {lead} | {vals} | {row['Total Flagged']} |")
    lines.append("")
    lines.append("## Projects By Project Lead")
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
    df = clean(df)
    df = add_phase(df, phase_map)
    now = pd.Timestamp(datetime.now())
    df = flag(df, now)
    df = fill_no_lead_label(df)

    pivot, phase_cols = build_pivot(df)
    write_outputs(df, pivot, phase_cols, excluded_count)

    print(f"Projects analyzed: {len(df)} (excluded {excluded_count} project(s))")
    print(f"Project Leads: {len(pivot)}")
    print(f"Wrote {OUTPUT_DETAIL} and {OUTPUT_SUMMARY}")


if __name__ == "__main__":
    main()
