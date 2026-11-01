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

PR #200 remains Draft/unmerged. No hosted migration was applied. No cron was enabled. PR #201 remains paused.
