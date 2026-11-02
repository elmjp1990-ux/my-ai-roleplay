# Account deletion character preservation — schema and UI dependency audit — 2026-11-02

## User-approved behavior

When an author account is deleted, preserve every character row, including private/unpublished characters, public introduction/personality, private settings, stories, structured schedules, natural-language schedule descriptions, illustrations, avatar video path/object, and historical creator attribution as plain text (not a clickable deleted profile).

For any other player who already has a chat/group/encounter/story session with the character:
- Keep their session, transcript, speaker snapshots, and encounter/story state.
- Existing sessions continue using their persisted character snapshot.
- Do not allow any new session with an account-archived character.
- Keep character media private; allow only the existing session owner to read exact referenced assets.

## Live schema facts (read-only Supabase catalog, 2026-11-02)

### Character ownership/profile FKs that currently cascade

- `characters.author_id -> profiles(id) ON DELETE CASCADE`, NOT NULL.
- `character_private_info.author_id -> profiles(id) ON DELETE CASCADE`, NOT NULL.
- `character_illustrations.author_id -> profiles(id) ON DELETE CASCADE`, NOT NULL.
- `character_schedule_descriptions.author_id -> auth.users(id) ON DELETE CASCADE`, NOT NULL. This is a separate direct Auth FK and was not covered by the earlier profile-FK inventory.
- `character_illustrations.character_id`, `character_private_info.character_id`, `character_schedules.character_id`, `character_stories.character_id`, and `character_schedule_descriptions.character_id` reference `characters(id)` with ON DELETE CASCADE. Preserving the character row therefore preserves these child records.
- `character_schedule_descriptions` has columns `character_id`, `author_id`, `description`, `created_at`, `updated_at`; RLS is author-only.
- `character_illustration_cleanup_jobs` has `author_id`, `storage_path`, `attempts`, `last_error`, timestamps, and no FK to profiles/Auth. Pending cleanup jobs need explicit handling so a future cleanup worker cannot delete archived character media.
- `profiles.id -> auth.users(id) ON DELETE CASCADE` remains expected.

### Account-owned Auth cascades (not other players' rows)

Auth FKs also cascade rows owned by the deleting account, including `chat_sessions.user_id`, `chat_groups.owner_id`, group turns/charges/diaries/photos, `chat_memory_photos.owner_id`, `chat_turn_charges`, `chat_turn_events`, encounter state/diary/lifecycle/turn/evaluation rows, story relationship rows, daily check-ins, own comments/likes/follows, legacy conversations, and wallet rows.

These owner-scoped cascades do not delete another player's session when its `user_id` / `owner_id` is different. The critical data-loss path is the character's own FK to profiles and the direct Auth FK on schedule descriptions. Account deletion may still remove the deleting player's own sessions; that policy is separate from preserving other players' sessions.

### Current RLS / Storage behavior

- Character, private-info, illustration metadata, schedule, story RLS policies rely on `author_id`, `visibility`, and/or `deleted_at`.
- Current character illustration Storage SELECT requires the author or a public eligible character; avatar-video SELECT similarly requires the owner or a public eligible character.
- Current upload/update/delete policies are owner/path-bound and should remain owner-only.
- Memory-photo Storage policies are scoped to the chat owner and active single/group parent; do not broaden these as part of character media access.
- The existing-session read path needs a new narrowly scoped authorization path for exact character media references; do not make character buckets public.

## Existing-session continuity evidence

- `chat-turn/index.ts` authenticates the player, checks the player's own account status, loads `chat_sessions` by both session ID and owner ID, validates `character_id` against `character_snapshot.id`, and then reserves/settles a turn. It does not re-check the character's current visibility/author, so existing story sessions can continue after the author character is private/archived.
- Encounter turn/session functions have already been adjusted so existing session turns/retries are allowed before checking new-session eligibility; new encounter sessions still require a public eligible character.
- Frontend chat sync explicitly updates an already-owned `chat_sessions` row even when the character is down/private, and only applies the current visibility gate to new session INSERT.
- Frontend currently derives creator profile lookup IDs from `chat_sessions.character_snapshot.authorId` and queries `public_profiles`. If account archival sets `author_id` to NULL, the deleted profile lookup naturally returns nothing; the snapshot must also carry plain-text creator attribution and the UI must render it without a profile link.
- Frontend illustration hydration reads `character_illustrations` metadata and calls `storage.from('character-illustrations').createSignedUrl(storage_path)`; avatar video hydration calls `character-avatar-videos.createSignedUrl(path)`. Both metadata and Storage SELECT need exact existing-session authorization for private/archived characters.

## Proposed clean pre-launch architecture (DRAFT — not applied)

1. Add durable text snapshots to `characters`: `creator_display_name`, `creator_handle_snapshot`; add `account_archived_at` as a durable marker. Backfill creator text from `profiles.nickname` and `profiles.handle` before detaching.
2. Make `characters.author_id`, `character_private_info.author_id`, `character_illustrations.author_id`, and `character_schedule_descriptions.author_id` nullable; change their relevant FKs to `ON DELETE SET NULL`. Preserve `profiles.id -> auth.users` cascade.
3. In one service-only account-archive transaction, select **all** characters owned by the account (no published/private filter), lock them, snapshot creator display text, set visibility to private, set `account_archived_at`, and detach `author_id`. Do not set character `deleted_at` and do not enqueue character media deletion.
4. Detach the same author columns in private-info, illustration metadata, and schedule-description rows. Keep all child records and Storage objects.
5. Update `chat_sessions.character_snapshot`, `chat_group_members.character_snapshot`, and `chat_group_messages.speaker_snapshot` for all matching character IDs: `authorId: null`, `creatorDisplayName`, `creatorHandleSnapshot`, and archived/private marker. Preserve all other snapshot fields. Frontend must treat explicit `authorId: null` as authoritative (not fallback to stale local authorId).
6. Cancel/remove only the author's pending `character_illustration_cleanup_jobs` queue rows (never delete the referenced Storage objects) so no future cleanup job can remove archived character media.
7. Add a private SECURITY DEFINER helper that returns true only when `auth.uid()` owns an undeleted `chat_sessions` row for the character or an undeleted/unarchived `chat_groups` row whose member references the character. Grant to authenticated only.
8. Add that helper to `character_illustrations` metadata SELECT and exact-path Storage SELECT policies for `character-illustrations` and `character-avatar-videos`. Keep upload/update/delete policies owner-only. Do not grant anon.
9. Keep new-session paths closed: `character_can_start_chat`, `can_open_encounter_session`, group creation, and story/encounter creation must reject `account_archived_at IS NOT NULL` (and/or private visibility); existing session turn paths must not re-check current public eligibility.
10. Update chat-list and group speaker UI to show creator attribution as plain text when `authorId` is null; never link to a deleted profile.

## Important implementation caveats

- The old `20261017010847_account_deletion_worker.sql` is not a valid final implementation: it deletes legacy conversations and other sources, and its Auth/profile cascade assumptions destroy character-owned child data. The worker stays disabled with the fixed 503 guard.
- This proposal is not an active migration and must not be applied to the hosted test project until the migration ledger/baseline is reconciled.
- Validate all referenced table/FK definitions again on the disposable local database; add tests for private/unpublished characters, multiple other players, group snapshots, encounter/story records, private info/schedules, signed illustration/video access, revoked old-author access, no new sessions, and no Storage deletion.
