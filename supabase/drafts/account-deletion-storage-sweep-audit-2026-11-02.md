# Account deletion Storage-sweep audit — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`
PR: #200 — Draft / unmerged
Environment: connected Supabase test project; catalog/function definitions read only.
Scope: account deletion worker, chat Storage queue, character illustration/video asset lifecycle.
No DDL/DML, Auth mutation, Storage mutation, deployment, or Cron change was performed.

## Confirmed current behavior

### Account deletion worker

The current `account-deletion-worker` Edge Function orchestrates only:
- `get_account_deletion_work_items()`
- `archive_account_deletion_data()`
- `prepare_account_deletion()`
- Auth Admin user lookup/delete
- `finalize_account_deletion()`
- `record_account_deletion_failure()`

It does not enumerate, queue, or remove Storage objects.

### Chat-memory objects

- Private bucket: `personax-memory-photos`.
- `chat_deletion_jobs` has no FK to chat parents or Auth users, so its retention job can survive account/profile/Auth cascade.
- `chat_storage_deletion_jobs.deletion_job_id` references `chat_deletion_jobs(id) ON DELETE CASCADE`.
- The storage claim RPC only claims storage jobs after their parent chat-deletion job is completed and its 30-day `purge_after` is due.
- Chat deletion RPCs snapshot chat-memory object paths into that queue before marking the parent deleted.
- The account deletion prepare function does not explicitly delete either queue. Auth cascades can remove the chat parent and `chat_memory_photos` metadata, but the independent chat-deletion job remains available to gate the later Storage cleanup.

This is consistent with preserving the chat's 30-day retention policy even if the account is deleted earlier, provided the queue and worker remain operational.

### Character assets

The test project has private buckets:
- `character-illustrations`
- `character-avatar-videos`

The relational structure confirms:
- `characters.author_id` references `profiles(id) ON DELETE CASCADE`.
- `character_illustrations.author_id` references `profiles(id) ON DELETE CASCADE`.
- `character_illustrations.character_id` references `characters(id) ON DELETE CASCADE`.
- `characters.avatar_video_path` stores the avatar-video object path.
- `character_illustration_cleanup_jobs` is an owner-scoped queue used by browser code for failed-upload/temporary illustration cleanup. It is not an account-deletion worker queue and no database trigger was found on `characters` or `character_illustrations` to enqueue account-deletion cleanup.

When Auth/profile cascade removes a user's character and illustration rows, Storage objects do not automatically disappear. The current account-deletion worker does not sweep either character bucket. This creates a likely orphaned-private-object gap for account deletion.

## Required design before implementation

1. Decide and document the retention point for character assets on account deletion (remove at the end of the account grace period, or retain for a separate period). Do not infer this from chat's 30-day policy.
2. Before relational/Auth deletion removes the source rows, snapshot only that user's character asset paths into a durable account-deletion Storage queue linked to the archive batch, not by FK to `auth.users`, `profiles`, or `characters`.
3. Include both `characters.avatar_video_path` and every `character_illustrations.storage_path` row owned by the target author.
4. Validate bucket allowlist and exact object path shape: owner UUID / character UUID / asset UUID + allowed extension. Never use a broad owner-folder recursive delete.
5. Keep chat-memory objects out of this character-asset queue. Their independent 30-day chat-deletion job controls their timing.
6. Make claim/mark/retry/dead-letter operations service-role-only, idempotent, bounded, and durable after Auth deletion. Do not depend on a browser session or the current owner remaining authenticated.
7. Recheck that the object path is not referenced by another live row before removal; treat missing objects as idempotent success only after a confirmed Storage response.
8. Add tests for Auth cascade, multiple characters, primary/gallery/video assets, duplicate paths, foreign-owner path rejection, retryable Storage errors, dead-letter, and chat-memory retention separation.

## Status / release gate

- Finding: character illustration/video Storage cleanup is not currently integrated into account deletion.
- Chat-memory Storage retention has a separate durable queue and 30-day gate; do not bypass it during account deletion.
- No implementation or policy change made in this audit.
- The account-deletion Storage sweep remains a merge blocker until retention semantics, queue design, tests, and recovery behavior are approved.
