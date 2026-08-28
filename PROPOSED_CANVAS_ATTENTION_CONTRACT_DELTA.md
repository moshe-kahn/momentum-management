# Canvas Ordinary-Attention Contract Delta — Adopted Provenance

Status: Adopted provenance; not a competing canonical Productions contract.

This file preserves the repository delta incorporated into Momentum Management
Filesystem Contract (DOC-0016) version 1.11 and aligned with the independently
accepted root `AGENTS.md` correction. The sections below retain their original
change-instruction form as provenance; they are not pending instructions.

## DOC-0016 — Canvas contract

Replace “Start work and Stop work are the only ordinary application actions”
and their action bullets with:

> Focus and Clear are the ordinary application actions that request desired
> Canvas attention. Both are explicit; passive loading, opening, selection,
> preview, refresh, search, discussion, session preparation, and administrative
> updates remain read-only.
>
> Focus requires nonblank Reason and Context and rereads the live Canvas while
> holding the scoped write lock. If the target is not current, one atomic
> transaction appends `Placed` followed by `Engaged`. If the target is already
> current, Focus succeeds as an explicit no-op and appends no event.
>
> Clear requires nonblank Reason and Context and rereads live Canvas while
> holding the scoped write lock. If the target is current, one atomic
> transaction appends `Cleared`. If the target is already off Canvas, Clear
> succeeds as an explicit no-op and appends no event.
>
> An ordinary Focus or Clear operation may make at most four nonblocking lock
> attempts, separated by 150 milliseconds, and only while every failed attempt
> is proven to precede mutation. It never busy-loops and never retries a write,
> partial outcome, committed outcome, or uncertain outcome.
>
> Every ordinary operation, including an already-desired no-op, has a unique
> operation identity recorded in its operation journal together with the exact target identity, Canvas
> preimage hash and bytes, intended event rows, expected replacement hash,
> Reason, Context, and target fingerprint. After interruption, reconciliation
> may report a mutating operation as successful only when canonical Canvas
> contains the exact journal-bound preimage prefix and complete intended event
> sequence and that operation's `Placed` or `Cleared` boundary remains the
> requested target's latest boundary. Desired membership alone never proves a
> commit: a partial Focus containing only `Placed`, or independently produced
> matching membership, remains uncertain. It may classify no commit after a
> replacement exception only when immediate canonical inspection proves the
> bound preimage; that durable definite-no-commit terminal state remains
> inspectable if Canvas later changes.
>
> An exact journal-bound event sequence followed by a later target boundary is
> reported as a historical commit that has been superseded, separately from
> current desired-state satisfaction. It is never reported as current success,
> even if another later operation independently restores matching membership.
> Target changes, malformed or fragmented Canvas, partial rows, contract
> defects affecting the live Canvas or target, and all other ambiguous outcomes
> stop visibly without automatic retry.
>
> Historical defects unrelated to the live Canvas schema and requested target
> do not by themselves block a valid ordinary transaction. The writer still
> rejects malformed or fragmented Canvas, invalid events, unresolved or
> duplicate requested targets, target changes, unsafe replacement, failed
> reload validation of the requested target or desired membership, and hash or
> lock conflicts. Before either a no-op or mutation, it validates the requested
> target's complete transition history: `Placed` is valid only while off
> Canvas, `Engaged` only while current, and `Cleared` only while current.
> Duplicate `Placed`, duplicate or off-Canvas `Cleared`, off-Canvas `Engaged`,
> and every other invalid requested-target transition stop the operation.
>
> Replacement exceptions are not presumed to precede a write. Immediate
> inspection records definite no-commit only for the exact preimage; exact
> reconciliation records a reconciled commit; partial, malformed, or otherwise
> unproved outcomes remain uncertain and visible to startup recovery. A
> reconciled commit, definite no-commit, already-desired no-op, or proven
> historical-but-superseded commit is terminal and is not reported as an
> incomplete startup recovery item.
>
> If a proven commit cannot be written to its correct terminal journal state,
> the operation returns an exit-3 outcome containing its operation identity,
> states exactly one of three classifications—committed and currently
> satisfied, historically committed and superseded, or historically committed
> with current state uncertain—states that journal finalization failed, and
> prohibits retry. The writer records a typed terminal
> journal-finalization-failure marker for that classification when the
> fallback write is available; if even the fallback write fails, the diagnostic
> states that startup recovery may still show the operation as incomplete.
> Every journal-finalization-failure marker semantically proves a historical
> commit. If live Canvas later equals the journal preimage, reconciliation
> reports historically committed with current state uncertain, flags the
> append-only inconsistency, and prohibits retry; it never reclassifies the
> operation as not committed.
> Historical-commit proof is monotonic across every journal transition. Once a
> terminal state proves a historical commit, later inspection failure, target
> mismatch or unavailability, Canvas validation failure, return to the
> preimage, or other reclassification may only preserve that proof and report
> current state uncertain; it may never downgrade the operation to a terminal
> state that does not prove the historical commit.
> Definite no-commit replacement failures retain exit 2, include their
> operation identity and journal-finalization status, and direct the operator
> to the non-mutating operation inspection command.
> A durable `definiteNoCommit` terminal state is authoritative journal-only
> proof. Operation inspection returns that classification before loading or
> validating mutable Canvas or target state, so later malformed Canvas,
> unavailable or removed targets, duplicate target resolution, and other live
> defects cannot erase the stored no-commit result. Other classifications keep
> their stricter live-state inspection requirements.
>
> If the recovery journal cannot be read after `replacementFailed`, the
> operation returns exit 3 with its UUID, a possible-commit classification,
> current Canvas and journal state marked uncertain, inspection guidance for
> when journal access is restored, and an explicit prohibition on retry. If
> the journal cannot be read after `reloadFailed`, the operation instead
> preserves that a historical commit is proven, marks current Canvas and
> journal state uncertain, returns exit 3, and prohibits retry. Neither
> post-mutation journal-read failure may fall through to a generic exit-2
> result.
>
> Focus and Clear report compact success or no-op outcomes that include the
> discoverable operation identity. `canvas inspect --productions-root <path>
> --operation <UUID>` is a non-mutating diagnostic surface that reports the
> journal hashes, intended events, terminal state, historical commit evidence,
> current-boundary proof, and reconciliation classification. Confirmation
> material and recovery detail otherwise remain diagnostic. Neither action renders a session package, changes
> Registry lifecycle or priority, or creates, resolves, or supersedes a
> Memento.
>
> The existing preview-confirmed low-level Start and Stop commands remain
> supported for compatibility and explicitly sensitive or manual workflows.
> Start retains its existing `Placed`/`Engaged` behavior, including an
> `Engaged` append for an already-current target; Stop retains its current-only
> precondition. Their confirmation tokens, no-retry classifications, locking,
> hashes, journaling, atomic replacement, reload validation, and recovery
> guarantees are unchanged.

