# Chat Deletion Retention Matrix and Reference Transition (Draft)

Date: 2026-11-01  
PR: #200 — `security/chat-deletion-lifecycle-reconciliation`  
Environment evidence: read-only catalog inspection of test project `ouyewoagbmtqehbofrje`.  
Status: design only; no executable migration and no database changes.

## 1. Governing rule

A user deleting a single chat or group chat starts one common 30-day deletion lifecycle. The 30-day period applies to chat content and chat-linked personal media. It does **not** automatically erase wallet/accounting evidence needed to explain charges, refunds, idempotency, or wallet history. The group model is one player with multiple AI characters, not a multi-user group.

At day 30, content eligible for purge is erased. Minimal financial audit evidence remains detached from chat parent/message foreign keys. Any retention period beyond the chat deletion window for financial/accounting records must follow the platform's separately approved retention policy; this document does not invent a statutory duration.

## 2. Field-level retention matrix

| Data | Current dependency / behavior | Proposed after user deletes chat | Day-30 purge |
|---|---|---|---|
| `chat_sessions` / `chat_groups` parent | Single session has `deleted_at`; group currently lacks it | Mark parent deleted atomically; keep tombstone and deletion job | Remove parent only after children and references are safely detached |
| `chat_messages.content` | Message IDs referenced by charge and generation records; message-version trigger captures OLD content on edits | Keep content inaccessible during 30-day grace period; block new writes | Hard-delete chat content; ensure purge path cannot create new versions |
| `chat_message_versions.content` | FK `message_id` NO ACTION | Inaccessible with deleted parent | Delete all versions for purged messages, unless separately approved content retention supersedes |
| `chat_turn_charges` financial fields | `session_id` CASCADE; `user_message_id` RESTRICT; assistant FK SET NULL; unique turn/assistant/user-message IDs | Preserve amount, silver/diamond reserved, status, timestamps, idempotency identifiers, and minimal non-content refs | Retain financial audit row; detach chat FK only after immutable reference snapshot is populated and verified |
| `chat_group_turn_charges` financial fields | `group_id` and `group_turn_id` both CASCADE; unique (group, request_key), unique group_turn_id | Preserve cost, member_count, silver/diamond charged, status, timestamps, request key, minimal refs | Retain financial audit row; detach group/group-turn FK after verified snapshot; never lose due to cascade |
| `chat_turn_events` | `turn_id` CASCADE to charge | Preserve event type, stage, attempt, retryable, duration, timestamps needed to explain billing lifecycle | Retain with charge; transition FK only after charge identity is durably retained |
| `wallet_transactions` | No chat FK; user_id FK to profiles; reference_id can identify turn | Preserve ledger rows and idempotency/reference values; no deletion from chat deletion | Never delete as part of chat purge |
| `ai_generation_records` | session/user_message/assistant_message FK NO ACTION and NOT NULL; assistant_message_id unique; (user_id, request_id) unique; stores `original_content` | Keep operational metadata and status needed for retry/idempotency; restrict content access after parent deletion | Clear `original_content`; preserve only approved metadata and immutable reference IDs; detach chat FKs after verified backfill |
| `encounter_session_turns` and evidence | Evidence references charge turn_id and chat message IDs; lifecycle/evaluation jobs read unsettled charges | Preserve pending settlement/reconciliation evidence until completed; reject new evidence writes after deleted parent | Retain only approved minimal affinity/audit evidence; no message content unless explicitly justified |
| `story_relationship_batches` | Validates source turn IDs against settled charge/session/user | Do not invalidate in-flight settlement or already committed relationship updates | Keep required source identity snapshots; remove content-bearing summaries only if policy says they are chat content |
| Chat memory photo rows + Storage objects | Photo rows reference chat parent; storage path can outlive parent | Hide immediately; enqueue exact bucket/path in durable storage job | Delete only `personax-memory-photos` objects; never delete character illustrations/videos |
| Character assets | Separate character illustration/video buckets | Not part of chat deletion | Never purge from chat deletion worker |

## 3. Reference snapshot requirements

Before changing any financial/generation FK, introduce immutable non-FK references sufficient for audit and idempotency:

- Single charge: `session_ref`, `user_message_ref`, `assistant_message_ref` (nullable where assistant was never persisted), and stable `turn_id`.
- Group charge: `group_ref`, `group_turn_ref`, stable request key, and charge row identity.
- Turn events: stable `turn_ref` independent of a charge-row FK.
- AI generation: `session_ref`, `user_message_ref`, `assistant_message_ref`, request ID, and generation row identity.

Do not assume UUID references alone are enough for wallet display. `get_my_wallet_transaction_character_names()` currently joins wallet reference_id → chat_turn_charges → chat_sessions and filters deleted sessions. Preserve a safe character display snapshot or update this read path so wallet history remains understandable after chat parent purge, without restoring access to deleted chat content.

## 4. Migration / backfill gates

1. Confirm disposable baseline can replay without touching the current test DB migration history.
2. Inventory every SQL function and application consumer for affected columns, including wallet history, charge reserve/settle/refund, assistant guards, group append, encounter evidence/evaluation, story relationship validation, and account-deletion archive routines.
3. Add reference snapshot columns as nullable, write snapshots for all new rows, and backfill existing rows in bounded batches.
4. Verify zero missing/mismatched references, preserve all unique/idempotency constraints, and compare row counts/checksums.
5. Introduce FK transition in a separate reviewed migration; never drop CASCADE constraints before references are verified.
6. Add regression tests for reserve/settle/refund exactly-once, group charge retention, turn event retention, wallet history rendering, encounter settlement, account deletion archive, and rollback.
7. Only then implement hard purge and worker scheduling. Worker/cron remains disabled until separately accepted.

## 5. Open policy decisions (not silently assumed)

- Exact retention period for wallet/accounting evidence after chat deletion.
- Which AI generation metadata fields are necessary after raw `original_content` is cleared.
- Whether encounter affinity/diary summaries are considered chat content or a separately retained relationship record.
- Whether wallet character-name display snapshots should be stored at charge creation or materialized during FK decoupling.

## 6. Explicit non-goals

- No changes to wallet pricing, silver/diamond order, charge amounts, refunds, or signup bonuses.
- No deletion of character illustration or avatar-video assets.
- No production schema changes, cron, or worker deployment.
- No executable migration in this document.
