# Account deletion — durable creator attribution and retained character schema design — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`
PR: #200 — Draft / unmerged
Round: 43
Environment: read-only inspection of the connected Supabase test project and PR branch.
Status: design-only. No migration was generated or applied; no DDL/DML, Auth, Storage, deployment, or Cron mutation was performed.

## User-approved behavior (unchanged)

When an account deletion grace period expires:
- Delete the Auth account.
- Preserve every character row, character settings, private settings, schedules, stories, illustration metadata, illustration objects, avatar video objects, and historical creator attribution, including never-published characters.
- Archive/private all retained characters and remove them from public discovery and every new-chat/session creation path.
- Existing authorized player conversations remain usable.
- Historical creator attribution is display-only and must not link to a live author profile.
- Keep chat-memory photo cleanup separate on its existing 30-day schedule.

Test grace period remains 5 minutes; production target remains 30 days. This design does not change either value.

## Round 43 live schema findings

Read-only catalog inspection confirmed:

### Identity and ownership
- `profiles.id` is the profile identity.
- `characters.author_id` is UUID NOT NULL and FK to `profiles(id)` with `ON DELETE CASCADE`.
- `character_illustrations.author_id` is also FK to `profiles(id)` with `ON DELETE CASCADE`.
- `character_illustrations.character_id` cascades from `characters(id)`.
- Character content is stored directly on `characters`, including `name`, `intro`, `personality_profile`, `phone_settings`, `avatar_video_path`, publication/deletion fields, and visibility.
- `profiles` currently has `handle`, `nickname`, and `avatar_url`; these can supply the historical creator display snapshot, but must not be retained as a navigable profile.
- Current `author_id NOT NULL` and author-based RLS assumptions mean simply setting author_id to NULL is not a complete migration. Every dependent policy, query, insert/update path, and FK must be reconciled.

### Other profile foreign keys
The inspected public-schema FKs referencing profiles include:
- `author_follows.author_id` — CASCADE
- `character_illustrations.author_id` — CASCADE
- `character_private_info.author_id` — CASCADE
- `characters.author_id` — CASCADE
- `conversations.user_id` — CASCADE
- `wallet_accounts.user_id` — CASCADE
- `wallet_transactions.user_id` — CASCADE
- `ai_generation_records.user_id` — NO ACTION
- `chat_message_versions.edited_by` — NO ACTION
Other FKs point from chat/encounter/story/group records to characters, mostly SET NULL for session references and CASCADE for character-owned configuration/illustration rows. These must be assessed table-by-table; do not globally rewrite all profile FKs to SET NULL.

### Storage
Three private buckets exist:
- `character-illustrations` (private)
- `character-avatar-videos` (private)
- `personax-memory-photos` (private)

Current illustration/video object paths are owner-prefixed. Existing Storage SELECT policies permit the author to read their own objects, and permit public eligible viewers to read character-linked media through `character_illustrations` / `characters`. Once a character is archived, public eligibility no longer applies. Existing-chat viewers therefore need a narrowly scoped read path for the exact character media referenced by their existing active chat session; this must not grant general bucket or folder access.

Existing illustration INSERT/UPDATE/DELETE policies also rely on a live `characters.author_id = auth.uid()` ownership relationship. These author-management paths must become unavailable after account deletion; do not preserve edit rights merely to preserve historical attribution.

### Worker
The PR branch worker calls, in order, the service-side RPCs for work-item retrieval, archive, prepare, then Supabase Auth Admin `deleteUser(userId)`, checks Auth absence on retry, and finalizes. The worker source therefore has a real Auth deletion step; the archive/prepare RPCs must complete the durable attribution and ownership decoupling before that call. This worker remains disabled/un deployed and PR #200 remains Draft.

## Proposed schema direction (not executable SQL)

Prefer a separate immutable attribution identity, not a retained profile and not an FK to Auth:

