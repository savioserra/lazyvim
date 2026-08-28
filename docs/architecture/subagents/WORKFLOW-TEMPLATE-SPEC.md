# Strong TOML workflow-template specification

Status: **Draft; not implemented**

This document defines the design boundary for reusable workflow templates. The current daemon does not load workflow templates. Every proposed TOML key below remains subject to schema review before implementation. Non-runnable dogfood examples live in [`examples/`](examples/). Those examples are parse fixtures only; successful TOML parsing is not semantic validation and does not make any key implemented.

## Terms

| Term | Meaning |
|---|---|
| Workflow template | Owner-authored, versioned TOML blueprint describing actors, capabilities, tasks, communication, supervision, and acceptance requirements. |
| Materialization plan | Fully resolved and validated actors, resources, policies, tasks, and inputs produced without side effects. |
| Workflow run | Actor-owned execution pinned to one template version and normalized template digest. |
| Dynamic proposal | Bounded actor-requested deviation permitted by the template and requiring the configured authorization. |

Templates remove planning ambiguity: a run materializes declared topology and policy rather than asking agents to infer them. Dynamic behavior is allowed only through explicit extension policy.

## Existing canonical vocabulary

These names exist in current code and should be reused or deliberately migrated rather than silently renamed.

| Area | Implemented names | Canonical source |
|---|---|---|
| Configuration | `schema_version`, `service`, `hosted_pi`, `remoting` and their strict leaves | `services/subagents/internal/config/config.go` |
| Public identity | `agent_id`, `role`, `display_name` | `services/subagents/api/subagents/v1/subagents.proto` |
| Registration | `AgentID`, `Role`, `DisplayName`, `AllowedCapability`, `Retention`, `Recovery`, `RuntimeStartTimeout` | `services/subagents/internal/application/messages.go` |
| Project runtime | `project_directory`, `trust_project`; internal `ProjectDirectory`, `TrustProject` | protobuf and `services/subagents/internal/application/durable.go` |
| Communication | Tell/Ask, target, bounded payload/result, dedupe ID, chain ID, hop limit, source mutation sequence, deadline, fence, ACK, replay cursor | canonical protobuf |
| Runtime state | inactive, starting, ready, degraded, stopping, stopped; exact tmux/process identity; bridge readiness | canonical protobuf and application messages |
| Task lifecycle | START/STATUS/WAIT; lifecycle ID; accepted/model-running/completed/failed/timeout/actor-lost | canonical protobuf |
| Internal workflow | workflow ID, task, worker/reviewer/QA/correction/completed/failed stages, evidence, acceptance, terminal reason | `services/subagents/internal/application/messages.go` |
| Quarantine | `FailClosed`, reason items | `services/subagents/internal/application/messages.go` |
| Versioning | config schema version, durable schema version, protocol major/minor | their respective boundaries |

Current retention and recovery values are opaque strings, not reviewed policy enums. Current digest support belongs to durable mutation results, not template integrity.

## Capabilities not yet exposed as template schema

The following are **not implemented template attributes**:

- Actor `description` or charter.
- Model, provider, thinking level, context, or temperature settings.
- Actor slots or actor-count declarations.
- Declarative task graph or dependencies.
- Declarative communication rules.
- Evidence and acceptance-gate declarations.
- Structured supervision, restart, backoff, or quarantine policy.
- Secret-reference abstraction.
- Implemented template versioning or normalized template digest. Proposed examples use `template_version` only as unimplemented draft vocabulary.
- External workflow protobuf contract.

Worktree allocation and one-writer policy must be revalidated against the latest implementation before their schema names are accepted; roadmap wording alone is not an external contract.

## Schema requirements

A v1 schema must:

1. Use strict TOML decoding with unknown-field rejection.
2. Carry an explicit schema version and stable template identity/version.
3. Define typed inputs and reject unresolved interpolation.
4. Define arbitrary actor display names, roles, and descriptions without role enums.
5. Separate human role labels from capability authorization.
6. Define project/worktree access and enforce one writer per worktree.
7. Define communication allow/deny rules independently of actor names.
8. Define task dependencies as an acyclic graph.
9. Define supervision and terminal-failure bounds.
10. Define required evidence and acceptance gates.
11. Refer to secrets only through reviewed references; never embed credential values.
12. Produce a normalized, digestible materialization plan before side effects.
13. Pin each run to the exact template version and digest.
14. Permit actor proposals only through explicit extension policy and authorization.

## Proposed TOML vocabulary

