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

Historical observation (not a product defect):
- Both group aggregates read chat_group_messages without joining chat_groups.
- This means historical turns from a soft-deleted group remain included during the 30-day grace period. That behavior matches the user's requirement that deleting a chat must not erase character cumulative turns.
- The earlier audit incorrectly called this a gap. That conclusion is withdrawn. The correct future design must archive each deleted parent's per-character contribution, then switch from live rows to the immutable archive so transcript purge cannot erase counts and the live/archive sources are never double-counted.

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

## Correct archive/snapshot proposal — NOT APPLIED

Do not apply the earlier proposed filter `g.deleted_at IS NULL` as a standalone change to the count RPCs: doing so would erase the deleted group's historical contribution from the character's cumulative total.

The cumulative snapshot proposal supersedes the old filter-only proposal. Its correct source split is:
- Active parents: count valid live single/group character replies.
- Deleted parents: count one immutable aggregate snapshot per character and parent.
- After day-30 transcript purge: retain the same aggregate snapshot.
- Never sum a deleted parent's live child rows and its archive simultaneously.

Regression tests required:
1. Active group: each character's successfully completed replies contribute to that character.
2. Delete a group: each participating character's total is unchanged; the deleted group's contribution moves to its per-character archive.
3. Owner-visible and public aggregate RPCs include archived contribution during grace period and after transcript purge, subject to existing character visibility/NSFW/deleted-character gates.
4. Deleted individual group messages are not included in the snapshot.
5. Repeated delete RPC / worker retry does not duplicate archived counts.
6. Active single chat counts remain unchanged; deleted single chat uses one archive snapshot.
7. Failed delete rolls back both snapshot and job/parent changes.
8. Concurrent parent-first writer/delete locking prevents post-snapshot replies.
9. RPC grants, owner=postgres, SECURITY DEFINER, search_path='' and character visibility restrictions remain unchanged.

## Migration workflow decision

Historical source recovery is now complete for the three live migration rows above, but broader migration history drift remains. Do not create/apply a new migration against the hosted test DB until a reproducible local migration workflow is available. No local Supabase CLI/Docker was available in this environment. Do not run db reset, db push, migration repair, or ad hoc DDL.

Next safe action:
- Reconcile the 20261022185425 vs 20261023120000 timestamp/name mismatch without editing hosted migration history.
- Build the additive reviewed migration from the current live function definitions, not stale historical snapshots.
- Add the regression tests above.
- Apply only after an approved, reproducible migration workflow is available; verify function definitions, grants, owner, security_definer, search_path, and count behavior in the test DB.

PR #200 remains Draft/unmerged. No deletion cron is enabled. PR #201 remains paused.


## 2026-11-02 requirement correction

The previous heading and statements calling the deleted-group count behavior a confirmed gap are superseded. The product requirement is that group role replies remain in each character's cumulative total after chat deletion and after the 30-day transcript purge. Use `supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql` as the sole current proposal; do not use the narrower filter-only proposal.
