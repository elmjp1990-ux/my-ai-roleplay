# Account deletion — retained character ownership and asset lifecycle — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`
PR: #200 — Draft / unmerged
Environment: connected Supabase test project; schema/function inspections are read-only.
No DDL/DML, Auth mutation, Storage mutation, deployment, or Cron change was performed.

## User-approved product policy

When an account deletion grace period expires:

1. **Do not delete the author's character content.** Keep the character records, character settings, illustration files, avatar videos, and creator attribution.
2. **Detach the author from the public profile route.** The author attribution may still be displayed as historical creator information, but it must not be clickable and must not navigate to a live author profile page.
3. **Move all characters owned by that account into a private/archived state.** They must disappear from public discovery, city/map encounter discovery, recommendations, and every entry point that creates a new conversation.
4. **Allow existing conversations to continue.** A player who already has a conversation with that character may continue that same conversation. The character must not be selectable to start a new single chat, new group chat, new encounter/story session, or a duplicate conversation.
5. Preserve existing conversation history and references to the character; do not cascade-delete the character or its media as part of account deletion.
6. This policy is distinct from chat-memory photo retention. Existing chat deletion's 30-day Storage lifecycle remains unchanged.

This supersedes the earlier open question about deleting character Storage assets after the grace period: **character illustrations and avatar videos are retained with their character records; they are not queued for account-deletion deletion.**

## Important schema consequence

The live test schema currently has:
- `characters.author_id → profiles(id) ON DELETE CASCADE`
- `character_illustrations.author_id → profiles(id) ON DELETE CASCADE`
- `character_illustrations.character_id → characters(id) ON DELETE CASCADE`
- `profiles.id` is the profile identity, and the inspected schema links profile deletion to Auth deletion through the account data model.

Therefore, simply deleting the Auth user using the existing cascade path would destroy the character and illustration metadata even if Storage objects were left untouched. Leaving Storage objects behind is not sufficient.

The account-deletion implementation must be redesigned so character records and attribution survive without retaining a login-capable Auth account or a navigable public author profile. Do not weaken RLS or leave a deleted Auth identity active merely to preserve attribution.

## Required architecture work before implementation

1. Introduce a durable, non-login creator-attribution identity (or equivalent immutable snapshot) that is not FK-cascaded from `auth.users` or `profiles`. It must preserve the agreed author attribution while exposing no live author-page link.
2. Repoint/decouple character ownership and illustration ownership from the deletable Auth profile. Preserve a stable creator reference for historical attribution, but distinguish it from an active account owner.
3. Define a strict account-deleted character state, e.g. `visibility='private'` plus an explicit account-deleted/archived state. Existing private/deleted status semantics must not be conflated if they produce different access rules.
4. Make all public discovery and new-conversation entry points reject archived characters, including direct RPC/Edge Function paths. Frontend hiding alone is not sufficient.
5. Add a narrow authorization path for existing conversation participants to continue their existing conversation with an archived character. It must validate the existing conversation/character relationship server-side and must not allow creating a new conversation or reusing an old conversation ID to bypass the restriction.
6. Preserve character rows, `character_illustrations` rows, `avatar_video_path`, and both private Storage buckets. Ensure existing signed-URL refresh and media access still work for permitted existing conversations; do not make assets public.
7. Account deletion worker must snapshot/transform ownership and archive profile attribution before Auth deletion, under the same fenced transaction/lease protocol. The process must be idempotent and recoverable if it crashes before or after Auth deletion.
8. Retain the independent chat-memory photo deletion queue and its 30-day `purge_after` gate. Account deletion must not bypass or reset it.
9. Test with multiple characters and multiple existing conversations; verify discovery/new-chat denial, existing-chat continuation, creator label display without link, image/video access, RLS isolation, stale JWT denial, and Auth deletion recovery.

## Acceptance criteria

- [ ] Auth account is deleted after the configured grace period.
- [ ] Character records and all associated illustration/video Storage objects remain.
- [ ] Historical creator attribution remains visible, but author handle/avatar attribution is not a link to a live author page.
- [ ] Characters are absent from all public lists, map locations, recommendations, and new-chat creation paths.
- [ ] Existing authorized conversations can continue.
- [ ] No new single/group chat, encounter, or story session can be created for an archived character.
- [ ] A stale JWT or deleted account cannot use author-management APIs or mutate retained characters.
- [ ] Chat-memory photo retention continues on its separate 30-day schedule.
- [ ] Local migration replay, independent-session concurrency tests, and all CI checks pass before merge.

## Status / release gate

- User-approved policy recorded; implementation is not yet done.
- Previous proposed character-asset Storage sweep is no longer the correct solution. Preserve those objects and their metadata instead.
- The current profile/character cascade is incompatible with this policy and is a critical blocker for account deletion.
- PR #200 must remain Draft/unmerged until schema, RLS, frontend, RPC/Edge Function guards, recovery tests, and migration provenance are resolved.
- No database or hosted data changes were made in this update.