All names in this section are **PROPOSED**, not current configuration fields. The examples in [`examples/`](examples/) use one coherent proposed schema to stress missing production-line, decision, work-unit, artifact, and cleanup vocabulary; they are documentation fixtures, not loader fixtures.

### Proposed workflow-line vocabulary

The following tables and keys are **PROPOSED/not implemented** unless explicitly marked **OPEN_DECISION**:

| Vocabulary | Proposed meaning | Status |
| --- | --- | --- |
| `schema_version`, `template_id`, `template_version`, `display_name` | Draft template identity fields for examples; not accepted by any loader. `schema_version` intentionally reuses the existing config field name but is not the service config schema. | PROPOSED/not implemented; **OPEN_DECISION**: template identity, version, and digest contract. |
| `runnable = false` / `status = "PROPOSED/not implemented"` | Documentation-only marker for examples that must not be treated as executable templates. | PROPOSED/not implemented |
| `[inputs.*]`, `type`, `required` | Draft typed input declarations and interpolation sources. | PROPOSED/not implemented; **OPEN_DECISION**: input type system and interpolation syntax. |
| `[workflow]` with `owner = "WorkflowActor"` | Draft declaration that WorkflowActor, not a prompt role, owns authorization, materialization, leases, decisions, cleanup, and terminal state. | PROPOSED/not implemented |
| `materialization`, `decision_authority`, `urgency` | Draft workflow-level policy hints for side-effect timing, decision source, and urgency. | PROPOSED/not implemented; **OPEN_DECISION**: policy enums and durable behavior. |
| `producer_authority = "trusted_registered_domain_producers_only"` | Restricts stage producers to registered domain producers selected by daemon authority rather than arbitrary role names. | PROPOSED/not implemented; **OPEN_DECISION**: registration and selection contract. |
| `[[producers]]` | Declares a producer requirement by domain, capability set, dynamic role-label policy, and reuse/passivation policy. | PROPOSED/not implemented; **OPEN_DECISION**: relation to `AgentActor` registration and existing `AllowedCapability`, `Retention`, and `Recovery` strings. |
| `producer_kind` | Distinguishes single registered producers from bounded producer pools. | PROPOSED/not implemented; **OPEN_DECISION**: cardinality and pool allocation semantics. |
| `domain`, `role_policy`, `capabilities` under `[[producers]]` | Draft producer selection attributes. Capability strings in examples are illustrative and are not an implemented authorization vocabulary. | PROPOSED/not implemented; **OPEN_DECISION**: capability taxonomy and role-label binding. |
| `reuse_policy = "retain_or_passivate"` | States that global reusable actors are retained or passivated, not stopped by workflow cleanup. | PROPOSED/not implemented |
| `[[worktrees]]`, `writer_slots`, `allocation` | Describes worktree leases and the one-writer-per-worktree constraint before side effects. | PROPOSED/not implemented; **OPEN_DECISION**: exact worktree allocator and conflict protocol. |
| `[[stages]]`, `stage_kind`, `requires`, `outputs` | Defines a production line as an acyclic graph of named stages and produced evidence/artifacts. | PROPOSED/not implemented; **OPEN_DECISION**: migration from current worker/reviewer/QA/correction stages. |
| `work_unit_template` | Connects a stage to dynamically materialized work units owned and authorized by WorkflowActor. | PROPOSED/not implemented |
| `[[work_unit_templates]]` | Bounds actor-proposed units by authorization, parallelism, worktree lease, writer slots, max open units, and required evidence. | PROPOSED/not implemented; **OPEN_DECISION**: materialized work-unit protobuf contract. |
| `[[decision_gates]]`, `decision_gates[].urgency` | Pauses progress for user/operator decisions with explicit options, timeout behavior, and optional per-decision urgency hints. | PROPOSED/not implemented; **OPEN_DECISION**: durable decision record, notification channel, urgency enum, and escalation behavior. |
| `[[evidence_gates]]` | Names required evidence kinds for stage or acceptance progress. | PROPOSED/not implemented; **OPEN_DECISION**: canonical evidence taxonomy. |
| `[[artifact_gates]]` | Names final or intermediate artifact requirements separately from evidence strings. | PROPOSED/not implemented; **OPEN_DECISION**: artifact manifest and retention policy. |
| `[[resource_bounds]]` | Applies resource limits such as parallelism, runtime, hop limits, and outstanding decisions. | PROPOSED/not implemented; **OPEN_DECISION**: enforcement layer and units. |
| `[supervision]` | Draft bounded correction, retry, terminal-failure, and passivation policy. | PROPOSED/not implemented; **OPEN_DECISION**: relationship to current opaque `Retention` and `Recovery` strings. |
| `[compensation]` | Describes bounded, authorized reversal/compensation behavior for incident-like workflows. | PROPOSED/not implemented; **OPEN_DECISION**: compensation result model. |
| `[[acceptance.gates]]` | Draft final acceptance requirements linking stages, evidence gates, artifact gates, and decisions. | PROPOSED/not implemented; **OPEN_DECISION**: acceptance protobuf and evidence semantics. |
| `[cleanup]` and `[[cleanup.steps]]` | Describes incremental cleanup of leases, credentials, worktrees, evidence capture, actor passivation, and exactly-owned ephemeral actor stop. | PROPOSED/not implemented; **OPEN_DECISION**: cleanup transaction and retry semantics. |

