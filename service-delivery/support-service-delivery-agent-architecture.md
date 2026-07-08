# Technical Support & Service Delivery Agent Architecture

**Purpose:** Multi-agent system for support/service delivery — reactive ticket handling, proactive pattern detection and capacity planning, with an orchestrator tuned for high ticket volume (tighter auto-resolution, escalation reserved for pattern-level findings).

---

## Architecture Overview

```
                        ┌───────────────────┐
                        │    ORCHESTRATOR    │
                        │  (routes, resolves  │
                        │  conflicts, escal-  │
                        │  ates PATTERNS not  │
                        │  individual tickets)│
                        └─────────┬──────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                          │
   REACTIVE TIER             PROACTIVE TIER              DATA LAYER
   (event-driven)          (scheduled/polling)         (shared source
                                                          of truth)
  ┌───────────────┐       ┌───────────────┐
  │ Coordinator    │       │ Planner        │
  │ Client Comms   │       │ Analyst        │
  │ Intake/Triage  │       │ Risk/Compliance│
  └───────────────┘       │ Resource       │
                           │  Allocation    │
                           └───────────────┘
```

---

## Reactive Tier (event/request-driven)

### 1. Coordinator (Ticket/Dispatch)
**Trigger:** New ticket created, ticket status change, SLA clock threshold crossed

| | |
|---|---|
| **Inputs** | PSA/ticketing system webhook, SLA policy by contract tier, tech availability |
| **Outputs** | Ticket assignment, SLA-risk flag, stalled-ticket escalation |
| **Responsibilities** | Track ticket status/ownership/SLA clocks; assign to correct tech by skillset/severity; flag tickets approaching SLA breach; escalate stalled tickets |
| **Hands off to** | Resource Allocation (no available tech matches skillset), Orchestrator (SLA breach imminent and no clear resolution path) |

### 2. Client Communication Agent
**Trigger:** Ticket status milestone (assigned, in-progress, resolved), client inbound request

| | |
|---|---|
| **Inputs** | Coordinator status, resolution notes from tech, client message |
| **Outputs** | Draft status update, resolution summary in client-appropriate language |
| **Responsibilities** | Translate technical resolution detail (e.g., root cause, remediation steps) into client-readable updates |
| **Hands off to** | Human review before send, at least initially |

### 3. Intake/Triage Agent
**Trigger:** New ticket received (email, portal, phone-to-ticket)

| | |
|---|---|
| **Inputs** | Raw ticket content, severity/contract-tier rules, known-issue library |
| **Outputs** | Severity classification, initial routing decision, known-issue match flag |
| **Responsibilities** | Classify severity; check against known-issue library (e.g., "this matches the FortiOS 7.6.6 bug pattern") before it even reaches a tech; route to Coordinator |
| **Hands off to** | Coordinator (standard routing), Analyst (ticket matches or may extend a known pattern) |

---

## Proactive Tier (scheduled/polling)

### 4. Planner (Scheduling/Capacity)
**Trigger:** Scheduled poll, on-call rotation boundary, ticket queue depth threshold

| | |
|---|---|
| **Inputs** | Tech calendars (reactive + project work), on-call rotation, current queue depth |
| **Outputs** | Coverage gap alert, queue-depth-vs-capacity forecast, rebalance recommendation |
| **Responsibilities** | Balance tech time between reactive ticket work and project/PM work; ensure on-call coverage; forecast queue depth against available capacity |
| **Hands off to** | Resource Allocation (persistent skillset gap, not just a scheduling gap), Orchestrator (coverage gap with no internal fix) |

### 5. Analyst
**Trigger:** Scheduled poll (e.g., daily/weekly), Intake known-issue-match flag, ticket volume threshold crossed

| | |
|---|---|
| **Inputs** | Ticket history by device/customer/issue type, vendor bug databases, historical resolution data |
| **Outputs** | Cross-ticket pattern report, emerging-issue flag, recommended proactive action (e.g., "escalate to vendor TAC," "push scheduled remediation") |
| **Responsibilities** | Detect patterns across tickets (e.g., N tickets this month reference memory conserve mode on a specific firewall model); flag emerging issues before/alongside individual ticket resolution; distinguish one-off incidents from systemic problems |
| **Hands off to** | Risk/Compliance (pattern implicates a contract/SLA-wide issue), Orchestrator (pattern-level finding — this is the primary human-escalation trigger for this tier) |

### 6. Risk/Compliance Agent
**Trigger:** Scheduled poll, SLA-risk flag from Coordinator, Analyst pattern flag

| | |
|---|---|
| **Inputs** | Contract SLA terms by tier, ticket resolution timestamps, Analyst pattern data |
| **Outputs** | SLA breach report, contract-tier violation flag, MSSP response-time compliance report |
| **Responsibilities** | Monitor SLA compliance by contract tier; flag response-time commitment violations; track MSSP-specific regulatory/contractual obligations |
| **Hands off to** | Orchestrator (any breach or violation escalates to human) |

