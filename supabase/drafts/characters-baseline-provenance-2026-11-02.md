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

## Account-deletion worker / scheduler execution-path audit — 2026-11-02

### Deployed Edge Functions inventory

The connected Supabase project currently lists these active Edge Functions:
- chat-turn
- expire-memory-album-photos
- encounter-session
- encounter-turn
- story-session
- encounter-session-state
- purge-chat-deletions

There is no account-deletion worker Edge Function in the deployed function inventory. The repository tree at the audited PR head likewise contains no account-deletion worker function; the only deletion worker function is purge-chat-deletions.

### Important separation: chat deletion worker is not account deletion worker

The deployed purge-chat-deletions handler claims chat deletion jobs and chat Storage deletion jobs, then calls purge_chat_deletion_job / mark_chat_deletion_job_failed and the corresponding storage RPCs. It does not call:
- get_account_deletion_work_items()
- archive_account_deletion_data()
- prepare_account_deletion()
- Auth Admin deleteUser
- finalize_account_deletion()

It must not be treated as proof that account deletion is automated.

### Scheduler evidence

A read-only query of cron.job returned exactly one active job:
- jobid 1, every minute: SELECT public.enqueue_due_encounter_evaluations(50);

No scheduled account-deletion worker invocation was present in cron.job. The repository migration enabling pg_net explicitly says the schedule for the chat-deletion Edge Function is intentionally deferred until end-to-end worker tests pass. This is separate from account deletion.

### Current conclusion

The database has account-deletion request/archive/prepare/finalize RPCs and permissions, but the connected project's deployed Edge Function inventory and active pg_cron schedule do not show an account-deletion worker or an automatic Auth user deletion path. Therefore, end-to-end automatic account deletion after the 30-day grace period is NOT verified and appears not yet implemented/deployed.

This is a material implementation gap, not a confirmed runtime failure. Do not create a cron schedule or worker as part of this audit. The next implementation step should be a separate account-deletion worker design and test suite, with strict service-only authentication, idempotent batch claims, archive verification, Auth Admin deletion, finalize, retry/failure states, and a dry-run/test-user gate. Keep it separate from purge-chat-deletions.

### Safety boundary

Only Edge Function inventory, repository tree, and SELECT from cron.job were inspected. No account data was read, no worker was invoked, no function was deployed, no cron job was created/modified, and no Auth user was deleted.

## Account-deletion worker implementation draft — 2026-11-02

### Added to PR branch (not deployed)

- `supabase/functions/_shared/account-deletion-worker.ts`: dependency-injected processor for archive → prepare → Auth Admin delete → finalize; sanitizes failure codes; marks a batch failure when a batch ID is known; only treats an Auth deletion error as idempotent success when a separate Auth lookup positively confirms the user is absent.
- `supabase/functions/_shared/account-deletion-worker.test.ts`: deterministic tests for success ordering, archive fail-closed behavior, Auth deletion failure, already-deleted Auth retry, and finalize false.
- `supabase/functions/account-deletion-worker/index.ts`: POST-only service-secret-authenticated Edge Function; does not accept target user IDs from request input; reads due work exclusively from service-only get_account_deletion_work_items(); limits each run to 10 items; calls the existing restricted RPCs and Supabase Auth Admin.
- `.github/workflows/account-deletion-worker-tests.yml`: isolated Deno test workflow.
- `supabase/config.toml`: function config uses verify_jwt=false only because the handler uses `withSupabase({ auth: "secret:default" })` to validate the named Supabase Secret Key before handler execution.

### Implementation boundaries / not yet accepted

- This is PR-only source code. The function has NOT been deployed; no cron schedule has been created.
- CI run has not yet been observed. The deterministic test file has been reviewed statically only; no claim that tests pass.
- The worker is intentionally separate from purge-chat-deletions.
- Existing SQL work-item function does not claim/lease rows. Archive and prepare RPCs lock the exact deletion request and reuse the same batch; Auth delete is retried idempotently by checking Auth user absence before finalize. A dedicated lease/claim mechanism may still be desirable if operational concurrency or worker overlap testing exposes contention.
- Before deployment, add an end-to-end disposable local Supabase test covering due request, archive verification, prepare cleanup, Auth Admin deletion, finalize, transient failure between each stage, and repeated invocation.
- Do not schedule until secret provisioning, deployed function behavior, failure recovery, and E2E tests are reviewed. Do not use real user accounts.

