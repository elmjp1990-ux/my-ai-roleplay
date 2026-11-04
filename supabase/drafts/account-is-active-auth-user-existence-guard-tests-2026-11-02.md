# Account activity guard — stale JWT regression test plan (2026-11-02)

Status: **draft test plan; not executed**. Run only against a disposable local Supabase stack after a complete schema bootstrap. Never run against the hosted test project.

## Threat model

Supabase access JWTs are stateless and can remain valid until their `exp` after an Auth user is deleted. The current `public.account_is_active()` checks only `auth.uid() IS NOT NULL` and absence of `public.account_deletion_requests`. Because that request table has an `ON DELETE CASCADE` FK to `auth.users`, deletion removes the pending-request row while the old JWT may still contain its subject.

The proposed draft function adds an existence check against `auth.users` while retaining SECURITY DEFINER and an empty search_path.

## Local fixture requirements

Create all users through the local Supabase Auth Admin API (do not hand-insert into `auth.users`):
- `active_user`: exists, no deletion request.
- `pending_user`: exists, with a pending deletion request.
- `deleted_user`: create through Auth Admin, capture its access JWT and UUID, then delete it through local Auth Admin while retaining the captured JWT for the stale-token test.
- `control_user`: exists and owns seeded records used to prove unrelated public/owner access is unchanged.

Use only synthetic data and a disposable local Supabase stack. Do not reuse hosted user IDs or credentials.

## Function-level assertions

For each case, set the local request JWT claims and execute as `authenticated`:
1. active_user: `account_is_active() = true`.
2. pending_user: `account_is_active() = false`.
3. deleted_user with captured, unexpired JWT after Auth deletion and request-row cascade: `account_is_active() = false`.
4. no subject / anon: no authenticated access; function must not become an anonymous information oracle.

For the stale-token assertion, verify the captured JWT is still cryptographically/time-valid locally and that only the Auth-user-existence check denies it. Do not replace this with a fabricated claim alone in the final E2E test.

## Restrictive RLS integration assertions

The live policy inventory shows `account_is_active()` in RESTRICTIVE policies on:
- `characters`
- `character_stories`
- `conversations`
- `messages`
- `profiles`
- `chat_groups`
- `chat_group_scenes`
- `chat_group_members`
- `chat_group_turns`
- `chat_group_messages`

For each table, use synthetic rows and test the operations permitted by its existing grants/policies:
- Existing active owner retains the previously allowed owner read/write behavior.
- Pending-deletion owner is denied by the restrictive policy.
- Deleted-user stale JWT is denied even though the deletion-request row has cascaded away.
- A different active owner’s private rows remain inaccessible.
- Public/anon read behavior remains exactly as before; this patch must not broaden public access.
- Service-role worker RPCs retain their existing EXECUTE grants and are not routed through authenticated-user RLS assumptions.

Record table, command, expected result, actual result, and fixture IDs. Do not infer a pass from the scalar function test alone.

## Function security regression

Verify after applying the draft locally:
- `prosecdef = true`
- `proconfig` includes empty `search_path`
- owner remains `postgres`
- EXECUTE is available to `authenticated` and `service_role`
- EXECUTE is not available to `PUBLIC` or `anon`
- function body checks both `auth.users` existence and absence of a deletion request.

## Migration provenance blocker

The connected project's `supabase_migrations.schema_migrations` lists version `20261017010847`, name `account_deletion_worker`, but:
- the exact migration path has no GitHub commit history;
- the PR branch tree has no corresponding migration file;
- the connected project migration history is metadata, not the original SQL body.

Do not reconstruct and label a new file as the original migration. To unblock disposable replay, first obtain an authoritative original SQL source from a trusted backup/export or explicitly create a clearly named **local-only baseline reconstruction** after comparing the full live catalog. Keep the reconstruction outside deployable migrations and never apply it to hosted environments.

## Exit criteria

Do not call this fixed until:
1. A disposable local stack is bootstrapped reproducibly.
2. The proposed function draft is applied locally only.
3. All function-level and table-level stale-JWT tests pass.
4. Existing active-user and public-read behavior is unchanged.
5. Function ACL/security attributes match the expected matrix.
6. CI runs these tests on PR updates.


## Retained character media regression

After applying both account activity and character-preservation drafts locally:

- An active player with an existing single-chat session can read only the linked illustration/video objects.
- An active player with an existing group session can read only assets linked to that group's existing character members.
- A player with no prior session cannot read the archived character's private assets.
- A deleted account with a still-valid captured JWT cannot read media through `private.user_has_existing_character_session` or `private.can_read_character_asset`.
- A pending-deletion account is denied by the same helper.
- A live unrelated account cannot enumerate arbitrary owner-prefixed folders or read another character's assets.
- Public/eligible character media reads remain unchanged for non-archived characters.

The character-preservation draft now explicitly calls `public.account_is_active() IS TRUE` inside `private.user_has_existing_character_session`. This must be tested together with the Auth-user-existence guard; applying only one half leaves the stale-JWT risk unresolved.
