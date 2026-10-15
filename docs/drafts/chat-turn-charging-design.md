# Chat-turn billing implementation draft

Status: design-only. No Supabase schema or production balances have been changed.

## Test-mode decision

The project owner confirmed that the current environment has no real users and fixed demonstration replies can be treated as billable responses. Real AI-provider integration is not required to test wallet charging.

## Confirmed schema facts

- `wallet_accounts` has one row per user, non-negative `silver_coins` and `diamonds`, and a primary key on `user_id`.
- `wallet_transactions` records `user_id`, `currency_type`, signed integer `amount`, `biz_type`, and optional `reference_id`. It currently has only its primary key, so duplicate transaction protection must be provided by a separate charge ledger or database-enforced key.
- `chat_sessions` has `id`, `user_id`, and `deleted_at`; `chat_messages` belongs to a session.
- The current message handler creates a user message and a fixed assistant demonstration reply, then persists the chat. It does not call an AI provider.
- The current account initializer uses `ensure_wallet_account()`; the browser must not directly update wallet balances.

## Proposed database ledger

Create a dedicated `chat_turn_charges` table, separate from the wallet transaction history, with:

- `turn_id` UUID primary key — created once per user send attempt and reused on retry.
- `user_id`, `session_id`, optional `user_message_id`, optional `assistant_message_id`.
- Fixed `cost = 2`, `silver_amount`, `diamonds_amount`.
- `status` limited to `reserved`, `settled`, or `refunded`, plus timestamps.
- Row-level security enabled and no direct browser insert/update/delete permissions.

The browser should call narrowly scoped database RPCs. The RPC derives the user from `auth.uid()`; it must never trust a browser-supplied user ID, currency split, or amount.

## RPC behavior

### Reserve

1. Verify authenticated, active account.
2. Verify the chat session belongs to the caller and is not soft-deleted.
3. Lock the caller's wallet row.
4. Look up the `turn_id`. If it already exists for the same user/session, return the existing status without charging again; reject a conflicting reuse.
5. If total balance is less than 2, return `insufficient_balance` without changing any balance.
6. Deduct exactly 2 atomically, using silver first and diamonds for any remainder:
   - 2 silver -> 2 silver
   - 1 silver + 1 diamond -> 1 of each
   - 2 diamonds -> 2 diamonds
7. Insert the charge row and corresponding signed wallet-ledger rows in the same database transaction.

### Settle

After the demonstration reply and its cloud persistence are confirmed, change the matching reservation from `reserved` to `settled` and attach the assistant message ID. A repeated settle must not charge again.

### Refund

If reply creation/persistence fails before a usable reply is committed, refund the exact reserved currency split. Lock the charge row and only allow `reserved -> refunded`; repeated refund calls must not credit twice. A settled charge must not be refunded by this path.

## Frontend integration order

1. Ensure the cloud session exists and the current user's message has a stable ID.
2. Generate a stable UUID for this send attempt. Reuse it if the same request is retried; do not reuse it for a genuinely new send.
3. Reserve the 2-unit charge through the RPC.
4. If the result is `insufficient_balance`, do not append/save an assistant reply; refresh the wallet display and show the rewarded-video guidance modal.
5. If reservation succeeds, add the fixed demonstration reply and save the user/assistant messages.
6. Settle after successful persistence. If persistence fails, invoke the guarded refund and show a clear retry/error state.
7. Editing a previous user message without regeneration must not call reserve/settle and must not charge.
8. Distinguish insufficient balance from network/database errors; only insufficient balance should open the rewarded-video modal.

## Required tests before merge

- Silver-only, diamond-only, and mixed payment.
- Combined balance below 2 leaves balances and ledger unchanged.
- Repeated same `turn_id` does not charge twice.
- Concurrent distinct turns cannot overdraw the wallet.
- Session ownership and soft deletion are enforced.
- Account deletion-pending users cannot reserve a new charge.
- Failed persistence refunds the exact split once.
- Settled turns cannot be refunded by the failure path.
- Editing without regeneration does not charge.
- Refresh/relogin shows balances consistent with the database ledger.

## Safety boundary

This is a design document committed to `feat/ayet-rewarded-video-callback` only. It has not been applied to Supabase, merged to main, or deployed. The exact RPC SQL and frontend patch must be reviewed against the existing RLS/grant model before execution.
