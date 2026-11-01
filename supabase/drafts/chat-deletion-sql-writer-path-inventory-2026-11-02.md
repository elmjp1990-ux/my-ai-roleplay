# PR #200 — SQL writer-path inventory (bounded review, 2026-11-02)

Status: partial inventory; not a claim of repository-wide completeness.

## Scope inspected

- All SQL migration files changed by PR #200.
- Changed Edge Function files: `chat-deletion-worker.ts`, `purge-chat-deletions/index.ts`, `story-session/index.ts`.
- Frontend call sites in the PR branch `index.html`.
- The deployed single-chat `chat-turn` Edge Function fetched from the PR branch.
- Live test-project definition of `public.sync_character_chat_snapshot(uuid)`.

## Confirmed writer paths

| Path | Writes | Parent serialization / gate | Result |
|---|---|---|---|
| `append_chat_group_mock_turn` | group turn, player message, character reply, charge, wallet transactions | locks `chat_groups` FOR UPDATE; owner + active + not archived | Good for this writer |
| Frontend group edit/delete latest message | updates `chat_group_messages` | authenticated direct DML denied by grants; restrictive active-parent RLS | Requires transaction race fixture |
| `delete_chat_group_with_related_data` | soft-delete marker + deletion/storage jobs | locks group parent first | Deletion entry point |
| `delete_chat_session_content` | soft-delete marker + deletion/storage jobs | locks session parent first | Deletion entry point |
| `chat-turn` Edge Function | service-role assistant insert into `chat_messages` | calls `reserve_chat_turn`; assistant insert trigger locks session and checks active state | Single-chat late-write gate exists |
| `sync_character_chat_snapshot` | updates session snapshot, group member snapshot, group message speaker snapshot | live definition had no parent-first group lock and no deleted-parent filter | Gap; draft fix added |

## Confirmed gap and proposed fix

Live `sync_character_chat_snapshot(uuid)` is SECURITY DEFINER and updates group child metadata by character ID, including rows whose parent group has `deleted_at`. This bypasses the authenticated RLS lifecycle guard. Draft-only fix:

`supabase/drafts/sync-character-chat-snapshot-parent-lock-proposal.sql`

The proposal locks active single-session parents, then active group parents in deterministic ID order, and only updates children belonging to active parents. No migration has been applied.

## Limits

- This review covered PR changed SQL files, selected frontend call sites, and the named deployed Edge Function. It did not enumerate every unchanged repository migration, every live function, Dashboard SQL, external service-role integration, or manually invoked service-role query.
- service_role bypasses RLS. Do not revoke service_role table grants until every worker/function dependency is inventoried.
- The group mock writer is the only explicit `INSERT INTO chat_group_messages` found in the PR changed migrations. This does not prove no other writer exists outside that scope.
- No schema changes, data changes, Storage operations, deployment, cron, or production operations were performed.

## Required next work

1. Full repository-wide SQL function/trigger/view writer index, not only PR changed files.
2. Inventory all service_role callers and any direct DML to group tables.
3. Add transaction fixtures for writer/delete ordering and child edit/delete ordering.
4. Integrate immutable per-character turn snapshots into delete RPCs and the latest purge RPC; make count RPCs use active live rows plus archived snapshots exactly once.
5. Add rollback, idempotency, incomplete-snapshot detection, purge retry, and post-purge count-invariance tests.
6. Restore a trustworthy schema-only local baseline and pass clean replay before applying migrations anywhere.
7. Complete browser multi-tab/device and real Storage failure/retry E2E.

No cron, deployment, merge, or hosted DDL is authorized by this document.

## Fifth-round extension: historical migrations and character lifecycle writers

A targeted pass over the historical group-chat and character snapshot migrations found:

- `create_chat_group(...)` creates a new group/scenes/member snapshots atomically. It is a creation path, not a writer into an already deleted parent; its member-limit trigger locks the parent group before member insert/update.
- Historical definitions of `append_chat_group_mock_turn(...)` existed in 2026-10-15 migrations and were later replaced by billing and parent-first guard migrations. Do not assess only the earliest definition; the effective latest definition is in `20261101053732_chat_writer_parent_first_guards.sql`.
- `soft_delete_character(...)` in `20261022175412_sync_group_character_snapshots_on_delete_and_update.sql` is a second SECURITY DEFINER snapshot writer. It originally updates all chat sessions, group members, and group messages by character ID without locking chat parents or excluding deleted parents. Fixing only `sync_character_chat_snapshot` would leave this sibling bypass.
- The parent-lock proposal was expanded to replace both `soft_delete_character` and `sync_character_chat_snapshot`. Both paths now lock active single-chat parents and active group parents in deterministic order before child snapshot updates; deleted parents are skipped. Draft-only commit `e76edc374d872765fbea51d1fa938df4b860480c`.
- Encounter writer paths `reserve_encounter_chat_turn` and `record_encounter_session_turn_evidence` in `20261101054027_encounter_chat_deletion_gates.sql` both lock `chat_sessions` parent first and reject deleted parents before lifecycle/charge/evidence writes.
- Encounter interaction writer `record_encounter_turn_interaction` also reads the matching charge, then locks the session parent before locking charge and inserting receipt/affinity/diary evidence; it rejects deleted sessions.
- Encounter evaluation queue functions write evaluation jobs/lifecycle state, not chat transcript rows; their session-deletion interaction still needs explicit coverage in the dedicated queue/worker audit.

