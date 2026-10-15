# Chat-turn billing implementation draft

Status: design-only. No Supabase schema, production balances, or deployed code have been changed.

## Test-mode decision

The project owner confirmed that the current environment has no real users and fixed demonstration replies can be treated as billable responses. Real AI-provider integration is not required to test wallet charging.

## Confirmed schema and code facts

- `wallet_accounts` has one row per user, non-negative `silver_coins` and `diamonds`, and a primary key on `user_id`.
- `wallet_transactions` records `user_id`, `currency_type`, signed integer `amount`, `biz_type`, and optional `reference_id`. It has no observed unique idempotency key, so duplicate protection must be database-enforced in the new charge ledger.
- `chat_sessions` has `id`, `user_id`, and `deleted_at`; `chat_messages` belongs to a session.
- The current message handler adds a fixed demonstration reply, calls local `persist()`, then awaits `saveChatSessionSafely(s)` but ignores its boolean result. This is a confirmed integration defect: cloud persistence can fail while the UI still appears to have a completed reply.
- `saveChatSessionToCloud` creates the cloud session and upserts messages together, but returns false for a chat without a non-empty user message. This matters for first-send flow: the current reserve RPC cannot require an existing cloud session unless the first-send session creation sequence is designed explicitly.
- The current handler does not call an AI provider. The browser must not directly update wallet balances.
- The latest-user-message edit path saves the edit and does not regenerate; it must remain outside the billing flow.

## Billing invariants (must always hold)

1. A successful new user turn costs exactly 2 total units; silver is spent first, diamonds cover the remainder.
2. The database, not the browser, decides the split and atomically deducts it.
3. A given logical turn can reserve at most once, even across double-clicks, retries, tabs, or page refresh.
4. A turn can reach only one terminal state: `settled` or `refunded`. A settled charge cannot be refunded by the ordinary failure path; a refunded turn cannot later settle or deliver a billable reply.
5. Insufficient balance makes no balance/ledger changes and must not trigger generation.
6. Editing a message without regenerating is free. A new generation from an edited message is a new billable turn with a new turn ID.
7. Wallet balance, charge row, and wallet ledger entries must commit in the same database transaction for each reserve/settle/refund operation.
8. Only trusted server-side orchestration may decide whether to settle or refund. Do not expose an authenticated-user-callable refund RPC that lets the user refund their own pending reservation.
9. The user must see a clear pending/failure state. Do not display a reply as completed until its durable save and charge settlement are confirmed.

## Proposed database ledger

Create a dedicated `chat_turn_charges` table, separate from the wallet transaction history, with:

- `turn_id` UUID primary key, generated once per logical send and reused on retries.
- `user_id`, `session_id`, stable `user_message_id`, optional `assistant_message_id`.
- Fixed `cost = 2`, `silver_amount`, `diamonds_amount`.
- Statuses: `reserved`, `settled`, `refunded`, and `needs_reconciliation` for ambiguous/interrupted work.
- Created/updated timestamps, and a short failure/reconciliation code that contains no secrets.
- RLS enabled; no direct browser insert/update/delete permissions. Any status transition must be enforced by narrow database functions and/or trusted server code.

Add database uniqueness for the logical turn ID and unique wallet-ledger references per turn and currency/transaction kind, so accidental duplicate ledger writes are rejected by the database rather than relying on JavaScript.

## Trusted processing architecture

For real AI integration, a server-side Edge Function should own the complete lifecycle: authenticate the caller, validate ownership/account status, reserve, invoke the AI provider, persist the result, then settle or refund. The browser must not be trusted to report “AI succeeded” or choose a refund amount.

For the current fixed demo reply test, use the same lifecycle semantics. If implementation temporarily coordinates some steps in the browser, treat it as a limited test harness only—not a production-safe design—and keep refunds unavailable to direct authenticated client calls.

## First-send and session-creation ordering

The existing application creates a cloud session only after the first user message, while charging requires a valid session ID. Resolve this explicitly rather than silently changing the existing behavior:

- Preferred: a trusted server/database operation validates the character and atomically creates/claims the initial cloud session plus reserves the turn, using the supplied stable session/message/turn IDs and server-validated character snapshot.
- Alternative: persist the user message/session first, then reserve. If balance is insufficient, keep the message visibly marked as not sent/not generated and allow retry after obtaining currency; never show it as a completed assistant turn.
- Do not reserve against a local-only or arbitrary session ID, and do not create duplicate cloud sessions on retry.

