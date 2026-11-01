# Chat deletion worker runbook — test project

Date: 2026-11-01  
PR: #200  
Function: `purge-chat-deletions`  
Project: `ouyewoagbmtqehbofrje`  
Status: stable worker source deployed ACTIVE as version 8 to the test project; valid/invalid key authentication and full disposable single/group content + Storage purge E2E passed; not scheduled.

## Purpose

Process the shared 30-day deletion queues for single and group chats. The worker is service-role-only and handles relational content purge first, then chat-memory Storage objects.

## Safety contract

- Only process jobs where `purge_after <= now()`.
- The relational purge retains minimal session/group/message/turn tombstones so charge and wallet evidence foreign keys remain valid.
- It clears chat message content, message versions, AI raw content, chat snapshots, encounter/story summaries and chat-only diary/media metadata.
- It preserves `chat_turn_charges`, `chat_group_turn_charges`, `chat_turn_events`, wallet ledger rows, group turn IDs, and global encounter affinity state.
- Storage deletion is restricted to `personax-memory-photos`; character illustration/video buckets are not accepted.
- Storage paths are copied into the durable Storage queue before any chat photo metadata is purged.
- Failures are retried with bounded exponential backoff; after eight attempts they become `dead_letter`.
- Never log object paths, signed URLs, message content, prompts, or raw error messages.

## Invocation

The Edge Function uses Supabase's official `@supabase/server` wrapper with `auth: 'secret:default'`. Platform `verify_jwt` is disabled for this function only; the wrapper validates the named Secret Key on the `apikey` header before the handler runs. The handler uses `ctx.supabaseAdmin` only after successful secret-key validation.

The test project's `default` Secret Key is stored in Vault under `chat_deletion_worker_service_role_key`. The function source and `supabase/config.toml` are tracked in PR #200. Never place the key in browser code, a public repository, or a user-facing client.

The function processes at most:
- 10 due relational chat deletion jobs per invocation.
- 50 due Storage object jobs per invocation.

The response contains counts only; it does not return chat IDs or object paths.

## Current deployment controls

- Function is deployed only to the test Supabase project.
- `pg_net` 0.20.4 is enabled in the `extensions` schema; `pg_cron` 1.6.4 remains enabled.
- One manual `pg_net` POST invocation using the Vault secret returned HTTP 200 with all chat/Storage counts equal to zero. No persistent jobs were present or modified.
- No pg_cron, external cron, Vercel Cron, or other schedule has been created.
- The SQL claim/purge/retry RPCs have been exercised inside rollback-only test transactions and the real Worker has completed disposable single-chat and group-chat due-job fixtures.
- Actual Storage API upload/remove was verified for both single and group fixture objects; both objects were confirmed missing after the worker ran.

## Before enabling any schedule

1. Run true two-transaction concurrency tests for delete-vs-reserve, delete-vs-message insert, and delete-vs-encounter evidence.
2. Verify Storage API failure/retry/dead-letter behavior and object-not-found idempotency against a real failed request.
3. Verify account deletion does not cascade-delete pending chat deletion jobs or Storage jobs.
4. Verify financial evidence retention with a fixture that includes valid charge/turn rows; the latest disposable E2E intentionally created no financial rows.
5. Obtain explicit approval before creating any cron schedule; production scheduling requires separate approval.

## Authentication and pg_net security notes

- Supabase's current service-to-service pattern accepts a Secret Key in `apikey` and validates it with `withSupabase({ auth: 'secret:<name>' })`; this replaces the legacy JWT role-claim parser.
- `pg_net` stores request headers in `net.http_request_queue` until dispatch. Supabase documents that any direct database login role can read those headers. The test project currently has only Supabase-managed login roles (no custom application login role); do not add custom direct-login roles while this scheduling pattern is in use.
- The request queue is not exposed through the Data API by default. Do not expose the `net` schema or add it to API-exposed schemas.
- Schedule remains intentionally absent until disposable single/group relational + Storage E2E and account-deletion interaction tests pass, and the user explicitly approves scheduling.

## Latest disposable E2E evidence — 2026-11-01

The stable worker source was temporarily extended with a secret-authenticated test-only probe to create synthetic fixtures, then redeployed from the tracked PR source. The deployed stable function is ACTIVE version 8 and does not contain the test probe.

- Single-chat fixture: created a disposable session, one user message, one message version, chat-memory photo metadata and a real PNG Storage object. The due-job worker retained the session tombstone, cleared session snapshot/data and message content, removed message versions and photo metadata, completed the relational and Storage jobs, and the Storage API confirmed the object was missing.
- Group-chat fixture: created a disposable group, scene, user turn/message, diary, photo metadata and a real PNG Storage object. The worker retained the group tombstone, removed group messages, redacted the retained turn request text to `[purged]`, removed diary/photo metadata, completed both jobs, and the Storage API confirmed the object was missing.
- Both fixture sets were cleaned after verification. Final checks: no test sessions/groups, no sentinel content, no deletion queue rows, no `_worker-e2e` photo metadata or Storage objects, and no pending pg_net requests.
- The E2E fixtures did not create financial charge rows; financial evidence retention remains supported by earlier rollback-only SQL tests and still needs a dedicated fixture containing valid charge/turn rows.
- No existing user chat or character asset was touched. No chat-deletion Cron schedule was created.