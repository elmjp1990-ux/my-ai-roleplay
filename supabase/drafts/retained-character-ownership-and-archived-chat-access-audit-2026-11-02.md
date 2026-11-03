# Retained character ownership and archived-chat access audit (2026-11-02)

## Scope and safety

Read-only inspection of the connected test Supabase project and the current account-deletion design. No DDL/DML, Storage mutation, Auth mutation, deployment, or scheduled job was performed.

This document refines the user-approved account deletion policy:
- Retain character records, character settings, illustration rows, illustration objects, and avatar-video objects.
- Retain historical creator attribution, but render it as plain, non-navigable text (never a link to an author page).
- Preserve each character's original visibility and review state. Previously public/approved works remain publicly discoverable; private/unpublished works remain private. All account-owned characters become offline and cannot start a new chat, encounter or story session.
- Existing authorized conversations may continue; no new single/group/encounter/story conversation may be created for those characters.
- Chat-memory photo cleanup remains its separate 30-day queue.

## Live schema findings

### 1. Profile deletion currently cascades into retained creator/character data

Observed foreign keys:
- `characters.author_id -> profiles.id ON DELETE CASCADE`
- `character_illustrations.author_id -> profiles.id ON DELETE CASCADE`
- `character_illustrations.character_id -> characters.id ON DELETE CASCADE`
- `character_private_info.author_id -> profiles.id ON DELETE CASCADE`
- `character_private_info.character_id -> characters.id ON DELETE CASCADE`
- `character_schedules.character_id -> characters.id ON DELETE CASCADE`
- `character_schedule_descriptions.character_id -> characters.id ON DELETE CASCADE`
- `character_stories.character_id -> characters.id ON DELETE CASCADE`

Therefore retaining Storage objects alone is insufficient. Deleting the profile cascades the character and illustration metadata; deleting the character would cascade its private settings, schedules, descriptions, and stories. The account-deletion path must transform ownership/attribution before deleting the profile, and must not delete the character row.

### 2. Conversation references mostly preserve history, but some character relations are nullable

Observed:
- `chat_sessions.character_id -> characters.id ON DELETE SET NULL`
- `encounter_session_lifecycle.character_id -> characters.id ON DELETE SET NULL`
- `encounter_session_turns.character_id -> characters.id ON DELETE SET NULL`
- `story_relationship_states.character_id -> characters.id ON DELETE SET NULL`
- `chat_group_members.character_id -> characters.id ON DELETE SET NULL`
- `chat_group_messages.character_id -> characters.id ON DELETE SET NULL`
- `chat_groups.world_character_id -> characters.id ON DELETE SET NULL`

This supports preserving the actual character rows rather than relying only on snapshots. Do not delete characters as part of account deletion; otherwise the live foreign keys intentionally detach conversation references and some encounter/story relationships.

## Current new-conversation gates inspected

### Group chat

`public.create_chat_group(...)` currently:
- rejects unauthenticated callers and users with a pending account-deletion request;
- accepts a character only when `deleted_at IS NULL AND visibility = 'public'`;
- does not currently use an explicit account-deleted/archive marker.

The new archived state must be checked in this server-side insert path. Frontend hiding is not a security boundary.

### Encounter

`public.can_open_encounter_session(character_id)` currently checks public visibility, not deleted, approved review, rights confirmed, and adult gate for NSFW. It needs an explicit archived-account exclusion.

`public.create_encounter_session_with_lifecycle(...)` inserts a new `chat_sessions` row and lifecycle row. Its SQL body accepts `p_user_id` and does not itself compare it with `auth.uid()` or call `account_is_active()`. This may be intentional only if execution is strictly restricted to a trusted Edge Function/service role. Verify EXECUTE grants and the Edge Function's authenticated-user-to-parameter binding before changing it; never assume the parameter is safe.

### Story mode

`public.create_story_session_with_relationship(...)` similarly accepts `p_user_id` and `p_character_id`, inserts a new story session, and does not itself compare the supplied user to `auth.uid()` or check the character's archived status. Verify EXECUTE grants and the Edge Function's authenticated-user-to-parameter binding. Add an explicit server-side archived-character denial at the trusted creation boundary.

### Shared helper

`public.character_can_start_chat(character_id)` currently permits the author or a public approved character when `deleted_at IS NULL`. It has no account-deleted/archive exclusion. It must not be treated as sufficient by itself until updated and every direct creation RPC is audited.

## Additional security blocker: stale JWT account state

The live definition of `public.account_is_active()` currently returns true when `auth.uid()` is non-null and no `account_deletion_requests` row exists. Since account deletion removes the request/profile rows but existing JWTs can remain valid until expiry, a stale token may satisfy this predicate after Auth deletion unless the helper independently verifies that the Auth user still exists (or uses an equally strong revocation/session check).

