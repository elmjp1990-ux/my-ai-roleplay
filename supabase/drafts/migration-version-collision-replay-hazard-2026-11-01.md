# Migration version collision / replay hazard — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay
Branch: security/chat-deletion-lifecycle-reconciliation
Test Supabase project: ouyewoagbmtqehbofrje
Scope: read-only comparison of repository migration source, live migration ledger, and live function definitions. No DDL/DML.

## Confirmed ledger facts

The test project's migration list contains:
- 20261022185425 / exclude_deleted_group_messages_from_turn_counts
- 20261023095003 / exclude_deleted_chat_from_character_turn_counts

It does NOT contain:
- 20261023120000 / exclude_deleted_group_messages_from_turn_counts

The repository branch contains:
- supabase/migrations/20261023120000_exclude_deleted_group_messages_from_turn_counts.sql
- recovered supabase/migrations/20261023095003_exclude_deleted_chat_from_character_turn_counts.sql

The SQL body in the repo's 20261023120000 file exactly matches the SQL statement stored in the live 20261022185425 migration row after stripping leading comments and normalizing whitespace/terminal semicolon. The version/timestamp differs only.

## Why this is more than a cosmetic timestamp mismatch

The repository file 20261023120000 is not recorded as applied in the connected test DB. A version-based migration runner will therefore treat 20261023120000 as pending even though the same SQL body has already been applied under live version 20261022185425.

More importantly, 20261023120000 replaces both turn-count functions with an older function body:
- It does not filter soft-deleted single chat sessions.
- It does not filter soft-deleted single chat messages.
- It does not include the current public NSFW adult gate.
- It filters deleted individual group messages, but does not exclude messages whose parent chat_groups row is soft-deleted.

The recovered 20261023095003 source does include the single-session and single-message deleted filters, and the current live definitions include those filters plus the NSFW adult gate. Applying the repo-only 20261023120000 after 20261023095003 can therefore regress protections before later migrations run; whether later migrations restore every predicate must be proven from their exact SQL, not assumed.

Current live definitions (read-only):
- public.get_character_turn_counts(uuid[])
- public.get_public_character_turn_count(uuid)
Both are postgres-owned SECURITY DEFINER functions with empty search_path. Current ACL allows anon, authenticated, service_role and owner postgres; PUBLIC is not an EXECUTE grantee.
Both current definitions exclude deleted single sessions/messages and deleted individual group messages, and enforce visibility/owner/NSFW conditions. Both still omit the parent group deleted_at filter.

## Current data impact

A read-only aggregate query found:
- deleted groups with undeleted character messages: 0
- undeleted character messages under deleted groups: 0
- affected characters: 0

This means no current rows are affected in the test database at the time of the check. It does not remove the correctness risk for future soft-deleted groups.

## Required safety decision

Do NOT run db push, db reset, migration repair, or manual edits to supabase_migrations. Do not assume the matching migration name means the runner considers it applied; the runner keys by version.

Before any clean replay or hosted migration operation, explicitly reconcile the repo-only 20261023120000 file. Candidate approaches require separate review:
1. Quarantine/retire the repo-only duplicate from the executable migration chain, while preserving its SQL as provenance documentation; this needs confirmation that no other environment has applied version 20261023120000.
2. Keep the historical file immutable but build and test a later additive migration that restores all current single-chat/NSFW protections and adds the parent-group deleted filter. This does not make applying the stale migration harmless during a deployment window, and the full replay order must be tested.

No approach is selected or applied in this note. Do not mutate the existing migration file or hosted history until environment scope and replay behavior are confirmed.

## Next safe steps

1. Reconcile which environments (if any) have recorded version 20261023120000. Only the connected test DB has been inspected so far.
2. Review exact later migration SQL to establish whether it restores the solo deleted filters and NSFW predicates after 20261023120000 during a clean replay.
3. Choose and document the repository strategy for the duplicate version.
4. Once a reproducible local Supabase CLI/Docker workflow exists, run clean replay and regression tests on a disposable local database; stop on first error.
5. Build the final additive migration from the current live definitions with only the parent-group deleted filter delta, then test active/deleted groups, deleted individual group messages, solo session/message deletion, NSFW/owner visibility, grants, owner, SECURITY DEFINER and search_path.

## 2026-11-01 addendum — current NSFW count gate has no matching migration source

A second read-only scan searched every recorded migration statement for either count RPC name:
- public.get_character_turn_counts(uuid[])
- public.get_public_character_turn_count(uuid)

Only four migration versions contain either function:
- 20261021023530 / include_group_turns_in_character_counts
- 20261022173642 / secure_character_turn_count_visibility
- 20261022185425 / exclude_deleted_group_messages_from_turn_counts
- 20261023095003 / exclude_deleted_chat_from_character_turn_counts

