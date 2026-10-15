# Account Deletion Implementation Design (Proposal Only)

This is a design document for the repair branch, not a deployed implementation. Do not apply SQL from this document to production.

## Product timing contract
- Production UI currently promises a 30-day recovery window. Production request creation must schedule the deadline at 30 days from the server timestamp.
- Five-minute timing is strictly for a disposable test environment. Do not shorten the production database default to test the workflow.
- Existing request rows must not have their deadline silently extended by repeated clicks.

## Request lifecycle
1. `request_account_deletion()`:
   - Requires `auth.uid()`.
   - If no request exists, insert one with a server-calculated production deadline (30 days).
   - If a request exists and its deadline is in the future, return the existing timestamps unchanged.
   - If a request is expired, do not silently reset it; return a clear error instructing the user to use the controlled recovery path.
2. `cancel_account_deletion()`:
   - Requires `auth.uid()`.
   - Only cancels a request before the configured deadline.
   - Must not erase audit/archive records.
3. Controlled recovery:
   - A separate authenticated recovery RPC can be considered for an expired request only when no destructive deletion has started.
   - It must reject requests with a batch in `deleting` or `completed` state.
   - If a prior batch is only `archived`, remember that the current archive function retains source rows, but verify source/archive integrity before restoring access.
   - Recovery should record who/when/why, or use an auditable append-only event table. Do not implement by blindly deleting rows in the dashboard.
4. Status RPC:
   - Return explicit lifecycle state, deadline, and whether cancellation/recovery is allowed. Avoid representing every extant request as the same generic pending state.
5. Account gating:
   - Keep server-side RLS/RPC enforcement. The client-side UI lock is only supplemental.

## Archival and deletion worker
- The current archive function is not a deletion worker. It archives only `ai_generation_records` and `wallet_transactions`, leaves source data in place, and does not remove the Auth user.
- Make archive idempotency and batch semantics explicit. `archived` must mean “archive verified,” not “account deletion completed.”
- Use a separate deletion phase after all required data classes are accounted for and retention rules approved.
- Worker should claim one due request atomically, avoid duplicate concurrent processing, increment attempts, persist safe error details, and stop for manual review after a bounded number of failures.
- Worker must use least-privilege service credentials, never accept an arbitrary target user ID from an untrusted client, and initially support dry-run only.
- Do not enable a cron/schedule until all dry-run acceptance tests pass.

## Data policy decisions required before enabling deletion
- Creator-owned characters and stories: delete, transfer, anonymize, or retain?
- Chats and message versions: delete or retain/anonymize? If retained, what access controls and retention period apply?
- AI generation records: archive, delete, or anonymize? They currently reference profiles, chat sessions, and chat messages with restrictive foreign keys.
- Wallet transactions: define retention/audit requirements and whether archived copies are accessible only to privileged operators.
- Archive payload retention: define `retention_until`, access policy, and secure expiry/deletion.
- Any cascade should be intentional and covered by tests; do not globally change foreign keys to CASCADE to make deletion “work.”

## Required test matrix (disposable test environment only)
- No existing request -> request creates a fresh deadline from server time.
- Repeated request before deadline -> same deadline returned, not extended.
- Cancel before deadline -> request removed and normal access restored.
- Cancel after deadline -> rejected without data changes.
- Expired legacy request -> normal request fails safely; controlled recovery works only if no destructive phase began.
- Account with archived batch -> archive/source counts and payloads reconcile before recovery or retry.
- Pending deletion account -> owner write attempts are denied by RLS, including direct Data API calls.
- Public approved character/story reads remain available according to product policy.
- Worker dry-run -> lists exact planned operations and performs zero writes/deletions.
- Concurrent worker attempts -> only one processor claims a request.
- FK validation -> no orphan records; intended retained data remains accessible only under policy.
- Failure/retry -> attempt count and last error recorded; no duplicate or partial destructive effects.
- Production deadline remains 30 days while test project uses five minutes.

## Release gate
Do not call this feature repaired until:
- the RLS bypass is corrected and tested,
- the production/test timing mismatch is resolved,
- recovery semantics are implemented and tested,
- complete data-retention and FK plans are approved,
- dry-run worker and retry behavior pass,
- a disposable-account end-to-end test passes,
- production changes are reviewed and explicitly approved.
