# `public.characters` baseline provenance investigation — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`  
Working branch: `security/chat-deletion-lifecycle-reconciliation`  
Supabase test project: `ouyewoagbmtqehbofrje`  
Scope: read-only schema and migration-history inspection; documentation only.

## Confirmed live test database state

Read-only `list_tables` and catalog inspection confirms:

- `public.characters` exists in the connected test project.
- It currently contains 11 rows. This count does not establish whether those rows are the original sample characters; no row names or content were inspected.
- It is RLS-enabled.
- Current columns include `id`, `author_id`, `name`, `title`, `gender`, `age`, `avatar_url`, `visibility`, `review_status`, `created_at`, `intro`, `race`, `style`, `tags`, `first_published_at`, `latest_eligible`, `rights_confirmed`, `deleted_at`, `deletion_reason`, `phone_settings`, `nsfw_workplace_warning`, `is_nsfw`, `avatar_video_path`, and `personality_profile`.
- Numerous live tables have foreign keys referencing `public.characters(id)`, including chat, group, story, illustration, schedule and encounter tables. It is a core application table, not a sample-data table.

## Confirmed migration-history gap

The live `supabase_migrations.schema_migrations` history begins at version `20261015065943` (`isolate_character_private_info`).

That first recorded migration creates `public.character_private_info` with a foreign key to `public.characters(id)`, and copies rows from `public.characters`. It does not create `public.characters` or `public.profiles`.

The next recorded migrations also assume existing base tables. The repository's `supabase/migrations` directory has no migration that creates the original `public.characters` table. A read-only scan of all recorded migration statements also found no `CREATE TABLE public.profiles`; the baseline gap therefore appears to include both foundational tables, not just `characters`. Its earliest timestamped group schema migration is `20261015141259_group_chat_core_schema`, which also references `public.characters`.

Repository file `supabase/migrations/20261015_character_soft_delete.sql` is an ALTER/soft-delete migration; it adds `deleted_at` and `deletion_reason` and creates functions/policies. It is not the base table creation.

Therefore the local clean replay error is consistent with a missing pre-existing baseline: the live database had base schema created before the first tracked migration, likely through an earlier manual SQL / Dashboard operation or an untracked initial setup script. The exact source is not yet recovered.

## GitHub history cross-check

The earliest matching repository commit found for the character persistence flow is `79760d81e2d72b73808ac8807c7ec0b75bb61ecf` (2026-10-14, "Connect character editor to Supabase"). Its application diff already upserts rows into `public.characters` and `public.profiles`, but contains no CREATE TABLE SQL. This supports that the application was connected to pre-existing tables by that point; it does not reveal who/what originally created them.

Commit: https://github.com/elmjp1990-ux/my-ai-roleplay/commit/79760d81e2d72b73808ac8807c7ec0b75bb61ecf

## User-provided history

The user recalls creating a batch of public sample characters before using ChatGPT for coding, then later asking for those sample character records to be deleted.

That history may explain deletion of example rows, but it does not imply the `public.characters` relation was dropped. Current live schema confirms the relation still exists. Do not conflate row deletion with table deletion.

## Safety decisions

- Do NOT drop, recreate, truncate, or reset `public.characters`.
- Do NOT treat the current 11 rows as proof of original sample data or inspect their contents without a specific need.
- Do NOT create a guessed baseline migration from current live state and label it as the original history.
- Do NOT alter hosted migration history or run `db reset` / `db push` to bypass this issue.
- Do NOT replay historical migrations against the connected test project.
- PR #200 remains Draft/unmerged; no hosted DDL/DML was executed during this investigation.

## Next recovery steps

1. Search the earliest project setup history, old SQL Editor snippets/exports, and repository history before `20261015065943` for the original `profiles` and `characters` CREATE TABLE statements.
2. Compare recovered original base schema against live catalog metadata: columns/defaults, PK/FK/check constraints, indexes, RLS policies, triggers, grants, sequences and dependent objects.
3. If original source cannot be recovered, design a separately reviewed, clearly labeled **baseline reconstruction for disposable local test replay only**, generated from catalog evidence and validated independently. Do not silently backdate it or claim it is the original migration.
4. Only after the baseline is reproducible should PR #200 migration replay and transactional deletion/snapshot tests resume.

## Evidence

- Live migration `20261015065943 / isolate_character_private_info` begins by creating `character_private_info` referencing `characters`; it does not create `characters`.
- Live test database table listing confirms `public.characters` and its current columns/FK dependencies.
- Repository file `supabase/migrations/20261015_character_soft_delete.sql` alters an already-existing table.


## Additional catalog fingerprint captured read-only

For future baseline comparison, the live test project reports:

