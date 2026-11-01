# PR #200 — Chat deletion final acceptance matrix

Date: 2026-11-01  
Repository: `elmjp1990-ux/my-ai-roleplay`  
Branch: `security/chat-deletion-lifecycle-reconciliation`  
Test Supabase project: `ouyewoagbmtqehbofrje`  
Status: **Draft — not approved for merge or scheduling**

## Executive result

The shared 30-day single/group chat deletion lifecycle has substantial implementation and test evidence: immediate parent-level access gates, writer/delete serialization, relational purge, actual disposable PNG Storage deletion, financial-evidence preservation, and Auth-parent cascade behavior have been tested. Missing-object idempotency was also confirmed through a real Dashboard invocation.

Two release boundaries remain:
1. A real Storage API error response flowing through the live Worker into retry/backoff has not been demonstrated. DB-only rollback tests and source inspection are not equivalent to that E2E.
2. The test project's migration history is materially drifted from repository history; a clean replay plan is not established. Do not assume this branch can be replayed into a fresh environment or repair remote migration history manually.

PR #201 account deletion remains paused. No chat purge cron has been created.

## Acceptance matrix

| Area | Result | Evidence / limitation |
|---|---|---|
| Shared single/group 30-day soft-delete contract | PASS | Both entry points enqueue the shared lifecycle; one player/multiple AI characters remains one group parent. |
| Immediate access freeze | PASS | Deleted-parent restrictive RLS gates and parent-first writer locks implemented; delete-vs-message, delete-vs-reserve, and delete-vs-encounter-evidence two-transaction races rejected contenders. |
| User-facing delete confirmation | PASS | Single and group confirmations explain immediate hiding/access stop and permanent purge after 30 days. |
| Day-30 relational purge | PASS | Real disposable single/group E2E cleared message content, versions, snapshots, chat-only group children and photo metadata while retaining tombstones and financial evidence. |
| Actual Storage deletion | PASS | Real disposable PNG objects in `personax-memory-photos` were removed through Storage API for single and group E2E. |
| Missing-object idempotency | PASS | Real Dashboard invocation treated a missing legal object path as completed without error. |
| Storage API error → retry | NOT VERIFIED | No supported Storage fault-injection interface found. Traversal-shaped path did not cause API error. Do not modify Supabase-managed `storage` schema or use speculative paths as a failure stimulus. |
| DB retry/backoff/dead-letter state machine | PASS — DB-only | Actual claim/failure RPCs tested in rollback-only transactions for both queue types, including retry through attempt 7 and dead-letter at attempt 8. Does not prove live Storage HTTP error behavior. |
| Financial evidence retention | PASS — rollback-only | Actual purge RPC preserved settled charge, turn event and wallet transaction while clearing content/snapshots; transaction rolled back after assertions. |
| Auth cascade leaves durable jobs | PASS — rollback-only | Synthetic Auth deletion removed Auth/profile/session/group parents while relational and Storage queue rows survived; transaction rolled back. |
| Service-only worker authorization | PASS on prior worker version; v9 source unchanged for auth | Named Secret Key wrapper `withSupabase({ auth: "secret:default" })`; positive/negative key behavior previously tested. Never expose Vault value. v9 was source-verified after deployment but not freshly invoked. |
| Worker result accounting | PASS — source fix deployed | v9 checks RPC boolean results for both relational purge and Storage completion; `false` is not counted as success. |
| Storage bucket/path allowlist | PASS — source + E2E | Worker accepts only `personax-memory-photos`; character illustration/video buckets are excluded. |
| Signed URL lifetime | IMPLEMENTED / SOURCE REVIEW | New chat-memory signed URLs use 300 seconds; previously issued URLs can remain valid until their original expiry (up to 1 hour). |
| Cron / scheduling | NOT ENABLED | No chat-deletion cron exists. Only pre-existing `poyozz-encounter-evaluation-dispatch` is active. Explicit user approval required before creating schedule. |
| Account deletion integration | OUT OF SCOPE / BLOCKED FOR PR #201 | Group charge archival and orphan chat-content coordination remain unresolved; no account-wide Storage sweep worker is deployed. Do not start account deletion implementation until separately reconciled. |
| Migration replayability | NOT READY | Live DB and repository migration inventories diverge (141 historic live entries before this PR's 10 additions vs 96 repo SQL files, 57 live-only, 14 repo-only, 67 shared names with version-prefix mismatch, duplicate repository prefixes). No reset/replay or manual remote history repair performed. |
| CI / preview | PASS for current source commit | Vercel preview deployment completed; `inline-javascript-syntax` workflow passed. This does not replace backend E2E. |

## Worker v9 correction

Commit `0ee2899db4f6629f48b906b55ade41c1b15f505a` updates `supabase/functions/purge-chat-deletions/index.ts`:
- Require `purge_chat_deletion_job` to return `true` before incrementing `chat_purged`.
- Require `mark_chat_storage_deletion_job` to return `true` before incrementing `storage_deleted`.
- A lost/stale lease can cause a SECURITY DEFINER mark RPC to return `false` without a transport error; v8 could misreport that as successful completion. v9 counts it as failure instead.
- v9 deployed ACTIVE to the test project and source was read back to verify both boolean checks. No new Dashboard invocation was run after v9 deployment; prior HTTP/E2E evidence applies to v8. Authentication wrapper and Storage removal implementation were not changed by this correction.

## Current test residue and safety state

- `chat_storage_deletion_jobs`: 0 rows.
- `chat_deletion_jobs`: one completed synthetic parent tombstone remains: `46d4c421-d490-4357-9e2b-7bf7802d19e7`; attempt_count 1, no error, no next retry, zero Storage children.
- Direct SQL cleanup was blocked by the pre-existing Supabase `storage.protect_delete()` guard (SQLSTATE 42501); no bypass was attempted. No Storage trigger was added or altered.
- No real user, account, chat, or character asset was deleted in this final pass.
- No Vault secret value was read or disclosed.
- No production deployment or chat-deletion schedule was created.

## Decision

**Keep PR #200 Draft. Do not merge and do not create cron yet.**

Before treating this as launch-ready:
1. Decide whether live Storage API failure injection can be tested using a Supabase-supported isolated mechanism; otherwise retain it as an explicit external verification limitation and decide whether it is an acceptable residual risk.
2. Establish a separately reviewed migration replay/reconciliation plan in a disposable environment.
3. Keep account deletion (PR #201) separate; resolve group-charge archival, orphan chat content, and bucket-specific asset sweep rules before implementing it.

This document records the current evidence and limitations; it does not approve merge, scheduling, or production rollout.


## 2026-11-01 — deterministic Worker adapter tests added

Commits:
- `9d509f1925459b19807c5c3408dbce7861085e08` — extracted the chat Storage deletion adapter into `supabase/functions/_shared/chat-deletion-worker.ts`.
- `820d839c106dbbcc2cc91939c434f9e2bbd7c1c5` — added deterministic adapter tests.
- `b653b74173f87385560fadeef6a6085dffe5accb` — wired the deployed Worker entrypoint to the tested adapter.
- `a8280befa6dbfb5b7f183a33552c0df5d8aa650f` — added a focused Deno 2 GitHub Actions workflow.

The adapter tests cover:
1. Successful Storage removal is counted only after the queue-mark RPC returns `true`.
2. Simulated Storage HTTP 5xx returns an error and is routed to the queue failure marker.
3. Simulated network failure is routed to the queue failure marker.
4. A false or errored queue-mark RPC is never counted as completed.
5. Non-chat buckets and empty object paths are rejected without calling Storage.

**Evidence classification:** these are deterministic Worker/queue adapter tests with fake Storage and RPC adapters. They are not a live Storage HTTP fault-injection test and do not prove a real Supabase Storage 5xx response. The existing DB retry/backoff/dead-letter rollback tests remain separate evidence.

**CI status:** workflow was added to run `deno test --no-check supabase/functions/_shared/chat-deletion-worker.test.ts`; GitHub Actions result must be checked before marking the tests as passed. No local Deno executable is available in the current execution environment.

No database DDL, migration history, Storage schema, Storage objects, queue rows, cron jobs, Vault values, or production resources were changed by these commits. PR #200 remains Draft and unmerged. PR #201 remains paused.