### Current status

Implementation draft exists on PR #200 branch only. PR remains Draft/unmerged. No live DB mutation, no account deletion invocation, no Edge Function deployment, and no schedule change occurred.

## Account-deletion post-Auth crash recovery fix — 2026-11-02

### Defect found during end-to-end control-flow review

The SQL work-item function deliberately includes a second result set for batches still in `deleting` when the corresponding account_deletion_requests row no longer exists. This is the recovery path after Auth Admin deletion cascades away the request row but the worker crashes before finalize.

The initial worker implementation ignored `work_status` / `batch_id` and always called archive_account_deletion_data() first. That RPC requires a due request row, so it would fail on precisely this post-Auth/pre-finalize recovery case. The existing 5 unit tests did not cover it.

### Fix

- For a work item with `work_status = deleting` and a non-null `batch_id`, the worker first checks Auth Admin for the target user.
- If Auth confirms the user is absent, the worker calls finalize(batch_id) directly. The finalize RPC independently verifies Auth absence and batch status before completion.
- If the Auth user still exists, the worker follows the normal archive → prepare → Auth delete → finalize path.
- Any lookup error is fail-closed by the outer error handler; no finalize is attempted unless absence is positively confirmed.

### Added regression tests

- Auth user absent + deleting batch: only Auth lookup and finalize are called; no request-dependent archive/prepare call.
- Auth user still exists + deleting batch: normal retry path continues; no premature finalize.

### Verification

- New CI run: GitHub Actions run 41365781489; status was in progress at documentation time. Do not claim pass until completed.
- This is a static/unit-test correction only. No Auth user was deleted, no worker deployed, no cron created, and no hosted DB mutation occurred.

## Stale JWT access after Auth deletion — critical RLS guard gap — 2026-11-02

### Verified live behavior

Supabase documents that deleting an Auth user removes refresh sessions / prevents new token minting, but an already-issued access JWT remains valid until its exp claim. Sensitive operations must check the session_id against auth.sessions or otherwise check the current Auth user record.

The connected database's current `public.account_is_active()` definition is:
- auth.uid() IS NOT NULL
- AND NOT EXISTS a row in public.account_deletion_requests for auth.uid()
- It does NOT check that auth.uid() still exists in auth.users.

The FK `account_deletion_requests.user_id → auth.users(id)` is ON DELETE CASCADE. Therefore, after Auth Admin deletes the user, the deletion request row disappears. An already-issued JWT can still carry auth.uid(); the current function then evaluates true, even though the Auth user no longer exists.

### RLS scope confirmed

The function is used by RESTRICTIVE policies (not merely permissive) on:
- characters
- character_stories
- conversations
- messages
- profiles
- chat_groups, chat_group_scenes, chat_group_members, chat_group_turns, chat_group_messages

Because these policies are RESTRICTIVE, the current account_is_active() result is a real guard on those tables. The missing auth.users existence check means that guard can reopen after request cascade for an outstanding JWT.

The function is SECURITY DEFINER, owned by postgres, search_path empty; current EXECUTE ACL is postgres, authenticated, service_role. A draft preserves this execution model while explicitly revoking PUBLIC/anon.

### Draft correction (not applied)

Added `supabase/drafts/account-is-active-auth-user-existence-guard.sql`:
- Require auth.uid() IS NOT NULL.
- Require an auth.users row matching auth.uid().
- Require no pending account_deletion_requests row.
- Preserve SECURITY DEFINER and empty search_path.
- Preserve authenticated/service_role execution; revoke PUBLIC/anon.

This draft is NOT a migration and has NOT been applied to the connected hosted project.

### Migration provenance gap

The live `supabase_migrations.schema_migrations` table lists version `20261017010847` / name `account_deletion_worker`, but the corresponding SQL migration file is absent from the current PR branch tree. This is a migration-source drift/provenance issue and must be reconciled before local replay. Do not invent the missing original migration or edit applied history.

### Required tests before applying

1. Valid existing Auth user, no deletion request → account_is_active() true.
2. Existing Auth user with pending request → false.
3. Deleted Auth user represented by a still-valid JWT claim and no request row → false.
4. Verify restrictive policies deny SELECT/INSERT/UPDATE/DELETE as appropriate for deleted JWT on the guarded tables.
5. Verify anon remains denied where it was previously denied and public read policies remain unchanged.
6. Verify service_role worker RPC execution remains intact.

