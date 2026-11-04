# Account deletion character-preservation draft review — 2026-11-02

PR #200: Draft / unmerged
Review scope: current character-preservation draft SQL, current hosted RLS/catalog definitions, current Edge Function entrypoints.
No hosted DDL/DML, RPC, Auth/Storage mutation, deployment, or Cron change was performed.

## 1. Confirmed live owner-child RLS policy gap

The current hosted test database has these author-managed child policies:

| Table | Existing owner policy | Calls account_is_active()? |
|---|---|---|
| `character_private_info` | author_id = auth.uid() and parent characters.author_id = auth.uid() | No |
| `character_schedules` | parent characters.author_id = auth.uid() and deleted_at IS NULL | No |
| `character_schedule_descriptions` | author_id = auth.uid() and parent characters.author_id = auth.uid() and deleted_at IS NULL | No |
| `character_illustrations` INSERT | own author_id + parent owner + NSFW gate | Yes |
| `character_illustrations` UPDATE | own author_id + parent owner + NSFW gate | Yes |
| `character_illustrations` DELETE | own author_id + parent owner | No |
| `character_stories` | existing restrictive account_must_be_active policy plus owner policy | Yes |

The live `account_is_active()` returns false as soon as an account-deletion request exists. However, the above child tables do not all enforce that state. During the grace period, an account marked pending deletion may still directly read/write private settings and schedules or delete illustration metadata through policies that omit the active-account restriction.

This is an inconsistent write-freeze boundary. Before account deletion is enabled, add restrictive `account_is_active()` policies to the owner-managed child tables/commands, or otherwise prove an equivalent server-side guard for every read/write path. Keep the existing permissive owner policies; a restrictive policy is an additional AND gate, not a replacement for ownership checks.

At minimum cover:
- `character_private_info` ALL
- `character_schedules` ALL
- `character_schedule_descriptions` ALL
- `character_illustrations` DELETE (and preferably a consistent table-level restrictive gate for authenticated owner operations)

Do not apply the gate to unrelated public/anon read behavior. Verify policy composition with both active and pending users in local RLS tests.

## 2. Retained-session media access must reject deleted/stale identities

The character-preservation draft originally checked only non-null `auth.uid()` and exact existing session ownership. That is insufficient because an already-issued JWT can remain cryptographically valid after Auth deletion.

Updated draft:
- `supabase/drafts/account-deletion-character-preservation-draft.sql` now additionally requires `public.account_is_active() IS TRUE` inside `private.user_has_existing_character_session()`.
- This must be paired with `supabase/drafts/account-is-active-auth-user-existence-guard.sql`, which checks that the JWT subject still exists in `auth.users` and has no pending deletion request.
- The stale-JWT test plan now includes exact character-media access checks through both session and Storage helper functions.

This is still draft-only. Do not claim stale-JWT protection until the paired functions are replayed and tested on a disposable local stack.

## 3. Existing-session and new-session separation

The current Edge entrypoints perform caller authentication and an `account_is_active()` check before service-role RPC:
- Encounter: `encounter-session/index.ts` checks `can_open_encounter_session` using the caller JWT before it calls the service-role creation RPC.
- Story: `story-session/index.ts` checks `character_can_start_chat` using the caller JWT before it calls the service-role creation RPC.
- Group: `create_chat_group` uses caller `auth.uid()`, rejects pending deletion, and only inserts public/non-deleted characters.

The two encounter/story creation RPCs are executable only by postgres/service_role in the inspected ACL; authenticated clients do not have direct EXECUTE. Preserve this boundary. Continue to verify the Edge Function binds the target user to the verified `auth.getUser()` result, never to untrusted request input.

After account archival, preserve the character's existing `visibility` and `review_status`; do NOT force a previously public/approved work to private. `author_id` is detached, while `account_archived_at` is the explicit offline/new-session-denial marker. Existing eligibility helpers must require `account_archived_at IS NULL`, and the shared archived-entry trigger must guard every new session/member attachment. Public discovery must continue to show previously public/approved works and must not require a live `profiles` join; however, all new-chat/encounter/story entry points remain disabled.

## 4. Attribution minimization decision

