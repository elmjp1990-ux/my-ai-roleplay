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


## Round 34 — live schema invariants and lease protocol refinement

Read-only inspection of connected test project `ouyewoagbmtqehbofrje` confirmed the following implementation constraints:

- `account_deletion_requests` has `user_id` as its primary key and a cascading FK to `auth.users(id)`. It stores only `requested_at` and `scheduled_for`; there is no stable request UUID.
- `account_deletion_archive_batches` has a UUID primary key, nullable `target_user_id`, `requested_at`, and `scheduled_for`; it has no FK to Auth and no unique constraint on the exact request identity. Do not assume a uniqueness guarantee that is not present.
- `account_deletion_archive_items.batch_id` references the archive batch with NO ACTION; archive rows are not automatically removed by deleting the Auth user.
- No lease-control table exists in the inspected public schema.
- Existing worker RPCs are SECURITY DEFINER, owned by postgres, use an empty search_path, and have service_role-only execute ACLs, except user-facing request/cancel RPCs which also grant authenticated. New lease RPCs must preserve the service-only boundary.
- Test database currently stores the five-minute grace period in `account_deletion_settings`; the request table's default is also five minutes. The setting table remains authoritative; lease work must not change either grace-period policy.

### Refined row identity and lock order

Because there is no request UUID, use the tuple `(target_user_id, requested_at, scheduled_for)` as the exact logical request identity. A lease row keyed by `target_user_id` can be reused only after verifying the prior tuple is terminal/cancelled and the prior batch is not active; every new request identity must rotate token and increment generation. Do not permit a previous lease to be silently rebound while it is active.

All operations that need both rows must take locks in one consistent order:

1. Lock the exact `account_deletion_requests` row (when it still exists).
2. Lock or create the durable lease row for that target user.
3. Lock the associated archive batch (when one exists).

Claim and cancellation must use the same order. If claim wins, it creates/renews the lease while holding the request lock; cancellation then sees an active, unexpired claim and must refuse. If cancellation wins, it deletes the exact request under lock; claim subsequently sees no eligible request and cannot create a lease. Once prepare commits and the request disappears, recovery must start from the retained lease + deleting batch, not attempt to reacquire a request lock.

### Fencing requirements by existing RPC

- Claim replaces the current read-only `get_account_deletion_work_items()` behavior: atomically select and lease a bounded set; return token and generation only to service_role. The Edge Function must never call the old unclaimed listing path for work.
- Archive must require request identity + token + generation and attach the resulting `batch_id` to the lease in the same transaction. It must reject a mismatched or expired lease before creating or changing archive state.
- Prepare must validate the same lease inside its transaction before snapshot verification and destructive relational cleanup. It must retain the lease row while deleting the request/profile/Auth-dependent data.
- Failure recording must validate token + generation + expiry and exact batch association. A stale worker must not update `last_error` or `attempt_count`.
- Finalize must validate token + generation + expiry and batch association in the same transaction that checks Auth absence and marks completed; it then marks the lease terminal without deleting the durable audit row.
- Renew must be conditional on current token + generation and must not resurrect an expired lease. Reclaim creates a new token and increments generation.
- Cancellation must reject an active lease even if the archive batch has not yet been created. A lease that has expired and has no batch may be cancelled under the same row-lock order; if policy instead requires cancellation to be permanently blocked once any claim occurred, preserve a durable claimed marker and test it explicitly.

### External Auth call boundary

PostgreSQL fencing cannot make an external Auth HTTP request atomic with a database transaction. Therefore:
- Renew and validate immediately before calling Auth Admin; set a bounded HTTP timeout shorter than the lease's remaining time.
- A stale worker can never finalize or write failure metadata after reclaim because every database mutation is fenced.
- Two Auth delete calls may overlap only in a pathological pause/network-delay case; deletion of the same Auth user must be treated as an idempotent external side effect. A new owner must independently check Auth state before deciding whether to call delete and before finalize.
- Do not claim that a lease can cancel an already in-flight Auth HTTP request. The safety guarantee is fenced database state plus reconciliation of Auth absence, not distributed transaction semantics.

### Open gates before implementation

1. Baseline migration provenance is still unresolved. The clean local replay workflow fails before reaching the draft SQL because foundational `public.characters` and `public.profiles` creation migrations are absent. No guessed baseline or hosted migration-history mutation is allowed.
2. The complete set of all callers to the seven existing RPCs must be inventoried before signature changes; current Edge Function caller is confirmed, but frontend/admin/manual callers still need repository-wide search.
3. The SQL concurrency test harness must prove simultaneous claim/cancel/renew/reclaim behavior using independent database sessions, not only sequential unit tests.
4. Lease TTL must be selected from measured local worker phase durations and Auth HTTP timeout; do not hardcode an arbitrary TTL in the migration.
5. Archive batch uniqueness must be established in the new protocol without retroactively assuming existing data already satisfies it. The migration must first detect and safely handle any duplicate active exact-request batches.

