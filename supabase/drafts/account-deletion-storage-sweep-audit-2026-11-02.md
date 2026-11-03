# Account deletion — Storage lifecycle and sweep audit — updated 2026-11-03

Repository: `elmjp1990-ux/my-ai-roleplay`
PR: #200 — Draft / unmerged
Environment: test project only; no real users. This document is a source/schema audit and implementation plan. No hosted DDL/DML, Auth mutation, Storage mutation, deployment, or Cron change was performed.

## User-confirmed account deletion policy

- Preserve every authored character and its child data, including private settings, schedules, stories, illustrations and avatar videos.
- Preserve the character's existing public/private visibility and review state. Do not force public works to private.
- Public works keep the historical creator display name as plain text only; no live author profile, avatar, handle link, follow/message/management entry.
- Character status is offline after account deletion; all new chat, group-member, encounter and story entry is blocked server-side.
- Other players' existing solo/group/encounter conversations continue, including the character's replies and the normal billing rules.
- Character illustration/video Storage objects remain attached to retained character rows. Account deletion must never enqueue them in `character_asset_cleanup_jobs` or send them to `purge-character-assets`.

This supersedes the earlier proposal in this document to force all authored characters private. The current product rule is offline + no new entry while preserving original visibility/review state.

## Storage buckets and ownership boundaries

### Character assets — retain

- Buckets: `character-illustrations`, `character-avatar-videos`.
- Their metadata remains in `character_illustrations.storage_path` and `characters.avatar_video_path`.
- Account deletion detaches the active author identity and preserves a plain-text creator attribution; it does not remove character rows or media.
- `character_asset_cleanup_jobs` and `purge-character-assets` are exclusively for a never-published, history-free draft that qualifies for hard deletion. They are not an account-deletion sweep.
- Existing-player asset access is authorized through exact existing session/character relationship checks; stale/deleted author JWTs must not retain author-management or asset privileges.

### Chat-memory photos — separate from character assets

The disposable current-state schema manifest confirms:

- `chat_memory_photos` has cascading FKs from `session_id → chat_sessions`, `group_id → chat_groups`, and `owner_id → auth.users`.
- `chat_group_memory_photos` has cascading FKs from `group_id → chat_groups` and `owner_id → auth.users`.
- `chat_deletion_jobs` has no FK to Auth users or chat parents.
- `chat_storage_deletion_jobs` references `chat_deletion_jobs(id) ON DELETE CASCADE`, not the Auth user or chat parent. Therefore an already-created deletion job and its Storage child jobs can survive Auth cascade, provided their parent job is not removed.
- The normal single/group chat deletion RPCs enqueue `personax-memory-photos` object paths into `chat_storage_deletion_jobs` before soft deletion. The 30-day chat purge worker processes only this bucket and must not accept character asset buckets.

### Identified account-deletion gap — active chat photo paths

The active-photo gap is now addressed in the PR #200 draft integration:

- `private.enqueue_account_chat_memory_photo_cleanup()` is called inside the locked `prepare_account_deletion()` transaction, only after the exact request has reached its scheduled execution time. A cancellation that wins before prepare creates no photo cleanup jobs.
- It enumerates `chat_memory_photos` owned by the account, validates the owner-prefixed exact Storage path and verifies the parent session/group belongs to the same account.
- It creates or reuses one parent `chat_deletion_jobs` row per solo/group resource and one `chat_storage_deletion_jobs` row per exact object path. Both queues have no Auth/session/group FK and survive the Auth cascade.
- The photo retention clock is independent of the environment's account grace period: active account-owned photos are due at `requested_at + 30 days`, even when the test environment uses a shorter account grace period. Already-soft-deleted chats keep their original `deleted_at + 30 days` clock.
- Existing queued jobs are not rewritten. Conflicting owner/resource/path associations fail closed. The Storage queue remains restricted to `personax-memory-photos`; character asset buckets are impossible to enqueue.
- The legacy `chat_group_memory_photos.image_url` table is not currently referenced by the application UI, which reads group photos from `chat_memory_photos.storage_path`. Legacy rows remain excluded from automatic deletion until their historical URL formats and Storage ownership can be proven; no arbitrary URL is passed to Storage.remove.

Existing pending chat deletion jobs remain independent: their parent job has no Auth FK, so the existing queue survives the account cascade. The account flow does not delete, cancel, rewrite or detach those pending jobs or their Storage children.

## Required work before enabling account deletion

