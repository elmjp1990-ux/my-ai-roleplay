# Wallet chat-turn validation matrix

Status: test specification only; no tests in this document have been executed.
Scope: `wallet_chat_turn_charging`, deployed demo `chat-turn`, and the review-only assistant UPDATE guard.
Safety: run only against a disposable Supabase branch/project. Do not run fixtures against the connected production project. Every data test must roll back or use isolated test identities and explicit cleanup.

## 1. Preconditions and test isolation

- Start from the same migration set as the connected project, including `20261015101628 wallet_chat_turn_charging`.
- Confirm the test database has `chat_turn_charges`, `chat_turn_events`, `reserve_chat_turn`, `settle_chat_turn`, `refund_chat_turn`, and `guard_chat_turn_assistant_insert`.
- Do not install `guard_chat_turn_assistant_update` in production. Install the draft only in the isolated test database.
- Create disposable auth users, profiles/wallets, chat sessions, and user messages through supported fixture setup. Never reuse the owner's actual account or delete existing wallet rows.
- Snapshot wallet balances and relevant `wallet_transactions`, `chat_turn_charges`, `chat_turn_events`, `chat_messages`, and `chat_message_versions` before each case.
- For every rejected operation, assert both the expected error and that all balances, transaction counts, charge status, and message content remain unchanged.
- Test concurrency with two independent database connections; a single sequential SQL transaction does not prove race safety.

## 2. Reservation and currency matrix

For each case, start with a fresh user, wallet, session, user message, turn UUID, and assistant-message UUID.

| Case | Starting silver | Starting diamonds | Expected reservation | Expected ending balance |
|---|---:|---:|---|---|
| S1 silver-only | 5 | 0 | 2 silver | 3 silver, 0 diamonds |
| S2 diamond-only | 0 | 5 | 0 silver, 2 diamonds | 0 silver, 3 diamonds |
| S3 mixed | 1 | 1 | 1 silver, 1 diamond | 0 silver, 0 diamonds |
| S4 exactly enough | 2 | 0 | 2 silver | 0 silver, 0 diamonds |
| S5 insufficient | 1 | 0 | no deduction | 1 silver, 0 diamonds; status `insufficient_funds` |
| S6 concurrent reserve | 2 | 0 | only one distinct turn can reserve 2 | balance never negative; other turn is insufficient |
| S7 same turn retry | 4 | 0 | one reservation only | 2 silver, 0 diamonds; exactly one charge debit per currency |
| S8 same turn, changed identifiers | any | any | reject with `turn_id_reuse_conflict` | no additional deduction |

Assertions for S1-S4 and S7:
- One charge row per `turn_id`; stable user/session/user-message/expected-assistant IDs.
- Reservation fields sum to exactly 2 for a reserved turn.
- `wallet_transactions` contains only the currency debit rows actually used, with `biz_type='chat_turn_charge'` and `reference_id=turn_id::text`.
- Repeating reserve with identical identifiers returns existing state without another debit or duplicate transaction.

## 3. Settlement and refund matrix

| Case | Action | Expected result |
|---|---|---|
| C1 | Settle with exact assistant ID after non-empty assistant row is durable | status becomes `settled`; no second debit |
| C2 | Settle twice with same IDs | remains `settled`; no extra transactions |
| C3 | Settle before reply is durable | rejects `durable_assistant_reply_not_found`; reservation remains |
| C4 | Settle with different assistant ID | rejects `turn_assistant_id_conflict`; no balance change |
| C5 | Refund reserved silver-only turn | exact original silver split restored once |
| C6 | Refund reserved diamond-only turn | exact original diamond split restored once |
| C7 | Refund mixed turn | restores 1 silver and 1 diamond exactly |
| C8 | Refund same turn twice | second call is idempotent; no extra credit transaction |
| C9 | Refund after settlement | rejects `settled_turn_cannot_be_refunded`; no balance change |
| C10 | Refund while exact non-empty assistant reply is durable | rejects `reply_already_persisted`; reservation remains |
| C11 | Reply persistence outcome cannot be read | turn remains unresolved / `needs_reconciliation`; no speculative refund |
| C12 | Reuse a turn UUID with different user/session/message/assistant IDs | rejects; no cross-account or cross-session debit |

For every successful refund, assert each refund transaction has `biz_type='chat_turn_refund'`, the same turn reference, and the original currency split. Verify the partial unique index prevents duplicate transaction rows and that the wallet balance is not credited twice.

