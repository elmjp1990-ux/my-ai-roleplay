# Test-only premise and migration ledger reconciliation — Round 49 — 2026-11-02

## User-confirmed project premise

The user explicitly confirmed that the entire POYOZZ website is still a test environment and has no real users.

Engineering implications:
- We may choose a clean, coherent pre-launch architecture rather than preserve compatibility for non-existent production users.
- Test fixtures, test accounts, and test-only rows may be reset or recreated later when a reviewed plan identifies the exact scope and effects.
- This does not authorize indiscriminate hosted database resets, dropping core tables, deleting financial/audit evidence, or weakening RLS/Storage protections.
- Do not perform destructive hosted Supabase operations until the exact objects, dependencies, rollback/recovery path, and user-approved scope are recorded.
- Existing product requirements remain binding: existing authorized player chats survive character deletion/account archival; archived characters cannot start new chats; account deletion preserves all character content/media and historical creator attribution; chat deletion keeps the approved 30-day lifecycle and cumulative character-turn evidence.

## PR #200 and branch state

- PR #200 remains open, Draft, and unmerged.
- Head branch: `security/chat-deletion-lifecycle-reconciliation`, current reviewed head before this round: `08460126eb10d8d3536c605aef2a8392e205116e`.
- Base `main` advanced to `d4e55c20616ca16e3e1ccb19aded66dd40872bd4`; PR branch is one commit behind and has 221 commits ahead of the merge base. Compare status is `diverged`.
- Main's new commit changes the same local migration replay workflow file; the PR branch already contains an expanded version of that workflow. Do not blindly rebase or overwrite either version; reconcile the workflow deliberately.
- No PR workflow run was returned for main's latest commit. CI/replay remains unverified.

## Newly confirmed migration-ledger mismatch

Read-only comparison of the connected test project's `supabase_migrations.schema_migrations` with the PR branch recursive Git tree found:

- Remote test database ledger: **152** migration records.
- PR branch: **102** timestamp-prefixed migration SQL files, plus **5** legacy non-timestamp-prefixed SQL files.
- Only **48** timestamp versions are shared between the remote ledger and the branch's timestamped files.
- **104** remote ledger versions have no matching timestamped SQL file in the branch.
- **80** branch timestamp versions have no matching remote ledger version.
- Five duplicate timestamp collisions exist in the branch:
  - `20261015151500`: two files
  - `20261020120000`: two files
  - `20261023120000`: two files
  - `20261024170000`: two files
  - `20261031120000`: three files
- The branch has five older migration files without the required 14-digit timestamp prefix.
- This is a much broader replay problem than only the missing original `profiles` / `characters` baseline. A simple baseline addition alone cannot make replay trustworthy.
- Do not rename already-applied remote versions, invent historical version IDs, or edit hosted migration history to make the counts match.

## Current security-advisor snapshot

Read-only Supabase security advisor results (2026-11-02):
- 16 tables have RLS enabled with no policies. This may be intentional for service-only queues/archive tables, but each table's grants and all SECURITY DEFINER access paths must be verified.
- 4 SECURITY DEFINER RPCs are executable by `anon`: `get_character_comments_safe`, `get_character_turn_counts`, `get_encounter_character_schedule`, `get_public_character_turn_count`. Their intended public behavior and exact output filtering need explicit review; do not blindly revoke access if the frontend depends on them.
- 27 SECURITY DEFINER RPCs are executable by `authenticated`; review each function's caller binding, authorization, fixed search_path, and least-privilege grants. The advisor flag alone does not prove exploitability.
- Leaked-password protection is disabled in Auth; this is a separate pre-launch configuration gate.
- No advisor remediation or hosted mutation was performed in this round.

## Next engineering sequence

1. Produce a deterministic migration reconciliation manifest: remote version/name ↔ tracked file ↔ commit provenance, including duplicates, missing files, legacy filenames, and migrations intentionally absent from the repository.
2. Identify which migrations were applied through Dashboard/manual SQL and recover their source from Git history or authoritative SQL evidence; do not fabricate provenance.
3. Because there are no production users, evaluate a clean pre-launch rebuild path using a disposable local database and an explicitly reviewed consolidated baseline. Keep this separate from the connected hosted test project.
4. Reconcile the branch with main's one additional commit without losing the expanded local-only workflow.
5. Replay the full schema from a clean local database, then run structural, RLS/ACL, deletion lifecycle, existing-chat continuation, and Storage authorization tests.
6. Keep account-deletion worker's source-level 503 kill switch and all deletion cron schedules disabled until acceptance gates pass and the user explicitly approves activation.

## Safety record

This round used GitHub metadata/file reads, Supabase migration listing, table listing, and security advisors only. No hosted DDL/DML, migration apply, Auth/Storage mutation, Edge deployment, database reset, or Cron operation occurred. PR #200 remains Draft/unmerged.
