# Account deletion worker concurrency audit — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`
Branch: `security/chat-deletion-lifecycle-reconciliation`
Environment inspected: connected Supabase test project, read-only catalog/function-definition queries only.

## Confirmed test grace period

The live test project's `public.account_deletion_settings.grace_period` is `00:05:00`. This is the user-confirmed test-only setting. Production must be independently verified as 30 days before launch; frontend timing must use the backend `scheduled_for` value.

No settings were changed.

## Worker concurrency findings

The current `get_account_deletion_work_items()` function returns due requests and interrupted `deleting` batches, but it does not claim rows, assign a lease, or otherwise ensure only one worker owns a request.

The current archive / prepare routines lock the request row and the matching archive batch with `FOR UPDATE`. This serializes individual RPC transactions, but the worker sequence spans several separate transactions:

1. get work items
2. archive and verify
3. prepare and delete relational data
4. Auth Admin deleteUser
5. finalize

Consequently, two invocations can both receive the same due item before either has created a batch. They may then serialize at archive/prepare while still running independent orchestration. In particular, a second worker can encounter a missing request row after the first worker commits relational cleanup and cascades the request row. The second worker may then call `record_account_deletion_failure()` against a batch that the first worker is actively finalizing.

The failure recorder currently updates `last_error`, `updated_at`, and `attempt_count` for batches in `archived`, `deleting`, or `failed`; it does not change the status. This is not proof of data loss, but it can produce misleading failure metadata during a successful concurrent run and makes operational state harder to interpret.

The current `deleting` recovery branch is correct for a worker that fetches an already-deleting batch after the Auth user has disappeared. It does not solve the race where a second worker fetched the original `due` item before the first worker created the batch.

## Required next implementation / test gates

Before enabling any schedule:

- Design an atomic claim/lease mechanism for each exact deletion request (user_id + requested_at + scheduled_for), with bounded lease expiry and safe reclaim after worker crash.
- Ensure a worker can only record failure for a batch/request it still owns; stale workers must not overwrite active progress or clear another worker's lease.
- Preserve current idempotent archive and finalize behavior.
- Test two workers claiming the same due request concurrently: exactly one obtains the lease; the other skips without recording a false failure.
- Test lease expiry after crash at each phase: before archive, after archive, after prepare, after Auth deletion, and before finalize.
- Test the Auth-deleted / finalize-pending recovery path and repeated delivery.
- Test that an unexpired lease prevents duplicate Auth Admin deletion attempts.
- Run these tests only on a disposable local Supabase stack with synthetic Auth users.

## Safety

- This was a read-only audit: only SELECT/catalog/function-definition inspection was performed.
- No account-deletion RPC was invoked.
- No Auth user was created or deleted.
- No hosted schema/data/settings were modified.
- No Edge Function was deployed and no cron schedule was created.
- PR #200 remains Draft/unmerged.


## Round 29 - deleting-batch recovery defect found and corrected (2026-11-02)

### Live SQL control-flow confirmation (read-only)

- get_account_deletion_work_items() returns a second class of work items: batches in deleting state for which the exact account_deletion_requests row no longer exists.
- prepare_account_deletion() marks the batch deleting and performs relational cleanup in the same PostgreSQL transaction. Once that transaction commits, the worker must not restart archive/prepare as though it still has a due request row.
- archive_account_deletion_data() explicitly requires an existing due account_deletion_requests row and raises when it is absent.
- finalize_account_deletion() independently locks the batch, requires deleting status, and verifies the Auth user is absent before marking completed.

### Defect in the previous Edge Worker

For a work item with work_status=deleting and a batch_id, the worker checked whether the Auth user was absent. If the user still existed, it fell through to archive_account_deletion_data(), which cannot succeed for the request-row-missing recovery result. This stranded the exact crash-recovery case where prepare had committed but Auth deletion had not yet happened.

### Correction committed to PR branch

- When work_status=deleting and batch_id is present, the worker now treats relational preparation as already committed.
- If Auth user is absent, it finalizes directly.
- If Auth user still exists, it calls Auth Admin deleteUser directly; if that returns an error, it independently checks Auth absence and fails closed unless absence is confirmed.
- It then calls finalize, which independently verifies Auth absence and deleting batch state.
- It no longer re-enters archive/prepare for a deleting batch.
- Updated regression test asserts exact call order: Auth lookup -> Auth delete -> finalize, with no archive/prepare calls.

Commits: 60e339fed954533b6ea95fd8652504576682c99b (worker), 380ab0567c700feac602c815a053324ca0708f32 (test).

### Verification status and boundaries

- Previous CI run 41365781489 passed Deno type-check and 7 tests, but it predates this correction.
- No workflow run is yet associated with the new test commit at the time of this note; the correction is NOT yet CI-verified.
- No hosted function invoked, no account deletion RPC invoked, no Auth user created/deleted, no hosted DDL/DML, no deployment, and no cron change.
- The separate atomic lease/fencing design remains unimplemented; concurrency safety is still an outstanding gate.


## Round 30 - isolate failure-reporting errors (2026-11-02)

- Further reviewed the worker's per-item catch path. A rejected `markFailure()` promise previously escaped the catch block and could abort processing the remaining work items in the same invocation.
- Wrapped failure telemetry recording in a narrow try/catch so a transient reporting RPC failure does not terminate the batch loop. The original processing failure remains counted; the worker proceeds to later items. This does not claim that the failure was durably recorded.
- Added a regression test with two items where archive fails and failure reporting throws; asserts both items are attempted and both count as failed.
- Commits: worker `74e43af63a6fe762aeb9d17886b5f128bded19a6`; test `cc1ecbcac6d6658161baf869ca1c6fb2c28c7f9b`.
- No workflow run is currently associated with the latest test commit; not CI-verified yet. No hosted RPC/DDL/DML, Auth user creation/deletion, deployment, or cron change.
- Important: swallowing failure-reporting errors prevents batch starvation but makes observability/alerting essential. The handler should emit structured logs/metrics for failed markFailure calls; this is a follow-up check before considering production readiness.


## Round 31 - make failure-reporting failures observable (2026-11-02)

- Follow-up review found the Round 30 guard was incomplete: `markFailure()` returns an RPC result object, so a resolved `{ error }` did not throw and was silently ignored.
- Worker summary now includes `failureReportFailed`. Both thrown errors and resolved RPC errors / non-true results increment it, while the item remains failed and later items continue.
- Edge Function emits a structured, redacted `console.error` event when failure reporting is incomplete (counts only; no user IDs, batch IDs, or raw provider errors). HTTP success now requires both zero processing failures and zero failure-reporting failures; otherwise returns 207.
- Added regression coverage for resolved RPC error. Existing thrown-error/two-item regression remains.
- Commits: worker `48a07804c85ec4852c2282aa7068ecd60eb10999`; handler `d4686645b7c1a4122bce7abbea46072183931a4c`; test `1b2af4648407d58eafe597fb436282fbea808364`.
- CI runs for worker and handler commits were observed in progress at audit time; test commit was just pushed and requires its own run/result. Do not call this verified until all latest runs complete successfully.
- No hosted RPC/DDL/DML, Auth user creation/deletion, deployment, or cron change. PR #200 remains Draft/unmerged. Atomic lease/fencing remains a separate blocking item.
