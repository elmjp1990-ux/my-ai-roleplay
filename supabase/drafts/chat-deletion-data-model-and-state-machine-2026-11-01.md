# POYOZZ unified chat deletion data model and state machine — 2026-11-01

Status: proposed design only; not an executable migration. No database objects or data were changed.

## Product contract

- Single chat and group chat use one lifecycle contract and one purge service.
- A group contains one player and multiple AI characters; deleting it removes that player's entire group conversation.
- Player-facing deletion is immediate and treated as irreversible. The backend retains the content for 30 days as a safety buffer; no restore UI or promise is exposed.
- At 30 days, chat content and chat-only memory assets are permanently purged.
- Wallet transactions, charge/refund evidence, security audit metadata and required billing evidence are not deleted with chat content.
- Character primary images, illustrations, videos and character snapshots are excluded from chat purge.

## Proposed shared lifecycle state

Use the existing `chat_sessions.deleted_at` for single chats and add `chat_groups.deleted_at` for groups. Do not reuse `archived_at`.

A single generic deletion job represents either resource:

```sql
-- Conceptual schema only; do not apply directly.
chat_deletion_jobs (
  id uuid primary key,
  resource_type text check (resource_type in ('single_session','group')),
  resource_id uuid not null,          -- deliberately no FK to the chat parent
  owner_id uuid not null,             -- immutable identity snapshot; no cascading FK
  deleted_at timestamptz not null,
  purge_after timestamptz not null,   -- deleted_at + interval '30 days'
  status text not null,               -- queued | processing | retry | completed | dead_letter
  attempt_count integer not null default 0,
  next_attempt_at timestamptz,
  lease_until timestamptz,
  last_error_code text,               -- sanitized code only; never raw chat content
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (resource_type, resource_id)
)
```

No FK to chat parent is intentional: the queue must survive deletion of the parent row. No user-facing table grants or RLS policies; only a tightly scoped service-role worker may read/update jobs. User deletion/archive is a separate lifecycle and must not cascade away a pending chat purge job.

## Durable Storage cleanup queue

```sql
-- Conceptual schema only; do not apply directly.
chat_storage_deletion_jobs (
  id uuid primary key,
  deletion_job_id uuid not null,      -- FK to chat_deletion_jobs, not chat parent
  bucket_id text not null check (bucket_id = 'personax-memory-photos'),
  object_path text not null,
  resource_type text not null,
  resource_id uuid not null,
  status text not null,               -- queued | processing | retry | completed | dead_letter
  attempt_count integer not null default 0,
  next_attempt_at timestamptz,
  lease_until timestamptz,
  last_error_code text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (bucket_id, object_path)
)
```

The allowlist is deliberately limited to the chat-memory bucket. Never accept a client-supplied bucket name. The worker must additionally verify that every path belongs to the expected owner/resource prefix before deletion. Character asset buckets (`character-illustrations`, `character-avatar-videos`) are prohibited.

## Atomic soft-delete transaction

For both RPCs, one transaction must:

1. Authenticate and verify the caller owns the target resource; reject pending account deletion.
2. Lock the parent row first (`chat_sessions` or `chat_groups`) using `FOR UPDATE`; re-check it is not already deleted while holding the lock.
3. Set `deleted_at` once (do not overwrite the original timestamp on retries); for groups, preserve `archived_at` semantics independently.
4. Insert/upsert one `chat_deletion_jobs` row with `purge_after = deleted_at + interval '30 days'`.
5. Snapshot every chat-memory Storage object path into `chat_storage_deletion_jobs` before any relational parent/child deletion can occur.
6. Return success only after both the lifecycle marker and durable jobs commit together.

The user UI hides the chat immediately. No message bodies, snapshots, memories, album data or generation content are cleared at this stage.

## Writer lock order and post-delete behavior

All write paths must acquire locks in one order:

1. parent session/group row;
2. turn/reservation/charge row;
3. wallet row;
4. message/evidence rows.

New sends, generation reservations, new assistant messages, memory uploads, edits, encounter evidence, affinity writes and diary writes must reject a deleted parent. Existing pre-delete reservations may complete only through a narrow settle/refund/reconciliation path that is idempotent and cannot create new chat content. This exception must be explicitly tested.

## Billing and generation evidence decoupling

The current schema has non-null FK columns that prevent parent/message purge:

