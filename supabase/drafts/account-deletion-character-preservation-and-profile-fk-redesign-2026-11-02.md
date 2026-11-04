# Account deletion — character preservation and profile-FK redesign plan — Round 47 — 2026-11-02

Status: design only; no migration or hosted write.
PR #200 remains Draft/unmerged. Worker fail-closed guard from Round 46 remains mandatory.

## 1. Verified live schema facts (read-only catalog inspection)

### Character-owned rows that currently cascade from characters

- `character_private_info.character_id -> characters.id ON DELETE CASCADE`
- `character_illustrations.character_id -> characters.id ON DELETE CASCADE`
- `character_schedules.character_id -> characters.id ON DELETE CASCADE`
- `character_schedule_descriptions.character_id -> characters.id ON DELETE CASCADE`
- `character_stories.character_id -> characters.id ON DELETE CASCADE`
- `character_comments.character_id -> characters.id ON DELETE CASCADE`
- `encounter_character_state.character_id -> characters.id ON DELETE CASCADE`
- `encounter_diary.character_id -> characters.id ON DELETE CASCADE`
- `encounter_turn_interaction_receipts.character_id -> characters.id ON DELETE CASCADE`

Conversation/session references mostly use SET NULL, but preserving the character row avoids losing its stable identity and content snapshots.

### Profile-owned author references

- `characters.author_id -> profiles.id ON DELETE CASCADE`
- `character_illustrations.author_id -> profiles.id ON DELETE CASCADE`
- `character_private_info.author_id -> profiles.id ON DELETE CASCADE`
- `author_follows.author_id -> profiles.id ON DELETE CASCADE`
- `conversations.user_id -> profiles.id ON DELETE CASCADE`
- `wallet_accounts.user_id -> profiles.id ON DELETE CASCADE`
- `wallet_transactions.user_id -> profiles.id ON DELETE CASCADE`
- `ai_generation_records.user_id -> profiles.id ON DELETE NO ACTION`
- `chat_message_versions.edited_by -> profiles.id ON DELETE NO ACTION`

The current prepare RPC explicitly deletes AI generation rows and wallet transactions after archiving them; it also deletes conversations. It nulls `chat_message_versions.edited_by` only for edits to another player's messages. Auth deletion then cascades from profiles to characters and their child records. Therefore, current behavior violates the character-preservation requirement.

## 2. Character row facts to preserve

Read-only catalog inspection confirmed `characters` contains:
- identity and author: id, author_id, name, title
- presentation: gender, age, race, intro, style, tags, avatar_url
- publication and moderation: visibility, review_status, first_published_at, latest_eligible, rights_confirmed, deleted_at, deletion_reason
- settings: phone_settings, personality_profile, NSFW flags
- media pointer: avatar_video_path

Separate tables hold private_info, illustration metadata/storage_path/asset_type/sort_order/display_name, schedule rows, natural-language schedule descriptions, and story content. Do not flatten these into a partial character-only archive payload.

## 3. Recommended target model — preserve live character records

Prefer retaining the original `characters.id` row and child rows in place rather than serializing then reconstructing them. This preserves stable foreign-key identity for chat/encounter/story records and avoids lossy JSON round-tripping.

Introduce a durable creator-attribution identity independent of Auth/profile:
- One durable attribution row per original creator identity, with immutable display label snapshot and created timestamp.
- `characters.creator_attribution_id` references that durable row.
- A nullable active-owner reference (for editing/admin authorization) is separate from historical creator attribution.
- Before Auth deletion, snapshot creator display label from profiles, set active owner to NULL, and set a dedicated account-archived/offline marker. Preserve the character's original visibility and review state: public/approved works remain publicly discoverable, while private/unpublished works remain private. Block new chat/encounter/story entry independently of discovery visibility.
- The historical creator label is plain non-navigable text; it must not resolve to a profile page.
- Never reuse `author_id` as historical attribution after the account is deleted.

