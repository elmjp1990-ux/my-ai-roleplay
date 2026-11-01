# Chat deletion worker runbook — test project

Date: 2026-11-01  
PR: #200  
Function: `purge-chat-deletions`  
Project: `ouyewoagbmtqehbofrje`  
Status: worker source deployed ACTIVE as version 9 to the test project. Version 9 adds explicit boolean-result checks for relational purge and Storage job completion. Earlier valid/invalid key authentication, disposable single/group content + Storage purge E2E, and missing-object idempotency passed; v9 source is verified deployed but has not yet had a fresh Dashboard invocation. Not scheduled.

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
- Historical manual `pg_net` POST invocation using the Vault secret returned HTTP 200 with empty queues; this was not a recurring schedule. The latest live invocation was performed through Supabase Dashboard Test (not SQL/pg_net) on 2026-11-01 and returned `chat_claimed=1, chat_purged=1, chat_failed=0, storage_claimed=2, storage_deleted=2, storage_failed=0`. It confirmed one synthetic relational job purge and two Storage jobs completed; one missing legal object path was treated as idempotent success. A traversal-shaped path also completed without Storage API error and is not failure-test evidence.
- No pg_cron, external cron, Vercel Cron, or other schedule has been created.
- The SQL claim/purge/retry RPCs have been exercised inside rollback-only test transactions and the real Worker has completed disposable single-chat and group-chat due-job fixtures.
- Actual Storage API upload/remove was verified for both single and group fixture objects; both objects were confirmed missing after the worker ran.

## Before enabling any schedule

1. Missing-object idempotency has now been confirmed through the live Dashboard invocation. DB retry/backoff/dead-letter behavior passed rollback-only tests, and Worker source routes Storage remove errors to the retry RPC. A real Storage API failure response flowing through the live Worker remains unverified: Supabase exposes no supported fault-injection parameter, and modifying `storage` schema is prohibited. Treat this as an external validation limitation, not a pass.
2. No account-deletion Edge Function or account-wide Storage sweep is currently deployed in this test project. The account-deletion workflow still has separate blockers (including group-charge archive and orphan chat-content coordination) tracked for PR #201; do not treat that workflow as complete.
3. Obtain explicit approval before creating any chat purge cron schedule; production scheduling requires separate approval.

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
## Concurrency and account-deletion FK review — 2026-11-01

### True two-transaction race tests (passed)

- Delete-vs-message insert: transaction A locked the session parent, paused, then called the authenticated soft-delete RPC. Transaction B attempted a new user-message insert while A held the lock. After A committed the delete marker, B was rejected by `guard_chat_turn_assistant_insert` with `chat_session_not_found_or_deleted`; the contender message row was not inserted.
- Delete-vs-reserve: transaction A locked and soft-deleted a separate synthetic session. Transaction B called `reserve_chat_turn` as the service role while A held the lock. After A committed, B was rejected with `chat_session_not_owned_or_active`; no charge row or wallet transaction was created.
- Delete-vs-encounter evidence: a synthetic Encounter session was provisioned with a valid active lifecycle, user/assistant messages, and a settled synthetic charge. Transaction A locked and soft-deleted the parent. Transaction B called `record_encounter_session_turn_evidence` while A held the lock; after A committed, B was rejected with `Encounter chat is deleted or not owned`; no encounter evidence row was created.
- All synthetic sessions, messages, lifecycle rows, charges, deletion jobs and test markers were cleaned. Final check: zero concurrency fixtures, zero synthetic charge rows, zero evidence rows, and both deletion queues empty.

### Account-deletion cascade structural review (not yet full transaction E2E)

- `chat_deletion_jobs` intentionally has no FK to `auth.users`, `chat_sessions`, or `chat_groups`; owner/resource IDs are immutable snapshots. Therefore account deletion of a user/chat parent does not directly cascade-delete the relational deletion job.
- `chat_storage_deletion_jobs` has one FK to `chat_deletion_jobs.id` with `ON DELETE CASCADE`, and no FK to `auth.users`, session, or group. It survives user/chat parent deletion as long as the relational job row is retained.
- `chat_sessions.user_id`, `chat_groups.owner_id`, and chat-memory photo owner/session/group references do cascade from Auth/chat parents. The purge worker's orphan-parent handling and independent queue are intended to finish Storage cleanup after these parents are gone.
- `prepare_account_deletion` archives `chat_turn_charges` and `chat_turn_events` before deleting source rows; it also archives AI generation and wallet transactions through the account archive path. `finalize_account_deletion` only marks completion after the Auth user no longer exists.
- A rollback-safe transaction probe inserted a synthetic Auth user, profile, single/group parent rows and two relational + two Storage queue rows, then deleted the Auth user. Before forced rollback, the observed state was: Auth user/profile/session/group parents = 0; relational deletion jobs = 2; Storage deletion jobs = 2. The exception rolled the entire probe back; a follow-up query confirmed zero synthetic Auth user/profile/jobs persisted. This proves parent cascades leave the durable queues intact in the tested schema.
- The account deletion worker/Storage-prefix cleanup must be audited separately to ensure it does not delete chat deletion queue rows or sweep character illustration/video assets.
## Charge-bearing purge and Auth cascade rollback probes — 2026-11-01

