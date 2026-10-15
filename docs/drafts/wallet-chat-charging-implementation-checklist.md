# PersonaX wallet and chat charging — implementation checklist

Status: partial source implementation on the feature branch only. No production database, balances, main branch, or deployment changed.

## Priority order

### P0 — Correctness and wallet safety (do first)
- [ ] Add a server-enforced charge ledger keyed by a stable UUID for each logical turn.
- [ ] Implement atomic reservation for cost 2, silver first and diamonds for the remainder.
- [ ] Enforce wallet row locking and non-negative balances for concurrent turns.
- [ ] Make repeated reserve/settle/refund calls idempotent.
- [ ] Persist charge transitions and wallet transaction entries atomically.
- [ ] Prevent clients from directly changing charge states, refunding themselves, or writing trusted audit events.
- [ ] Reject unauthenticated users, accounts with pending deletion, invalid/soft-deleted sessions, and sessions owned by another user.
- [ ] Define first-message/session creation order so local-only or arbitrary session IDs cannot be charged.
- [ ] Ensure insufficient balance never calls generation and makes no debit; record a sanitized attempt event.
- [ ] Confirm a reply is non-empty and durably stored before settlement.
- [ ] Confirm failure before a usable reply refunds the exact original silver/diamond split once.
- [ ] Treat ambiguous provider/network timeouts as reconciliation work, not immediate refunds or automatic duplicate generation.
- [ ] Add a scheduled server-side reconciliation job for stale reservations if the browser closes or acknowledgement is lost; the current Edge Function can reconcile retries for the deterministic demo reply, but not yet stale turns without a retry.

### P1 — Persistent operational audit (part of wallet safety)
- [ ] Add append-only `chat_turn_events` events for received, reserved, generation started, provider error/timeout, empty response, persistence failure, settlement, refund, and reconciliation.
- [ ] Store event IDs, turn/user/session IDs, stage, stable sanitized error code, attempt count, retryable flag, duration, timestamps, and safe provider request IDs where available.
- [ ] Do not log API keys, authorization/signature headers, raw stack traces, full prompts, or generated content.
- [ ] Set RLS and server-only write permissions; decide retention before public launch.
- [ ] Ensure every failed send reaches a terminal failure/refund outcome or explicit `needs_reconciliation` state.

### P2 — Functional integration and verification
- [x] Route the current fixed demo response through the same charge lifecycle; do not wait for real AI integration.
- [x] Stop treating a chat turn as complete when `saveChatSessionSafely` fails: the feature-branch handler rolls back the local reply and newly added memories.
- [x] Wire the browser handler to the server-side fixed-demo `chat-turn` Edge Function using stable turn/message IDs.
- [ ] Keep edit-without-regeneration free; a new generation is a new billable turn.
- [ ] Verify the authoritative wallet balance after success/refund.
- [ ] Test silver-only, diamond-only, mixed payment, insufficient balance, double-click, concurrent turns, retries, refresh/relogin, provider failure, empty response, persistence failure, stale reservation, and lost acknowledgement.
- [ ] Verify a refunded turn can never later deliver a reply as a successful paid turn and a settled turn cannot be refunded through the ordinary failure path.

### P3 — Low-priority presentation polish
- [ ] Add send-button spinner and character typing dots/text.
- [ ] Add 45-second wait message and 90-second status-check presentation.
- [ ] Support dark/light themes and reduced-motion preferences.
- [ ] Treat animation as display only; server turn state remains authoritative.

## Suggested state model

- `created`: request recorded; not yet charged.
- `reserved`: 2 units held/deducted provisionally; processing may proceed.
- `settled`: durable assistant response exists; charge is final.
- `refunded`: confirmed failed turn; original split restored exactly once.
- `needs_reconciliation`: outcome ambiguous; no new generation or blind refund until server-side reconciliation resolves it.

Keep charge state as the money source of truth. The append-only event log explains the processing history but must never override the charge ledger.

## Release gates

Do not merge or deploy until:
1. Database constraints and RPC transitions are reviewed for transactionality, RLS, grants, and idempotency.
2. Server-side orchestration owns generation outcome, persistence, settlement, and refunds.
3. Automated or repeatable tests prove no double charge, no duplicate refund, no overdraw, and no successful reply after refund.
4. Test mode is clearly scoped and cannot accidentally grant free production replies.
5. A safe rollback plan exists; no destructive cleanup is part of this feature.

## Current boundary

This checklist is committed only to `feat/ayet-rewarded-video-callback`. The chat persistence rollback fix, draft wallet RPC SQL, demo Edge Function source, and frontend invocation path now exist on the branch. The SQL has not been applied and the function is not deployed. The source review corrected an assistant-message ID collision risk by replacing upsert with insert plus exact-content recovery checks. SQL/function semantics still need repeatable tests before deployment. P3 UI polish remains explicitly lower priority.