Proposed invariants for the unimplemented vocabulary:

- A future implementation would reject any template that tries to grant capabilities to itself; WorkflowActor would authorize a side-effect-free materialization plan before leases or actors are created.
- Producer domains would be authority inputs, not hardcoded project-manager/worker role semantics. Display roles would remain dynamic labels from daemon state.
- Dynamic work units would remain proposals until WorkflowActor validates acyclicity, capabilities, worktree writer exclusivity, resource bounds, and required decisions.
- One writer per worktree would be mandatory for every materialized unit. Parallelism would be allowed only when worktree and resource leases prove it safe.
- Global reusable AgentActors would be retained or passivated only. Cleanup would stop only actors proven to be exactly workflow-owned ephemeral children.
- Decision gates would be productive workflow state and would be durably recorded separately from runtime visibility or tmux state.
- Cleanup would be incremental and evidence-preserving: release leases and credentials promptly, but do not remove user-requested artifacts or global reusable actors.

### Minimal production-line shape example

This minimal TOML block uses the same **PROPOSED/not implemented** production-line vocabulary as the dogfood examples. It is documentation-only, non-runnable, and not accepted by any loader.

```toml
schema_version = 1
template_id = "example.minimal-production-line"
template_version = 1
display_name = "Minimal production-line example"
runnable = false
status = "PROPOSED/not implemented"

[inputs.objective]
type = "string"
required = true

[workflow]
owner = "WorkflowActor"
materialization = "side_effect_free_until_authorized"
producer_authority = "trusted_registered_domain_producers_only"
decision_authority = "user"

[[producers]]
key = "planning_producer"
producer_kind = "trusted_registered_domain_producer"
domain = "planning"
role_policy = "dynamic_runtime_label"
capabilities = ["read", "produce_evidence"]
reuse_policy = "retain_or_passivate"

[[producers]]
key = "delivery_producer"
producer_kind = "trusted_registered_domain_producer_pool"
domain = "delivery"
role_policy = "dynamic_runtime_label"
capabilities = ["read", "write", "test", "produce_evidence"]
reuse_policy = "retain_or_passivate"

[[worktrees]]
key = "candidate"
project_directory = "${input.project_directory}"
writer_slots = 1
allocation = "existing_or_isolated"
trust_project = false

[[stages]]
key = "plan"
stage_kind = "planning"
producers = ["planning_producer"]
requires = []
decision_gate = "plan_user_decision"
outputs = ["plan_record"]

[[stages]]
key = "materialize_units"
stage_kind = "dynamic_work_unit_materialization"
producers = ["delivery_producer"]
requires = ["plan"]
work_unit_template = "bounded_delivery_unit"
outputs = ["authorized_unit_plan"]

[[stages]]
key = "deliver"
stage_kind = "delivery"
producers = ["delivery_producer"]
requires = ["materialize_units"]
work_unit_template = "bounded_delivery_unit"
outputs = ["delivery_evidence"]

[[work_unit_templates]]
key = "bounded_delivery_unit"
proposed_by = "delivery_producer"
materialized_by = "WorkflowActor"
authorization = "requires_user_decision"
parallelism = "allowed_when_disjoint_worktree_and_paths"
worktree = "candidate"
writer_slots_required = 1
max_open_units = 1
required_evidence = ["delivery_evidence"]

[[decision_gates]]
key = "plan_user_decision"
decision_kind = "user"
requires_stages = ["plan"]
options = ["approve", "revise", "cancel"]
default_on_timeout = "pause"

[[evidence_gates]]
key = "delivery_trace"
requires_stages = ["deliver"]
evidence_kinds = ["delivery_evidence"]

[[acceptance.gates]]
key = "minimal_done"
requires_stages = ["deliver"]
requires_evidence = ["delivery_trace"]
requires_decisions = ["plan_user_decision"]

[supervision]
max_correction_rounds = 1
retry_policy = "bounded_by_stage"
terminal_on_retry_exhaustion = true
passivate_if_idle = true
idle_passivation_after = "30m"

[cleanup]
incremental = true
workflow_owned_ephemeral_actor_policy = "stop_exactly_owned_only"
global_reusable_actor_policy = "retain_or_passivate_only"
worktree_policy = "remove_only_workflow_owned_isolated_after_evidence_capture"
credential_policy = "revoke_workflow_scoped_leases"

[[cleanup.steps]]
key = "after_terminal"
when = "acceptance_terminal"
actions = ["capture_evidence", "release_worktree_lease", "passivate_reusable_actors"]
```