### Safety

All findings came from SELECT-only function/policy/FK/catalog inspection and official Supabase documentation. No application rows were read; no function invoked; no DDL/DML, migration, deployment, cron, or Auth deletion occurred.

## Follow-up: source provenance and stale-JWT test plan — 2026-11-02

Further verification:
- GitHub commits API queried for exact path `supabase/migrations/20261017010847_account_deletion_worker.sql`; no commits returned.
- Recursive PR branch tree confirms no account-deletion migration source, only the current worker Edge Function/tests and later account-deletion guard migrations.
- Live migration history records only version/name metadata; it does not provide the SQL body.
- Live `account_is_active()` definition reconfirmed unchanged: non-null auth.uid() AND no account_deletion_requests row; no auth.users existence predicate.
- Live request FK reconfirmed ON DELETE CASCADE.
- Live account deletion schema reconfirmed: request scheduled_for default currently five minutes (test configuration), not 30 days. Existing settings/defaults need a separate policy review before any production launch; no changes made.

Added `supabase/drafts/account-is-active-auth-user-existence-guard-tests-2026-11-02.md` with local-only test fixtures and function + RESTRICTIVE RLS integration matrix. The stale JWT test must use a real locally issued, still-unexpired JWT captured before local Auth Admin deletion, not just a fabricated subject claim.

No hosted DB changes. No function execution. No user deletion. No deployment or cron changes.


## 2026-11-02 follow-up: repository and hosted schema-source recheck

A fresh recursive Git tree read at PR head `dd31b44124328ac9004f2ac5de38fbb10f30c4ff` confirms:
- The tracked migration directory begins with migrations that assume the foundational application tables already exist; no foundational `CREATE TABLE public.characters` / `public.profiles` migration is present in the branch tree.
- GitHub code-search requests for the exact table creation statements returned zero results (search endpoint marked results incomplete, so this is not proof that no historical source exists anywhere).
- The live Supabase migration ledger still starts at `20261015065943` and contains the previously identified migration history, but the missing original SQL body is not included in the ledger response.
- Verbose table inventory confirms that live `public.characters` and `public.profiles` have evolved columns, keys and references. This inventory is not a complete schema dump: it does not reconstruct all historical constraints, indexes, triggers, policies, grants, functions, extension dependencies, or exact creation order. It must not be used as a fabricated baseline migration.

## Local replay workflow review

The manual workflow starts a disposable local stack and then runs `supabase db reset --local --no-seed`. Because migration replay begins before the later CI-only draft migrations are copied into the migrations directory, the missing foundational schema prevents a valid clean replay before the workflow can reach the new account-deletion lease tests. This is a baseline blocker, not a reason to alter the connected hosted test database.

## Decision

Do not reconstruct `characters` / `profiles` from the compact table inventory and do not run the current workflow as if it were a valid end-to-end database test. The safe next source is a trusted schema-only dump or the original project bootstrap SQL from its true provenance. Once obtained, compare it against the live catalog and the migration sequence, then mark any local-only reconstruction as explicitly synthetic and separately reviewed. No application rows were queried by this follow-up, and no hosted writes were performed.


## 2026-11-02｜第二十八輪：擴大搜尋備份分支與 bootstrap 歷史

### 本輪查核

- GitHub branch search 找到舊分支 v1-backup，並另外檢查 chore/bootstrap-local-migration-replay-workflow 與目前 PR 分支。
- 在上述分支檢查常見 schema / bootstrap 位置：supabase/schema.sql、supabase/seed.sql、supabase/config.toml、supabase/migrations/20261017010847_account_deletion_worker.sql、根目錄 schema.sql、database/schema.sql 等；沒有找到可直接採信的 schema dump 或缺失 migration 原始檔。
- GitHub commit search 以 characters migration、profiles migration、schema snapshot、initial schema、database bootstrap 等詞擴大查找；結果仍未提供可驗證的 foundational CREATE TABLE source。搜尋結果只能說明目前查詢未找到，不能證明私人 SQL Editor / Dashboard 歷史或所有未索引來源不存在。
- 檢查可用 Supabase connector 能力：目前有 table inventory、migration metadata、catalog SQL、TypeScript types 等讀取能力，但沒有提供 schema-only pg_dump / migration source export 的專用動作。TypeScript types 也不足以重建 constraints、indexes、triggers、policies、grants 與 functions，因此不以它替代 schema dump。