### Coverage status

The PR branch tree contains 107 migration files. This round inspected a targeted subset of historical group, character snapshot, encounter writer, and chat-deletion migrations; it did not fetch/review every one of the 107 migration bodies. Therefore the repository-wide writer inventory remains partial. Do not mark 5A fully complete.

## Encounter evaluation queue: deleted-session re-enqueue risk

Review of `20261031240000_encounter_evaluation_dispatch_queue.sql`, its bounded-retry replacement `20261031250000_bound_encounter_evaluation_retries.sql`, and the latest chat purge RPC found:

- `enqueue_due_encounter_evaluations()` locks/updates `encounter_session_lifecycle` and can enqueue a job based on lifecycle status/time, but does not join/check `chat_sessions.deleted_at` and does not lock the chat session parent first.
- `claim_encounter_evaluation_jobs()` also selects ready lifecycle/job rows without checking `chat_sessions.deleted_at`; it claims only the job row.
- Chat purge deletes `encounter_session_evaluation_jobs` and clears lifecycle payload fields, but does not transition the lifecycle status out of `active/paused/ready_to_settle`. The lifecycle row survives because it is the queue FK parent.
- Therefore, after chat purge deletes an evaluation job, the existing minute dispatcher can potentially enqueue it again from the surviving due lifecycle row. This is a real static lifecycle integration risk; no runtime race has yet been executed.
- Added draft-only proposal `supabase/drafts/encounter-evaluation-deletion-gate-proposal.sql` (commit `016e20389900443fdc34ffcee573e795d14832a6`). It joins/checks the chat parent, uses parent-first locking before lifecycle/job locks, and prevents enqueue/claim for deleted sessions. It preserves the existing service_role-only function ACL and does not add a chat-deletion Cron.
- Claim-time filtering is not enough by itself: the evaluator's final settlement RPC must also recheck and lock the chat session parent, because deletion can happen after a job is claimed. That path remains a required audit/test.

Required tests: purge-then-dispatch no re-enqueue; dispatcher-first vs delete-first lock ordering; claim skips deleted sessions; settlement rejects deleted sessions under parent lock; active-session retry/lease remains bounded.


## Seventh-round extension: Encounter settlement vs deletion (2026-11-02)

A cross-check of the queue-gate proposal against the existing draft `encounter-session-delete-lifecycle-guards.sql` found:

- The existing draft replacement for `settle_encounter_session(...)` already locks `chat_sessions` first with `deleted_at IS NULL`, then locks `encounter_session_lifecycle`, and only then updates `encounter_character_state` and lifecycle settlement fields. This is the correct serialization shape against chat deletion **if this draft is included and its ACL is preserved**.
- The settlement replacement is currently draft-only; it is not in the PR's changed migration list and has not been applied. It must not be described as an active protection.
- The queue-gate proposal separately fixes dispatcher and claimer parent locking. Both are required: queue filtering prevents deleted work from being enqueued/claimed, while settlement parent locking prevents an already-claimed worker from committing affinity after deletion wins the parent lock.
- The settlement draft shown in this file does not itself include explicit GRANT/REVOKE statements for `settle_encounter_session`. Before promotion, fetch the live function ACL and preserve its exact intended caller boundary. Do not assume that SECURITY DEFINER alone makes it service-only.
- The settlement RPC returns idempotently for an already-settled lifecycle only after the parent lock/check, which is desirable: a deleted parent cannot use the idempotent branch to reveal or mutate settlement state.
- The inspected settlement body checks pending pre-expiry reserved/reconciliation charges and evidence-count equality before applying affinity. It does not settle while there is incomplete turn evidence.

### Remaining evaluator integration evidence gap

The PR-changed Edge Function set contains the deletion worker and story-session function; it does not contain a dedicated Encounter evaluator file. This bounded pass has not yet established the deployed evaluator's exact function name, RPC call order, or failure/retry behavior. Trace the deployed evaluator entry point and confirm it calls `settle_encounter_session` only after a successful claim, and that failures use the bounded `fail_encounter_evaluation_job` path. Do not infer this from the queue SQL alone.

### Required combined race matrix

1. Evaluator claims first, then delete acquires `chat_sessions`: settlement must block, observe `deleted_at`, and reject without affinity/lifecycle mutation.
2. Settlement acquires `chat_sessions` first: deletion must wait; settlement may complete, then deletion proceeds and hides/purges the chat on its schedule.
3. Dispatcher claims/queues before delete: delete must remove the job; worker settlement must still reject if delete wins parent lock.
4. Delete/purge completes before dispatcher: no job may be recreated from surviving lifecycle rows.
5. Verify function ACL for settlement, enqueue, claim, and fail RPCs; verify evaluator service identity; verify retry count/lease is bounded.

Coverage remains partial; no runtime lock-race fixture or deployed evaluator trace has been completed in this round.
