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

The current account-deletion prepare integration snapshots character-turn/history aggregates and archives billing/idempotency evidence, but it does not enqueue the storage paths of active account-owned `chat_memory_photos` before Auth deletion. Those photo metadata rows can be removed by the Auth/session/group cascade while the Storage objects remain in `personax-memory-photos`, leaving orphaned objects without a durable cleanup job.

Existing pending chat deletion jobs are a separate case: their parent job has no Auth FK, so the existing queue should survive the account cascade. The account flow must not delete, cancel, rewrite or detach those pending jobs or their Storage children.

`chat_group_memory_photos` is a legacy metadata table with an `image_url` column rather than the current `storage_path` shape. Its live usage and whether those URLs point to Storage objects must be classified before any cleanup is proposed; do not treat arbitrary URLs as Storage paths.

## Required work before enabling account deletion

1. Preserve character illustration/video rows and objects; add an invariant that account deletion never inserts them into the character asset cleanup queue.
2. Before Auth cascade, capture active account-owned chat-memory photo paths into a durable queue that survives Auth deletion. Preserve existing queued deletion jobs exactly; do not create duplicate/conflicting bucket/path jobs.
3. Decide and encode the retention clock for account-owned chat-memory photos. The existing chat deletion policy is 30 days from chat deletion; account deletion reaches its final worker phase after the account grace period. The current draft does not yet establish whether account-owned chat photo objects should be removed immediately at final account deletion or receive a fresh 30-day photo retention window. Do not invent a timestamp or bypass the queue's retention invariant.
4. Audit legacy `chat_group_memory_photos.image_url` records and any external/Storage references separately; never pass a URL directly to Storage.remove.
5. Add rollback-only SQL tests for: active solo/group photo path queueing; already-pending deletion job preservation; queue survives Auth cascade; no duplicate object path; character assets never queued; malformed/foreign-owner paths fail closed.
6. Add a disposable Storage E2E for the chosen retention policy, including a live Storage API failure/retry path before enabling any worker or Cron.

## Current implementation / release status

- The account character-preservation draft and `prepare_account_deletion()` integration preserve character records/media and snapshot the author's own chat character-turn counts before Auth cascade.
- Account deletion worker remains hard-disabled in source and returns 503 before claiming work or calling destructive RPC/Auth operations.
- Character asset cleanup worker is implemented and has deterministic tests but is not deployed.
- Test-project `purge-chat-deletions` worker v9 is deployed; no chat purge Cron is enabled.
- The latest PR #200 HEAD `c11028ef7491d2a9696ff095d8eda0b65edd3d6` passed disposable PostgreSQL deletion behavior/rollback and two-session concurrency tests, plus Local Supabase synthetic current-state schema replay. These tests do not yet cover the account-owned chat-photo queue gap identified above.
- PR #200 remains Draft / unmerged. No hosted rollout or schedule activation.

## Explicit safety boundary

Do not use the character asset cleanup worker for account deletion. Do not delete character illustration/video objects. Do not remove existing chat deletion jobs or their Storage child jobs as part of account deletion. Do not infer a new 30-day account-photo retention clock until it is explicitly decided and tested. No hosted DDL/DML, Storage mutation, worker deployment, or Cron activation without explicit approval.