### 結論

目前仍沒有可信來源可還原最初 public.characters / public.profiles 建表 SQL，也沒有找到缺失的 20261017010847_account_deletion_worker.sql。不能僅憑備份分支名稱或目前 live catalog 推定存在完整備份。

### 安全界線與下一步

- 沒有建立 synthetic baseline、沒有新增 migration、沒有 reset local stack 或 hosted DB。
- 沒有執行 hosted DDL/DML、帳號刪除 RPC、Auth user 建立/刪除、Worker deployment 或 cron。
- PR #200 維持 Draft/unmerged。
- 下一個可靠來源需由原始專案 SQL Editor 歷史、使用者保存的 SQL 匯出，或由有權限的資料庫管理流程產生 schema-only dump（排除所有應用資料列）提供。取得後才進行逐項 schema 對照。


## Round 28 - repository backup and bootstrap search (2026-11-02)

- Searched repository branches including v1-backup, chore/bootstrap-local-migration-replay-workflow, and the current PR branch.
- Checked conventional schema/bootstrap paths (supabase/schema.sql, supabase/seed.sql, supabase/config.toml, the missing account-deletion migration path, root schema.sql, and database/schema.sql). No trusted schema dump or original migration source was found.
- Expanded commit searches for character/profile migrations, schema snapshots, initial schema, and database bootstrap. No verifiable foundational CREATE TABLE source was returned. This is a bounded search result, not proof that private SQL Editor history or every unindexed source is absent.
- Reviewed available Supabase connector capabilities: table inventory, migration metadata, catalog SQL, and generated TypeScript types are available; a dedicated schema-only dump/export action is not exposed. Generated types cannot reconstruct constraints, indexes, triggers, policies, grants, functions, or exact creation order.

Conclusion: the original public.characters / public.profiles DDL and missing account-deletion migration remain unrecovered. No synthetic baseline or migration was created. No local/hosted reset, hosted DDL/DML, deletion RPC, Auth user creation/deletion, worker deployment, or cron operation occurred. PR #200 remains Draft/unmerged.

Next trusted sources: original SQL Editor history, a user-held SQL export, or an authorized schema-only dump that excludes application rows. Compare it against live catalog only after provenance is established.


## 2026-11-02｜Round 71：找回五個已套用 migration 的原始 SQL

從舊分支 `fix/account-deletion-ready` 找回五個與 Supabase migration ledger 版本及名稱完全一致的 SQL，並恢復到目前 PR #200 分支 `supabase/migrations/`。逐一重新讀取兩分支檔案後，Git blob SHA 完全一致：

- `20261017010838_preserve_group_history_on_character_delete.sql` — `628b6a6ecf56962b64bdc1764d04b81d8687c4c0`
- `20261017010841_account_deletion_grace_period_config.sql` — `664c30ff901817050cacb86f67bc0a84986f9dac`
- `20261017010847_account_deletion_worker.sql` — `1e329c68a40f5ada56bf7dd47f9b64bf45a77367`
- `20261017035145_guard_group_mock_turn_during_deletion.sql` — `730e8d037d79f6718728ef8dc77bd90372477a7c`
- `20261017040730_guard_snapshot_sync_during_deletion.sql` — `25f46d7163589c9d4c97caf155e43ebf05a85d08`

這修復了五個「migration ledger 有紀錄、目前 PR 分支卻缺少對應 SQL」的來源缺口。Migration manifest 已同步調整：repo SQL files 112、exact version+name matches 32、仍無同名來源的 remote migration 52。

### 安全界線

- 這是原始檔案恢復，不是執行 migration。
- 沒有修改 Supabase hosted migration ledger，沒有執行 hosted DDL/DML、reset、db push 或 migration replay。
- 特別注意：`20261017010847_account_deletion_worker.sql` 是歷史版本，其 `prepare_account_deletion()` 仍依賴既有 cascade 行為，沒有滿足目前帳號刪除時保留角色及其子資料的要求；恢復原始檔不代表批准執行或啟用 worker。
- `profiles` / `characters` 最初的 CREATE TABLE baseline 仍未找回；五個 migration 不會解決這個基礎表缺口。
- PR #200 維持 Draft/unmerged；帳號刪除 worker維持 disabled，沒有部署或排程。

### 下一步