Do not simply change `characters.author_id` to nullable while leaving the other author_id FKs and RLS policies untouched. The illustration/private-info rows also have profile FKs and owner-based RLS/Storage policies. The whole owner/creator model must be migrated coherently.

## 4. Required transaction boundary before Auth deletion

A new privileged prepare step must run atomically and fail closed:
1. Lock the due account_deletion_requests row and exact archive batch.
2. Snapshot and verify immutable creator attribution for every character owned by the account.
3. Ensure each character has an independent durable attribution reference.
4. Detach active ownership from characters and all author-owned child metadata without deleting those rows.
5. Mark every owned character account-archived and block all new single/group/encounter/story creation.
6. Preserve existing session continuation through snapshots and explicit session-scoped access; do not rely on current public visibility.
7. Verify all character and child-row counts/identities are unchanged and all Storage object references remain present.
8. Only then mark the batch deleting and allow Auth deletion.

Any missing profile label, FK mismatch, child-row mismatch, unknown media object, or policy inconsistency must abort the transaction before Auth deletion.

## 5. Storage and existing-session access are a separate gate

Buckets are private. Character illustration/video objects must remain in place. Existing players may continue existing authorized sessions, but after the author account is deleted, the current owner-based storage policies will no longer authorize them.

Required design:
- Use narrow server-side authorization tied to an existing, non-deleted session and the exact character/media object path.
- Verify session owner, character reference/snapshot, allowed asset type, and exact path; never grant access to the whole character folder.
- Keep character assets separate from the 30-day chat-memory photo cleanup queue.
- No Storage move/delete in account deletion.

## 6. Additional FK blockers not to paper over

- `ai_generation_records.user_id ON DELETE NO ACTION`: current prepare deletes these rows after archiving. Retention/legal policy for raw generation records needs explicit disposition before changing this.
- `chat_message_versions.edited_by ON DELETE NO ACTION`: current prepare handles only edits to other users' messages by nulling editor. Verify every other reference and audit semantics.
- `wallet_transactions` currently CASCADE from profile but are archived then deleted. This is a financial evidence design decision, not something to silently convert to SET NULL.
- `wallet_accounts` cascades from profile. The user-facing wallet is deleted with account; archive evidence must be independently retained and access-restricted.
- `conversations` cascade and are explicitly deleted. This behavior is distinct from the existing-player character chat continuation requirement; verify legacy conversation rows versus chat_sessions and do not infer that all player chats are supposed to be deleted.

## 7. Why no migration was created this round

The repo's migration history lacks a recovered foundational CREATE TABLE baseline for profiles/characters. A partially written migration touching FK actions, RLS, and Storage could not be safely replayed or structurally validated. The current connected test DB must remain untouched. First prepare a disposable local reconstruction or recover the original baseline; then implement and test the full schema transition as one reviewed migration series.

## 8. Acceptance tests required before worker enablement

- Account deletion preserves every character row and every child row (including never-published characters).
- Creator attribution survives Auth/profile deletion and is non-navigable.
- Active owner is null and no owner-only editing path remains.
- Public discovery preserves the original visibility/review state; private/unpublished characters remain private. All new session entry points reject account-archived characters.
- Existing single, group, encounter, and story sessions continue for their original player owners.
- Existing players can read exact character media objects but cannot enumerate or read unrelated assets.
- Retry after prepare but before Auth deletion is idempotent; retry after Auth deletion but before finalize completes.
- Injected failure at every step leaves no partially detached/partially archived character set.
- Profile FK checks report no unhandled NO ACTION/CASCADE blockers.
- No change to 30-day chat-memory photo retention.
- Local migration replay, Deno checks, integration and RLS/Storage E2E pass.

## 9. Safety status

This round used read-only catalog SELECTs only. No hosted RPC, DDL/DML, Auth/Storage mutation, deployment, or Cron operation occurred. No migration was added. Worker remains code-disabled and must not be deployed/enabled.
