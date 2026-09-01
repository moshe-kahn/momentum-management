# Task Intake and Promotion Policy

Document ID: DOC-0010
Status: Current
Revision date: 2026-08-29
Canonical owner: Office

## Purpose

Keep arrival, Processing, contextual thoughts, durable possibilities, and
committed work distinct.

## Record types

| Record | Use | Identifier |
| --- | --- | --- |
| Registered Inbox item | Unreviewed arrival with routing metadata | `FLOW-######` |
| Unregistered Inbox item | Manually added arrival awaiting explicit intake | None yet |
| Processing bundle | Reviewed material not fully integrated | `BND-######` |
| Crumb | Small contextual Idea, Decision, or considered Action attached to work or a bundle | `CRMB-######` |
| Idea | Durable possibility worth retaining without commitment | `IDEA-####` |
| Task | Finite commitment needing a managed outcome | `TASK-####` |
| Step / to-do | Work small enough to remain inside a Task | Local checklist or `S##` |

Every issued ID is unique and never reused.

## Intake and Processing

Inbox should normally be emptied through review. Each immediate non-hidden
child is one payload. A manually added payload may remain temporarily
Unregistered; viewing it does not issue an ID or write Productions. Explicit
intake registers it with a unique `FLOW-######` row. A reviewed item that needs
delayed or substantial formation moves into a Processing bundle rather than
remaining in Inbox.

A bundle remains in Processing until every payload is Integrated, Promoted,
Archived, Trashed, or Sent and its Threads are resolved or transferred. A
partly formed Task is not moved to Outbox; either create the Task with an
appropriate Pending state or keep processing the bundle.

### Task-linked Processing handoff

When a Processing bundle may change or materially inform an existing durable
work item:

1. set the Flow row's `Related work` to the exact record name and identifier;
2. add a `Pending Processing Inputs` link and a concise review question to the
   durable work record;
3. require the coordinator to read the bundle before advising on or resuming
   that work; and
4. explicitly decide whether each input updates the work, supports it without
   changing it, remains archival reference, promotes separately, or receives
   another final disposition.

The link is a notification and review obligation, not approval. It does not
change lifecycle, priority, Canvas membership, scope, plan, or authority. When
the bundle is fully resolved, record the final disposition, remove its live
Flow row, and update or remove the pending-input notice in the related record.

## Crumb handling

Crumb kinds are exactly:

- Idea — something to ponder;
- Decision — a choice among alternatives;
- Action — a possible action under consideration, not a commitment.

Resolve a Crumb by integrating it into its target, dismissing it, transferring
it, or promoting it. A substantial continuing possibility becomes a durable
Idea. An accepted Action may become a to-do, Step, Task, or Processing bundle.

## Task promotion

Create a Task when:

1. the finite outcome or completion criterion is clear enough to manage; and
2. the user has decided that it should exist as work.

Its initial state may be Pending / Review if priority, timing, scope, or
commitment still needs a decision. Task creation does not require immediate
Active status.

Codex:

1. issues the next Task ID;
2. creates `Workspace/<TASK-ID>/<TASK-ID>.md`;
3. adds the Registry row;
4. integrates or links the source material;
5. updates the source bundle's disposition; and
6. preserves provenance without maintaining competing records.

## Projects and Initiatives

Use a Project when an outcome coordinates several distinct Tasks. Use an
Initiative when a broad strategic outcome coordinates multiple Projects,
products, or departments. Use the smallest durable record type that accurately
represents the work.

**Advisory eligibility review.** `Review after` records an exact condition under which a durable Task, Idea, Project, or Initiative is visibly offered for owner review. It is not intake, promotion, commitment, approval, activation, priority, Canvas placement, Focus, or permission to start. `Proceed` records interest in considering that exact hook only. Any promotion or new Task, Project, or Initiative still requires the ordinary owner decision, identifier issuance when applicable, Registry and Workspace creation or update, provenance preservation, and separately authorized transaction described by this policy. `Decline`, `Defer`, and `Replace` disposition only the exact hook. Applications must not infer advisory hooks from prose, dependencies, related records, lifecycle history, or product-session handoffs.

## Canvas independence

Only durable Tasks, Ideas, Projects, and Initiatives participate in Canvas.
Processing bundles remain in Flow; a Crumb or Memento provides continuity when
bundle processing is interrupted. Canvas events do not promote work or change
its Registry state.