This refinement is still a design/audit note only. No lease table, RPC, migration, hosted DDL/DML, account-deletion execution, Auth user creation/deletion, deployment, or Cron change was performed.


## Round 35 — repository caller inventory follow-up

A recursive Git tree at the current branch head was inspected (180 tracked files; tree response was not truncated). The following tracked application entry points were fetched and searched for all seven account-deletion RPC names:

- `index.html`: direct client calls only to `request_account_deletion()` and `cancel_account_deletion()`.
- `supabase/functions/account-deletion-worker/index.ts`: direct service-role calls to `get_account_deletion_work_items()`, `archive_account_deletion_data()`, `prepare_account_deletion()`, `finalize_account_deletion()`, and `record_account_deletion_failure()`.
- Other tracked Edge Function entrypoints inspected: `chat-turn`, `encounter-session`, `encounter-session-state`, `encounter-turn`, `expire-memory-album-photos`, `purge-chat-deletions`, and `story-session`; no direct calls to these account-deletion RPCs were found.
- The live definition of `prepare_account_deletion()` internally invokes `archive_account_deletion_data()` when no batch exists. This internal call must be redesigned together with the worker-facing archive/prepare API; it cannot remain an unfenced bypass.
- GitHub code search returned `incomplete_results=true`; therefore this is a tracked application-entrypoint inventory, not proof that no external SQL Editor/manual/admin caller exists. The live ACL inventory remains the authority for callable roles.

Implementation consequence: keep the two player-facing RPCs (`request_account_deletion`, `cancel_account_deletion`) authenticated and separate from the service-only worker RPC set. The cancellation function must lock the request then lease; worker claim/archive/prepare/failure/finalize use the same canonical request → lease → batch lock order where those rows exist. Refactor prepare's internal archive invocation so both operations validate the same lease within the same transaction rather than exposing an unleased nested path.

This is still pre-implementation documentation. No RPC signature, migration, worker code, hosted schema or data was changed.


## Round 36 — first implementation landed in a disposable-only SQL draft

Implementation file: `supabase/drafts/account-deletion-worker-atomic-lease.sql` (DRAFT ONLY; deliberately not in `supabase/migrations/`).

Implemented:
- Durable `account_deletion_work_leases` table with no Auth/request FK, request identity tuple, random UUID token, monotonic generation, expiry, status, batch association and failure metadata. RLS enabled; all table privileges revoked from PUBLIC/anon/authenticated/service_role.
- `claim_account_deletion_work_items(1)`: transaction-scoped claim, request → lease → batch lock order for due requests, `FOR UPDATE SKIP LOCKED`, active-lease filtering, expired-lease reclaim, duplicate active-batch fail-closed guard, deleting-batch recovery after request-row cascade, and no starvation behind an earlier active lease.
- `renew_account_deletion_lease`: renews only the current unexpired token/generation; expired/stale owners cannot resurrect a lease.
- `prepare_account_deletion_leased`: validates token/generation inside the same transaction as the existing complete prepare routine; supports recovery when the request row is already gone but a deleting batch remains.
- `finalize_account_deletion_leased` and `record_account_deletion_failure_leased`: fence batch completion and failure telemetry; stale owners cannot mutate either.
- `cancel_account_deletion()` now follows request → lease → batch lock order. An active lease blocks cancellation; an expired lease without a batch can be cancelled. Claim and cancellation therefore serialize.
- Old unleased work-list/archive/prepare/finalize/failure RPC execute privileges are revoked from service_role. The Edge Function now uses only claim + lease-fenced RPCs. It claims one account per invocation, renews before Auth Admin calls/finalize, and fails closed on non-404 Auth lookup errors.
- Ten-minute lease TTL is provisional and must be revisited against measured phase duration / Auth request timeout before any schedule is enabled. Worker remains source-disabled.

Verification:
- Account worker Run #642 on HEAD `7f4f6f1`: account-worker/static checks and disposable PostgreSQL schema replay passed. Logs confirmed exactly-one concurrent claim, active-lease fairness, expired reclaim/new generation, stale renew/failure rejection, and cancellation behavior.
- Run #647 on HEAD `9a5130b`: account-worker and disposable-schema-replay both success; additionally confirmed stale generation cannot call prepare or finalize.
- Run #648 on HEAD `32fe709`: account-worker and disposable-schema-replay both success. This run includes corrected 9-scenario summary text; the new simultaneous claim-vs-cancel race cases are added in later HEAD `659e75a` and await their own run.
- Latest HEAD `659e75a`: account worker/static job passed; disposable-schema-replay is running. The new two independent-session races test both outcomes: claim wins → cancellation waits then refuses; cancellation wins → claim skips the locked request and cannot claim after commit.
- Worker deterministic tests cover lease renewal, stale fencing generation propagation, Auth lookup failure fail-closed, recovery after Auth deletion, and failure-report isolation.