The confirmed product rule is: a deleted creator's works remain visible with the creator name, but no author profile interface is available. The preservation draft now stores only `creator_display_name` (profile nickname; fallback `原作者` if no nickname exists). It does not retain a handle snapshot.

- Render creator name as plain, non-clickable text only.
- Do not show author avatar/profile link/follow/message/management actions.
- Do not retain email, birthdate, profile bio, avatar, or handle solely for attribution.
- The character must visibly be offline (`characterStatus='offline'`, `isOnline=false`) while existing conversations remain usable.

## 5. Confirmed safe scope of current draft

- Character rows remain in place; `author_id` becomes nullable and uses ON DELETE SET NULL.
- Character private info and illustration metadata are detached from the deleted profile rather than cascaded.
- Schedule-description author FK is detached from Auth with ON DELETE SET NULL.
- Character Storage objects are retained; account deletion does not delete object bytes.
- The existing-session media helper is restricted to exact illustration paths/video paths linked to an existing single/group conversation.
- The helper does not grant upload/update/delete rights.

The design still needs local replay, full RLS composition tests, media signed-URL refresh tests, session-creation rejection tests, and worker crash/retry tests.

## 6. Release gate

- This is a review note; no hosted schema or data was changed.
- Do not enable or deploy the account-deletion worker.
- Do not move draft SQL into active migrations until a trusted local baseline exists and all tests pass.
- PR #200 remains Draft/unmerged.


## Round 79 follow-up — shared archived-entry guard consolidation

A further branch review found that the repository already contains the more complete draft `account-archived-character-session-insert-guard.sql`. It covers:
- `chat_sessions.character_id`
- `chat_groups.world_character_id`
- `chat_group_members.character_id`
- `encounter_session_lifecycle.character_id`
- `story_relationship_states.character_id`
- legacy `conversations.story_id`

It resolves the story_id through `character_stories`, checks both `deleted_at` and `account_archived_at`, and takes `FOR KEY SHARE` on the character row to serialize new-entry creation against character archival/hard deletion. It deliberately does not attach to continuation tables such as `chat_messages` or `chat_group_messages`.

To avoid duplicate BEFORE triggers and conflicting implementations, the temporary duplicate trigger block was removed from `account-deletion-character-preservation-draft.sql`. That file retains only the explicit `account_archived_at IS NULL` checks in `character_can_start_chat()` and `can_open_encounter_session()`; the shared guard draft remains the single database trigger source.

The static account-deletion test script now checks:
- active-account requirement in existing-session media helper;
- restrictive child-table policies;
- explicit archived-state checks in caller-side eligibility functions;
- row locks for retained schedule/story child rows;
- the shared archived-entry trigger coverage and no triggers on continuation message tables.

The CI workflow now runs when the child-table policy SQL or its test plan changes. This remains static verification only; PostgreSQL trigger execution and concurrency tests are still pending local replay.


## Round 80 — product clarification: account deletion retains works, author name, and offline state

The user explicitly confirmed:

> 帳號刪除，如果是作者他的作品還是要顯示作者名稱，只是沒有作者介面，然後顯示角色離線（不可開新的聊天室）

This is now the governing acceptance rule:
- A previously public/approved character remains publicly discoverable; account deletion is not character deletion and must not set `visibility='private'`.
- A previously private/unpublished character stays private.
- Store only the creator's display name as plain text; do not retain a clickable handle/profile reference.
- Hide all author profile/avatar/follow/message/management affordances for the deleted creator.
- Character status is offline; no new single chat, group membership, encounter, or story session.
- Existing single/group conversations continue with the same transcript and character identity.
- Public discovery queries must not require an active `profiles` row or non-null `author_id` for a previously public character.
- The SQL draft snapshots `creatorDisplayName`, `creatorProfileAvailable=false`, `characterStatus='offline'`, `isOnline=false`, and the original visibility for existing chat/session snapshots. UI/query implementation remains to be audited and accepted separately.

The draft SQL now:
- removed `creator_handle_snapshot` and `creatorHandleSnapshot`;
- no longer changes `characters.visibility`;
- preserves the original visibility in chat/group snapshots;
- retains the creator nickname as plain text and sets offline metadata;
- keeps `account_archived_at` as the server-side no-new-session gate.

No hosted schema/data was changed. The draft is not replayed; UI and public discovery behavior are not yet verified.
