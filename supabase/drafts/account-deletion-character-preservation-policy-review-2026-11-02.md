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

After character archival, the current proposed `visibility='private'` plus `author_id=NULL` causes the existing caller-side character start checks to reject new sessions. Still add/verify an explicit `account_archived_at IS NULL` predicate at all trusted creation/discovery boundaries so the new lifecycle state is explicit and cannot be bypassed by future visibility logic changes.

## 4. Attribution minimization decision

The preservation draft currently stores both `creator_display_name` and `creator_handle_snapshot`. The approved requirement is historical creator attribution displayed as plain, non-clickable text; a retained handle is not necessary to satisfy that minimum and may preserve more identifying information than needed.

Before migration finalization:
- Prefer only the minimum agreed display label unless there is an explicit product requirement for the historical handle.
- Never use the snapshot to build a profile URL or grant author-management privileges.
- Do not retain email, birthdate, profile bio, or avatar merely for attribution.

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