Still open:
1. Latest HEAD's full disposable two-session replay must pass, including both claim/cancel race directions.
2. Measure actual worker phase times and choose final lease TTL; add bounded Auth Admin HTTP timeout/reconciliation review.
3. Run Supabase CLI advisors / final routine ACL and RLS review against the disposable schema.
4. Generate a fresh uniquely-versioned migration via Supabase CLI only after draft acceptance; compare to current test schema/ledger. Do not apply it to hosted DB without separate approval.
5. Complete account-wide Storage sweep / legacy photo classification and final rollout audit.

No hosted DDL/DML, Auth/Storage mutation, Edge Function deployment, Vault secret, or Cron change occurred. PR #200 remains Draft / unmerged.


## Round 38 — 12-scenario two-session acceptance passed (2026-11-03)

Latest implementation code HEAD: `f67befe2cfddb7fb134d09f34dd34fa62b7cb6bd`.

Account deletion worker Run #654 (`41618839849`) passed both jobs:
- account-worker: Deno type-check, 12 deterministic worker tests, character cleanup tests, structural lease/ACL/kill-switch assertions.
- disposable-schema-replay: current-state fixture replay, deletion behavior/rollback, and the expanded independent-session concurrency suite all success.

The concurrency script explicitly reports `Deletion concurrency tests: 12 passed, 0 failed`, including:
1. Exactly one worker claims one due request under concurrent invocation.
2. An older active lease does not starve another due account.
3. Expired lease is reclaimed with new token and generation; old renew/failure calls return false.
4. Old generation cannot invoke fenced prepare or finalize.
5. Active lease prevents cancellation; expired unstarted request remains cancellable.
6. Claim-wins concurrent claim/cancel race: cancellation waits, then refuses.
7. Cancel-wins concurrent claim/cancel race: claim skips the locked request and cannot claim after cancellation commits.
8. Committed deleting batch is recovered after request-row cascade using a new lease; fenced prepare returns the same batch and does not create a duplicate.
9–12. Existing character deletion/new-session, account archive/child-write, asset reattach-first and delete-first path-lock races remain green.

Same code HEAD Chat deletion worker Run #415 and Group UI Run #1138 also succeeded. Chat Storage API retry E2E Run #57 is still in progress and must finish before the complete same-HEAD CI set is called green.

This closes the previously identified missing atomic-claim/fencing test gate at the disposable implementation level. It does NOT authorize hosted deployment: 10-minute TTL remains provisional pending runtime/HTTP timeout measurements; final Auth external-side-effect timeout/reconciliation review, CLI-generated incremental migration, storage sweep/release audit, and explicit deployment/Cron approval remain open. Worker remains source-disabled and PR #200 remains Draft/unmerged.


## Round 40 — wall-clock fencing and bounded Auth Admin HTTP added (2026-11-03)

- Lease expiry checks now use `clock_timestamp()` after acquiring the relevant row locks, rather than `statement_timestamp()`. This prevents a renew/prepare/finalize/failure operation that started before expiry but waited on a row lock until after expiry from being accepted using its stale statement-start timestamp.
- Claim now locks an existing lease with `FOR UPDATE SKIP LOCKED` before attempting first-time insertion, avoiding waiting behind a lease row already locked by another invocation. A first-row insert race remains serialized by the primary key and then rechecked under lock.
- Failure reporting requires the exact `p_batch_id IS NOT DISTINCT FROM lease.batch_id`; if a batch is supplied, it is locked and verified before either failure record is updated.
- Recovery rejects mismatched lease/request identity and a completed lease that still has a deleting batch; it does not silently skip these inconsistent states.
- Added `account-deletion-auth-fetch.ts`: Auth Admin user lookup/delete HTTP requests have a 60-second AbortSignal timeout, while unrelated PostgREST/Storage requests retain the caller's fetch. Worker uses this fetch wrapper; unit tests verify timeout, caller abort composition, and that unrelated paths are not changed.
- Added an independent-session regression where a renew statement starts before expiry, blocks behind a row lock, then wakes after another session has expired the lease. Renew must return false; the lease is then reclaimed with a new token/generation.
- Account worker Run #673 (`41620209355`) on HEAD `401ee12`: account-worker job and disposable-schema-replay job both success. Disposable logs explicitly report `Deletion concurrency tests: 14 passed, 0 failed`, including the lock-wait expiry regression, request-cascade recovery, two directions of claim/cancel races, and effective SQL ACL/RLS checks.
- Chat deletion worker Run #434 (`41620209357`) success; Group UI Run #1157 (`41620209362`) success. Chat Storage API retry E2E Run #76 (`41620209358`) still starting its isolated local Supabase stack at note time; await completion for same-HEAD full CI.

The 10-minute lease remains provisional pending actual phase-duration telemetry; Auth Admin HTTP is now bounded at 60 seconds, below the lease duration. No hosted database/Auth/Storage mutation, worker deployment, Vault secret, or Cron change. PR #200 remains Draft/unmerged.
