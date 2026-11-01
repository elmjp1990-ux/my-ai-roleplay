# Live NSFW turn-count gate provenance — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay  
Working branch: security/chat-deletion-lifecycle-reconciliation  
Test Supabase project: ouyewoagbmtqehbofrje  
Scope: read-only catalog and migration-ledger trace. No DDL/DML.

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

## What the recorded migration ledger proves

A full scan of every stored statement in `supabase_migrations.schema_migrations` for either count RPC found exactly four migration versions that define/replace them:

1. `20261021023530` — include_group_turns_in_character_counts
2. `20261022173642` — secure_character_turn_count_visibility
3. `20261022185425` — exclude_deleted_group_messages_from_turn_counts
4. `20261023095003` — exclude_deleted_chat_from_character_turn_counts

No later recorded migration statement replaces either count RPC.

The later NSFW-related migration chain does exist, but it changes other objects:

- `20261024073819` creates `public.current_user_is_adult()`, adds `characters.is_nsfw`, and updates character RLS.
- `20261024075220` moves the helper to `private.current_user_is_adult()` and updates character/video policies.
- `20261024083626` enforces NSFW age gating in character read/write policies.

None of those recorded statements updates either turn-count RPC.

The current live count functions reference the private helper introduced by the later NSFW chain, but the migration ledger has no corresponding count-function replacement. Therefore the origin of the live count gate is not proven by the recorded migration history. Plausible explanations include an out-of-band SQL Editor change or a missing migration source; neither can be asserted without further evidence.

## Safe conclusion

- The live test database currently has an NSFW gate on both count RPCs.
- The recorded migration history inspected does not reproduce that gate on those RPCs.
- A clean replay of the repository migration chain cannot currently be claimed to reproduce the live function definitions.
- Do not remove the live gate, do not replay historical count migrations, and do not use hosted db push/reset/repair to try to reconcile it.

## Candidate correction retained as draft

`supabase/drafts/character-turn-count-parent-delete-filter-proposal.sql` was reviewed against the current live definitions. It preserves the current NSFW, ownership, visibility, deleted solo-session/message and deleted individual group-message predicates, and adds an inner join to `chat_groups` with `g.deleted_at IS NULL` in both group aggregates.

That SQL remains draft-only. It has not been applied or executed against fixtures. Before promotion into an executable migration, the repository migration collision and reproducible local workflow must be resolved, and the regression cases in the SQL comments must be run.

## Next safe actions

1. Preserve this provenance gap in the migration reconciliation record.
2. Search repository history/PRs and available deployment evidence for the untracked count-function NSFW alteration. A negative code-search result on the default branch is not proof that no historical branch or manual SQL existed.
3. Keep the candidate parent-group filter un-applied until a reproducible local Supabase migration/test workflow is available.
4. Keep PR #200 Draft/unmerged, no deletion cron, and PR #201 paused.

No database schema/data, migration history, Storage object, cron, or production environment was changed during this investigation.
