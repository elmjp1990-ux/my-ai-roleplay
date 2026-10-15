# PersonaX Account Deletion Repair Plan

Status: investigation/design only. This document is not an executable migration.

## Safety boundary
- Do not delete the existing account-deletion request or archive rows as part of diagnosis.
- Do not call Supabase Auth Admin deletion or delete user-owned source rows until the complete retention and foreign-key plan is reviewed and explicitly approved.
- Do not deploy an automatic deletion worker until its dry-run path and retry behavior are validated.
- All initial database checks must be read-only.

## Confirmed defects
1. `request_account_deletion()` inserts with `ON CONFLICT (user_id) DO NOTHING`. An existing expired request therefore prevents a fresh five-minute schedule from being created.
2. `cancel_account_deletion()` only removes a request when `scheduled_for > statement_timestamp()`; an expired request cannot be cancelled through the normal RPC.
3. `archive_account_deletion_data(uuid)` archives only `ai_generation_records` and `wallet_transactions`; it does not delete source rows or the Auth user.
4. The archive function marks a batch `archived`, but does not set `completed_at`. Its guard treats `archived` as unfinished, so a subsequent run is blocked.
5. No active `pg_cron` job or deployed Edge Function responsible for processing account-deletion requests was found during the read-only audit.
6. The archive tables allow only `ai_generation_records` and `wallet_transactions`; additional data categories and retention requirements have not yet been reconciled.

## Foreign-key risks requiring a complete inventory
- `ai_generation_records.user_id -> profiles.id` has no `ON DELETE CASCADE` and is NOT NULL.
- `chat_message_versions.edited_by -> profiles.id` has no `ON DELETE` action; the column is nullable, so anonymization may be an option after product/legal review.
- `characters.author_id -> profiles.id`, `conversations.user_id -> profiles.id`, wallet rows and several auth/session relations cascade. Cascading deletion may remove user content and transaction history, so the exact intended retention behavior must be decided before deleting the Auth user.
- This list is not a substitute for a complete FK/table inventory.

## Intended repair sequence
1. Finish a read-only inventory of user-linked tables, foreign keys, triggers, RLS policies, RPC privileges, and data retention expectations.
2. Define request states and transitions explicitly: pending/cancellable, due, archiving, archived, deleting, completed, failed, cancelled. Keep archive completion distinct from account deletion completion.
3. Make request creation idempotent only for a still-valid pending request. Expired/failed requests must use an explicit, audited recovery path; never silently reset an expired request.
4. Make archival retry-safe and verifiable. A retry must not compare current source counts to a previous batch accidentally, and must record attempt/error/completion timestamps.
5. Implement a least-privilege backend worker (for example, a scheduled Edge Function) that claims due work safely, supports dry-run, and cannot be invoked by anon/authenticated clients to delete arbitrary users.
6. Add an explicit retention/deletion policy for every user-linked data category. Handle FK blockers intentionally; do not blanket-change FK rules to CASCADE.
7. Test on a disposable test account: request -> five-minute due time -> dry-run -> archive verification -> cancellation boundary -> retry/failure recovery. Only after approval should a real Auth deletion path be enabled.
8. Add monitoring and a manual stop/rollback procedure before production activation.

## Acceptance criteria before asking for the five-minute test
- A new request gets a fresh `scheduled_for` exactly five minutes from the server timestamp.
- Repeated submissions do not extend a valid request's deadline.
- Expired old requests can be recovered only through a controlled, audited path.
- Cancellation succeeds before the deadline and fails after it, without modifying unrelated accounts.
- Dry-run lists the exact actions without changing source or auth data.
- Archive counts and payloads reconcile for all in-scope tables; retries do not create inconsistent batches.
- No account is actually deleted during these checks.
- A real deletion test is separately approved and uses a disposable account.
