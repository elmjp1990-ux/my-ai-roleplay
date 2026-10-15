# Chat-turn billing implementation design and acceptance criteria

Status: the reviewed wallet SQL migration and fixed-demo `chat-turn` Edge Function v1 are deployed to production Supabase. The frontend remains on the feature branch and is not merged/deployed to the production website. No end-to-end billing acceptance tests have passed. The stale-turn reconciliation and assistant-reply UPDATE guard are source-only SQL drafts and have not been applied.

## Test-mode decision

The project owner confirmed that the current environment has no real users and fixed demonstration replies can be treated as billable responses. Real AI-provider integration is not required to test wallet charging.

## Confirmed schema and code facts

- `wallet_accounts` has one row per user, non-negative `silver_coins` and `diamonds`, and a primary key on `user_id`.
- `wallet_transactions` records `user_id`, `currency_type`, signed integer `amount`, `biz_type`, and optional `reference_id`. It has no observed unique idempotency key, so duplicate protection must be database-enforced in the new charge ledger.
- `chat_sessions` has `id`, `user_id`, and `deleted_at`; `chat_messages` belongs to a session.
- The current message handler adds a fixed demonstration reply, calls local `persist()`, then awaits `saveChatSessionSafely(s)` but ignores its boolean result. This is a confirmed integration defect: cloud persistence can fail while the UI still appears to have a completed reply.
- `saveChatSessionToCloud` creates the cloud session and upserts messages together, but returns false for a chat without a non-empty user message. This matters for first-send flow: the current reserve RPC cannot require an existing cloud session unless the first-send session creation sequence is designed explicitly.
- The deployed `chat-turn` handler returns a fixed demonstration reply and does not call an AI provider. The browser must not directly update wallet balances.
- Production RLS includes `chat_messages_update_own`; the billing trigger currently protects assistant INSERT but not later UPDATE. A source-only guard draft now prevents changes to a charged assistant reply's ID, session, role, or content while allowing unrelated updates such as soft-delete metadata. Review and test before applying.
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

## Persistent failure and attempt audit (new requirement)

The owner requested that failed sends also be recorded in the database. Implement this as a server-owned append-only `chat_turn_events` audit log linked to `turn_id` and the charge row, rather than relying on browser console logs or overwriting one last-error field.

Recommended event fields:

- Event UUID, `turn_id`, `user_id`, `session_id`, event type, stage, occurred-at timestamp.
- Sanitized stable error code/category, retryable flag, attempt number, duration in milliseconds, and provider request/job ID when safe and available.
- Examples: `request_received`, `reserved`, `generation_started`, `provider_timeout`, `provider_error`, `empty_response`, `message_persist_failed`, `settled`, `refund_started`, `refunded`, `needs_reconciliation`, `reconciled`.
- Do not store API keys, authorization headers, HMAC/signature values, raw stack traces, full prompts, or full generated content in this operational log. Chat content remains in the existing message/version records; logs should reference stable IDs.
- Log confirmed insufficient-balance attempts too, but do not create a charge or wallet ledger debit for them. Rate-limit or aggregate unauthenticated noise to prevent log flooding.
- Enable RLS; clients may only read their own sanitized history if a user-facing history is needed. All event inserts must be server-side only. Restrict service-role access and retention; define a retention period before public launch.
- A failed request must have an explicit final outcome or `needs_reconciliation`; failures must not be recorded only in localStorage. The charge row remains the source of truth for money state, while events explain how it reached that state.

## Frontend interaction: typing / generating state (new requirement)

The owner requested a roleplay-style typing indicator while waiting for a reply. Add this as a separate, reusable chat UI component, but keep its state driven by the same server turn state machine so the animation cannot claim success on its own.

- Immediately after the send is accepted and reservation begins, disable the send button and show a spinner on the paper-plane button.
- In the message area show a subtle typing indicator, such as three animated dots and muted italic text like `角色正在輸入…`; use the character's display name when available.
- Respect both dark and light themes; use muted theme variables and accessible status text (e.g. `role=status`, `aria-live=polite`). Honor reduced-motion preferences; provide a non-animated fallback.
- At 45 seconds, change the text to a calm waiting message (e.g. `回覆需要一點時間，請稍候…`) without launching another request.
- At 90 seconds, show a delayed state and query the authoritative turn status. Do not automatically refund, regenerate, or enable a second generation merely because the browser timer elapsed.
- On confirmed success, replace the typing indicator with the persisted assistant message only after settlement is confirmed.
- On confirmed failure/refund, remove the typing indicator, preserve the user's text as failed/not delivered, show a concise error and a retry action that reuses the same logical turn only if the server says retry/recovery is safe.
- If outcome is unknown, keep a recoverable pending state and let server reconciliation resolve it. On refresh/relogin, reconstruct the indicator from server state rather than from a client-only timer.
- Animation is decorative only: it must not determine charge, refund, or AI success.

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
5. Record each meaningful stage transition and sanitized failure in `chat_turn_events`, including failures that happen before a charge is reserved.

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
- Provider error, empty response, persistence failure, and server crash refund at most once and write an audit event.
- Timeout with unknown provider result enters reconciliation instead of blindly retrying/refunding.
- Saved response with lost settlement acknowledgement recovers without another generation or charge.
- Settled turns cannot be refunded; refunded turns cannot later settle/deliver as successful.
- Editing without regeneration does not charge.
- Typing indicator reflects server state, handles 45/90-second thresholds, and respects reduced-motion preference.
- Refresh/relogin shows balances and turn status consistent with the database ledger and failure log.

## Safety boundary

The design and acceptance criteria live on `feat/ayet-rewarded-video-callback`. The wallet migration and fixed-demo Edge Function v1 are already applied/deployed; the frontend is not merged/deployed. No end-to-end tests have passed. The stale-turn reconciliation and assistant UPDATE guard are drafts only. Next steps: review the two SQL drafts, add repeatable isolated tests for the state machine and concurrent races, then request explicit approval before any further production DB changes, frontend merge, or deployment.
