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
