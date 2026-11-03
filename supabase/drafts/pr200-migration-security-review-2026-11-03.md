# PR #200 migration / ACL / RLS security review — 2026-11-03

Scope: read-only inspection of the connected test project's migration ledger, effective function/table privileges, public RLS policies, Storage object policies, and the PR #200 migration sources. No hosted DDL/DML, migration apply/repair/reset, Storage/Auth mutation, deployment, or Cron change was performed.

## Migration ledger inventory

- Connected test project migration ledger: 152 entries.
- PR #200 changed-file set contains 28 SQL migration files; all 28 14-digit version values are present in the connected test project's ledger.
- This proves version presence only. It does not prove byte-for-byte or normalized SQL statement-body parity, and it does not make the repository's historical chain safe for a clean replay.
- The original pre-ledger profiles/characters foundation remains intentionally out of scope. The disposable current-state fixture remains the approved validation method.
- No migration was applied, repaired, reset, or re-recorded during this audit.

## Function ACL and SECURITY DEFINER spot-check

Read-only effective privilege inspection confirmed:

- `delete_chat_session_content(uuid)` and `delete_chat_group_with_related_data(uuid)`: executable by authenticated and service_role, not anon; SECURITY DEFINER with empty search_path; both validate auth.uid()/ownership in the function body.
- Chat purge queue RPCs (`claim_chat_deletion_jobs`, `purge_chat_deletion_job`, `mark_chat_deletion_job_failed`, `claim_chat_storage_deletion_jobs`, `mark_chat_storage_deletion_job`): executable by service_role only among anon/authenticated/service_role.
- `reserve_chat_turn` and Encounter evidence/settlement writers: service_role-only where the edge/server is the trusted caller.
- `append_chat_group_mock_turn`: authenticated + service_role, SECURITY DEFINER, empty search_path, and explicit auth.uid()-based group ownership check.
- All inspected SECURITY DEFINER functions use `search_path = ''`.

## Queue table ACL / RLS

- `chat_deletion_jobs` and `chat_storage_deletion_jobs`: RLS enabled; anon/authenticated have no table privileges; service_role has queue privileges.
- Queue rows are not directly readable or writable by players. Worker RPCs are the service-role boundary.
- The queue's Storage bucket constraint remains restricted to `personax-memory-photos`; character illustration/video buckets are not eligible.

## Parent / child RLS and Storage policy spot-check

- Restrictive lifecycle policies exist for active `chat_sessions` and `chat_groups`, and their child message/member/turn/diary/photo tables require an active, undeleted parent for authenticated access.
- `chat_memory_photos` has owner policies plus a restrictive active-parent guard.
- `chat_group_memory_photos` has owner-scoped authenticated policies plus a restrictive active-group guard. The legacy `image_url` row is not converted to a Storage path.
- Storage object SELECT/INSERT/DELETE policies are restricted to authenticated owners, bucket `personax-memory-photos`, owner-prefixed exact object-name patterns, and matching active/undeleted single/group parent ownership. INSERT additionally checks account_is_active().
- These checks are a focused spot-check, not a complete audit of every policy in every migration.

## Direct parent DELETE ACL — release migration requirement

The live test project's current table ACL inspection found:

- `chat_sessions`: anon, authenticated, and service_role still have table-level DELETE privilege.
- `chat_groups`: service_role has table-level DELETE privilege; authenticated/anon do not.
- The current RLS policy set has no permissive DELETE policy for anon/authenticated on these parents, so direct client DELETE is blocked by RLS today. However, the service_role bypass path still has direct table DELETE capability, and the table ACL is broader than the intended single lifecycle RPC.
- The PR already contains `supabase/drafts/chat-deletion-direct-parent-delete-privilege-guard.sql`, which revokes direct DELETE on both parent tables from PUBLIC, anon, authenticated, and service_role. The synthetic replay applies this draft and `verify-deletion-draft-replay.sql` asserts that authenticated/service_role cannot directly DELETE either parent.
- The draft is not an active hosted migration. Include it in the final fresh, uniquely versioned incremental migration set before hosted rollout. SECURITY DEFINER purge RPCs remain owned by the database migration owner and perform final deletion after retention.

## Remaining content-level review

1. Compare the SQL statement bodies for the 28 version-matched migrations against the connected ledger where the stored statements are available; do not fabricate or repair migration history.
2. Review all relevant grants, policies, triggers, and ownership for the complete final incremental migration set, not only the spot-check above.
3. Keep the direct parent DELETE ACL revocation in the final incremental migration set.
4. Complete browser multi-tab/device acceptance and live Storage API failure/retry E2E through an explicitly approved isolated test path.
5. Do not enable Cron, deploy a changed worker, apply a hosted migration, or merge PR #200 until explicit approval.

## Status

PR #200 remains Draft / unmerged. The current code-validation HEAD and disposable synthetic replay evidence are recorded separately in `pr200-runtime-and-migration-status-2026-11-03.md`. This audit is read-only and does not authorize rollout.


## Exact migration source reconciliation — 2026-11-03

The `supabase_migrations.schema_migrations` ledger includes `version`, `name`, and `statements text[]`; for all 28 PR migration versions, `array_length(statements, 1) = 1` and `statements[1]` contains the full applied SQL source. This enabled direct source reconciliation rather than version-only checking.

Initial comparison found 9 byte-identical files and 19 files with textual differences. A token-aware comparison that removes SQL comments/whitespace, normalizes unquoted token case, and preserves quoted string literals showed:
- 15 differences were comments/formatting only.
- 4 remaining files differed only by: one error-message string wording; four optional `AS` table-alias keywords; splitting an equivalent Storage path regex string into adjacent concatenated literals; and two unused local variable declarations in the purge worker migration.
- No changed predicates, grants, RLS policy conditions, trigger behavior, queue constraints, retention intervals, or function control flow were identified in the differences.

To prevent future replay drift, the 19 non-identical repository migration files were restored byte-for-byte from their already-applied test-project ledger `statements[1]` sources. The 9 already-identical files were left unchanged. A second direct comparison now confirms **28/28 exact source matches** after normalizing CRLF to LF. This was a Git branch file restoration only; no hosted migration was applied, repaired, reset, or re-recorded.

Restored migration source commit: `68e3ed291d3079efebc7a2a128c9df6827f254b4`.

The separate fresh incremental migration requirement remains: do not edit/replay historical migrations. The direct parent DELETE ACL guard must be carried in a new uniquely versioned migration before any hosted rollout. Original `profiles`/`characters` baseline provenance remains unresolved but is not a blocker for disposable current-state fixture validation, per the agreed project decision.
