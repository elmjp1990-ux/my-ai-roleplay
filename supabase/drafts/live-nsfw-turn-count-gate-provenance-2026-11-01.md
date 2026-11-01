# Live NSFW turn-count gate provenance — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay  
Working branch: security/chat-deletion-lifecycle-reconciliation  
Test Supabase project: ouyewoagbmtqehbofrje  
Scope: read-only GitHub source-history and live migration-ledger trace. No DDL/DML.

## Confirmed live state

The current test-project definitions of:

- public.get_character_turn_counts(uuid[])
- public.get_public_character_turn_count(uuid)

both reference `private.current_user_is_adult()` and include an `is_nsfw` predicate.

Current function fingerprints captured from pg_proc on 2026-11-01:

- get_character_turn_counts: md5 `98888a9db9a8fdd6d41dd08dc2e0e99e`
- get_public_character_turn_count: md5 `9220900db4fd4dcdf886d53abf04e6c5`
- private.current_user_is_adult: md5 `e075ed49d1a7d6ba0ad825d077aebcdf`

Both count RPCs remain postgres-owned SECURITY DEFINER functions with an empty search_path. Their existing owner/visibility and deleted-session/message rules must be preserved.

## Source migration has now been found

The earlier statement that the source migration was unknown is superseded by this finding.

GitHub history contains commit:

- `bd6c0afe23299438b2d867d0d456504fb51fed02`
- Commit message: `fix: enforce NSFW age gate in public SECURITY DEFINER RPCs`
- Commit date: 2026-10-24
- Commit branch lineage: `fix/nsfw-public-rpc-age-gate`
- Source file: `supabase/migrations/20261024180000_fix_nsfw_public_rpc_age_gate.sql`
- The file is present on the repository default branch.

That migration defines/replaces both `get_character_turn_counts` and `get_public_character_turn_count` with the NSFW predicate using `private.current_user_is_adult()`. It also updates `get_character_comments_safe`. The current live count-function logic is consistent with the count-function definitions in this source migration.

## What the live migration ledger proves

A full scan of every stored statement in the accessible test project's `supabase_migrations.schema_migrations` found only four migration versions that define/replace either count RPC:

1. `20261021023530` — include_group_turns_in_character_counts
2. `20261022173642` — secure_character_turn_count_visibility
3. `20261022185425` — exclude_deleted_group_messages_from_turn_counts
4. `20261023095003` — exclude_deleted_chat_from_character_turn_counts

A targeted lookup for version `20261024180000` and name `fix_nsfw_public_rpc_age_gate` returned no row in the accessible test project's migration ledger.

The helper's supporting migrations do exist in the ledger:

- `20261024073819` creates `public.current_user_is_adult()`, adds `characters.is_nsfw`, and updates character RLS.
- `20261024075220` moves the helper to `private.current_user_is_adult()` and updates character/video policies.
- `20261024083626` enforces NSFW age gating in character read/write policies.

Therefore the source code is now known, but the deployment-history discrepancy remains: the repository has migration `20261024180000`, the live functions reflect its NSFW count-gate logic, and the accessible test project's migration ledger does not record that version. Possible explanations include migration SQL applied without a corresponding ledger entry or incomplete/altered migration history. The evidence does not distinguish these explanations.

## Safe conclusion

- The live test database currently has an NSFW gate on both count RPCs.
- The corresponding repository migration source is identified and present on the default branch.
- The accessible test project's migration ledger does not contain version `20261024180000`.
- Do not run `migration repair`, manually insert a history row, or replay this historical migration against the hosted test DB without a separately reviewed reconciliation plan.
- A clean replay still cannot be claimed to reproduce the live environment until the migration ledger drift and the separate `20261022185425` / `20261023120000` version collision are reconciled.

## Candidate correction retained as draft

`supabase/drafts/character-turn-count-parent-delete-filter-proposal.sql` was reviewed against the current live definitions. It preserves the current NSFW, ownership, visibility, deleted solo-session/message and deleted individual group-message predicates, and adds an inner join to `chat_groups` with `g.deleted_at IS NULL` in both group aggregates.

That SQL remains draft-only. It has not been applied or executed against fixtures. Before promotion into an executable migration, the repository migration collision and reproducible local workflow must be resolved, and the regression cases in the SQL comments must be run.

## Next safe actions

1. Reconcile the missing live ledger entry for `20261024180000` without mutating hosted migration history prematurely.
2. Search deployment evidence/other environments to determine whether the migration was applied but unrecorded, and confirm the migration's effects on the other RPC `get_character_comments_safe`.
3. Reconcile the separate `20261022185425` vs repo-only `20261023120000` version collision.
4. Keep the candidate parent-group filter un-applied until a reproducible local Supabase migration/test workflow is available.
5. Keep PR #200 Draft/unmerged, no deletion cron, and PR #201 paused.

No database schema/data, migration history, Storage object, cron, or production environment was changed during this investigation.