This example establishes shape only. Field names, interpolation syntax, capability vocabulary, model settings, evidence vocabulary, defaults, cardinality, and enums require dedicated review against canonical code before v1 acceptance.

### Future actor-presentation fragment

`[actors.panel]` is a separately labeled **PROPOSED/not implemented** future actor-presentation fragment. It is not part of the production-line example above, and the current daemon does not load it from templates.

```toml
# PROPOSED/not implemented: runtime-owned tmux panel projection preferences.
# Every field in [actors.panel] is PROPOSED/not implemented.
[actors.panel]
enabled = true # PROPOSED/not implemented
show_display_name = true # PROPOSED/not implemented
show_role = true # PROPOSED/not implemented
show_activity = true # PROPOSED/not implemented
show_access_mode = true # PROPOSED/not implemented
history_limit = 50000 # PROPOSED/not implemented
mouse_scroll = true # PROPOSED/not implemented
```

`[actors.panel]` fields express requested visibility preferences only; they do not authorize tmux access and do not permit templates or actors to inject tmux format strings. `history_limit` is only a proposed panel preference and cannot substitute for the implemented hosted Pi `--tui-mode fullscreen` transcript scrolling mechanism. `mouse_scroll` remains a proposed template preference and is distinct from the hosted Pi fullscreen scrolling mechanism, which has source-only Linux end-to-end verification after rebuild. Style tokens are centrally controlled by the runtime-owned visualization adapter described in [ADR 0004](0004-supervisor-hierarchy-and-owned-workflows.md#runtime-owned-tmux-panel-projection). The model never executes tmux commands.

## Materialization

```text
read owner-private template
→ strict syntax/schema validation
→ resolve typed inputs and reviewed references
→ validate identities and capabilities
→ validate projects, worktrees, and writer exclusivity
→ validate communication graph
→ validate acyclic task graph
→ validate supervision budgets and acceptance gates
→ normalize and calculate template digest
→ emit side-effect-free materialization plan
→ authorize plan
→ spawn/reuse actors and create WorkflowActor
→ persist run with template identity, version, and digest
```

Materialization failure creates no actors, credentials, worktrees, sessions, or partial workflow run. Uncertain persistence fails closed and enters quarantine.

## Actor participation

A template may permit actors to propose role clarification, capability changes, task decomposition, or additional collaborators. Proposals are typed messages to the WorkflowActor. Actors cannot grant their own capabilities, create writers, allocate worktrees, or bypass approval.

```text
PROPOSED → SPAWNED → REVIEW_CHARTER
                       ├── ACCEPT_CHARTER → ROLE_READY
                       └── PROPOSE_CHANGE → AUTHORIZE | REJECT
```

## Future TUI

The actor-backed dashboard should list, validate, dry-run, clone, and start workflow templates. It should show the normalized materialization plan and capability/resource changes before authorization. Settings may provide defaults, but a run remains pinned to its resolved template digest.

## Acceptance before implementation

- Reconcile every proposed field with current protobuf, application, durable, and configuration types.
- Decide whether templates extend the existing daemon TOML or use a separate owner-private template directory.
- Define capability and evidence vocabularies.
- Define model/provider settings only after inspecting supported Pi APIs and repository model policy.
- Define secret references without generalizing existing credential paths by assumption.
- Define protobuf contracts for template validation, dry-run, materialization, and workflow-run status.
- Add shared strict-parser corpus, semantic validation tests, digest fixtures, failure compensation tests, and TUI round-trip tests.
