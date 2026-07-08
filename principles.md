# Workspace Principles

## The 60/30/10 Rule

*(credit: John Elder)*

Every automation built in this workspace is governed by a deliberate ratio of how work gets done: 60% programmatic, 30% data-driven, 10% AI. The goal is consistency, cost control, reduced hallucination/error surface, and auditability — a human should be able to look at any flag or recommendation this workspace produces and see exactly why it fired.

This is a design bias, not a literal percentage to calculate per project. See `CLAUDE.md` for how this plugs into the rest of the workspace's conventions.

---

### 60% — Programmatic

Rule-based, deterministic. Work that follows a defined structure — a conditional, a threshold, a calculation — and produces a predictable, explainable output without requiring AI judgment.

In this workspace, programmatic work includes:
- Threshold/rule-based flagging (e.g. `project-management/01-coordinator`'s overdue/stale/stalled-intake definitions — all objective date/status comparisons)
- Applying exclusion lists or lookup tables to filter data
- Report formatting, sorting, and output structure
- File naming, folder conventions, and handoffs between roles
- Scheduling and threshold rules (e.g. `STALE_DAYS`, `STALLED_INTAKE_DAYS` constants)

**When in doubt, reach for a rule or a calculation first.** If the task can be fully defined by a conditional or formula, do it that way — don't call an LLM to do arithmetic or status comparison.

---

### 30% — Data-Driven

Grounded in actual stored files and records — not inference, not generated content. Work that reads real data and uses it to inform a decision or output.

In this workspace, data-driven work includes:
- Raw source exports (`data/raw/`) — the actual system-of-record data (e.g. the Autotask project export)
- Reference/lookup files (`data/reference/`) — e.g. `excluded-projects.csv`, maintained by a human and read by scripts, not re-derived by AI each run
- Historical baselines used for variance/trend comparison (e.g. an Analyst's burn-rate baselines)
- One role's output consumed as another role's documented input (e.g. Coordinator's status feed as an Analyst input)

**Read before generating.** If the answer already lives in a file, use the file — don't ask AI to reconstruct something that's already recorded.

---

### 10% — AI

Genuine judgment, synthesis, or human-facing prose generation that cannot be templated or looked up. AI's role is narrow and high-value — reserved for moments where rules and data aren't enough.

In this workspace, AI work includes:
- Judging ambiguous/unstructured input that doesn't cleanly match a rule (e.g. classifying a scope deviation that doesn't fit any SOW template)
- Drafting human-facing prose (e.g. a Client Communication agent's tone-adjusted status update, translating technical detail for a client audience)
- Synthesizing multiple data points into a novel narrative insight where no template applies

**AI generates only what cannot be looked up or computed.** If a step can be done with a conditional or a lookup, don't spend an AI call on it.

---

## Why This Ratio Matters

| Concern | How 60/30/10 addresses it |
|---|---|
| **Cost** | Less AI usage = fewer tokens/API calls consumed per run |
| **Consistency** | Rules and thresholds produce repeatable results across every run, not a new judgment call each time |
| **Hallucination / Errors** | AI operates on a narrow, bounded task with real data as input — not open-ended generation |
| **Context window** | Programmatic and data steps don't need a large context window; only genuine judgment/drafting moments need rich context |
| **Auditability** | A human can ask "why was this flagged overdue?" and get a literal, inspectable answer — not "the model thought so" |

---

## Applying the Ratio Per Role

Each role's `context.md` should document a **60/30/10 Breakdown** section listing which of its tasks fall into which bucket. Before building a task within a role, work through this in order:

1. Is there a rule, threshold, or calculation that fully defines this? → **Programmatic**
2. Is the answer already in a file (raw export, reference lookup, another role's output)? → **Data-Driven**
3. Does this genuinely require judgment, synthesis, or prose generation? → **AI, but only then**

See `project-management/01-coordinator/context.md` for the first worked example — a role that turned out to be 100% Programmatic + Data-Driven, 0% AI, and works well precisely because "overdue"/"stale" are objective definitions rather than judgment calls.