- Both `characters` and `profiles` are owned by `postgres`, RLS enabled, FORCE RLS disabled.
- `characters` primary key `id`; FK `author_id → profiles(id) ON DELETE CASCADE`; checks for owner-scoped avatar video path, JSON object `phone_settings`, and bounded JSON object `personality_profile`.
- `characters` indexes: primary key, `idx_characters_author_id`, and partial `characters_active_public_idx` on visibility/review status/first published time where not deleted.
- `profiles` primary key `id`; unique `handle`; FK `id → auth.users(id) ON DELETE CASCADE`; `persona_presets` JSON array check.
- Character policies currently include owner create/update/delete, visibility + age-gated select, account-active restriction, and restrictive soft-delete visibility. Profiles policies include owner read/update/insert and public six-column read.
- Character triggers currently include `characters_prevent_soft_delete_restore` and `guard_pending_account_character_write` (BEFORE INSERT/UPDATE/DELETE).

This is a current-state fingerprint only, not a claim about the original base schema. Full current column list and constraints are available from the live catalog; future reconstruction must compare every object and dependency rather than copying only this summary.


## Detailed read-only catalog capture — 2026-11-02 follow-up

The following was captured directly from the connected test project's PostgreSQL catalogs. This is current live state only; it is not original migration provenance.

### Column-level evidence

public.characters columns in ordinal order (ordinal gaps are retained; do not infer missing historical columns):
- id uuid NOT NULL DEFAULT gen_random_uuid()
- author_id uuid NOT NULL
- name text NOT NULL
- title text NULL
- gender text NULL
- age integer NULL
- avatar_url text NULL
- visibility text NULL DEFAULT 'public'
- review_status text NULL DEFAULT 'approved'
- created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
- intro text NULL
- race text NULL
- style text NULL
- tags jsonb NOT NULL DEFAULT '[]'::jsonb
- first_published_at timestamptz NULL
- latest_eligible boolean NOT NULL DEFAULT true
- rights_confirmed boolean NOT NULL DEFAULT false
- deleted_at timestamptz NULL
- deletion_reason text NULL
- phone_settings jsonb NOT NULL DEFAULT '{}'::jsonb
- nsfw_workplace_warning boolean NOT NULL DEFAULT false
- is_nsfw boolean NOT NULL DEFAULT false
- avatar_video_path text NULL
- personality_profile jsonb NOT NULL DEFAULT '{}'::jsonb

public.profiles:
- id uuid NOT NULL (no column default observed)
- handle text NOT NULL
- nickname text NOT NULL
- avatar_url text NULL
- bio text NULL
- status text NULL DEFAULT 'active'
- created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
- persona_presets jsonb NOT NULL DEFAULT '[]'::jsonb
- birthdate date NULL
- follower_count integer NOT NULL DEFAULT 0

### Constraints and indexes

- characters: PK id; FK author_id → profiles(id) ON DELETE CASCADE; check avatar_video_path is NULL or owner-scoped path; personality_profile must be JSON object and <= 12000 bytes; phone_settings must be JSON object.
- characters indexes: PK; idx_characters_author_id(author_id); partial characters_active_public_idx(visibility, review_status, first_published_at DESC) WHERE deleted_at IS NULL.
- profiles: PK id; unique handle; FK id → auth.users(id) ON DELETE CASCADE; persona_presets must be JSON array and <= 30 entries.
- Extension dependencies, grants, sequences, object owners and referenced function definitions still need separate capture.

### Current RLS policy evidence

- characters: account_must_be_active ALL; owner DELETE/INSERT/UPDATE; SELECT allows owner or public non-deleted character subject to NSFW age gate.
- profiles: account_must_be_active ALL; public read policy profiles_public_read_six_columns; owner-only UPDATE/INSERT/SELECT policies.
- RLS is enabled on both tables; FORCE RLS is disabled.
- Trigger evidence: characters has BEFORE UPDATE characters_prevent_soft_delete_restore; and BEFORE INSERT/UPDATE/DELETE guard_pending_account_character_write. No public.profiles trigger was returned by information_schema.triggers.

### Verification boundaries and next step

- Successful read-only catalog queries returned columns, policies, indexes, constraints and triggers. An initial combined catalog query failed due to an OID-array cast; a revised query succeeded. No data rows were read.
- This evidence narrows reconstruction work but does not yet make a safe baseline. Exact grants/ACLs, function definitions and dependencies, enum/domain/extension dependencies, table owner/replica identity, and all foreign keys referencing these tables remain to be captured. We must reconcile live catalog state with later migrations to avoid duplicating columns or policies.
- Do not generate or apply baseline SQL until this dependency and migration-delta review is complete.

## Account-deletion FK dependency and cleanup reconciliation — 2026-11-02

### Live FK dependents of public.characters

Current catalog lists these references:
- CASCADE: character_comments.character_id; character_illustrations.character_id; character_private_info.character_id; character_schedule_descriptions.character_id; character_schedules.character_id; character_stories.character_id; encounter_character_state.character_id; encounter_diary.character_id; encounter_turn_interaction_receipts.character_id.
- SET NULL: chat_group_members.character_id; chat_group_messages.character_id; chat_groups.world_character_id; chat_sessions.character_id; encounter_session_evaluation_jobs.character_id; encounter_session_lifecycle.character_id; encounter_session_turns.character_id; story_relationship_batches.character_id; story_relationship_states.character_id.
This is a mixed retention model: character-owned auxiliary records cascade, while chat/encounter snapshots and relationship/audit records can survive with a nullable character reference.

