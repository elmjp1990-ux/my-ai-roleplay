# Chat Deletion Retention Matrix and Reference Transition (Draft)

Date: 2026-11-01  
PR: #200 — `security/chat-deletion-lifecycle-reconciliation`  
Environment evidence: read-only catalog inspection of test project `ouyewoagbmtqehbofrje`.  
Status: retention policy draft; executable migrations have been applied to the existing test database. This document remains non-executable.

## Implementation decision — tombstone-based content purge (2026-11-01)

This section supersedes the earlier FK-decoupling / hard-delete proposal in sections 2–4 for the first implementation.

- Day 0: mark the parent deleted, immediately hide it through RLS and enqueue the shared 30-day relational and Storage jobs.
- Day 30: clear chat content and chat-specific metadata, but retain minimal parent/message/turn tombstones. This avoids deleting rows still referenced by billing and AI-generation FKs.
- Single chat: keep `chat_sessions` and `chat_messages` IDs; clear `chat_sessions.session_data` and `character_snapshot`; set message `content=''` and `deleted_at`; delete `chat_message_versions`; clear `ai_generation_records.original_content`.
- Group chat: keep `chat_groups` and `chat_group_turns` IDs; replace group name with `已刪除對話`, clear world/player text; delete group messages, diary, scenes, members and photo metadata; set each group turn's request text to the neutral tombstone marker `[purged]`.
- Preserve `chat_turn_charges`, `chat_group_turn_charges`, `chat_turn_events`, `wallet_transactions`, and their reference IDs. No financial FK decoupling is required for this first-pass tombstone strategy.
- Preserve `chat_sessions.character_name` so the user's own wallet history can still show the character label; `get_my_wallet_transaction_character_names()` no longer filters deleted sessions.
- Clear encounter evaluation/schedule payloads and story summaries/imported memories belonging to the deleted session; delete encounter diary entries tied to that session and null the matching receipt diary IDs. Preserve global `encounter_character_state` affinity and interaction receipts.
- Storage objects remain in `chat_storage_deletion_jobs` until the service-role worker removes them. The queue survives parent/account cascades because it has no parent/user FK.

The earlier reference snapshot/backfill sections describe a possible future hard-delete design, not the current implementation. Do not apply FK changes unless a separate reviewed decision replaces this tombstone strategy.

## 1. Governing rule

A user deleting a single chat or group chat starts one common 30-day deletion lifecycle. The 30-day period applies to chat content and chat-linked personal media. It does **not** automatically erase wallet/accounting evidence needed to explain charges, refunds, idempotency, or wallet history. The group model is one player with multiple AI characters, not a multi-user group.

At day 30, content eligible for purge is erased. Financial audit evidence remains attached to minimal tombstone parent/message/turn rows; those IDs are not hard-deleted by the chat purge. Any retention period beyond the chat deletion window for financial/accounting records must follow the platform's separately approved retention policy; this document does not invent a statutory duration.

## 2. Field-level retention matrix

| Data | Current dependency / behavior | Proposed after user deletes chat | Day-30 purge |
|---|---|---|---|
| `chat_sessions` / `chat_groups` parent | Both now have `deleted_at`, distinct from group `archived_at` | Mark parent deleted atomically; keep tombstone and deletion job | Retain minimal parent row; clear session snapshots or group world/player text and set a generic group label |
| `chat_messages.content` | Message IDs are referenced by charge and generation records; message-version trigger captures OLD content on edits | Keep content inaccessible during 30-day grace period; block new writes | Set `content=''`, set `deleted_at`, retain message IDs/rows as billing tombstones; delete versions without creating new ones |
| `chat_message_versions.content` | FK `message_id` NO ACTION | Inaccessible with deleted parent | Delete all versions for purged messages, unless separately approved content retention supersedes |
| `chat_turn_charges` financial fields | `session_id` CASCADE; `user_message_id` RESTRICT; assistant FK SET NULL; unique turn/assistant/user-message IDs | Preserve all charge/refund fields and reference IDs | Keep charge rows and referenced session/message tombstones; no FK detachment in this phase |
| `chat_group_turn_charges` financial fields | `group_id` and `group_turn_id` both CASCADE; unique (group, request_key), unique group_turn_id | Preserve cost, member_count, silver/diamond charged, status, timestamps, request key and IDs | Keep charge rows and referenced group/group-turn tombstones; clear group-turn request text to `[purged]` |
| `chat_turn_events` | `turn_id` CASCADE to charge | Preserve event type, stage, attempt, retryable, duration, timestamps needed to explain billing lifecycle | Retain with charge; transition FK only after charge identity is durably retained |
| `wallet_transactions` | No chat FK; user_id FK to profiles; reference_id can identify turn | Preserve ledger rows and idempotency/reference values; no deletion from chat deletion | Never delete as part of chat purge |
| `ai_generation_records` | session/user_message/assistant_message FK NO ACTION and NOT NULL; assistant_message_id unique; (user_id, request_id) unique; stores `original_content` | Keep metadata inaccessible through deleted parent RLS | Clear `original_content`; retain IDs/FKs and non-content operational metadata |
| `encounter_session_turns` and evidence | Evidence references charge turn_id and chat message IDs; lifecycle/evaluation jobs read unsettled charges | Reject new evidence writes after deleted parent; preserve global affinity | Clear per-session evaluation payloads and schedule/settlement snapshots; delete session-linked diary content, null receipt diary IDs, retain idempotency receipts and global affinity state |
| `story_relationship_batches` | Validates source turn IDs against settled charge/session/user | Do not invalidate in-flight settlement or already committed relationship updates | Keep required source identity snapshots; remove content-bearing summaries only if policy says they are chat content |
| Chat memory photo rows + Storage objects | Photo rows reference chat parent; storage path can outlive parent | Hide immediately; enqueue exact bucket/path in durable storage job | Delete only `personax-memory-photos` objects; never delete character illustrations/videos |
| Character assets | Separate character illustration/video buckets | Not part of chat deletion | Never purge from chat deletion worker |

## 3. Earlier hard-delete reference snapshot alternative (not current implementation)

Before changing any financial/generation FK, introduce immutable non-FK references sufficient for audit and idempotency:

- Single charge: `session_ref`, `user_message_ref`, `assistant_message_ref` (nullable where assistant was never persisted), and stable `turn_id`.
- Group charge: `group_ref`, `group_turn_ref`, stable request key, and charge row identity.
- Turn events: stable `turn_ref` independent of a charge-row FK.
- AI generation: `session_ref`, `user_message_ref`, `assistant_message_ref`, request ID, and generation row identity.

Do not assume UUID references alone are enough for wallet display. `get_my_wallet_transaction_character_names()` currently joins wallet reference_id → chat_turn_charges → chat_sessions and filters deleted sessions. Preserve a safe character display snapshot or update this read path so wallet history remains understandable after chat parent purge, without restoring access to deleted chat content.

## 4. Migration / backfill gates for any future hard-delete redesign

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
- Current first-pass decision: preserve global encounter affinity; delete session-linked encounter diary content and clear session evaluation payloads. Revisit only if product requirements change.
- Wallet label decision: retain `chat_sessions.character_name` and allow the user's own wallet-label RPC to read that label for deleted tombstone sessions; no chat content is exposed.

## 6. Explicit non-goals

- No changes to wallet pricing, silver/diamond order, charge amounts, refunds, or signup bonuses.
- No deletion of character illustration or avatar-video assets.
- No production schema changes or cron. A service-role Edge Function is deployed to the test project but has not been invoked or scheduled.
- No executable migration in this document.
