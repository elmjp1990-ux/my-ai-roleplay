# Account deletion — author/profile dependency inventory, Round 44 — 2026-11-02

PR #200: Draft / unmerged
Branch: `security/chat-deletion-lifecycle-reconciliation`
Scope: read-only live Supabase catalog + complete tracked branch entrypoint scan.
No hosted DDL/DML, Auth/Storage mutation, deployment, or Cron changes.

## Confirmed dependency inventory

### 1. Direct profile foreign keys

Read-only catalog inspection reconfirmed these public-schema FKs to `profiles(id)`:

| Table.column | Delete rule | Account-deletion disposition |
|---|---|---|
| `characters.author_id` | CASCADE | Must detach active owner and preserve character row/content. |
| `character_illustrations.author_id` | CASCADE | Must preserve metadata; replace active-owner relation with durable creator attribution. |
| `character_private_info.author_id` | CASCADE | Must preserve private character setting data; access must no longer be granted to deleted account. |
| `author_follows.author_id` | CASCADE | User social graph; likely delete/anonymize as user-owned relation, not preserve as character content. |
| `conversations.user_id` | CASCADE | User-owned conversation state; classify separately from character data. |
| `wallet_accounts.user_id` | CASCADE | Financial/account policy required; do not alter casually. |
| `wallet_transactions.user_id` | CASCADE | Potential financial audit evidence risk; must not silently cascade away charge/refund history. |
| `ai_generation_records.user_id` | NO ACTION | Can block profile/Auth deletion until retention/anonymization policy is explicit. |
| `chat_message_versions.edited_by` | NO ACTION | Can block profile/Auth deletion; historical editor attribution needs a safe non-auth identity or explicit retention policy. |

Character-related FKs:
- `character_illustrations.character_id -> characters.id ON DELETE CASCADE`
- `character_private_info.character_id -> characters.id ON DELETE CASCADE`

The account deletion migration must not delete a character row, or these character-owned records will be lost.

## 2. RLS policy dependencies

The live policy inventory identified author/profile-dependent policies on:

- `characters`: author INSERT/UPDATE/DELETE and SELECT visibility policy.
- `character_illustrations`: author INSERT/UPDATE/DELETE and eligible-viewer SELECT.
- `character_private_info`: author-only ALL policy, cross-checking both row author_id and characters.author_id.
- `character_schedules` and `character_schedule_descriptions`: author-only SELECT/INSERT/UPDATE/DELETE.
- `character_stories`: author-only ALL policy via characters.author_id.
- `chat_sessions`: INSERT policy allows public approved character or current author-owned character; this author exception must not permit new sessions after account archive.
- `character_comments` and `character_comment_likes`: visibility and whisper redaction depend on current author identity.
- `character_illustration_cleanup_jobs`: author-scoped upload rollback queue; must not be confused with durable character asset retention.
- `author_follows`: follower/author relation.

Important consequence: historical creator attribution must never be substituted into these write-authority checks. Durable attribution is display/provenance only. Former account credentials must not gain management or private-data access.

## 3. Trigger / function / view dependencies

Read-only catalog inspection found:

- `public_profiles` view selects `id, handle, nickname, avatar_url, bio, follower_count` from `profiles`; `reloptions = security_invoker=true`. It is not an independent historical attribution store.
- `sync_author_follower_count()` updates `profiles.follower_count`; account deletion/follow cascade must not cause a trigger failure or retain stale profile writes.
- `guard_pending_account_character_write()` reads `account_deletion_requests` and uses `characters.author_id` to block pending-account writes.
- `character_can_start_chat()` permits current author or public approved character, excluding deleted_at; future archive state must be an unconditional deny for new creation, including former author exception.
- `save_character_schedules()`, `soft_delete_character()`, and `sync_character_chat_snapshot()` all use `characters.author_id` as current ownership.
- `get_character_comments_safe()`, `private.comment_reply_allowed()`, `private.current_user_is_adult()`, and `get_character_turn_counts()` depend on character/profile identity or visibility. These need review for deleted-account and archived-character behavior.
- `handle_new_user()` and `save_my_profile()` are profile lifecycle/write functions; do not repurpose them for historical creator attribution.

## 4. Tracked frontend / Edge Function scan

Scanned all tracked TypeScript Edge Function files and `index.html` on the PR branch head. This is a repository-tree scan, not GitHub code-search indexing.

Frontend `index.html` dependencies include:
- Public character hydration selects `author_id`, builds an author ID list, and fetches `public_profiles`.
- Character owner state is computed as `state.account.uid === row.author_id`.
- My-character list queries filter `characters.author_id = user.id`.
- Character illustration load/save/delete and cleanup-job paths filter or insert `author_id = userId`.
- Character primary illustration/video path management updates `characters` by `author_id`.
- These paths must migrate to a distinct active-owner field. Historical attribution must only populate a non-clickable display label and must not mark a character as editable/owned by the deleted account.

Edge Function scan:
- `encounter-session/index.ts` and `story-session/index.ts` select `author_id` and include `authorId` in snapshots.
- No other tracked Edge Function TypeScript file in the current tree matched `author_id`, `authorId`, or `profiles`. This does not prove there are no dynamic SQL strings or external/manual callers.

## 5. Required implementation sequence

1. Recover/verify the complete foundational schema baseline; no guessed migration.
2. Create durable creator attribution independent of Auth/profile; snapshot only the historical display label required by product.
3. Introduce explicit active-owner identity (nullable after account deletion) and separate archived/account-deleted state. Do not overload `deleted_at` because author manual deletion and account deletion have distinct lifecycle semantics.
4. Backfill attribution for characters and illustration metadata before any FK change.
5. Preserve character-owned rows: characters, private info, stories, schedules, schedule descriptions, illustrations, avatar video references.
6. Update every RLS policy, trigger, helper, RPC, view and frontend query listed above. All author write paths must require a non-null active owner matching auth.uid and active account.
7. Make archived characters unavailable for all new single/group/encounter/story sessions; existing authorized sessions continue based on their own ownership and snapshots.
8. Preserve media objects in private buckets. Existing-session media read must be authorized by exact active session + character + exact media row/path; do not grant former author access or broad folder access.
9. Resolve NO ACTION references and financial retention policy before Auth deletion.
10. Test deleted account cannot authenticate/manage; creator label remains non-link text; characters/settings/media remain; existing players continue only their own chats; no new session can be created; public discovery is hidden.

## 6. Current risk / release status

- This is a dependency inventory, not an executable migration.
- Do not run account deletion on the live test project yet.
- Account-deletion worker remains disabled/un-deployed.
- PR #200 remains Draft/unmerged.
- Test grace period remains 5 minutes; production target remains 30 days.
- No hosted DDL/DML, Auth/Storage mutation, deployment or Cron changes occurred in this round.