1. Preserve character illustration/video rows and objects; add an invariant that account deletion never inserts them into the character asset cleanup queue.
2. Before Auth cascade, capture active account-owned chat-memory photo paths into a durable queue that survives Auth deletion. Preserve existing queued deletion jobs exactly; do not create duplicate/conflicting bucket/path jobs.
3. Verify the chosen independent 30-day account-photo retention clock in disposable SQL behavior tests, including the shorter test-environment account grace period. Do not derive the photo purge deadline from the environment-specific `scheduled_for` value.
4. Audit legacy `chat_group_memory_photos.image_url` records and any external/Storage references separately; never pass a URL directly to Storage.remove.
5. Complete rollback-only SQL tests for: active solo/group photo path queueing; already-pending deletion job preservation; queue survives Auth cascade; no duplicate object path; character assets never queued; malformed/foreign-owner paths fail closed.
6. Add a disposable Storage E2E for the chosen retention policy, including a live Storage API failure/retry path before enabling any worker or Cron.

## Current implementation / release status

- The account character-preservation draft and `prepare_account_deletion()` integration preserve character records/media and snapshot the author's own chat character-turn counts before Auth cascade.
- Account deletion worker remains hard-disabled in source and returns 503 before claiming work or calling destructive RPC/Auth operations.
- Character asset cleanup worker is implemented and has deterministic tests but is not deployed.
- Test-project `purge-chat-deletions` worker v9 is deployed; no chat purge Cron is enabled.
- The account-owned `chat_memory_photos` queue integration and solo/group cascade assertions have now been added to the PR #200 draft SQL/test fixture. The new HEAD still requires same-SHA CI execution before this is considered validated.
- PR #200 remains Draft / unmerged. No hosted rollout or schedule activation.

## Explicit safety boundary

Do not use the character asset cleanup worker for account deletion. Do not delete character illustration/video objects. Do not remove existing chat deletion jobs or their Storage child jobs as part of account deletion. The user has explicitly chosen 30-day retention for account-owned chat-memory photos; keep that clock independent from the environment-specific account grace period. No hosted DDL/DML, Storage mutation, worker deployment, or Cron activation without explicit approval.


## Legacy group-photo URL classification — 2026-11-03

A read-only aggregate query against the connected test project inspected public.chat_group_memory_photos without returning any URL values:

- Total legacy rows: 1.
- Empty URL rows: 0.
- Absolute URLs: 1.
- Relative/object-path values: 0.
- Supabase Storage object URLs: 0.
- URLs identifying the personax-memory-photos bucket: 0.

The one legacy value is therefore not a provable object path in the current chat-memory bucket. It is deliberately excluded from automatic Storage cleanup. Do not parse arbitrary external URLs, infer a bucket, or pass image_url to Storage.remove. Its relational metadata can be removed by the normal 30-day group purge; the external URL is not treated as a managed Storage object.

A static regression guard was added to scripts/test-account-deletion-character-preservation-draft.mjs to ensure the account photo queue helper never reads chat_group_memory_photos or image_url. The same guard now checks that single/group frontend deletion calls the lifecycle RPCs, persists tombstones, filters stale cached chats/groups, and exposes no player-facing restore/undo/reopen action or restore RPC call.

This is a classification of the current test-project row only; it does not establish that every historical deployment used the same URL format. If future evidence identifies a managed Storage object, add a separate exact-bucket + exact-owner-path migration/queue design rather than widening the existing cleanup helper.


## Account-photo queue parent timestamp reconciliation — 2026-11-03

A follow-up review found an interrupted-account-deletion edge case: account prepare could enqueue a chat-photo cleanup job with `deleted_at = requested_at` while leaving the still-existing `chat_sessions` / `chat_groups` parent `deleted_at` as NULL. If the Auth cascade had not completed by the time the 30-day job was claimed, `purge_chat_deletion_job()` would correctly reject the mismatched parent/job timestamps and retry until dead-letter.

The draft helper now, under the already-acquired parent lock and after revalidating the photo row, soft-deletes the exact owned parent using the same `v_deleted_at` timestamp used by the queue. Existing soft-deleted parents keep their original timestamp. It also processes solo parents first in stable ID order, then group parents, matching `snapshot_account_chat_character_history()` lock order and avoiding an inverse-order lock pattern.

The disposable behavior test now uses an expired 31-day request / 30-day account grace fixture, asserts both parent timestamps equal the queued `requested_at`, invokes the real `claim_chat_deletion_jobs()` and `purge_chat_deletion_job()` while both parent rows still exist, and verifies the jobs complete before the later Auth cascade. The service-role test claim intentionally has no end-user `sub`, matching the account worker's internal service context and allowing the existing owner-update guard to distinguish it from a browser user's update.

The account workflow path filter was also corrected to trigger when `test-account-deletion-character-preservation-behavior.sql` changes. A pre-existing `new RegExp()` string-escape defect in the static test harness was corrected so whitespace-crossing assertions work as intended. Await same-HEAD disposable schema replay and local synthetic replay before accepting this fix. No hosted mutation or worker deployment was performed.
