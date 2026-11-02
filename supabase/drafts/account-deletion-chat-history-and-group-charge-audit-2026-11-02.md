# Account deletion — chat history snapshots, group charge evidence, and stale-JWT audit
Date: 2026-11-02
Round: 77
PR: #200 — Draft / unmerged

## Scope and safety

Read-only Supabase catalog/function inspection plus repository draft updates. No transcript contents or user message bodies were queried. Live row checks were limited to aggregate counts/status/currency totals. No DDL/DML, migration, RPC execution, Auth/Storage mutation, deployment, or Cron operation occurred.

## 1. Account deletion bypasses ordinary chat deletion snapshots

The ordinary single/group chat deletion RPCs call `private.snapshot_chat_deletion_character_turn_stats(resource_type, resource_id, owner_id)` before setting parent `deleted_at`. This writes:
- `chat_deletion_character_history`: one immutable character-use tombstone per session/group/character, including group members who never produced an AI reply.
- `chat_deletion_character_turn_stats`: per-character completed assistant reply counts.

Account deletion follows a different path: `auth.users` directly owns `chat_sessions.user_id` and `chat_groups.owner_id` through ON DELETE CASCADE. The account prepare function does not call the ordinary chat delete RPCs. Auth deletion therefore removes the sessions/groups and their messages without first producing those chat deletion snapshots.

That can silently reduce cumulative character turn counts for every character the deleting user chatted with. It can also erase the evidence that a never-published character had prior chat history, potentially making a later history-aware hard-delete decision incorrectly appear eligible.

### Draft correction made

Added `private.snapshot_account_chat_character_history(p_user_id)` to `chat-deletion-cumulative-turn-statistics-proposal.sql`:
- Locks all account-owned single-session and group parents in stable ID order.
- Uses the existing snapshot helper for non-completed parents.
- For already completed 30-day purges, does not recount now-purged transcript rows; it requires the durable history tombstone to exist.
- Preserves no message text and stores no account/player ID in the aggregate tables.
- Revokes direct EXECUTE from PUBLIC, anon, authenticated, and service_role; it is intended to be called by the postgres-owned SECURITY DEFINER prepare RPC.

Integrated a single call to this helper into `prepare-account-deletion-character-preservation-integration.sql`, immediately after locking/validating the due deletion request and before existing-batch branching. It runs in the same transaction, so any later failure rolls the snapshot back with the prepare operation.

## 2. Group financial and idempotency evidence is not fully archived

Live catalog facts:
- `chat_group_turn_charges` has FKs to `chat_groups`, `chat_group_turns`, and `auth.users`, all ON DELETE CASCADE.
- `chat_group_turns` has FKs to `chat_groups` and `auth.users`, both ON DELETE CASCADE.
- Test DB aggregate only: 37 group charge rows, all `settled`; total cost 315 (115 silver + 200 diamonds).
- Corresponding `wallet_transactions` aggregate: 38 rows with `biz_type='group_chat_turn_charge'`, net amount -315.
- No row payloads or player message content were read.

The current prepare SQL archives `wallet_transactions`, single-chat `chat_turn_charges`, and `chat_turn_events`, but not `chat_group_turn_charges` or `chat_group_turns`. Wallet transaction rows alone do not preserve the full group charge record (request key, group turn link, member count, split currency amounts, status). The group turn row is also the source idempotency record; its `request_content` is transcript text and must not be copied into the account archive.

### Draft correction made

Updated the complete prepare-function draft:
- Extends the archive source-table allowlist for `chat_group_turn_charges` and `chat_group_turns`.
- Archives full `chat_group_turn_charges` payloads for financial evidence.
- Archives only minimal `chat_group_turns` metadata: id, group_id, request_key, status, created_at, completed_at.
- Explicitly excludes `request_content` and user_id from the group-turn idempotency snapshot.
- Adds source/archive row-count checks and exact-payload checks before the batch enters the irreversible `deleting` phase.
- These changes are draft-only; they do not alter the live archive allowlist or function.

## 3. Live account_is_active() still has a stale-JWT gap

The live function currently returns true when `auth.uid()` is non-null and no `account_deletion_requests` row exists. It does not verify that the corresponding `auth.users` row still exists.

Because Supabase access JWTs are stateless and can remain valid until expiry, a previously issued token can still yield the same `auth.uid()` after Auth Admin deletes the user. The request row is removed by its Auth FK cascade, so the current helper could incorrectly return true for that stale token.

The repo already has a draft replacement in `account-is-active-auth-user-existence-guard.sql`, which additionally requires an `auth.users` row. The static guard now checks this draft. It remains unintegrated and requires a disposable PostgreSQL test using a deleted Auth user plus a still-present signed JWT.

## 4. Static regression guard changes

Updated `scripts/test-account-deletion-character-preservation-draft.mjs` to check:
- Account-owned single/group history snapshot helper exists, locks parents, and handles already-completed purge tombstones.
- Account prepare calls the snapshot helper exactly once before batch lookup.
- Group charges are archived and verified.
- Group-turn idempotency metadata is preserved without request_content.
- account_is_active() draft requires an extant auth.users row.

Updated `.github/workflows/account-deletion-worker-tests.yml` to run when the chat aggregate proposal or stale-JWT guard draft changes.

## 5. Remaining acceptance gates

1. Current changes are draft SQL plus static guards only; they have not been parsed/executed by PostgreSQL.
2. The cumulative turn-statistics/tombstone proposal must be integrated and replayed before the account prepare replacement can call its helper.
3. Group charge archive schema/constraint must be tested with retry, duplicate payload conflict, and Auth/group cascade fixtures.
4. account_is_active() must be integrated and tested against a stale JWT after Auth deletion.
5. Full schema baseline, migration provenance, clean-room replay, and Storage E2E remain outstanding.
6. Account-deletion worker remains hard-disabled; PR #200 remains Draft/unmerged.


## CI confirmation — 2026-11-02

Static guard and worker checks completed successfully on code head `e9a8d4683a3d5690a73f8e3325fd02f10da97626`:
- Account deletion worker tests #151: **success** (includes account/character draft invariants).
- Chat deletion worker tests #121: **success**.
- Group background UI syntax check #849: **success**.

These are static/worker-unit checks only. They do not execute the draft SQL, prove PostgreSQL syntax/replay, or replace stale-JWT/Auth cascade integration tests. The audit document was committed separately after the tested code head; no code changed in that documentation-only commit.