1. Add a durable creator attribution table, provisionally `character_creator_attributions`, with a generated UUID primary key independent of `auth.users` and `profiles`. Store only the approved historical display snapshot (e.g. display label and attribution creation metadata). Do not store a live handle URL, profile route, or login identity that can be resolved into a public profile.
2. Add a non-null `creator_attribution_id` reference to each character and illustration metadata row. The FK must reference only the durable attribution table and must not cascade from Auth/profile deletion.
3. Separate current account ownership from historical creator attribution. Make active `author_id` nullable (or use a dedicated nullable active-owner column) and ensure its FK cannot cascade-delete the character. On account deletion, archive the character and clear the active owner while retaining `creator_attribution_id`.
4. For legacy rows, backfill one attribution record per original author identity (or a deliberate shared identity where the product explicitly requires it), snapshotting the chosen historical display label before deleting profiles. Link all their characters and illustration rows to it.
5. Do not retain profile rows, login credentials, or author-management privileges just to keep the attribution label.
6. Update every character/illustration RLS policy and all application queries to distinguish active owner from historical creator. Only active authenticated owners may manage content. Historical attribution is read-only display data.
7. Ensure creator label rendering is plain text, not a link, after account deletion. Avoid generating a route from a stale handle.

This is a design direction, not a final migration. Before writing executable migration SQL, inspect every RLS policy, trigger, view, RPC, Edge Function, frontend author query, and FK that references `author_id` or `profiles`. Confirm no hidden dependency expects author_id NOT NULL.

## Storage access design requirements

- Keep both character media buckets private; do not change them to public.
- Preserve object names and bytes. Do not run an account-deletion Storage sweep.
- Keep owner-prefixed paths stable to avoid rewriting character metadata and breaking existing references.
- Remove post-deletion author management access from object INSERT/UPDATE/DELETE.
- Preserve public eligible read behavior for currently public characters.
- Add a narrow existing-session media read policy or signed-URL Edge path that proves:
  - caller JWT is valid and account is active;
  - the caller owns a non-deleted existing chat session for the exact character;
  - the character/media path is linked to that exact character;
  - the session's character identity matches the stored character/snapshot;
  - no new session is created and no arbitrary object path is accepted.
- Evaluate encounter and story sessions as well as traditional chat sessions. A generic folder-level allow rule is prohibited.
- Keep `personax-memory-photos` policies and the independent 30-day cleanup queue unchanged.

## Additional blockers / required audit before implementation

- `character_private_info.author_id` cascades from profiles. Decide whether this private author-only data should be retained as character settings under the character's durable attribution, while making it inaccessible to former account credentials. The user's requirement to preserve character settings means it cannot silently disappear.
- `character_illustrations.author_id` is duplicated ownership metadata. It must be decoupled without weakening active-owner write checks.
- `conversations.user_id`, wallet tables, follows, and generation records are user-owned data and require their own account-deletion disposition. Do not preserve these merely because character content is retained.
- `ai_generation_records.user_id` and `chat_message_versions.edited_by` have NO ACTION FKs and may block Auth/profile deletion depending on their complete FK chain; audit before execution.
- Verify the profile-to-Auth FK and all indirect delete triggers in the full schema before migration.
- Existing media reads for already-started conversations must be tested after the profile and Auth identities are absent; signed URL refresh must not depend on a deleted owner session.
- Do not assume the current author_id-based character list queries will work after ownership is detached.

## Required tests before enabling account deletion

1. Delete synthetic account with multiple published and never-published characters.
2. Verify all character rows and all character configuration rows remain.
3. Verify creator attribution label remains visible but non-clickable; no public author profile route remains.
4. Verify both character media buckets retain every linked object and existing sessions can still load media.
5. Verify former account cannot authenticate, edit, delete, republish, or upload new media.
6. Verify public discovery and all new single/group/encounter/story creation paths reject archived characters.
7. Verify each pre-existing authorized player can continue only their own existing chat; no new session can be created by reusing an old session ID.
8. Verify unrelated users cannot read private settings or media.
9. Verify account-owned follows/wallet/profile data follows its separately approved deletion policy.
10. Verify NO ACTION FK blockers are resolved without deleting durable character content.
11. Verify crash/retry around archive, prepare, Auth deletion, and finalize.
12. Run local migration replay, RLS tests, Storage policy tests, Deno checks, and CI before considering merge.

## Safety / release gate

- This file is a design note only; it is not a migration.
- No hosted DDL/DML, Auth mutation, Storage mutation, Edge Function deployment, or Cron change occurred.
- PR #200 remains Draft/unmerged.
- Do not enable the worker until durable attribution, nullable active ownership, all RLS/Storage/session paths, and recovery tests are implemented and independently verified.
