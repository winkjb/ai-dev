# Program Management Agent Architecture

**Purpose:** Multi-agent system for recurring, ongoing technical assessments across the supported client book — firewalls, Microsoft tenants, and other managed platforms — with client-facing reporting and an orchestrator that (eventually) bridges findings into Service Delivery and Project Management.

**Folder structure note (2026-07-17):** the roles below are still the right *roles* — this doc hasn't changed. What changed is where they live on disk: Coordinator, Client Communication, and Orchestrator stay shared at `program-management/` root (they need a cross-offering view), while Collector and Analyst are offering-specific and live inside each offering's own folder (e.g. `program-management/ait-networking/`), since collection/evaluation logic is fundamentally different per platform. See `program-management/context.md` for the current layout.

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
  ┌────────────────┐      ┌────────────────┐
  │ Coordinator     │      │ Collector       │
  │ Client Comms    │      │ Analyst         │
  │ Intake/Onboard  │      │ Risk/Compliance │
  └────────────────┘      └────────────────┘
```

---

## Reactive Tier (event/request-driven)

### 1. Coordinator
**Trigger:** Scheduled check-in, on-demand query ("where do we stand with Client X"), assessment due-date crossed

| | |
|---|---|
| **Inputs** | Client/asset registry (which client owns which firewall, tenant, etc.), required cadence per asset type, Collector run status |
| **Outputs** | Due/overdue assessment flag, status summary by client or asset, assessment calendar |
| **Responsibilities** | Own the assessment registry and cadence; track which assets are due, overdue, or currently mid-assessment; answer status queries across the book of business |
| **Hands off to** | Orchestrator (an asset has gone overdue with no Collector data flowing — likely an access/credential problem, not just a scheduling gap) |

### 2. Client Communication Agent
**Trigger:** Assessment cycle complete for a client, Analyst/Risk-Compliance findings ready

| | |
|---|---|
| **Inputs** | Analyst findings, Risk/Compliance findings, prior report history (for trend framing) |
| **Outputs** | Client-facing scorecard/QBR-style report, tone-adjusted summary of technical findings |
| **Responsibilities** | Translate internal findings into client-appropriate language; frame drift/gaps as trend, not just a point-in-time snapshot |
| **Hands off to** | Human review before send, at least initially |

### 3. Intake/Onboarding Agent
**Trigger:** New device or tenant added to the supported estate, new client onboarded

| | |
|---|---|
| **Inputs** | New asset details (client, platform type, credentials/access), baseline checklist library |
| **Outputs** | New registry entry with assigned cadence and baseline, initial assessment kickoff |
| **Responsibilities** | Register new assets into the assessment program; assign the correct cadence and baseline checklist by platform type |
| **Hands off to** | Coordinator (registry updated, now part of the normal cadence) |

---

## Proactive Tier (scheduled/polling)

### 4. Collector
**Trigger:** Scheduled poll per asset cadence (e.g. monthly for M365 tenants, quarterly for firewalls)

| | |
|---|---|
| **Inputs** | Client/asset registry, platform API/export access (firewall vendor API, M365 Graph API, Secure Score, etc.) |
| **Outputs** | Raw current-state config/posture snapshot per asset |
| **Responsibilities** | Pull current-state data from each platform on schedule; land it in the raw data layer without interpretation |
| **Hands off to** | Analyst and Risk/Compliance (both read Collector's raw output) |

### 5. Analyst
**Trigger:** New Collector snapshot available, scheduled poll

| | |
|---|---|
| **Inputs** | Collector snapshots, internal best-practice baseline per platform type, prior snapshots (for drift comparison) |
| **Outputs** | Gap/drift flag vs. baseline, cross-client pattern summary, trend report |
| **Responsibilities** | Compare current state against internal best-practice baseline; flag configuration drift and gaps; identify patterns across the book of business (e.g. the same misconfiguration recurring across multiple clients) |
| **Hands off to** | Client Communication (findings ready to report), Orchestrator (pattern-level finding worth escalating) |

### 6. Risk/Compliance Agent
**Trigger:** New Collector snapshot available, scheduled poll, contract/regulatory requirement change

| | |
|---|---|
| **Inputs** | Collector snapshots, regulatory/contractual framework requirements by client (HIPAA, PCI, cyber-insurance terms, etc.) |
| **Outputs** | Compliance violation flag, framework-specific gap report |
| **Responsibilities** | Evaluate the same data against *external* obligations tied to a specific client — distinct from Analyst's internal best-practice comparison, since a client can be "best-practice compliant" and still miss a contractual/regulatory requirement, or vice versa |
| **Hands off to** | Client Communication (findings ready to report), Orchestrator (violation is a human-escalation candidate) |

---

## Orchestrator

**Trigger:** Analyst pattern-level finding, Risk/Compliance violation, Coordinator overdue-with-no-data flag

| | |
|---|---|
| **Inputs** | All agent outputs and handoff requests |
| **Outputs** | Routing decision, conflict resolution, human escalation packet |
| **Responsibilities** | Route between agents; resolve conflicting reads (e.g. Analyst calls something low-priority drift, Risk/Compliance calls the same finding a contractual violation); decide what surfaces to a human |

**Known conflict points to design for explicitly:**
- **Analyst vs. Risk/Compliance** — the same raw finding can be "minor drift" by internal best-practice standards but a hard violation under a specific client's regulatory framework. Orchestrator needs a rule (likely: Risk/Compliance severity wins when both fire on the same finding).
- **Coordinator overdue flag with no Collector data** — distinguish "we haven't gotten to it yet" from "we've lost API/credential access to this client's platform," since the second is a bigger problem than a late assessment.

**Future integration point (not built yet):** findings here are self-contained within program-management for now. A natural extension is routing a confirmed Risk/Compliance violation to Service Delivery as a ticket, or a large remediation effort to Project Management as a new project — revisit once the core assess → report loop is proven and real handoff patterns emerge.

---

## Data Layer (shared, not an agent)

- Client/asset registry — which client owns which firewall, tenant, etc., and its assigned cadence
- Baseline/best-practice checklists per platform type (used by Analyst)
- Regulatory/contractual framework requirements per client (used by Risk/Compliance)
- Raw collected config/posture snapshots (`data/raw`, populated by Collector)
- Historical assessment results (for Analyst drift trending and Client Communication's trend framing)

---

## Build Sequence Suggestion

1. **Coordinator + client/asset registry** — everything else depends on knowing what needs to be assessed, for which client, and how often
2. **Collector** — get real config/posture data flowing for at least one platform end-to-end (M365 Graph/Secure Score is likely the easiest first target given existing API access) before building evaluation logic
3. **Analyst** — needs Collector data flowing before baseline comparison is meaningful
4. **Intake/Onboarding** — formalize the registration path once the core collect → evaluate loop is proven on a pilot platform
5. **Risk/Compliance** — layer in once general best-practice evaluation works; regulatory frameworks vary per client so this is more config-heavy to set up
6. **Client Communication** — lowest-risk, build last, mostly a formatting/tone layer on top of Analyst + Risk/Compliance output
7. **Orchestrator** — wire in incrementally as real conflicts appear, and revisit the Service Delivery/Project Management handoff once patterns emerge
