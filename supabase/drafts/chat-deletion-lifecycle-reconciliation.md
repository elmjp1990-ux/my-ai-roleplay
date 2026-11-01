# POYOZZ chat deletion lifecycle — reconciliation and implementation plan

Status: Draft / design gate only  
Base: `main` at `0a951f290d6594a520afb4ab0dc3177a8ab16a24` (PR #199 merged)  
Test Supabase project: `ouyewoagbmtqehbofrje`  
Policy: user-requested chat deletion is immediate soft-delete; permanent relational and Storage cleanup only after 30 days.

> This file is intentionally under `supabase/drafts/`. It is not an executable migration. Do not apply it, schedule a worker, or deploy a cleanup function from this document.

## 1. Product contract

- Single and group chats share one lifecycle. A group has one player/owner and multiple AI characters; it is not a multi-human group.
- A successful delete request immediately makes the chat unavailable for read, send, edit, new generation, encounter evidence, diary, affinity updates, background selection, and photo upload/signing.
- The user-facing grace period is 30 days. Preserve recoverability during this period; do not clear messages, versions, AI generation content, snapshots, memories, diary, or album metadata at request time.
- At or after `deleted_at + interval '30 days'`, a service-role worker may permanently purge relational chat data and Storage objects.
- Storage paths must be durably queued before any parent/metadata row that contains the path can be removed. Failures remain retryable with bounded exponential backoff and dead-letter visibility.
- Financial ledger and audit evidence must survive chat purge. Chat deletion is not account deletion.
- Character assets (character portrait, encounter illustrations, avatar videos) are not chat assets and must never be deleted by chat cleanup.
- Existing one-year memory-photo expiry remains distinct from chat deletion. Explicit single-photo deletion can hide the photo immediately and queue its object for cleanup without deleting the chat.

## 2. Confirmed live test-database findings (read-only inspection, 2026-11-01)

### RPCs

- `append_chat_group_mock_turn` takes a `FOR UPDATE` lock on the owner/group row, but its predicate checks `archived_at IS NULL` and not `deleted_at IS NULL`. It then writes turns/messages and performs billing. Add a deleted-state gate under the same parent lock.
- `delete_chat_group_with_related_data` immediately hard-deletes group messages, members, turns, scenes, diary, group memory photos, chat memory photos, and the group row. It returns Storage paths only; no durable retry record is created first.
- `delete_chat_session_content` immediately removes message versions, clears AI generation original content, clears message content, marks photos deleted, removes memory/album session data, clears character snapshot, and only then sets session `deleted_at`. This violates the 30-day grace contract.
- `soft_delete_chat_memory_photo` updates photo status to `deleting` and sets `deleted_at`, but does not lock/check the parent session/group lifecycle before mutation.
- `enforce_chat_memory_photo_expiry` runs on INSERT and unconditionally resets the photo to active, clears `deleted_at`, and resets attempts. It must validate a live parent and must not revive deleted-chat photos.

### Financial and relational FK dependencies

- `chat_turn_charges.session_id → chat_sessions.id` is ON DELETE CASCADE.
- `chat_turn_charges.user_message_id → chat_messages.id` is ON DELETE RESTRICT.
- `chat_turn_charges.assistant_message_id → chat_messages.id` is ON DELETE SET NULL.
- `chat_turn_events.turn_id → chat_turn_charges.turn_id` is ON DELETE CASCADE.
- `chat_group_turn_charges.group_id → chat_groups.id` and `group_turn_id → chat_group_turns.id` are ON DELETE CASCADE.
- `ai_generation_records` session/message FKs are NO ACTION and include `original_content`.
- `chat_message_versions.message_id → chat_messages.id` is NO ACTION.
- `wallet_transactions` has no chat/session/group FK and must remain independent.
- Do not assume `wallet_transactions.reference_id` is a relational FK or sufficient audit preservation.

Before hard purge, charge/refund/turn-event records must be retained in an independent audit model or their FK dependency must be safely decoupled. Preserve charge IDs, user, amounts/currency split, status, timestamps, refund outcome, turn IDs, and audit events. Reconciliation must remain possible after the chat rows are gone.

### Trigger and RLS findings

- Assistant insert/update guards lock charge rows but do not check/lock the parent session lifecycle.
- Message version trigger can capture OLD content when content is cleared; purge ordering must explicitly avoid creating a new historical version during purge.
- Photo INSERT trigger can reset a row to active; require valid owner/type/parent and parent `deleted_at IS NULL`.
- Group RLS on parent and child tables mostly checks owner only; group parent direct DELETE policy allows a hard delete outside the lifecycle RPC.
- Single-chat session/message/version SELECT or UPDATE policies do not consistently reject deleted sessions.
- Group child reads/writes, group diary, group photo and photo UPDATE policies do not consistently reject deleted parent chats.
- `personax-memory-photos` has broad owner-folder Storage policies in addition to narrower chat-aware policies. Since permissive policies OR together, broad policies can bypass chat parent-state checks. Remove or rewrite broad policies so every operation enforces bucket + owner + chat type + live parent.
- Group policies currently use `archived_at`; do not treat it as a substitute for a new `deleted_at` lifecycle field.

## 3. Repository / migration drift — release blocker

The current GitHub `main` tree does not contain:
- `supabase/migrations/20261022094147_delete_chat_group_with_related_data.sql`
- `supabase/migrations/20261022094349_delete_chat_session_content.sql`

Both versions are present in the test Supabase migration history and their functions are live. A direct fetch of both paths from `main` returns 404. Therefore the live test DB contains applied migration history/function state that is not reproducible from the current GitHub main tree.

Do not add a new lifecycle migration on top of this unresolved drift. First recover the exact source SQL for those two applied migrations from the authoritative migration artifact/history, or create a reviewed baseline reconciliation migration that faithfully captures the live state. Do not guess or recreate historical files from function names alone.

Other migration names/timestamps also differ between the live database and repository history. Reconcile the full version/name inventory before any migration is applied.

## 4. Target implementation architecture

### 4.1 Parent lifecycle

- Keep `chat_sessions.deleted_at` as the single-chat deletion marker.
- Add `chat_groups.deleted_at` for group chats. Do not overload `archived_at`.
- Record deletion timestamp and immutable owner/chat identity. Repeated delete calls are idempotent and must not extend the original 30-day deadline.
- Delete request RPC locks the parent row first, verifies owner and active state, writes the deletion marker and creates cleanup work in the same transaction.
- All sends/reservations, group append, assistant insert/update, encounter evidence, story evaluation, diary writes, affinity settlement, photo operations, background selection and signed URL issuance must acquire/check the same parent lifecycle lock/gate. Keep a consistent parent-first lock order.
- Existing reserved turns may complete only through explicit pre-existing settle/refund/reconciliation rules; no new user content, AI generation, evidence or charge can be added after deletion starts.

### 4.2 Durable work records

Design two service-only queues:

1. Chat purge jobs: `chat_type` (`single` / `group`), parent UUID, owner UUID, requested_at, purge_after, status, attempts, next_attempt_at, locked_at, completed_at, last_error, idempotency key.
2. Storage object cleanup jobs: bucket ID, exact object path, owner, chat type, chat ID, reason, not_before, status, attempts, next_attempt_at, locked_at, completed_at, last_error, idempotency key.

Requirements:
- Unique idempotency key per logical parent cleanup / bucket + path.
- Queue insert happens in same DB transaction as soft delete and before metadata can be removed.
- Service-role only; no client SELECT/INSERT/UPDATE/DELETE grants or policies.
- Claim with `FOR UPDATE SKIP LOCKED`, bounded batch size and lease timeout.
- Retry transient Storage errors with capped exponential backoff; record attempt/error; permanent/not-found outcomes are idempotently completed; poison paths become dead-letter and alertable.
- Worker rechecks that object path is not referenced by a live chat or character asset before deletion.
- Storage cleanup only targets `personax-memory-photos` paths owned by the job owner. Never target `character-illustrations`, `character-avatar-videos`, or other buckets.
- Do not mark a chat purge complete until all associated Storage jobs are complete and relational purge succeeds.

### 4.3 Financial preservation and relational purge

- Before enabling hard purge, remove chat-parent cascade paths from financial audit records or archive the complete financial/audit payload into a separately retained immutable model with verified counts and idempotent retry.
- Do not cascade-delete charge rows or their audit events when deleting session/group/turn/message rows.
- Explicitly handle `ai_generation_records` content according to a field-level retention decision; preserve billing/usage evidence while minimizing or redacting prompt/raw model content where policy requires. Do not silently blank content at deletion request time.
- Purge child rows in FK-safe order only after 30 days and after storage paths have been queued.
- Use explicit allow-listed table list per chat type; never dynamic-delete arbitrary tables.

## 5. Required acceptance / adversarial tests

### Lifecycle and access
- owner can request delete once; repeated calls do not move purge_after.
- non-owner cannot delete or inspect queue.
- immediately after delete: chat/session, messages, versions, diary, memories, photos and signed-URL endpoints are inaccessible.
- cannot create or upload a photo for a deleted chat, cannot select a deleted photo as background, and cannot refresh/re-sign its object.
- cannot direct DELETE parent group or bypass RPC through Data API.
- private/deleted character snapshot preservation for other unrelated chats remains unchanged.

### Race / locking
- delete vs single reserve/send.
- delete vs group append.
- delete vs assistant insert and update.
- delete vs encounter evidence / settlement / story evaluation.
- delete vs diary and affinity writes.
- delete vs photo insert/update/delete and background selection.
- prove no deadlock using parent-first lock order; verify transaction rollback leaves no partial queue or wallet mutation.

### Billing / audit
- reserved turn at delete boundary follows explicit settle/refund policy.
- settled charge, partial silver/diamond split, wallet transaction and audit events survive chat purge.
- refund/reconciliation remains possible after chat rows are gone.
- no double charge/refund on retries.

### 30-day purge and Storage retries
- before purge_after, worker claims no chat purge job.
- at/after purge_after, worker queues/deletes only exact eligible chat photo paths.
- transient Storage failure remains retryable with attempt/error/next_attempt_at.
- repeated worker invocation is idempotent.
- already-missing object completes safely.
- one poison object does not erase retry evidence or falsely mark parent purge complete.
- character portraits, encounter illustrations and avatar videos remain intact.
- after successful purge, no chat rows remain, financial/audit records remain, and no storage cleanup jobs are left pending.

## 6. Implementation sequence

1. Reconcile migration history and recover missing historical migration sources.
2. Define and implement financial audit decoupling; validate rollback-only FK/preservation tests.
3. Add group `deleted_at`, lifecycle queue tables, service-only grants and RLS.
4. Replace single/group delete RPCs with one consistent soft-delete contract; persist paths/jobs atomically.
5. Add parent-first deleted-state gates to all RPCs, triggers, RLS and Storage policies.
6. Add service-role worker for Storage cleanup then relational purge, with bounded retry/dead-letter behavior.
7. Add SQL regression/race tests and worker tests; run on test DB in a transaction or isolated fixtures.
8. Only after review, apply migrations to test DB, run end-to-end tests, and request explicit release approval. Production worker/cron remains disabled until separate approval.

## 7. Current safety state

- This PR branch is based on latest `main`.
- No database mutation, migration application, worker deployment, cron setup, or production change is authorized by this draft.
- Do not merge as a completed deletion implementation. This document records the verified design and blocks unsafe partial rollout.


## 8. Full migration inventory comparison — 2026-11-01

A fresh comparison was made between the test project's migration history and the recursive Git tree at the PR #199 merge base (0a951f290d6594a520afb4ab0dc3177a8ab16a24).

- Test Supabase migration history: **141 entries**.
- GitHub main migration directory: **96 SQL files**.
- Same migration names in both inventories: **82**.
- Of those shared names, **67 have different version/timestamp prefixes** between the live DB and repository.
- Live DB-only names: **57**.
- Repository-only names: **14**.
- The two chat deletion migrations (20261022094147_delete_chat_group_with_related_data, 20261022094349_delete_chat_session_content) are among the live DB-only entries.
- GitHub commit-history lookup for the two exact missing migration paths returned no commits. PR #133's changed-file list remains only index.html; its description/comments mention the RPCs but do not provide the applied SQL source.

This is broader than two missing files. The repository migration directory and the test database history are not a one-to-one migration chain. A migration cannot safely be selected or applied based on filename/timestamp assumptions.

### Reconciliation decision

- Keep PR #200 Draft and keep all lifecycle SQL non-executable until a canonical baseline is established.
- Do not rename repository migration files to match the live history, invent missing historical SQL, or manually insert rows into supabase_migrations.schema_migrations.
- Next evidence-gathering step: capture a read-only schema inventory from the test project (tables/columns, constraints, indexes, triggers, policies, functions, grants, Storage bucket/policies) and compare it with the repository's migration replay state or a clean disposable project built from main.
- If a clean replay cannot be produced, create a separately reviewed baseline/reconciliation plan from an authoritative schema snapshot, with explicit object-by-object provenance and drift disposition. Do not treat pg_get_functiondef alone as a complete historical migration source because it omits surrounding grants, policies, triggers, dependencies, and data transformations.
- Only after baseline sign-off should the implementation branch add the first executable lifecycle migration. No test DB DDL/DML, migration application, worker deployment, or cron was performed in this inventory pass.