- Charge-bearing purge probe (explicit rollback): created a synthetic single session with one user and one assistant message, a valid settled `chat_turn_charges` row, one `chat_turn_events` row, and a matching `wallet_transactions` row. Marked the session due, claimed the job, and called the actual `purge_chat_deletion_job` RPC. Before forced rollback, verification returned: job `completed`; session snapshot/data empty; both message rows retained with empty content; settled charge row preserved; turn event preserved; wallet transaction preserved. The custom exception rolled the transaction back, and a follow-up query confirmed zero fixture/session/charge/event/wallet/job rows persisted.
- Auth cascade probe (explicit rollback): inserted a synthetic Auth user (trigger-created profile), session, group, two relational deletion jobs and two Storage jobs; deleted the Auth user. Before forced rollback, Auth user/profile/session/group parent counts were zero while both relational jobs and both Storage jobs remained. The custom exception rolled the transaction back; follow-up query confirmed zero synthetic rows persisted.
- These probes close the charge-bearing purge and Auth-parent cascade database checks without deleting an existing test account or leaving test data.
- Remaining gates: actual Storage API failure/retry/dead-letter and missing-object idempotency; review any account-deletion Storage sweep worker (none is deployed as a Supabase Edge Function in this project) to ensure it cannot sweep character assets or pending chat queues. No recurring chat purge schedule exists.
## Account-deletion Storage sweep inventory — 2026-11-01

- Active Supabase Edge Function inventory contains no account-deletion worker. The only related photo lifecycle function is `expire-memory-album-photos` v2; it selects expired `chat_memory_photos` metadata and removes objects only from `personax-memory-photos`. It is an expiry worker, not an account-wide Storage sweep, and it does not target character asset buckets.
- The only active `cron.job` is `poyozz-encounter-evaluation-dispatch` every minute. There is no chat-deletion schedule and no account-deletion schedule in Supabase Cron.
- `storage.objects` has a FK only to `storage.buckets`; there is no owner_id FK to `auth.users`. Therefore Auth user cascade does not automatically delete Storage object blobs/metadata.
- Existing private buckets are `personax-memory-photos`, `character-illustrations`, and `character-avatar-videos`, all with MIME restrictions. A future account-deletion worker must enumerate/delete only the target account's objects with bucket-specific ownership checks, coordinate with pending chat Storage jobs, and explicitly preserve or transfer character assets according to the separate character-deletion policy.
- No Storage sweep code was changed in this PR. The account-wide Storage cleanup remains a separate required implementation before account deletion can be marked complete.

## Final acceptance update — 2026-11-01

- Worker v9 is ACTIVE in the test project and its deployed source matches the PR branch. It now requires the boolean return from both `purge_chat_deletion_job` and `mark_chat_storage_deletion_job` to be exactly `true` before incrementing the corresponding success counter. This prevents a stale/lost lease (RPC returns false without transport error) from being reported as a successful completion.
- The v9 deployment was source-verified; a fresh Dashboard invocation after this v9 deployment has not yet been performed. Earlier Dashboard invocation and real disposable single/group + PNG E2E were against the prior function source. The v9 change only tightens result accounting, but must not be described as a new E2E run.
- Current queue readback: one completed synthetic parent tombstone remains; no Storage child rows and no Storage queue jobs. No chat deletion Cron exists; the only active Cron is the pre-existing `poyozz-encounter-evaluation-dispatch`.
- One synthetic parent tombstone ID `46d4c421-d490-4357-9e2b-7bf7802d19e7` is completed, has no error/next retry, and has zero Storage children. Direct SQL cleanup was blocked by the pre-existing `storage.protect_delete()` platform guard; no bypass was attempted. Keep as documented harmless test residue pending supported cleanup.
- The test DB migration history is materially drifted from repository history (141 historical live entries before this PR's 10 migrations, 96 repository SQL files, many shared names with version-prefix mismatches and duplicate repository prefixes). Do not assume a fresh replay or repair remote history by hand. Migration replay needs a separately reviewed disposable-environment plan before launch.
- Current PR head after v9 source correction: `0ee2899db4f6629f48b906b55ade41c1b15f505a`. Vercel preview deployment completed; the `inline-javascript-syntax` GitHub Actions check passed. PR remains Draft.
- No new cron, no production changes, no account deletion, no real chat/object deletion during this final pass.
