# Account deletion worker atomic lease design — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`
PR: #200 — Draft / unmerged
Status: design proposal only; no SQL or hosted changes in this round.

## Decision: use a durable lease-control row independent of the request row

The lease must survive `prepare_account_deletion()`, because that operation removes the request row and its FK-dependent data before the external Auth Admin deletion and finalization complete. Therefore, do not store the only lease on `account_deletion_requests`.

Proposed control table: `public.account_deletion_work_leases` (name is provisional), keyed by `target_user_id` with immutable request identity columns `requested_at` and `scheduled_for`. It must not have an ON DELETE CASCADE FK to `auth.users` or `account_deletion_requests`; otherwise the recovery lease disappears precisely when Auth deletion or relational cleanup occurs. A lease row is operational metadata, not user content.

The claim function must reconcile the exact request identity before issuing or renewing a lease. A user can have at most one pending deletion request under the current model; if that invariant is not enforced in the schema, the implementation must use a stable request UUID rather than assume user_id alone is unique.

## Lease fields and fencing

Minimum proposed fields:
- `target_user_id`
- `requested_at`, `scheduled_for` (exact request identity)
- `lease_token` (unguessable per-claim token)
- `lease_generation` (monotonically increasing fencing number)
- `lease_expires_at`
- `claimed_at`, `updated_at`
- `batch_id` nullable until archive creates the batch; retain after request row is deleted

Every mutating worker RPC must require both token and generation and verify, inside the same transaction as its mutation, that the lease is still current and unexpired. A stale worker must not be able to archive/prepare/finalize, renew, release, or record failure. A generation check prevents an old invocation from becoming valid again if a token is accidentally reused. Do not return lease tokens to ordinary authenticated clients; only the service-only worker path may call these RPCs.

## Atomic claim algorithm

1. In one transaction, select eligible due requests and interrupted `deleting` batches using row locking with `FOR UPDATE SKIP LOCKED`.
2. Reconcile the exact request identity against the durable lease row.
3. Claim only if there is no active lease or the existing lease has expired. On every successful new claim, rotate the token and increment generation; set a bounded expiry.
4. Return the work item plus token/generation only to the service-role caller. A competing invocation sees the active lease and receives no item; it must not call archive or failure recording for that item.
5. For the deleting-batch recovery case where the request row is already gone, claim from the batch plus its retained lease row. If a deleting batch exists without a lease row (legacy/incomplete state), use a narrowly scoped recovery claim that locks the batch, verifies Auth state, creates a new lease, and records the batch association.
6. When archive creates or finds the batch, atomically attach `batch_id` to the lease after validating the same token/generation.

The claim function must not use a read-then-write race. It should lock candidate rows and perform the lease insert/update conditionally in the same database transaction.

## Worker lifecycle and external Auth call

- Worker receives a claimed item, then passes token/generation to archive, prepare, finalize, and failure recording.
- Renew the lease before long-running phases and immediately before the Auth Admin delete call. Lease TTL must exceed the expected duration of one phase, but must remain bounded; choose and document a conservative initial TTL from observed execution time rather than guessing.
- After Auth deletion, finalize only if the same lease is still current. Finalize must continue to independently verify that the Auth user is absent.
- If Auth Admin returns an error, verify Auth absence independently. If absent, proceed to fenced finalize; if present or lookup fails, record a failure only while lease ownership remains valid.
- On successful finalize, mark the lease completed/released in the same transaction as batch completion. Retain enough metadata for audit/idempotency; define a cleanup/retention rule separately.
- If the process crashes, lease expiry permits a new worker to reclaim. A reclaimed worker gets a new token and higher generation.
- An old invocation may still have an in-flight Auth HTTP request when its lease expires. Fencing prevents it from changing database state afterward; Auth deleteUser is idempotently reconciled by a fresh Auth lookup before the new owner finalizes. The worker must renew immediately before the call and use bounded request timeouts.

## Failure semantics

`record_account_deletion_failure` must become lease-fenced:
- require matching batch (when known), request identity, token, generation, and unexpired lease;
- update failure metadata only for the current owner;
- never write a failure when claim returned no item;
- never let a stale invocation overwrite a newer owner's error/progress;
- if lease ownership is lost, return a distinct `lease_lost` result and do not mutate the batch.

Do not change a batch from `deleting` to `failed` merely because one worker timed out; the next owner must be able to resume safely.

## Cancellation and lifecycle constraints

- `cancel_account_deletion()` must serialize against claim using the same request/lease lock order. It may cancel only before an archive batch has begun, and must not clear an active lease belonging to a worker that has already started.
- If cancellation wins before claim, no worker may claim the canceled request.
- If claim wins, cancellation must return the existing not-cancelable result.
- Preserve the current archive evidence verification, prepare idempotency, Auth-absence check, and finalize guard.
- A lease must not cause the 5-minute test grace period or production 30-day grace period to change. The worker always trusts backend `scheduled_for`.

## Required implementation and test matrix

Use a disposable local Supabase stack and synthetic Auth users only.

| Scenario | Required result |
|---|---|
| Two invocations claim same due request concurrently | Exactly one gets a lease; other gets no work and records no failure |
| Claim before archive, then worker crash | Lease expires; new generation reclaims same request |
| Crash after archive | New owner finds same batch and continues; no duplicate archive evidence |
| Crash after prepare / request row cascade | Durable lease and batch allow recovery without request row |
| Crash after Auth deletion, before finalize | New owner verifies Auth user absent and finalizes |
| Old owner resumes after lease reclaimed | All DB RPCs reject old token/generation; no stale failure write |
| Old owner Auth call overlaps expiry | New owner checks Auth state; finalize remains idempotent |
| Lease renewal with stale token | Rejected; current lease unchanged |
| Failure write after expiry | Rejected/no-op; no false failure metadata |
| Cancellation races claim | Exactly one serializable outcome; no orphaned claim |
| Repeated delivery after completion | No second deletion side effect; completed result is idempotent |
| Lease row after Auth user deletion | Remains available until batch completion/audit retention |

## Implementation order

1. Confirm the live schema invariants and all callers of claim/archive/prepare/failure/finalize/cancel; preserve function signatures only where safe.
2. Recover or prepare the explicitly local-only schema baseline before attempting local replay. Do not invent the missing historical migration.
3. Add lease table and service-only atomic claim/renew/release RPCs in a new, properly generated migration.
4. Fence every state-mutating account-deletion RPC in the same transaction as its work.
5. Update Edge Function to process only claimed items and renew at safe boundaries.
6. Add deterministic SQL concurrency tests plus worker unit tests for stale owner, lease expiry, cancellation race, and Auth/finalize recovery.
7. Run local migration replay, database tests, Deno check/tests, and security advisors.
8. Only after all local gates pass, consider a separately approved synthetic-user E2E in the hosted test project. No cron or production deployment without explicit approval.

## Safety

This file is a design proposal, not an implementation or migration. No hosted DDL/DML, account-deletion RPC, Auth user creation/deletion, Edge Function deployment, or Cron change was performed. PR #200 remains Draft/unmerged.
