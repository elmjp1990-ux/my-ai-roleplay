# Character turn-count migration provenance — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay  
Working branch: security/chat-deletion-lifecycle-reconciliation  
Test Supabase project: ouyewoagbmtqehbofrje  
Scope: GitHub source-history and live migration/function read-only comparison. No DDL/DML.

## Current live function definitions

Read directly from the test project's pg_proc:

- public.get_character_turn_counts(p_character_ids uuid[])
- public.get_public_character_turn_count(p_character_id uuid)

Both are owned by postgres, SECURITY DEFINER, and SET search_path TO ''. Current ACL expansion shows EXECUTE for anon, authenticated, postgres (owner), and service_role; PUBLIC is not an execute grantee.

Current live protections:
- Deleted-character exclusion.
- Public/author ownership visibility checks.
- NSFW adult gate on public count paths (author's own character path remains owner-authorized).
- Deleted single chat sessions and messages excluded.
- Deleted individual group messages excluded.

Confirmed remaining gap:
- Both group aggregates read chat_group_messages without joining chat_groups.
- Neither filters chat_groups.deleted_at IS NULL.
- The 30-day soft-delete parent remains present with its child messages, so FK cascade does not solve this aggregate leak.

## Recovered migration provenance

The missing source was recovered from the test database's own supabase_migrations.schema_migrations.statements column. The table stores version, name, statements, created_by, idempotency_key, and rollback. The three relevant rows each contain one SQL statement and have no rollback SQL.

Live history:
1. 20261022173642 / secure_character_turn_count_visibility
2. 20261022185425 / exclude_deleted_group_messages_from_turn_counts
3. 20261023095003 / exclude_deleted_chat_from_character_turn_counts

The exact SQL statement for live version 20261023095003 was read from the migration history row and restored to:
supabase/migrations/20261023095003_exclude_deleted_chat_from_character_turn_counts.sql

Restoration commit: 2756470af522ea746c42f9a3eea818d295f058c4

Important: this is a historical source-recovery commit only. The restored migration must NOT be replayed against the hosted test DB. Its function body predates later live protections, including the NSFW adult gate, and it does not fix the deleted-parent group aggregate.

Timestamp mismatch still present:
- Live 20261022185425 has the same migration name as repository file 20261023120000_exclude_deleted_group_messages_from_turn_counts.sql, but the timestamps differ.
- The repository file 20261023120000 is a separate repo-only version; do not assume it is the exact source corresponding to the live 20261022185425 row.
- The first live source 20261022173642 is present in the repository under the same timestamp/name.

## Safe correction proposal — NOT APPLIED

For both current live functions, preserve the complete current live definitions and all existing visibility/ownership/NSFW/deleted-session/deleted-message predicates. Change only the group aggregate:
```sql
FROM public.chat_group_messages AS gm
JOIN public.chat_groups AS g
  ON g.id = gm.group_id
WHERE gm.character_id = ...
  AND gm.speaker_type = 'character'
  AND gm.deleted_at IS NULL
  AND g.deleted_at IS NULL
```

For get_character_turn_counts, retain its JOIN to allowed characters. For get_public_character_turn_count, retain public visibility and NSFW adult gate. Do not replace either function with a historical migration body.

Regression tests required:
1. Active group with character messages contributes to the count for an eligible public character.
2. Soft-deleted group with undeleted child messages contributes zero.
3. Soft-deleted individual group message in an active group contributes zero.
4. Active single chat counts remain unchanged.
5. Soft-deleted single chat/session remains excluded.
6. Author count remains owner-scoped and public count retains NSFW/adult restrictions.
7. RPC EXECUTE grants remain anon, authenticated, service_role; PUBLIC remains revoked (owner retains inherent owner rights).
8. Owner remains postgres, SECURITY DEFINER remains enabled, search_path remains empty.

## Migration workflow decision

Historical source recovery is now complete for the three live migration rows above, but broader migration history drift remains. Do not create/apply a new migration against the hosted test DB until a reproducible local migration workflow is available. No local Supabase CLI/Docker was available in this environment. Do not run db reset, db push, migration repair, or ad hoc DDL.

Next safe action:
- Reconcile the 20261022185425 vs 20261023120000 timestamp/name mismatch without editing hosted migration history.
- Build the additive reviewed migration from the current live function definitions, not stale historical snapshots.
- Add the regression tests above.
- Apply only after an approved, reproducible migration workflow is available; verify function definitions, grants, owner, security_definer, search_path, and count behavior in the test DB.

PR #200 remains Draft/unmerged. No deletion cron is enabled. PR #201 remains paused.
