# PR #200 runtime and migration status — 2026-11-03

Scope: read-only inspection of the connected test Supabase project `ouyewoagbmtqehbofrje`, GitHub PR #200, and a disposable PostgreSQL CI run. No hosted DDL/DML, migration apply/repair, Edge deployment, Storage mutation, Auth mutation, or Cron change was performed.

## Current PR

- Branch: `security/chat-deletion-lifecycle-reconciliation`
- Reviewed HEAD at start of this audit: `e447e630ef0d3c30f03c145d631b204caf8612a6`; subsequent test-only change adds the single-chat settlement assertion.
- PR #200 remains Open / Draft / unmerged and GitHub reports mergeable=true.
- Existing CI at the prior HEAD passed, including account-deletion disposable-schema replay, chat worker tests, group UI syntax, and four independent-connection deletion races.

## Live test-project migration ledger

A fresh read-only `list_migrations` returned 152 records. The latest 11 entries are:

- `20261101052444 chat_deletion_queue_foundation`
- `20261101052951 chat_soft_delete_lifecycle`
- `20261101053732 chat_writer_parent_first_guards`
- `20261101054027 encounter_chat_deletion_gates`
- `20261101054353 chat_memory_storage_lifecycle_policies`
- `20261101054423 fix_chat_memory_storage_insert_path`
- `20261101055617 chat_deletion_purge_worker_rpc`
- `20261101055901 fix_group_turn_content_purge_marker`
- `20261101060225 preserve_wallet_character_label_after_chat_purge`
- `20261101101343 enable_pg_net_for_chat_deletion_worker`
- `20261101110211 account_deletion_character_video_storage_gates`

The ten PR #200 chat-deletion migration versions (20261101052444 through 20261101101343) are already present in the connected test project's migration ledger. Do not try to re-apply them to that project. The last account-deletion character/video storage gate (20261101110211) is in the remote ledger but has no matching SQL file in the current branch; its source remains a provenance gap.

The repository still contains five timestamp-collision values:
- 20261015151500 (two files)
- 20261020120000 (two files)
- 20261023120000 (two files)
- 20261024170000 (two files)
- 20261031120000 (three files)

It also contains five legacy migration files without unique 14-digit timestamps. A full clean migration replay from the repository remains unsafe until these collisions and the missing 20261101110211 source are reconciled. The approved synthetic current-state fixture is a test harness, not a replacement historical migration chain.

## Live Edge Function / Cron state (read-only)

- `purge-chat-deletions` is deployed and ACTIVE at version 9, with `verify_jwt=false`. Its handler uses `withSupabase({ auth: "secret:default" })`, so the request is protected by the configured Supabase Secret Key wrapper; it is not an unauthenticated public purge endpoint.
- The deployed version contains the Storage job processing loop inline. Current PR source extracts that logic into `processStorageDeletionJobs` in a shared module. This is a source-version drift; review and deploy only through a separately approved rollout.
- `account-deletion-worker` is not present in the live Edge Function list. Its current PR source has `ACCOUNT_DELETION_EXECUTION_ENABLED = false`.
- `purge-character-assets` is not present in the live Edge Function list. The current PR source is type-checked and unit-tested but is not deployed.
- `pg_cron` 1.6.4 and `pg_net` 0.20.4 are installed.
- Exactly one active cron job was returned: `poyozz-encounter-evaluation-dispatch` every minute. No chat deletion or account deletion cron is configured.
- Therefore the deployed chat purge worker has no scheduled trigger in the observed project. Its existence does not mean automatic purge is running. Do not create or activate a cron until the worker's source, endpoint auth, RPC permissions, Storage scope, retry behavior, and retention acceptance are reviewed and explicitly approved.

## Existing character-deletion continuation evidence

Read-only live SQL definitions confirm:
- `soft_delete_character(uuid)` archives the character, updates existing single-chat and group snapshots with `deletedAt`, and does not delete chat parents.
- `reserve_chat_turn(...)` locks and validates the existing chat session and checks the user/account state; it does not reject a session because its referenced character is soft-deleted.
- `settle_chat_turn(...)` validates the durable assistant reply and settles the existing charge; it does not require the character row to remain active.
- `append_chat_group_mock_turn(...)` counts all persisted group members, uses the member snapshot as speaker identity, and bills 3 units per member. It does not filter deleted characters out of existing groups.
- The deployed `chat-turn` Edge Function validates the owned, undeleted session and its stable character identity snapshot; it does not require the referenced character to remain public/undeleted. It uses the site's existing deterministic demo reply, not a live external AI provider.

The DML test already reserves a normal single-chat turn, persists an assistant reply after character deletion, and verifies it is durable. This round adds a further assertion that `settle_chat_turn` returns `settled` and the charge row stores the expected assistant message ID. This closes the database-level continuation/charge-settlement check.

## Current safety boundary

- No hosted Supabase mutations or migrations.
- No Edge Function deployment or invocation.
- No Storage deletion.
- No cron creation/activation.
- No Vercel plan upgrade or extra paid resource.
- PR #200 remains Draft and unmerged pending the final migration provenance/replay review and explicit rollout approval.


## One-time isolated local replay validation

On 2026-11-03, a single push-triggered run of the manual synthetic Supabase workflow is enabled for this document update only. The workflow uses a temporary Supabase project under the runner's temp directory, an empty migrations directory, and the schema-only synthetic fixture. It contains no hosted Supabase credentials. The push trigger will be removed after the run completes; future runs remain manual-only.


## One-time local replay retry after default-ACL role membership fix

The first isolated Supabase CLI run successfully started and discarded its temporary local project, but schema loading stopped at an `ALTER DEFAULT PRIVILEGES` statement owned by Supabase platform roles. No DDL beyond the disposable local container was persisted. The workflow now grants local `postgres` membership in `supabase_admin` and `supabase_auth_admin` inside that disposable instance only, so the schema-only fixture can faithfully restore the recorded default ACLs. One more local-only run is triggered by this document update; the push trigger will be removed afterward.


## Second local replay retry: keep Supabase platform-owned default ACLs native

The attempted local-only membership grant was rejected because Supabase reserves those platform-role memberships. The synthetic fixture generator now restores only `postgres`-owned application defaults and deliberately leaves `supabase_admin` / `supabase_auth_admin` defaults to Supabase Local itself. Static tests assert that platform-owned default ACL statements are not emitted. One more isolated local run is triggered by this document update; no hosted credentials are used.