Replace the Session preparation sentence beginning “Start work may perform”
with:

> Ordinary Focus never renders a session package. Prepare session remains a
> separate read-only action. The compatibility low-level Start command may
> retain its existing post-commit renderer composition, and a committed Canvas
> transaction is never retried when later package generation fails.

## DOC-0005 — Starting and stopping work

Replace the current Start/Stop ordinary-attention bullets with the same Focus
and Clear desired-state semantics above. Preserve all distinctions among Task
lifecycle, Canvas attention, Mementos, Crumbs, passive viewing, and
administrative updates. State explicitly that an already-desired request is a
successful no-op rather than another attention boundary.

## Coordinator and Office Administrator guidance

Replace the default mechanism-selection instruction with:

> Use ordinary `canvas focus` and `canvas clear` for routine desired-state
> attention once this contract delta is adopted. Use preview-confirmed
> low-level `canvas start` and `canvas stop` when an explicitly sensitive or
> manual workflow requires review of the exact hash-bound mutation. Never
> translate an uncertain or partial outcome into an automatic retry.

In the Tier 3 description, add:

> The accepted ordinary Canvas desired-state surface is the narrow exception
> to owner-visible preview choreography. It preserves the same shared
> transaction service, bounded pre-mutation locking, operation journal,
> atomicity, canonical reconciliation, and visible uncertainty guarantees.
