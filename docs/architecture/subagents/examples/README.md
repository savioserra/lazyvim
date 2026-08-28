# Workflow-template dogfood examples

Status: **PROPOSED/not implemented**. These examples are syntactically valid TOML stress fixtures for the draft workflow-template schema. They are intentionally non-runnable and the daemon does not load them.

| Example | Stress-tested shape | Gaps and open decisions surfaced |
| --- | --- | --- |
| [`sprint-delivery.proposed.toml`](sprint-delivery.proposed.toml) | Broad feature intent, requirements validation, specification, dynamic implementation units, review/QA, user acceptance, bounded correction, parallel-safe isolated worktrees, incremental cleanup, idle passivation. | Production-line/stage vocabulary, dynamic work-unit materialization, user decision gates, artifact/evidence naming, and cleanup semantics need schema review. |
| [`academic-research.proposed.toml`](academic-research.proposed.toml) | Research question scoping, ethics validation, literature collection, evidence appraisal, synthesis, independent review, citation/evidence gates, uncertainty handling, final artifact acceptance. | Citation and uncertainty evidence kinds, non-code artifact gates, ethics/scope decisions, read-only dynamic research units, and artifact workspace retention are not implemented contracts. |
| [`incident-response.proposed.toml`](incident-response.proposed.toml) | Urgent triage, containment decisions, bounded parallel diagnostics/remediation, resource limits, validation/recovery, compensation, postmortem, incremental cleanup. | Operator decision semantics, urgency/escalation behavior, resource-bound enforcement, compensation records, and recovery/rollback vocabulary remain open. |

Proposed boundaries exercised by the examples:

- `WorkflowActor` ownership of authorization, materialization, leases, decisions, and cleanup is proposed template vocabulary, not implemented loader behavior.
- Producer entries describe proposed trusted registered domain producers. They do not hardcode project-manager/worker role semantics; runtime roles remain dynamic labels.
- Global reusable actor retention/passivation and exactly-owned ephemeral actor stop are proposed cleanup semantics, not implemented template behavior.
- One writer per worktree is represented as proposed `writer_slots = 1`; enforcement is not implemented by the template loader because no loader exists.
- The examples avoid commands, scripts, terminal automation, raw IDs, credentials, and runnable activation knobs.

Vocabulary classification remains in the [draft workflow-template specification](../WORKFLOW-TEMPLATE-SPEC.md). Architecture boundaries for actor-owned progress and panel projection remain in [ADR 0004](../0004-supervisor-hierarchy-and-owned-workflows.md).
