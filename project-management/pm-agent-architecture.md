# Project Management Agent Architecture

**Purpose:** Multi-agent system to support active project delivery — reactive coordination, proactive planning/risk detection, and client-facing communication — with a central orchestrator resolving conflicts and handling escalation.

---

## Architecture Overview

```
                        ┌───────────────────┐
                        │    ORCHESTRATOR    │
                        │  (routes, resolves │
                        │  conflicts, escal- │
                        │  ates to human)    │
                        └─────────┬──────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                          │
   REACTIVE TIER             PROACTIVE TIER              DATA LAYER
   (event-driven)          (scheduled/polling)         (shared source
                                                          of truth)
  ┌──────────────┐        ┌──────────────┐
  │ Coordinator   │        │   Planner     │
  │ Client Comms  │        │   Analyst     │
  │ Intake/Triage │        │   Risk/Comp.  │
  └──────────────┘        │   Resource    │
                           │   Allocation  │
                           └──────────────┘
```

---

## Reactive Tier (event/request-driven)

### 1. Coordinator
**Trigger:** On-demand query ("where are we on X"), inbound status request, task update event

| | |
|---|---|
| **Inputs** | User/client query, PM tool webhook (task status change), scheduled check-in trigger |
| **Outputs** | Status summary, blocker flag, updated tracker entry, meeting agenda draft |
| **Responsibilities** | Track task status/ownership/deadlines; compile team status responses; flag overdue items; maintain PM tool as source of truth |
| **Hands off to** | Orchestrator (if blocker requires reallocation or replanning) |

### 2. Client Communication Agent
**Trigger:** Status milestone reached, client inbound request, Coordinator-flagged update

| | |
|---|---|
| **Inputs** | Coordinator status summary, project milestone events, client message |
| **Outputs** | Draft client-facing update (email/report), tone-adjusted technical summary |
| **Responsibilities** | Translate internal technical detail into client-appropriate language; draft recurring status reports |
| **Hands off to** | Human review (client-facing output should not auto-send without approval, at least initially) |

### 3. Intake/Triage Agent
**Trigger:** New project request received

| | |
|---|---|
| **Inputs** | New request (form, email, ticket), SOW template library |
| **Outputs** | Initial scope assessment, SOW match/deviation flag, routing decision |
| **Responsibilities** | Scope new requests against SOW templates; route to correct Planner queue or team |
| **Hands off to** | Planner (new project → needs scheduling), Risk/Compliance (if scope deviates from standard SOW) |

---

## Proactive Tier (scheduled/polling)

### 4. Planner
**Trigger:** Scheduled poll (e.g., daily), new project from Intake, Analyst-flagged pattern

| | |
|---|---|
| **Inputs** | Project timelines, dependency graph, resource calendar, Analyst risk signals |
| **Outputs** | Updated timeline, re-sequenced tasks, capacity conflict alert, task breakdown structure |
| **Responsibilities** | Build/maintain timelines and dependency chains; capacity planning against technician hours; re-plan on scope change; translate SOW deliverables into task breakdown |
| **Hands off to** | Resource Allocation (capacity conflict), Orchestrator (if replan conflicts with Analyst's risk read) |

### 5. Analyst
**Trigger:** Scheduled poll (e.g., weekly), Coordinator status update, cross-project data refresh

| | |
|---|---|
| **Inputs** | Historical project data, current status feed from Coordinator, budget/timeline baselines |
| **Outputs** | Variance report (budget/timeline actual vs. baseline), risk indicator flag, cross-project pattern summary |
| **Responsibilities** | Pull burn rate/velocity/utilization metrics; compare actual vs. baseline; identify cross-project patterns; surface risk before it becomes a blocker |
| **Hands off to** | Planner (pattern requires re-sequencing), Risk/Compliance (pattern indicates governance issue), Orchestrator (if finding conflicts with Planner's feasibility read) |

### 6. Risk/Compliance Agent
**Trigger:** Scheduled poll, Intake scope-deviation flag, Analyst risk flag, change request submitted

| | |
|---|---|
| **Inputs** | Change request tiering framework, SOW terms, governance policy set, Analyst flags |
| **Outputs** | Compliance flag, change-request tier classification, escalation notice |
| **Responsibilities** | Monitor SOW deviations; enforce change request tiering; flag governance policy violations |
| **Hands off to** | Orchestrator (any violation is a human-escalation candidate) |

### 7. Resource Allocation Agent
**Trigger:** Scheduled poll, Planner capacity conflict, new project intake

| | |
|---|---|
| **Inputs** | Technician/engineer availability calendar, skillset matrix, Planner demand signal |
| **Outputs** | Assignment recommendation, capacity shortfall alert |
| **Responsibilities** | Own technician/engineer assignment across book of business; balance skillset fit against availability |
| **Hands off to** | Planner (assignment feeds back into schedule), Orchestrator (shortfall requires human staffing decision) |

---

## Orchestrator

**Trigger:** Any inter-agent handoff, conflicting outputs between agents, threshold breach requiring human input

| | |
|---|---|
| **Inputs** | All agent outputs and handoff requests |
| **Outputs** | Routing decision, conflict resolution, human escalation packet |
| **Responsibilities** | Route tasks between agents; resolve conflicting outputs (e.g., Planner says feasible, Analyst's data disagrees); decide what surfaces to a human vs. resolves autonomously |

**Known conflict points to design for explicitly:**
- **Planner vs. Analyst** — Planner proposes a schedule; Analyst's variance data suggests it's optimistic. Orchestrator needs a resolution rule (e.g., defer to Analyst on historical-pattern disputes, defer to Planner on pure sequencing).
- **Risk/Compliance escalations** — these should likely always route to a human rather than being auto-resolved by the Orchestrator, given governance stakes.

---

## Data Layer (shared, not an agent)

All agents read/write against a common source of truth — your PM tool (Autotask, via API) plus supporting stores:
- Project tracker (tasks, status, ownership)
- SOW/template library
- Change request tiering framework
- Technician/engineer availability + skillset matrix
- Historical project metrics (for Analyst baselines)

Recommend all agents hit this layer rather than each other's outputs directly, except where a direct handoff is explicitly listed above — keeps the Orchestrator as the actual conflict-resolution point rather than agents quietly overriding each other.

---

## Build Sequence Suggestion

1. **Coordinator + Data Layer** — get the source-of-truth integration solid first; every other agent depends on it
2. **Intake/Triage** — establishes clean entry point for new work
3. **Planner** — core proactive scheduling logic
4. **Analyst** — needs Coordinator's historical data flowing before patterns are meaningful
5. **Resource Allocation + Risk/Compliance** — can build in parallel once Planner exists
6. **Client Communication** — lowest-risk to build last, mostly a formatting/tone layer on top of Coordinator output
7. **Orchestrator** — wire in incrementally as real conflicts start appearing between agents, rather than pre-building every resolution rule speculatively
