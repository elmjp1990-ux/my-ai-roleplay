# Character child-table account-deletion RLS freeze tests — 2026-11-02

Status: draft test plan only; not executed.
Run only on a disposable local Supabase stack after a trusted baseline replay.
Never execute against the connected hosted test project.

## Tables and policies under test

The companion draft `account-deletion-character-child-write-freeze.sql` adds restrictive `account_must_be_active` policies for authenticated users on:

- `character_private_info`
- `character_schedules`
- `character_schedule_descriptions`
- `character_illustrations`

Existing permissive owner policies must remain in place. The new restrictive policy is an additional AND condition and must not replace ownership/parent-character checks.

`character_stories` already has a restrictive account-active policy in the live catalog; verify it remains intact. Do not apply this draft to player-authored `character_comments` or `character_comment_likes`; those records have a separate lifecycle.

## Synthetic fixtures

Create via local Auth Admin API:
- active creator account with one character and rows in all four child tables;
- pending-deletion creator account with equivalent rows;
- deleted creator account with captured unexpired access JWT;
- unrelated active player account;
- one public character and one private character for unchanged visibility controls.

All rows and objects must be synthetic and created on a disposable local Supabase stack.

## Required assertions

For each of the four child tables, test SELECT, INSERT, UPDATE, DELETE as supported by existing grants:

1. Active creator can perform only the operations previously allowed by the existing owner policy.
2. Pending-deletion creator is denied by the restrictive account-active policy, even if author_id still matches.
3. Deleted creator's still-valid JWT is denied after the Auth user row and deletion-request row are gone.
4. Unrelated active account cannot read or mutate another creator's private child rows.
5. Public/anon read behavior for eligible illustration metadata remains unchanged; no public write permission is added.
6. Existing owner predicates still prevent moving a child row to a character not owned by the caller.
7. A failed or missing account_is_active() evaluation fails closed.

## Character archival integration

After applying the character-preservation draft:
- character, private-info, schedule, schedule-description, illustration metadata rows remain.
- active owner fields are detached/null as designed.
- creator attribution remains display-only and non-navigable.
- former creator cannot use stale JWT to access author-only child rows.
- an active existing player retains only the exact existing-session reads required by product.
- no new single/group/encounter/story session can be created for the archived character.

## Concurrency / race tests

Use two independent authenticated sessions:
- Session A begins a child-row write before account archival.
- Session B runs the account-archive transaction.
- Verify the archive transaction waits/serializes or rejects the concurrent write and commits a fully consistent state.
- After archive commit, Session A and all later requests must not mutate any retained child row.
- Repeat for private info, schedules, schedule descriptions, and illustration metadata.
- Inject rollback before commit and verify all ownership fields/policies/data remain unchanged.

A restrictive policy only blocks statements whose policy snapshot sees the pending-deletion state. The implementation must also prove the archival transaction has a safe lock/fencing boundary for in-flight statements.

## Exit criteria

- All policy composition assertions pass.
- Existing active-owner permissions are unchanged.
- Pending and deleted accounts cannot access or mutate protected child rows.
- No public/anon privileges are broadened.
- Concurrency tests show no post-archive child writes.
- Test output is recorded with synthetic fixture IDs and SQLSTATE/results.


## Archived-character attachment trigger tests

The character-preservation draft also adds `private.guard_new_session_character_not_archived()` to:

- `chat_sessions` BEFORE INSERT OR UPDATE OF `character_id`
- `chat_group_members` BEFORE INSERT OR UPDATE OF `character_id`

Required tests on a disposable local stack:

1. Direct authenticated single-chat INSERT for an archived character is rejected.
2. Encounter and Story service-role RPC INSERTs for an archived character are rejected by the same database trigger, even if an Edge pre-check is accidentally omitted.
3. Group creation/member INSERT for an archived character is rejected.
4. Reassigning an existing session or group member to an archived character is rejected.
5. Existing single/group session continuation remains allowed because it does not insert or reassign the character reference.
6. Existing group messages for an already-authorized group remain allowed; do not add a blanket trigger to `chat_group_messages`.
7. Concurrency: if a new session obtains the character `FOR KEY SHARE` lock first, archival waits and the newly created session is treated as pre-existing; if archival obtains `FOR UPDATE` first, the new session waits and then fails after seeing `account_archived_at`.
8. A failed archival transaction rolls back the marker and does not permanently block new sessions.

The trigger is a defense-in-depth gate, not a replacement for caller authentication, account-active checks, RLS, or the explicit new-session eligibility functions.