### Live FK dependents of public.profiles

- CASCADE: author_follows.author_id; character_illustrations.author_id; character_private_info.author_id; characters.author_id; conversations.user_id; wallet_accounts.user_id; wallet_transactions.user_id.
- No ON DELETE action (default NO ACTION / RESTRICT): ai_generation_records.user_id and chat_message_versions.edited_by.
- Other dependent references observed: chat_message_versions.message_id → chat_messages(id); ai_generation_records.session_id → chat_sessions(id); ai_generation_records.user_message_id / assistant_message_id → chat_messages(id).

### Reconciliation with the actual account-deletion routine

The two non-cascading profile references are not automatically safe merely because the archive function exists. The current live prepare_account_deletion(p_user_id) definition explicitly handles both before profile deletion:
1. Deletes that account's ai_generation_records after archive verification.
2. Deletes version rows for messages belonging to the account being deleted.
3. For version rows on another user's messages, sets edited_by = NULL so another user's edit history is retained without retaining the deleted account's profile reference.
4. Deletes that account's chat_turn_charges, wallet transactions, and conversations before returning the batch as deleting.

The live archive_account_deletion_data(p_user_id) archives ai_generation_records and wallet_transactions as JSON payloads and verifies source counts and exact payload equality before marking the batch archived. The current prepare_account_deletion also verifies billing/audit snapshots before entering the irreversible phase. finalize_account_deletion(p_batch_id) only marks a batch completed after confirming the Auth user no longer exists.

### Risk / acceptance interpretation

- The RESTRICT references are intentional/manual-cleanup dependencies in the current function, not proof that account deletion necessarily fails.
- They are high-risk regression points: if a future code path deletes profiles / auth.users without calling the guarded preparation routine, FK deletion should fail closed rather than silently lose audit data.
- chat_message_versions.edited_by is nullable, and the current routine anonymizes the editor reference only for messages owned by other users.
- ai_generation_records.user_id is NOT NULL, so the current routine must delete these rows after verified archival; a nullable/set-null conversion would be a policy change and is not proposed here.
- The account_deletion_requests catalog query returned columns but no RLS policies in pg_policies. This needs separate ACL/function-privilege review; absence of a policy row alone does not establish exposure or access.

### Scope and safety

All evidence above came from SELECT-only catalog reads and function-definition inspection. No application rows were selected. No functions were invoked. No DDL/DML, migration, deployment, or hosted-data mutation occurred.

## Account deletion control-plane ACL / RLS review — 2026-11-02

### Tables

- account_deletion_requests: RLS enabled, FORCE RLS disabled; owner postgres; table ACL grants postgres and service_role. No direct anon/authenticated table grants were present in relacl. pg_policies returned no policies for this table.
- account_deletion_archive_batches: RLS enabled, FORCE RLS disabled; owner postgres; ACL only postgres. No policies returned.
- account_deletion_archive_items: RLS enabled, FORCE RLS disabled; owner postgres; ACL only postgres. No policies returned.
- This is a locked-down control-plane pattern: client access is through narrowly scoped SECURITY DEFINER RPCs; service_role owns worker access; archive payload tables are not directly granted to client roles. Continue verifying default privileges and any inherited role grants before final sign-off.

### RPC EXECUTE ACL and function properties

All inspected account deletion RPCs are SECURITY DEFINER and set search_path to empty:
- authenticated + service_role + postgres: request_account_deletion(), cancel_account_deletion(), get_account_deletion_status().
- service_role + postgres only: archive_account_deletion_data(uuid), prepare_account_deletion(uuid), finalize_account_deletion(uuid), record_account_deletion_failure(uuid,text), get_account_deletion_work_items().
- This keeps irreversible archive/preparation/finalization/worker queue functions unavailable to authenticated clients by direct EXECUTE grant.
- request_account_deletion() derives target identity from auth.uid(), checks configured grace period, and inserts only the caller's request.
- cancel_account_deletion() derives auth.uid(), locks that caller's request, and blocks cancellation after an exact request has entered an archive/deletion batch.
- get_account_deletion_status() filters by auth.uid().
- get_account_deletion_work_items() is service_role-only and returns due work plus interrupted deleting batches.
- record_account_deletion_failure() and finalize_account_deletion() are service_role-only. finalize requires batch status deleting and verifies the Auth user no longer exists.

### Remaining review gaps

- Table ACL relacl and function proacl were inspected, but default privileges, inherited grants, schema USAGE grants, and any edge-function / worker invocation authentication have not yet been fully audited.
- Need trace the actual worker/Edge Function or external invocation path that obtains get_account_deletion_work_items(), calls prepare_account_deletion(), deletes auth.users, then calls finalize_account_deletion(). The SQL function definitions alone do not prove that the deployed worker authenticates correctly or handles partial failures safely.
- No account deletion RPC was invoked. All evidence came from read-only catalog queries and pg_get_functiondef.