This conflicts with the previously identified stale-JWT requirement. Before enabling the worker, re-verify the deployed helper and add a regression test: deleted Auth user + still-present JWT must be denied. Do not rely on the account-deletion request row alone.

## Recommended retained ownership model (design only; not applied)

Use a stable creator-attribution identity independent of `auth.users` / `profiles`, plus an active-owner link that can be cleared:

- A durable creator-attribution row has its own UUID primary key and no cascading FK to Auth/profile.
- Store only the historical display information explicitly approved for retention. Minimum proposal: a creator display label captured at deletion time. Do not copy email, birthdate, bio, private profile data, or other unnecessary personal information. Avatar retention is a separate product/privacy decision.
- `characters` references the durable creator-attribution ID. Keep a nullable active-owner/Auth link only while the creator account exists and is allowed to manage the character.
- `character_illustrations` follows the same durable creator-attribution relationship; do not cascade its rows when the profile is removed.
- On account deletion, atomically snapshot the approved creator label, clear the active-owner link, mark the character as account-archived, and retain all character-owned settings and Storage paths.
- Account-archived is a distinct lifecycle state, not merely `visibility='private'`, because existing conversations must remain usable while all new creation/discovery paths are denied.
- Keep creator attribution non-clickable in all character cards, chat headers, encounter panels, and historical views after account deletion.

Avoid retaining a login-capable Auth user solely to preserve attribution. Avoid weakening RLS or making private media buckets public.

## Existing-chat continuation authorization

Allow continuation only when all of the following are true:
1. The requester is the authenticated participant/owner of an already-existing chat session or group.
2. The stored session/group is already linked to the archived character (single chat, or group member snapshot/member relation).
3. The operation is a continuation of that exact existing conversation; it cannot create a new session/group, add the archived character to another group, or fork a new encounter/story session.
4. The relevant session/group is not deleted/archived and the participant still has access.
5. Character media access is issued only through an authorization path tied to that existing conversation; no public bucket policy or globally reusable public URL.

New conversation creation must be denied for archived characters in every path:
- single-chat create/reuse-or-create path;
- group creation and member insertion;
- encounter creation;
- story creation;
- map/schedule encounter discovery;
- public character discovery, recommendations, and search;
- any direct RPC or Edge Function route that can create a new session.

Existing session reads/turns must not accidentally reuse a generic `character_can_start_chat` check if that helper is intended for new sessions only. Separate `can_continue_existing_session` from `can_create_new_session` semantics.

## Required implementation/test gates before worker activation

- Use the agreed disposable current-state schema fixture for draft validation; recovering the original pre-ledger profiles/characters CREATE TABLE files is not a prerequisite. Before hosted rollout, create fresh uniquely versioned incremental migrations and compare them against the existing test-project schema/ledger.
- Design and test the durable creator identity and active-owner separation, including profile/Auth deletion recovery.
- Inventory all direct and indirect single/group/encounter/story creation routes and EXECUTE grants.
- Verify Edge Functions bind supplied user IDs to the verified JWT user; preferably derive user identity server-side rather than trust request payload.
- Preserve public discovery for previously public/approved characters and preserve private state for unpublished/private characters. Add explicit archived-state denial to all new-session creation gates and encounter-start actions.
- Add exact-existing-session continuation checks for single and group chats.
- Verify illustration/avatar-video object reads and signed URL refresh for authorized existing chats only.
- Preserve `personax-memory-photos` and the existing 30-day `chat_deletion_jobs` / `chat_storage_deletion_jobs` workflow unchanged.
- Add regression tests for stale JWT after Auth deletion, creator label non-link rendering, RLS isolation, multiple characters per creator, existing single/group continuation, all new-session denials, media authorization, and worker retries/recovery.
- Integrate all state transitions with the account-deletion worker's atomic lease/fencing protocol.
- Run local migration replay and Supabase security advisors against a trusted schema baseline before review.
- Keep PR #200 Draft/unmerged until all gates pass and the user explicitly approves.

## Status

Architecture audit only. No schema, policy, data, Storage, Auth, worker deployment, cron, or hosted migration changes were made. This is not approval to activate account deletion.


## Round 80 superseding product clarification — 2026-11-03 reconciliation

Earlier wording in this audit that said account-deleted characters should be removed from all discovery is superseded.

The accepted behavior is:
- Preserve original `visibility` and `review_status`.
- Previously public/approved works remain publicly discoverable and retain plain-text historical creator display name.
- Private/unpublished works remain private.
- Every account-owned character is offline and cannot start new chat/group membership/encounter/story.
- Existing player conversations continue and the character still replies with normal billing.
- Preserve all character settings and media; account deletion never routes character media into the explicit character hard-delete cleanup worker.

This distinction is critical: **public discovery visibility is not the same as permission to create a new conversation**. Keep those checks separate.