### 7. Resource Allocation Agent
**Trigger:** Scheduled poll, Coordinator skillset-gap flag, Planner capacity-gap flag

| | |
|---|---|
| **Inputs** | Tech skillset matrix (certifications — FortiManager, Huntress, etc.), current assignments, ticket/project demand |
| **Outputs** | Assignment recommendation, skillset gap report (e.g., "only 2 techs are FortiManager-certified against current firewall fleet size") |
| **Responsibilities** | Match tech assignment to skillset across both ticket and project work; surface skillset gaps for hiring/training decisions |
| **Hands off to** | Orchestrator (skillset gap is a staffing/training decision, not something the agent layer resolves) |

---

## Orchestrator

**Trigger:** Pattern-level Analyst finding, SLA/compliance breach, persistent capacity or skillset gap

| | |
|---|---|
| **Inputs** | All agent outputs and handoff requests |
| **Outputs** | Routing decision, conflict resolution, human escalation packet |
| **Responsibilities** | Route between agents; resolve conflicts; decide what surfaces to a human |

**Key difference from the PM architecture:** ticket volume is high and individual-ticket stakes are usually low. The Orchestrator should be tuned to **auto-resolve at the individual-ticket level** (routine assignment, routine status updates) and **reserve human escalation for pattern-level or compliance-level findings** — a single ticket rarely needs a human in the loop; forty tickets pointing at the same firewall bug does.

**Known conflict points to design for explicitly:**
- **Planner vs. Resource Allocation** — Planner may see a capacity gap that's actually a skillset gap in disguise (enough tech-hours available, but not the right certifications). Orchestrator needs a rule for routing to the correct underlying fix.
- **Analyst vs. Risk/Compliance** — a pattern the Analyst flags as "emerging issue" may already be a compliance-level SLA problem. Decide whether Analyst findings auto-route through Risk/Compliance before reaching a human, or go straight to escalation.

---

## Data Layer (shared, not an agent)

- Ticketing/PSA system (tickets, status, SLA clocks, resolution notes)
- Known-issue library (including vendor bug tracking — e.g., FortiOS bug IDs)
- Contract/SLA terms by tier
- Tech skillset matrix + certifications
- On-call rotation and combined reactive/project calendar
- Historical ticket data (for Analyst pattern baselines)

---

## Where This Overlaps With the PM Architecture

Several agents are near-identical in function across both systems and could plausibly share underlying logic or even be the same agent instance operating on two data sources:

**Note (2026-07-08):** the Support-side folder names below now literally match the PM-side names (`01-coordinator`, `04-planner`) for cross-project naming consistency. That's a naming decision only — it does NOT change the "Shared?" column. Coordinator and Planner are still deliberately separate implementations (different data/constraints); only the four roles marked "strong candidate to share" are actual candidates for one shared implementation.

| PM Agent | Support Agent | Shared? |
|---|---|---|
| Coordinator (`project-management/01-coordinator`) | Coordinator (`service-delivery/01-coordinator`) | Same name, similar pattern, different data — **deliberately separate instances**, not shared logic |
| Client Communication | Client Communication | **Strong candidate to share** — same core function (technical → client-readable translation) |
| Intake/Triage | Intake/Triage | **Strong candidate to share** — same scoping/routing logic, different intake source |
| Planner (`project-management/04-planner`) | Planner (`service-delivery/04-planner`) | Same name, similar pattern, different constraints (dependencies vs. SLA clocks) — **deliberately separate instances** |
| Analyst | Analyst | Same core capability, different data domains — could be one Analyst agent querying both project and ticket data for a unified cross-org view |
| Risk/Compliance | Risk/Compliance | **Strong candidate to share** — governance logic likely overlaps significantly |
| Resource Allocation | Resource Allocation | **Strong candidate to share** — it's the same tech pool either way |

Worth discussing Monday: whether to build these as two parallel systems or one system with PM and Support as two data domains feeding shared agents. Given the resource pool overlap alone (techs doing both project and ticket work), a unified Resource Allocation and Scheduling layer is probably worth the extra design effort up front.

## Build Sequence Suggestion

1. **Intake/Triage + known-issue library** — biggest immediate win given the FortiGate situation; catching pattern matches at intake beats catching them after 40 tickets
2. **Coordinator + Data Layer** — same rationale as PM's Coordinator, everything depends on this (built 2026-07-07, as `01-coordinator/ticket_report.py`)
3. **Analyst** — second priority given direct relevance to current firewall fleet issue
4. **Risk/Compliance** — SLA monitoring, especially for MSSP-tier contracts
5. **Planner + Resource Allocation** — build once ticket data is flowing well enough to forecast against
6. **Client Communication** — lowest-risk, build last
7. **Orchestrator** — wire in as real pattern-vs-individual-ticket escalation decisions start appearing
