# Account deletion vs character deletion — publication history boundary (updated 2026-11-03)

## Critical distinction

The `first_published_at` hard-delete rule applies only when the user explicitly deletes an individual character. It does **not** authorize account deletion to hard-delete the author's never-published drafts.

The user-confirmed account-deletion policy is to preserve the author's characters and their associated data/media. Account deletion and explicit character deletion are separate product actions and must not share the same deletion branch.

## Explicit character deletion (character owner chooses Delete)

Use `first_published_at` plus complete history checks:

- If the character has ever been published, or has any solo/group/encounter/story/comment history, soft-delete and preserve existing conversation history.
- Only if it has never been published and has absolutely no history may the character be hard-deleted after all exact-path illustration/video assets have been durably queued, path reattachment is locked, and Storage cleanup is verified.
- The hard-delete worker is `purge-character-assets`; it is only for this explicit character-deletion path.

## Account deletion (owner deletes their account)

Preserve **all** authored characters, including never-published/private drafts:

- Preserve the character row, private settings, schedules, schedule descriptions, stories, illustration metadata, illustration objects and avatar-video objects.
- Preserve the original visibility and review state. A public/approved character remains public/discoverable; a private/unpublished character remains private.
- Store the approved historical creator display name as plain, non-navigable text. Do not retain a live author profile, handle link, avatar/profile route or author-management capability.
- Character status becomes offline. No new solo chat, group membership, encounter or story session may be created.
- Other players' already-existing authorized conversations continue; their character can still reply and normal billing applies.
- Never enqueue any account-owned character asset into `character_asset_cleanup_jobs`; never invoke `purge-character-assets` as part of account deletion.

## Classification rule

`first_published_at` remains a durable publication-history signal for **explicit character deletion only**. It is not an account-deletion filter.

For explicit character deletion:
- A currently-private character with non-null `first_published_at` is still previously published and must be soft-deleted.
- A null `first_published_at` is necessary but not sufficient for hard deletion; all history tables and tombstones must also be empty.
- Missing/ambiguous publication evidence fails closed to retention/manual review.

For account deletion:
- Do not classify a never-published draft as disposable.
- Preserve it and its media; its existing private visibility means it remains absent from public discovery.

## Implementation / test gates

- Test explicit character deletion separately: never-published/no-history hard-delete with asset queue; previously-published or any-history soft-delete.
- Test account deletion separately: public, private, previously published, and never-published characters all survive with original visibility/review state and all child/media references intact.
- Verify account deletion never writes to `character_asset_cleanup_jobs`.
- Verify offline state, no-new-entry guards, and existing-session continuation.
- Keep the account deletion worker disabled until full SQL, RLS, Storage and recovery gates pass.

## Safety status

Design clarification only. No hosted database writes, Storage deletion, Auth deletion, deployment, or Cron changes were performed.