## RPC / lifecycle behavior

### Reserve

1. Verify authenticated caller and account is active; pending account deletion must be rejected server-side.
2. Verify the session belongs to the caller, is not soft-deleted, and is valid for new messages. Validate character/session rules server-side.
3. Lock the wallet row, then enforce idempotency by `turn_id`. Reusing an ID for a different user/session/message is a hard conflict.
4. If the same turn is already reserved, return its current state without another deduction. If settled/refunded, return that terminal state; never silently start a second generation under that ID.
5. If total balance is less than 2, return `insufficient_balance` with no writes.
6. Deduct exactly 2 atomically, silver first:
   - 2 silver -> 2 silver
   - 1 silver + 1 diamond -> 1 of each
   - 2 diamonds -> 2 diamonds
7. Insert the charge and matching wallet-ledger rows in the same transaction.

### Generate and persist

1. A server-side worker/function checks the turn state before generation.
2. The same `turn_id` must not initiate a second provider generation after a result is already stored. Reuse provider idempotency support if available; otherwise persist an explicit in-progress state and reconcile ambiguous timeouts before retrying.
3. Treat provider errors, invalid/empty responses, and failed durable message persistence as failures.
4. Persist the assistant message with a stable ID and associate it with the charge. Do not rely on localStorage as proof of a successful paid reply.

### Settle

1. Settle only if the same turn is still `reserved`, the assistant response is non-empty, and durable cloud persistence is confirmed.
2. Transition atomically from `reserved` to `settled`; repeated settle is idempotent.
3. A successful provider response alone is not enough if the user cannot retrieve the response. Likewise, a client-side “success” flag is not proof.

### Refund and ambiguous outcomes

1. Refund the exact stored silver/diamond split only for a confirmed failure before a usable reply is committed.
2. Lock the charge row and allow only `reserved -> refunded`; repeated refunds do not credit twice. A settled charge cannot be refunded by this path.
3. Do not immediately refund on a network timeout when the provider may have generated a reply. Mark `needs_reconciliation`, query the provider/job/result if possible, and then settle or refund based on authoritative outcome.
4. If the browser closes or loses connectivity, a server-side reconciliation process must finish or refund stale reservations. Never depend on the browser remaining open.
5. If the assistant message was saved but settlement acknowledgement was lost, query the existing charge/message and settle idempotently; do not generate again or refund blindly.

## Frontend behavior

1. Disable the send control while a request is in flight, but rely on server idempotency—not the disabled button—for correctness.
2. Reuse the same `turn_id` for retry/recovery of the same logical send. A genuinely new user send gets a new ID.
3. On `insufficient_balance`, do not generate; refresh wallet balance and show the rewarded-video guidance modal. Do not open this modal for unrelated network/database errors.
4. Show “processing” while the result is unresolved. Do not append a second assistant reply or permit another generation for the same turn.
5. On confirmed failure/refund, preserve the user message as unsent/failed and provide a retry action that follows the idempotency rules.
6. On success, render the saved assistant response and refreshed authoritative wallet balance.
7. Do not clear the composer or claim success before the server has durably saved the turn; local optimistic UI must be reversible.

## Required tests before merge

- Silver-only, diamond-only, and mixed payment.
- Combined balance below 2 leaves balances and ledger unchanged and makes no generation call.
- Double-click, concurrent requests, refresh/relogin, and same-ID retries do not double-charge or duplicate a reply.
- Same `turn_id` reused for different session/user/message is rejected.
- Concurrent distinct turns cannot overdraw the wallet.
- Session ownership, soft deletion, character status, and account-deletion-pending are enforced server-side.
- First message/session creation followed by insufficient balance has a clear, recoverable state.
- Provider error, empty response, persistence failure, and server crash refund at most once.
- Timeout with unknown provider result enters reconciliation instead of blindly retrying/refunding.
- Saved response with lost settlement acknowledgement recovers without another generation or charge.
- Settled turns cannot be refunded; refunded turns cannot later settle/deliver as successful.
- Editing without regeneration does not charge.
- Refresh/relogin shows balances and turn status consistent with the database ledger.

## Safety boundary

This is a design document committed to `feat/ayet-rewarded-video-callback` only. It has not been applied to Supabase, merged to main, or deployed. No production data or schema has been changed. The next implementation step is to draft the idempotent ledger/RPC contract and frontend/server orchestration against the current schema, then review it before any database migration or deployment.