1. 繼續追查剩餘 52 個 remote migration 名稱的原始來源，優先找出基礎表之前的 bootstrap SQL。
2. 對五個恢復檔案逐項核對目前後續 migration 是否有重複定義或行為衝突。
3. 完成完整 migration manifest、時間戳衝突與依賴順序檢查後，再做 disposable-only replay 設計。


## 2026-11-02｜Round 73：擴大 Git 歷史與 Supabase catalog 證據

### Git 歷史追查結果

- 搜尋目前可見的 209 個 repository branches（分三頁），包含 `v1-backup`、`main`、security/account-deletion 分支及 bootstrap workflow 分支；沒有發現可直接採信的 schema dump 檔案。
- 檢查最早的角色雲端寫入程式 commit `79760d81e2d72b73808ac8807c7ec0b75bb61ecf`（2026-10-14）。它已對 `public.characters`、`public.profiles` 執行 upsert，但 diff 沒有 CREATE TABLE SQL，表示應用程式連線時兩表已存在；仍不能推定建表來源。
- 檢查最早的聊天雲端保存 commit `460adf7dfdd284b5f8e51ebedc8d0a7548c6ee2d`。它新增的是前端 chat_sessions / chat_messages persistence，沒有建立 profiles 或 characters。
- 針對 `CREATE TABLE public.profiles`、`CREATE TABLE public.characters` 等字串進行 GitHub code search，未回傳結果；該搜尋索引並非完整，因此只能記為「未找到」，不能證明所有 Git 歷史或私人 SQL Editor 記錄均不存在。
- 另以 commit search 檢查 migration 名稱，確認部分歷史 SQL 原始內容可在早期 commit diff 找到（如 wallet charging / transaction function / idempotency / conflict-target），但它們不是 profiles / characters bootstrap DDL，也不能補上基礎 schema 缺口。

### 本輪 Supabase read-only catalog evidence

使用 Supabase verbose table inventory 重新確認（未讀取任何資料列內容）：

- `public.profiles`：10 欄，PK `id`，unique `handle`，FK `id → auth.users(id)`；RLS enabled；4 rows。
- `public.characters`：24 欄，PK `id`，FK `author_id → profiles(id)`；RLS enabled；11 rows。
- characters 目前欄位包括 `id, author_id, name, title, gender, age, avatar_url, visibility, review_status, created_at, intro, race, style, tags, first_published_at, latest_eligible, rights_confirmed, deleted_at, deletion_reason, phone_settings, nsfw_workplace_warning, is_nsfw, avatar_video_path, personality_profile`。
- profiles 目前欄位包括 `id, handle, nickname, avatar_url, bio, status, created_at, persona_presets, birthdate, follower_count`。
- list_tables 也確認 characters 的直接 FK dependents 包含 chat_sessions、chat_groups、chat_group_members/messages、character_stories、character_private_info、illustrations、schedules、comments、encounter 與 story relationship records。這些依賴再次說明不能在 hosted project drop/recreate 核心表。
- Supabase extension inventory 顯示目前啟用的相關 extensions 包含 `pg_cron`、`pg_net`、`pgcrypto`、`uuid-ossp`、`pg_stat_statements`、`vector`、`pg_graphql` 等；但 inventory 不能證明 profiles/characters 原始建表時的 extension 依賴與安裝順序。

### 本輪結論與界線

- 沒有找到 profiles / characters 的原始 CREATE TABLE SQL 或可信 schema-only dump。
- live inventory 仍只能作為現況比對證據，不足以單獨生成可安全 replay 的完整 baseline；尤其 ACL/default privileges、完整函式定義、trigger function、所有 indexes/policies、extension dependencies 與精確 FK action 仍須逐項捕捉。
- 本輪只有 GitHub 讀取與 Supabase inventory/extension listing；沒有執行 SQL、DDL/DML、migration、RPC、reset、db push、部署或排程。
- 不新增 synthetic baseline，不變更 hosted migration ledger；PR #200 維持 Draft/unmerged。

### 下一步

1. 優先從 Supabase Dashboard SQL Editor 歷史或使用者保存的 schema-only export 取得真正的基礎表來源。
2. 若無法取得，需先明確批准建立「synthetic disposable-local-only baseline」，並以完整 catalog dump（非 list_tables 摘要）做來源註記與差異審查。
3. 取得完整 schema source 後，才恢復 local PostgreSQL migration replay；在此之前不將 CI 靜態測試稱為 SQL integration pass。