## 4. Assistant UPDATE guard matrix (draft only)

Install `supabase/drafts/chat-turn-assistant-update-guard.sql` only in the disposable test database, after capturing the original trigger/function definitions.

| Case | Mutation | Expected |
|---|---|---|
| U1 | Change content of a settled charged assistant reply | reject `charged_assistant_reply_is_immutable` |
| U2 | Change ID of a charged assistant reply | reject; original row remains unchanged |
| U3 | Change session ID of a charged assistant reply | reject; original row remains unchanged |
| U4 | Change role of a charged assistant reply | reject; original row remains unchanged |
| U5 | Change user message role from `user` to `assistant` without a charge | reject `assistant_role_change_requires_chat_turn` |
| U6 | Change an uncharged assistant message role to `user` | reject `assistant_role_change_requires_chat_turn` |
| U7 | Change ordinary user-message content without changing role | preserve existing intended edit behavior |
| U8 | Set/update `deleted_at` on a charged assistant reply | allowed; content, role, ID, and session remain unchanged |
| U9 | Update metadata not covered by the trigger column list | allowed only if the existing product behavior requires it |
| U10 | Change a charged row ID to another turn's expected assistant ID | reject; neither turn nor either message changes |
| U11 | Concurrent UPDATE and soft-delete of the same charged reply | no identity/content mutation can slip through |
| U12 | Version-history trigger fires for an ordinary allowed edit | prior content/version behavior remains intact |
| U13 | Failed protected edit | no unexpected row in `chat_message_versions` |

Important compatibility check: `chat_messages_save_version_before_update` must not persist a version or other side effect for an UPDATE that the immutability guard rejects. Confirm trigger execution order and rollback behavior explicitly.

## 5. Edge Function and recovery matrix

- E1: missing/invalid bearer token returns 401; no charge row or wallet mutation.
- E2: malformed UUID / invalid JSON returns 400; no charge row or wallet mutation.
- E3: inactive account or unowned/deleted session is rejected; no charge.
- E4: insufficient balance returns 402 and does not create an assistant reply.
- E5: same request repeated after successful settlement returns the same durable assistant reply and no second debit.
- E6: reply insert fails and a read confirms no reply; exact refund occurs once.
- E7: reply insert result is uncertain because verification read fails; no refund is issued and state is marked for reconciliation.
- E8: reply is durable but settlement RPC response is lost; retry settles the same turn and never refunds.
- E9: same assistant-message ID exists with different content/session/role; conflict is not treated as success.
- E10: two simultaneous identical requests create at most one durable assistant reply and one charge.
- E11: the same turn ID with altered identifiers is rejected.
- E12: event logging failure is exercised separately; a telemetry write failure must not silently claim a billing transition that did not occur.

The current Edge Function returns a fixed demo reply. Passing these cases does not prove real AI provider integration, provider job recovery, or production readiness.

## 6. Stale reconciliation draft

Only test `supabase/drafts/chat-turn-stale-reconciliation.sql` while the handler is deterministic and has no external provider job.

- R1: stale reserved turn with a durable non-empty expected reply settles.
- R2: stale reserved turn with no durable reply refunds the exact reserved split.
- R3: concurrent reply insert and reconciliation serialize on the charge row; the result is either a valid settlement or a valid refund, never both.
- R4: already settled/refunded/insufficient turns are not processed again.
- R5: invalid stale minutes (<5 or >1440) and batch size (<1 or >500) are rejected.
- R6: a row-level error increments failed count and records a reconciliation event without stopping the entire batch.
- R7: two workers using `FOR UPDATE SKIP LOCKED` do not process the same charge concurrently.
- R8: verify the schedule is disabled/not installed until explicitly approved; do not add cron jobs as part of this test.

## 7. Exit criteria before production change

- All applicable cases pass on an isolated database with recorded outputs.
- Two-connection concurrency cases pass.
- Before/after balance and ledger invariants match exactly.
- Protected UPDATE failures do not create version-history side effects.
- Review trigger lock order, grants, empty `search_path`, RLS interaction, and rollback SQL.
- A production migration proposal and rollback plan are reviewed and explicitly approved before application.
- Do not enable stale reconciliation on a real AI provider until it can query the provider/job status and prove generation has stopped before refunding.
