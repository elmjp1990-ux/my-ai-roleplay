# Controlled Recovery Design for Expired Account-Deletion Requests

Status: design proposal only. Not a migration. No Supabase changes have been applied.

## Current project phase
Phase 1 — repair design and read-only verification. The production frontend patch is deployed, but backend recovery and deletion processing are not repaired. Do not ask the user to repeat the five-minute test yet.

## Verified live constraints
- `account_deletion_requests` currently has only `user_id`, `requested_at`, and `scheduled_for`; the default deadline is five minutes.
- `cancel_account_deletion()` only deletes a request whose deadline is still in the future.
- `request_account_deletion()` does nothing on conflict, so an expired row is not replaced or rescheduled.
- `account_is_active()` treats any extant request row as inactive.
- Existing archive function archives only `ai_generation_records` and `wallet_transactions`; it retains source rows and does not delete the Auth user.
- One archive batch is currently `archived` with `completed_at IS NULL`. This is not evidence that account deletion completed.
- No active `pg_cron` job was found. The archive function is not executable by `service_role` in the current grant check; do not solve this by granting broad execution to clients or a general-purpose role.
- The live `account_must_be_active` policies on `characters`, `character_stories`, and `conversations` are RESTRICTIVE for `authenticated`. An earlier draft incorrectly called them permissive; the draft has been replaced by read-only diagnostics. No RLS changes are recommended based on that earlier assumption alone.

## Proposed recovery behavior (not implemented)
1. The caller must be authenticated. The function derives the target exclusively from `auth.uid()`; it must not accept an arbitrary user ID.
2. If no deletion request exists, return an idempotent “no pending request” result without changing unrelated data.
3. If a request is not expired, use the normal cancellation path rather than the expired-recovery path.
4. For an expired request, reject recovery if any processing batch indicates a destructive phase has begun or the account is completed. Until lifecycle states are implemented, the current `archived` status alone must not be interpreted as completed deletion.
5. Before restoring access when a batch is `archived`, verify that the original source rows still exist and that the archived payload is readable and reconciles. If the check is inconclusive, stop and require manual review; do not delete archive/source rows.
6. Record an append-only recovery event with request timestamps, actor, event time, result, and reason before removing or transitioning the blocking request. Restrict direct access to the event table; users must not be able to forge events or read other users' audit data.
7. Restore normal access only after the event is persisted and all preconditions pass. Perform the event write and request-state transition atomically in one database transaction.
8. Keep a recovery event even if a request row must be removed to restore access. Do not silently reset the deadline or overwrite the prior request history.
9. Return a stable, non-sensitive status to the frontend; write detailed errors only to a restricted audit/operations log.
10. Make repeated recovery calls safe and deterministic. Use row-level locking to avoid races with a worker.

## Required schema/lifecycle design before SQL
- Add a durable request lifecycle model or separate append-only events; the current request table cannot represent pending, expired, archiving, archived, deleting, completed, failed, cancelled, and recovered distinctly.
- Define legal state transitions and a unique/idempotency key for each processing attempt.
- Decide how to represent existing legacy requests and archived batches without fabricating a completion timestamp.
- Never mark a batch completed merely to bypass the current retry guard.
- Keep archive verification distinct from account deletion completion.
- Do not enable a scheduled worker until its lock/claim behavior, retry limit, least-privilege execution, dry-run mode, and stop switch are reviewed.

## Data retention decisions still required before destructive deletion
- Creator-owned characters and stories: delete, transfer, anonymize, or retain.
- Conversations, messages, chat sessions, and message versions: delete or retain/anonymize, with access and retention period.
- AI-generation records: archive, delete, or anonymize while respecting their NO ACTION foreign keys.
- Wallet transactions and archived payloads: required retention, privileged access, and secure expiry.
- Confirm whether archive payloads can contain personal content and who may access them.
- Complete FK inventory and deletion-order plan. Do not globally convert foreign keys to CASCADE.

## Test gates (disposable test environment only)
- Valid pending request cancellation succeeds before deadline and leaves audit history.
- Expired recovery works only when no destructive processing began and archive/source reconciliation passes.
- Expired recovery refuses ambiguous or destructive states without modifying data.
- Repeated/concurrent recovery requests do not create duplicate events or race a worker.
- Access returns only after the request state is safely transitioned.
- Five-minute timing is configured only in a disposable test project; production remains aligned with the promised 30-day recovery window.
- Dry-run processor changes zero rows and calls no Auth Admin deletion API.
- No real account is deleted during recovery tests.

## Approval boundary
This document is design only. Before any production SQL, schedule, worker, or data modification, show the exact change and obtain explicit approval. Do not perform actual account deletion as part of recovery repair.
