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


## Final privilege-hardening draft and advisor classification — 2026-11-03

A consolidated draft now exists at `supabase/drafts/pr200-final-privilege-hardening.sql`. It contains only:

1. `REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;`
2. Revoke direct `DELETE` on `chat_sessions` and `chat_groups` from `PUBLIC`, `anon`, `authenticated`, and `service_role`.

The disposable replay applies this combined draft before behavior tests. `verify-deletion-draft-replay.sql` now asserts that no public table retains client-role TRUNCATE, and that anon/authenticated/service_role cannot directly DELETE either chat parent. The actual authenticated soft-delete RPCs remain executable; final purge RPC remains service_role-only and runs as its postgres-owned SECURITY DEFINER function. CI on the disposable current-state schema passes these assertions and the behavior/concurrency suites. The draft is not applied to the hosted test project.

A read-only Supabase Security Advisor snapshot returned:
- 16 RLS-enabled tables with no policies. Effective ACL inspection confirmed anon/authenticated have no table privileges on all 16; 12 are service_role-only, while the four account archive/settings tables have no direct service_role table privileges and are accessed through SECURITY DEFINER routines. These are intentionally backend-only tables, not missing client policies.
- 4 anon-executable SECURITY DEFINER functions and 27 authenticated-executable SECURITY DEFINER functions. All 27 have `search_path = ''`; all 4 anon-callable functions were inspected and filter to public/approved/rights-confirmed data, with NSFW age checks where relevant. The deletion RPCs specifically enforce auth.uid()/owner matching; queue worker RPCs remain service_role-only.
- Auth Leaked Password Protection is disabled. This is a separate pre-launch Auth configuration hardening item and was not changed.

This advisor snapshot is a read-only point-in-time classification, not a full transitive audit of every app RPC. No hosted DDL, ACL, Auth setting, Storage mutation, worker deployment, or Cron activation occurred.


## 2026-11-03 addendum — account worker lease migration review

The account deletion worker's atomic lease implementation is now in `supabase/drafts/account-deletion-worker-atomic-lease.sql`, with effective-privilege assertions in `test-account-deletion-worker-lease-security.sql`. Do not move it to active migrations until the complete account-preservation/prepare integration draft chain is reconciled.

Verified in disposable PostgreSQL:
- lease table RLS enabled and no direct table privileges for service_role/authenticated/anon;
- fenced worker RPCs callable by service_role only;
- old unleased work-list/archive/prepare/finalize/failure RPCs are no longer service_role-callable;
- cancellation remains authenticated-only;
- all new SECURITY DEFINER RPCs have empty search_path;
- 14 independent-session/concurrency scenarios pass, including claim/cancel in both directions, lease expiry while a renewal is blocked on a row lock, stale token fencing, request-row cascade recovery, and existing character/asset deletion races.

Worker implementation now bounds Auth Admin user lookup/delete HTTP calls to 60 seconds using a dedicated fetch wrapper; non-Auth requests are unchanged. Lease duration is currently 10 minutes but provisional until actual worker phase timing is measured.

Migration status:
- This remains a DRAFT SQL implementation, not a generated migration file.
- The old foundational profiles/characters migration provenance remains unresolved; per the agreed route, do not recover or fabricate old migrations, do not replay the historical chain, and do not modify migration history.
- The eventual new incremental migration must be generated with Supabase CLI, combine the reviewed account-preservation + child-write freeze + archived-character session guard + complete prepare integration + lease SQL in dependency order, then be diffed against the connected test project's schema and migration ledger.
- No hosted DDL/DML, Auth/Storage mutation, Worker deployment, Vault secret, or Cron change has occurred. Worker source remains disabled; PR #200 remains Draft/unmerged.
