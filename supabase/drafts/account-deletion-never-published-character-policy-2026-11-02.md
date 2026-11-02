# Account deletion: never-published character disposition (2026-11-02)

## User-confirmed policy refinement

Account deletion must distinguish characters that have never been publicly published from characters with any public publication history.

### Never published

When the account deletion grace period expires and the account deletion is processed:
- If `characters.first_published_at IS NULL`, the character is an unpublished draft and must be permanently deleted as part of account deletion.
- Delete its character-owned relational data, including private info, schedules, schedule descriptions, stories, and illustration metadata.
- Delete its character illustration and avatar-video Storage objects as part of the same lifecycle, with retryable cleanup and verification. Do not leave orphaned private media.
- This is not a 30-day chat-memory photo retention item. The separate chat-memory photo queue remains unchanged.
- No retained creator-attribution record is needed solely for a never-published draft unless a separate legal/audit requirement is identified.

### Published at least once

If `characters.first_published_at IS NOT NULL`, retain the character and its creative assets:
- Preserve character data, settings, illustration rows, illustration objects, and avatar-video objects.
- Preserve historical creator attribution as non-navigable text; do not link to the deleted author's profile.
- Move the character to a distinct account-archived state, excluded from discovery, map encounters, recommendations, and every new-chat entry point.
- Allow only already-existing authorized conversations to continue; prohibit new single/group/encounter/story sessions.

## Classification rule

Use the durable publication-history field `first_published_at`, not current `visibility`:
- A character that is currently private but was public previously is still in the published-at-least-once category and must be retained/archived.
- A character with no publication timestamp is in the never-published category, subject to verifying that all publishing paths reliably set `first_published_at`.

Before implementation, audit every publication transition to confirm `first_published_at` is immutable once set and cannot be bypassed by direct RPC/API writes. If historical data has missing timestamps, do not silently classify it as never published; fail closed into retention/manual review until publication history can be established.

## Implementation gates

- Verify `first_published_at` semantics and every publish/unpublish path.
- Add a deterministic classification test for null/non-null timestamps, including currently-private previously-published characters.
- For never-published drafts, delete relational children in FK-safe order and enqueue private Storage object deletion durably before deleting metadata; retries must be idempotent and must not cross owner/character boundaries.
- For published characters, transform ownership/creator attribution and archive state before profile/Auth deletion; preserve media privately.
- Preserve the existing independent 30-day chat-memory photo cleanup queue.
- Keep PR #200 Draft/unmerged until schema provenance, RLS, cleanup retries, tests, and migration replay are verified.

## Safety status

Policy/design documentation only. No hosted database writes, Storage deletion, Auth deletion, deployment, or cron changes were performed.