- `chat_turn_charges.session_id` NOT NULL → `chat_sessions.id ON DELETE CASCADE`
- `chat_turn_charges.user_message_id` NOT NULL → `chat_messages.id ON DELETE RESTRICT`
- `chat_turn_charges.assistant_message_id` nullable → `chat_messages.id ON DELETE SET NULL`
- `chat_group_turn_charges.group_id` and `group_turn_id` NOT NULL → group/turn CASCADE
- `chat_turn_events.turn_id` → charge `turn_id ON DELETE CASCADE`
- `ai_generation_records.session_id`, `user_message_id`, `assistant_message_id` are NOT NULL and have NO ACTION FKs.
- `chat_message_versions.message_id` is NOT NULL with NO ACTION FK.

Proposed strategy (requires a separate reviewed migration and backfill plan):

- Add immutable non-FK reference columns such as `session_ref`, `user_message_ref`, `group_ref`, `group_turn_ref`, and any needed message reference snapshots.
- Backfill them from current FK values and verify 100% coverage before changing constraints.
- Make only the chat FK columns nullable where necessary, then change/delete FK constraints so retained ledger rows can detach from purged chat parents. Do not remove user_id, amounts, currency/asset type, reserved/settled/refunded amounts, status, request/idempotency keys, timestamps or charge/refund event history.
- Preserve `chat_turn_events` independently of chat parent rows; its FK to charge turn identity may remain only if the charge row itself is retained permanently under the billing retention policy.
- For `ai_generation_records`, preserve minimal operational metadata only if required; purge or redact `original_content` and detach session/message references after 30 days. This must be a field-level policy, not an assumption that raw prompts/responses are financial records.
- Delete `chat_message_versions` as chat content at the 30-day purge stage, before deleting messages. Never create new versions as a side effect of the purge worker.
- Wallet transaction ledger is independent and must never be deleted as part of chat cleanup.

Do not implement the FK changes until uniqueness/index dependencies, RPC references, all downstream queries, and rollback/backfill behavior are inspected.

## 30-day worker behavior

- Service-role only; no client-callable purge RPC.
- Claim due jobs using row locks and `SKIP LOCKED`; set a lease so crashed workers can be recovered.
- Idempotently remove Storage objects using the durable Storage queue; retries use bounded exponential backoff and dead-letter after a configured maximum, with monitoring/alerting.
- Relational purge order follows the verified FK graph: remove chat-only children and versions; detach retained financial/operational evidence; remove messages/turns/scenes/diaries/photos; delete the parent last.
- The relational purge may proceed even if Storage removal is failing because the object path is already durable in the separate queue. The Storage queue remains until success/dead-letter.
- Every operation is repeat-safe. A retry after partial success must not double-refund, double-charge, or delete unrelated assets.
- Never log message text, prompts, image URLs with signed tokens, or raw storage object contents in error fields.

## Required acceptance tests

- Soft-delete transaction is atomic: either marker + both queues exist, or none do.
- Duplicate delete requests do not reset the 30-day clock or duplicate queue items.
- Single and group delete behavior, player-visible semantics and retention window are identical.
- All client SELECT/UPDATE/INSERT/DELETE paths fail closed immediately after deletion, including direct REST and Storage paths.
- Delete racing send/reserve/assistant insert/photo upload/evidence/affinity/diary writes is serialized by parent-first locking.
- Pre-delete reservations settle/refund exactly once; post-delete reservations cannot start.
- Wallet transactions, charge/refund records and required audit evidence survive relational purge.
- AI generation raw content is removed according to the approved retention policy.
- Storage failure retries without losing object paths; dead-letter is observable and recoverable.
- Only `personax-memory-photos` objects are eligible; character illustrations/videos and character snapshots survive.
- Worker is not scheduled in production until rollback-only tests, test DB verification and explicit approval pass.

## Open decisions / blockers

1. Establish an authoritative schema baseline and prove migration replay in a disposable environment. The current repository has duplicate timestamp prefixes and the test DB history differs substantially.
2. Confirm whether AI generation metadata (excluding raw content) must be retained and for how long.
3. Inspect all downstream consumers before nullable FK/backfill changes.
4. Determine Storage signed URL lifetime and refresh paths so deleted chats cannot reissue access during the 30-day backend buffer.
5. Only after the above, convert this proposal into executable migrations and tests.