No later recorded migration statement updates either count RPC. In particular:
- 20261024073819 / character_nsfw_terms_and_age_gate adds NSFW schema/helper/policies but does not replace either count RPC.
- 20261024075220 / move_adult_check_to_private_schema moves the helper and updates character/video policies but does not replace either count RPC.
- 20261024083626 / enforce_nsfw_age_gate_for_character_reads updates character RLS policies but does not replace either count RPC.

The current live count RPC definitions nevertheless contain c.is_nsfw / private.current_user_is_adult() predicates. Therefore this part of the live function state is not represented in the recorded migration statements examined. It is an unexplained live-schema drift / missing migration provenance; do not assert that it is covered by the recorded NSFW policy migrations. It may have been applied out-of-band or its source migration may be missing from the ledger/repository. The exact origin is unknown.

Consequences:
- A clean migration replay from repository history cannot be assumed to reproduce the current live NSFW count gate.
- The repo-only 20261023120000 migration can overwrite deleted solo filters; no later recorded migration restores those two count functions.
- The final additive migration must preserve both current live functions in full, including NSFW and solo deletion predicates, and must be accompanied by a reviewed baseline/provenance decision. Do not rely on replaying only the historical files.

This addendum is based on a read-only scan of all schema_migrations.statements containing either function name and a separate read of the current live function definitions. No DDL/DML or migration application was performed.

PR #200 remains Draft/unmerged. No hosted migration was applied. No cron was enabled. PR #201 remains paused.

## Connected Supabase environment scope

The connected Supabase integration currently lists exactly one accessible project: `ouyewoagbmtqehbofrje` (ACTIVE_HEALTHY, ap-northeast-1). This matches the project treated as the test database in this work. No second Supabase project is currently visible through this connection.

This is not proof that no other unlinked Supabase organization/project or external environment exists. Therefore version 20261023120000 is confirmed absent only from the one accessible test project's migration ledger; do not generalize that absence to every environment without checking those environments separately.


## 2026-11-01 correction: later pending source migration changes the replay conclusion

A follow-up check found an important later source migration that was not accounted for in the earlier replay-risk wording:

- `supabase/migrations/20261024180000_fix_nsfw_public_rpc_age_gate.sql` exists on the repository default branch.
- It replaces both count RPCs after the repo-only `20261023120000` version in timestamp order.
- Its source definitions include the NSFW/adult gate and the deleted single-session/message filters that are absent from `20261023120000`.
- The test DB ledger contains the earlier NSFW helper/policy versions `20261024073819`, `20261024075220`, and `20261024083626`, but has neither `20261023120000` nor `20261024180000`.

Therefore the previous statement that applying `20261023120000` would necessarily leave a persistent solo-filter regression after a complete repository replay was too strong. If a version-ordered replay applies both missing files successfully, `20261024180000` subsequently restores the NSFW and solo deleted-session/message predicates. The earlier file is still stale and unsafe to treat as a standalone fix; it can create an intermediate state before the later migration executes. Whether that intermediate state is externally observable depends on the migration runner's transaction boundaries and deployment process; this has not been tested here.

The expected final definitions after applying both pending migrations would still lack the parent-group deleted filter, because `20261024180000` does not join `chat_groups` or test `g.deleted_at IS NULL`. The additive parent-group correction remains necessary.

Updated replay assessment:

1. Do not describe the old migration as causing a proven permanent regression after the *full* pending chain; describe it as a stale intermediate replacement superseded by the later NSFW migration.
2. Do not run hosted `db push`, reset, repair, or manual history edits. The full replay order and transaction behavior must first be reproduced locally.
3. The missing ledger entry for `20261024180000` remains a separate history discrepancy: live function clauses match the migration's behavior, but its version is absent from the accessible test ledger.
4. The only accessible Supabase project remains the test project; other unlinked environments have not been checked.
5. Preserve the parent-group filter as a separate additive change and test it against both RPCs, including NSFW and solo deletion cases.

This correction supersedes the earlier wording in this document that implied no later repository migration could restore the solo filters. No database changes were made.


## Supabase CLI workflow evidence checked

The current Supabase documentation states that timestamped migration files are applied in order, `db push` applies migrations absent from the remote history table, and local clean replay requires the Supabase CLI plus a Docker-compatible runtime:

- https://supabase.com/docs/guides/local-development/cli-workflows
- https://supabase.com/docs/reference/cli/global-flags

The docs confirm the ordered pending-migration model, but this investigation has not inspected the exact CLI version/source used by this project or run the two pending migrations locally. It therefore does not claim whether the whole pending set is one atomic transaction or whether requests can observe the interval between migration files. The exact migration runner version and transaction boundary must be confirmed in a reproducible local run before assessing exposure of the intermediate state.

This repository's current `supabase/config.toml` contains only `project_id` and the worker function's `verify_jwt` setting; it does not supply a preconfigured local stack override. The current execution environment has no Supabase CLI or Docker executable, so no local replay was attempted.

No hosted `db push`, `db reset`, or `migration repair` was run.
