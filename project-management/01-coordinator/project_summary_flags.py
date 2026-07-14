import pandas as pd
from pathlib import Path
from datetime import datetime

# --- config -----------------------------------------------------------------

RAW_EXPORT = Path("../data/raw/Project Search Results.csv")
EXCLUDED_LIST = Path("../data/reference/excluded-projects.csv")
PHASE_MAPPING = Path("../data/reference/status-phase-mapping.csv")
OUTPUT_DIR = Path("./output")
OUTPUT_DETAIL = OUTPUT_DIR / "coordinator-project-flags-detail.csv"
OUTPUT_SUMMARY = OUTPUT_DIR / "coordinator-project-flags-summary.md"
OUTPUT_SUMMARY_CSV = OUTPUT_DIR / "coordinator-project-flags-summary.csv"

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
    for col in ["% Complete - Task", "% Complete - Hours"]:
        df[col] = df[col].str.rstrip("%").str.replace(",", "").astype(float)
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
    # "New" + stale alone isn't enough - some projects sit at Status "New" while
    # real work (task/hours) has already been logged, meaning Status just never
    # got updated. Those aren't stuck in intake, so they're excluded here and
    # fall through to the plain "Stale" flag instead.
    no_progress = (df["% Complete - Task"] == 0) & (df["% Complete - Hours"] == 0)
    stalled_intake = (df["Status"] == "New") & stale & no_progress
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


def write_outputs(df, excluded_count):
    OUTPUT_DIR.mkdir(exist_ok=True)

    # Detail CSV - one row per in-scope project, for drill-down/audit.
    detail_cols = [
        "Project Number", "Account", "Project Name", "Project Lead",
        "Status", "Phase", "Project Team Tech Lead",
        "Last Activity Time", "Days Since Last Activity",
        "% Complete - Task", "% Complete - Hours",
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

    # CSV equivalent of the markdown summary table, Total row included.
    summary_csv = by_lead.reset_index()
    total_row = pd.DataFrame([{
        "Project Lead": "Total",
        **{label: flag_counts[label] for label in flag_labels},
        "Total Flagged": len(flagged),
    }])
    pd.concat([summary_csv, total_row], ignore_index=True).to_csv(
        OUTPUT_SUMMARY_CSV, index=False
    )

    lines = []
    lines.append(f"# Project Management Coordinator Report (Flags) - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append("## Executive Summary")
    lines.append("")
    lines.append(f"Project(s) excluded: {excluded_count} (see ../data/reference/excluded-projects.csv).")
    lines.append("")
    lines.append(f"Project(s) analyzed: {len(df)}")
    lines.append("")
    for label in flag_labels:
        lines.append(f"- {label}: {flag_counts[label]}")
    lines.append("")
    lines.append("## Flags by Project Manager")
    lines.append("")
    flag_header = "| Project Lead | " + " | ".join(flag_labels) + " | Total Flagged |"
    lines.append(flag_header)
    lines.append("|" + "---|" * (len(flag_labels) + 2))
    for lead, row in by_lead.iterrows():
        vals = " | ".join(str(row[c]) for c in flag_labels)
        lines.append(f"| {lead} | {vals} | {row['Total Flagged']} |")
    total_flag_vals = " | ".join(str(flag_counts[label]) for label in flag_labels)
    lines.append(f"| **Total** | {total_flag_vals} | {len(flagged)} |")
    lines.append("")
    lines.append(f"Summary (CSV): {OUTPUT_SUMMARY_CSV.name}  ")
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

    write_outputs(df, excluded_count)

    print(f"Projects analyzed: {len(df)} (excluded {excluded_count} project(s))")
    print(f"Wrote {OUTPUT_DETAIL}, {OUTPUT_SUMMARY}, and {OUTPUT_SUMMARY_CSV}")


if __name__ == "__main__":
    main()
