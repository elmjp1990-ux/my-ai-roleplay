# PR #200 — SQL writer-path inventory (bounded review, 2026-11-02)

Status: partial inventory; not a claim of repository-wide completeness.

## Scope inspected

- All SQL migration files changed by PR #200.
- Changed Edge Function files: `chat-deletion-worker.ts`, `purge-chat-deletions/index.ts`, `story-session/index.ts`.
- Frontend call sites in the PR branch `index.html`.
- The deployed single-chat `chat-turn` Edge Function fetched from the PR branch.
- Live test-project definition of `public.sync_character_chat_snapshot(uuid)`.

## Confirmed writer paths

| Path | Writes | Parent serialization / gate | Result |
|---|---|---|---|
| `append_chat_group_mock_turn` | group turn, player message, character reply, charge, wallet transactions | locks `chat_groups` FOR UPDATE; owner + active + not archived | Good for this writer |
| Frontend group edit/delete latest message | updates `chat_group_messages` | authenticated direct DML denied by grants; restrictive active-parent RLS | Requires transaction race fixture |
| `delete_chat_group_with_related_data` | soft-delete marker + deletion/storage jobs | locks group parent first | Deletion entry point |
| `delete_chat_session_content` | soft-delete marker + deletion/storage jobs | locks session parent first | Deletion entry point |
| `chat-turn` Edge Function | service-role assistant insert into `chat_messages` | calls `reserve_chat_turn`; assistant insert trigger locks session and checks active state | Single-chat late-write gate exists |
| `sync_character_chat_snapshot` | updates session snapshot, group member snapshot, group message speaker snapshot | live definition had no parent-first group lock and no deleted-parent filter | Gap; draft fix added |

## Confirmed gap and proposed fix

Live `sync_character_chat_snapshot(uuid)` is SECURITY DEFINER and updates group child metadata by character ID, including rows whose parent group has `deleted_at`. This bypasses the authenticated RLS lifecycle guard. Draft-only fix:

`supabase/drafts/sync-character-chat-snapshot-parent-lock-proposal.sql`

The proposal locks active single-session parents, then active group parents in deterministic ID order, and only updates children belonging to active parents. No migration has been applied.

## Limits

- This review covered PR changed SQL files, selected frontend call sites, and the named deployed Edge Function. It did not enumerate every unchanged repository migration, every live function, Dashboard SQL, external service-role integration, or manually invoked service-role query.
- service_role bypasses RLS. Do not revoke service_role table grants until every worker/function dependency is inventoried.
- The group mock writer is the only explicit `INSERT INTO chat_group_messages` found in the PR changed migrations. This does not prove no other writer exists outside that scope.
- No schema changes, data changes, Storage operations, deployment, cron, or production operations were performed.

## Required next work

1. Full repository-wide SQL function/trigger/view writer index, not only PR changed files.
2. Inventory all service_role callers and any direct DML to group tables.
3. Add transaction fixtures for writer/delete ordering and child edit/delete ordering.
4. Integrate immutable per-character turn snapshots into delete RPCs and the latest purge RPC; make count RPCs use active live rows plus archived snapshots exactly once.
5. Add rollback, idempotency, incomplete-snapshot detection, purge retry, and post-purge count-invariance tests.
6. Restore a trustworthy schema-only local baseline and pass clean replay before applying migrations anywhere.
7. Complete browser multi-tab/device and real Storage failure/retry E2E.

No cron, deployment, merge, or hosted DDL is authorized by this document.
