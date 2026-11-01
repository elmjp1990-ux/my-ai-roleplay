# Character turn-count migration provenance — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay  
Working branch: security/chat-deletion-lifecycle-reconciliation  
Test Supabase project: ouyewoagbmtqehbofrje  
Scope: GitHub source-history and live catalog/function read-only comparison. No DDL/DML.

## Current live function definitions

Read directly from the test project's pg_proc:

- public.get_character_turn_counts(p_character_ids uuid[])
- public.get_public_character_turn_count(p_character_id uuid)

Both are owned by postgres, SECURITY DEFINER, and SET search_path TO ''. Both are executable by anon, authenticated, and service_role.

The current live functions contain these protections:
- Exclude deleted characters.
- Public/author ownership visibility checks.
- NSFW adult gate on public count paths.
- Exclude soft-deleted single chat sessions.
- Exclude soft-deleted single chat messages.
- Exclude soft-deleted group messages (gm.deleted_at IS NULL).

Confirmed gap:
- Both group-count paths read chat_group_messages without joining chat_groups.
- Neither path filters chat_groups.deleted_at IS NULL.
- chat_group_messages.group_id has a foreign key to chat_groups.id with ON DELETE CASCADE, but the intended chat deletion lifecycle is a soft-delete grace period; the parent remains present while child messages remain, so FK cascade does not solve the count leak.

## Repository migration provenance

Repository source files found:
1. supabase/migrations/20261022173642_secure_character_turn_count_visibility.sql
   - Adds public-or-owner character visibility and deleted-character suppression.
   - Does not include deleted-session, deleted-message, or deleted-group filters.
2. supabase/migrations/20261023120000_exclude_deleted_group_messages_from_turn_counts.sql
   - Adds gm.deleted_at IS NULL for group messages.
   - Does not join chat_groups or filter chat_groups.deleted_at.
   - Its solo-count paths do not contain the current live deleted-session/message filters.
   - Its public function does not contain the current live NSFW adult gate.

The historical commit 25c7ad667bc99fa9a4f0bbc75604a63bac0d83dd created migration 20261023120000_exclude_deleted_group_messages_from_turn_counts.sql.

## Live migration history comparison

Read-only query of supabase_migrations.schema_migrations returned:
- 20261022173642 / secure_character_turn_count_visibility
- 20261022185425 / exclude_deleted_group_messages_from_turn_counts
- 20261023095003 / exclude_deleted_chat_from_character_turn_counts

Important mismatches:
- Live version 20261022185425 has the same migration name as repository file 20261023120000, but a different timestamp.
- Repository file 20261023095003_exclude_deleted_chat_from_character_turn_counts.sql was not found on the GitHub default branch when queried.
- The live function definitions include protections that are not represented together in the two repository files found above.
- Therefore, current live function state cannot be reconstructed by simply replaying those two visible repository files. This aligns with the already-documented broader migration-history drift and missing historical SQL sources.

## Safe correction proposal — NOT APPLIED

For each current live function, preserve its complete current definition and all existing access/visibility/NSFW/deleted-session/deleted-message predicates. Change only the group aggregate:

```sql
FROM public.chat_group_messages AS gm
JOIN public.chat_groups AS g
  ON g.id = gm.group_id
WHERE gm.character_id = ...
  AND gm.speaker_type = 'character'
  AND gm.deleted_at IS NULL
  AND g.deleted_at IS NULL
```

For get_character_turn_counts, retain its JOIN to allowed characters as well. For get_public_character_turn_count, retain the character visibility and NSFW adult gate. Do not reduce the function body to the older historical versions.

Regression tests required:
1. Active group with character messages contributes to the public count for a public eligible character.
2. Soft-deleted group with undeleted child messages contributes zero.
3. Soft-deleted individual group message in an active group contributes zero.
4. Active single chat counts remain unchanged.
5. Soft-deleted single chat/session remains excluded.
6. Author count remains owner-scoped and public count retains NSFW/adult restrictions.
7. RPC EXECUTE grants remain exactly anon, authenticated, service_role; PUBLIC remains revoked.
8. Function owner remains postgres, SECURITY DEFINER remains enabled, search_path remains empty.

## Migration workflow decision

Do not create/apply a migration against the hosted test DB yet. The project has known migration timestamp/name drift, missing historical SQL sources, and no local Supabase CLI/Docker available in the current environment. Do not run db reset, db push, migration repair, or ad hoc DDL.

Next safe action:
- Recover/identify the missing historical SQL source for live version 20261023095003 and map the full function evolution.
- Build the final reviewed additive migration from the current live function definitions, not from stale repository snapshots.
- Add the regression tests above.
- Apply only after an approved, reproducible migration workflow is available; then verify function definitions, grants, owner, security_definer, search_path, and count behavior in the test DB.

PR #200 remains Draft/unmerged. No deletion cron is enabled. PR #201 remains paused.
