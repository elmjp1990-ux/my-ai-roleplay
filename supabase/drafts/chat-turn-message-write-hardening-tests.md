# Message-write hardening test plan

Status: test plan only. No database tests have run.
Run only against a disposable Supabase branch/project. Do not execute fixture writes on the connected production project.

## Before testing

- Apply the full migration set to a disposable project.
- Capture the original `chat_messages_insert_own` policy, all non-internal triggers on `chat_messages`, and definitions of `save_chat_message_version()` and the chat-turn charge RPCs.
- Apply `supabase/drafts/chat-turn-message-write-hardening.sql` as one transaction in the disposable project. Do not apply either standalone draft independently.
- Use disposable users, sessions, messages, and wallet rows. Record balances, transaction rows, charge rows, messages, and version-history rows before each case.

## Browser/RLS policy tests

| Case | Authenticated client operation | Expected result |
|---|---|---|
| P1 | Insert a `role='user'` message into own active session | Allowed |
| P2 | Insert a `role='assistant'` message into own active session | Rejected by RLS |
| P3 | Insert a `role='system'` message into own active session | Rejected by RLS |
| P4 | Insert a user message into another user's session | Rejected by RLS |
| P5 | Insert a user message into a soft-deleted session | Rejected by RLS |
| P6 | Insert any message while account is inactive | Rejected by RLS |
| P7 | Service-role Edge Function inserts the expected assistant reply while turn is reserved | Allowed by RLS bypass and INSERT guard |
| P8 | Service-role Edge Function inserts assistant reply for refunded/insufficient turn | Rejected by INSERT guard |
| P9 | Service-role Edge Function inserts empty assistant reply for reserved turn | Rejected by INSERT guard |

## UPDATE protection tests

| Case | Operation | Expected result |
|---|---|---|
| U1 | Edit content on a charged assistant reply after the charge is `settled` | Allowed for the owning user; prior content is recorded in `chat_message_versions` and the current row displays the edited content |
| U2 | Change role on a charged assistant reply | Rejected |
| U3 | Change ID or session on a charged assistant reply | Rejected |
| U4 | Client upsert uses an existing charged assistant ID but supplies role=user | Rejected by UPDATE guard |
| U5 | Change ordinary user-message content | Allowed; existing version-history behavior preserved |
| U20 | Change the ID or session_id of an ordinary user message, while keeping its role unchanged | Rejected; user message content edits remain allowed, but identity and session ownership cannot change |
| U6 | Convert ordinary user message to assistant | Rejected |
| U7 | Convert uncharged assistant row to user | Rejected |
| U8 | Soft-delete a charged assistant reply after its charge is `settled`, changing only `deleted_at` | Allowed; protected fields remain unchanged |
| U9 | Attempt to target another turn's expected assistant ID | Rejected; neither turn/message changes |
| U10 | Two concurrent transactions attempt content edit and soft-delete on a settled reply | Each operation is serialized; edit history is preserved, identity/role cannot change, and the delete cannot overwrite edited content |
| U14 | Soft-delete a reply while its charge is `reserved` after the assistant row was inserted | Rejected; row remains visible so refund logic cannot mistake a persisted reply for no reply |
| U15 | Soft-delete a reply while its charge is `needs_reconciliation` or `refunded` | Rejected; only `settled` permits soft-delete |
| U16 | Attempt refund after a reply row exists but was hidden by legacy `deleted_at` before hardening | Refund must still be rejected after the refund RPC is hardened to detect any persisted expected assistant row, including soft-deleted rows |
| U17 | Change an ordinary user message role to `system`, or change a legacy system row to `user` | Rejected by the immutable-role guard; role changes cannot alter prompt semantics |
| U11 | Failed protected content edit with version trigger enabled | Transaction rollback leaves no new `chat_message_versions` row |
| U12 | Change message A's ID to the expected assistant ID of charged turn B while A belongs to charged turn A | Rejected as cross-turn conflict; both charge rows and messages remain unchanged |
| U13 | Run simultaneous opposite-direction ID swaps between two charged assistant messages | Both swaps rejected; charge rows are locked in deterministic expected-message-ID order, and neither transaction changes message/charge data |
| U18 | Edit content on a legacy assistant row with no charge-ledger row | Allowed for the owning user with prior content saved in `chat_message_versions`; ID, session, and role remain immutable |
| U19 | A reserved turn's expected assistant ID is occupied by a same-session row with a non-assistant role, empty content, or soft-deleted state; attempt refund | Refund is rejected as an integrity conflict; balance and charge state remain unchanged for manual reconciliation |

The existing `chat_messages_save_version_before_update` trigger runs on `UPDATE OF content`. Verify that every successful player edit writes the prior content to `chat_message_versions` and that any rejected edit rolls back the version insert. Players must be able to edit their own settled assistant replies; the guard protects ID/session/role and prevents editing a charged reply before settlement. Legacy assistant content remains editable with version history, while its ID/session/role remain immutable.

Message roles are immutable for every row, including user -> system changes, so an authenticated UPDATE cannot promote player-controlled text into a privileged prompt role. The UPDATE guard must lock all matching old/new charge rows in deterministic `expected_assistant_message_id` order. This both detects cross-turn ID swaps and avoids opposite-order locks for concurrent swaps. The guard trigger must include `deleted_at`; only a `settled` turn may soft-delete its charged assistant reply. The refund RPC must also be hardened to detect an expected assistant row regardless of `deleted_at`, so legacy hidden replies cannot be refunded as if absent.

## Edge Function reservation-error mapping tests

| Case | Injected/observed RPC failure | Expected HTTP/API result | Wallet/UI expectation |
|---|---|---|---|
| E1 | `account_not_active` | `account_not_active`, 403 | Client may clear this turn because account validation failed before reservation |
| E2 | `chat_session_not_owned_or_active` | `chat_session_not_owned_or_active`, 403 | Client removes the unsent local message and does not claim a charge occurred |
| E3 | `user_message_not_found` | `user_message_not_found`, 400 | Client may clear this turn because the server cannot reserve against the specified user message |
| E4 | `wallet_not_initialized` | `wallet_not_ready`, 409 | Client shows a recoverable wallet readiness error without claiming a refund |
| E5 | `turn_id_reuse_conflict` or an unknown database error | Generic `reservation_failed`, 503 | Client keeps the same stable turn IDs; never create a new turn or claim a refund from an unknown result |

These cases validate response mapping only; also verify no wallet transaction or reservation mutation occurs for errors thrown before the reserve RPC's transaction commits.

## Stale-turn reconciliation tests (demo handler only)

| Case | Stale charge and message state | Expected result |
|---|---|---|
| R1 | Old reserved turn has no expected assistant row | Refund exactly once; a retry of the worker does not create another refund transaction |
| R2 | Old reserved or needs_reconciliation turn has a non-empty, visible expected assistant row | Settle the turn; do not refund |
| R3 | Old turn has a non-empty expected assistant row with deleted_at set | Do not refund or mark the reply absent; emit reconciliation_blocked_soft_deleted_reply, keep the charge unresolved, set failure_code=expected_reply_soft_deleted and advance updated_at so repeated worker runs do not emit the same alert every run; count the row as failed for operator follow-up |
| R4 | Assistant INSERT races with stale reconciliation when no reply is visible initially | Charge-row locking serializes the operations: either the durable reply wins and the turn settles, or refund wins and the late insert is rejected. If the refund RPC detects the raced-in reply and raises, the worker records a reconciliation failure, sets status to `needs_reconciliation`, advances `updated_at`, and does not emit the same alert on every run |
| R5 | A real AI provider/job is configured and a generation request may still finish later | Do not enable this demo-only reconciliation worker until provider/job status and late completion are safely handled |

The worker is a source-only draft and is safe only for the deterministic demo reply. R3 intentionally leaves the charge unresolved: silently restoring funds while a persisted reply is hidden would violate the billing invariant. Investigate and resolve the deleted reply through an explicit audited recovery path; do not auto-refund it.

## Frontend sync regression tests

- F1: Before the first billable turn, cloud sync saves the user message, and no assistant-role row is written by the browser.
- F2: The server inserts the fixed demo assistant reply and settles exactly one charge.
- F3: After the reply, metadata sync does not attempt to upsert the assistant row again.
- F4: Reloading the session displays the saved assistant reply from `chat_messages`.
- F5: When no opening assistant row exists before the first user message, the UI reconstructs the opening text from `character_snapshot.opening` without inserting a database assistant row.
- F6: When an opening assistant row already exists, reload does not duplicate it.
- F7: Editing a user message remains free and persists normally.
- F16: Editing a settled assistant reply updates the visible content without a new AI call or charge, while the prior original content and each subsequent prior version are saved to `chat_message_versions`.
- F17: Attempting to edit a reserved or `needs_reconciliation` assistant reply is rejected without leaving a version-history side effect.
- F18: Attempting to change an assistant message ID, session ID, or role remains rejected even when content editing is allowed.
- F8: A failed user-message sync aborts before invoking `chat-turn`, so no wallet reservation occurs.
- F9: The Edge Function returns `status='settled'` but an assistant message ID different from the pending turn's expected ID; the UI does not render it or clear the pending turn.
- F10: The Edge Function returns a non-assistant role or empty content; the UI does not render it or clear the pending turn.
- F11: A recovered/idempotent settled response omits `role`; the UI rejects it, keeps the pending turn, and does not render the reply.
- F12: A reserved turn's expected assistant row exists but has `deleted_at` set; the Edge Function detects the row without filtering soft-deleted messages, sets/keeps `needs_reconciliation`, and never invokes refund.
- F13: A `needs_reconciliation` turn has a soft-deleted expected assistant reply; retry does not insert a replacement reply or refund the turn, and records `expected_reply_soft_deleted`.
- F14: After a persistence error, the follow-up lookup finds a soft-deleted expected assistant row; the code fails closed and does not refund, even if the currently deployed refund RPC has not yet been hardened.
- F15: A previously settled expected assistant reply is soft-deleted and the client retries after an ambiguous response; the Edge Function reports `status='settled'` with `replyHidden=true`, the frontend removes any stale local copy of that assistant reply, clears the pending marker locally and in cloud session metadata, refreshes the wallet, and does not create a new turn or charge. If metadata sync fails, the UI reports the sync failure without restoring hidden content or retrying billing.

## Acceptance criteria

- All tests pass in isolation, including an authenticated client and service-role request.
- User-message insert/edit and chat reload still work.
- Client cannot create arbitrary assistant messages, change an assistant reply's identity/role, or edit a charged reply before settlement.
- Owner can edit a settled assistant reply; the original and prior versions remain available for customer-support review.
- Failed UPDATE does not leave a message-version side effect.
- No production policy/function/trigger changes until isolated results and rollback SQL are reviewed and explicitly approved.


## Wallet state-transition and idempotency tests

| Case | Concurrent/repeated operation | Expected result |
|---|---|---|
| W1 | Submit the exact same reserve request twice with the same turn/user/session/message IDs | One charge row and one debit per currency; both callers observe the same reservation state and reserved split |
| W2 | Reuse a turn ID with a different user, session, user-message ID, or expected assistant ID | Reject with `turn_id_reuse_conflict`; do not debit or mutate the original charge |
| W3 | Two different turn IDs reserve concurrently against one wallet with exactly 2 total points | Wallet row lock serializes reservations; at most one turn reserves successfully, and balances never become negative |
| W4 | Reserve with 0 or 1 total point and retry the same turn ID after a later top-up | The original turn remains `insufficient_funds`; no charge occurs for that ID. A new intentional send must use a new turn ID |
| W5 | Call settlement twice for the same settled turn and same assistant ID | Both calls return settled; no additional wallet transaction or debit is created |
| W6 | Attempt settlement with a different assistant ID or with an empty/missing/soft-deleted expected reply | Reject; charge is not marked settled |
| W7 | Race settlement and refund for the same reserved turn | Charge-row lock serializes outcomes; exactly one terminal state wins, never both settled and refunded, and the wallet is changed at most once |
| W8 | Call refund repeatedly after a successful refund | Status remains refunded; no second refund transaction and no second balance credit |
| W9 | Attempt refund after settlement, or settlement after refund | Reject the incompatible transition without changing the wallet or transaction ledger |
| W10 | Force a wallet-transaction unique-index conflict during reserve/refund | The whole database transaction rolls back; no partial balance mutation or terminal status update remains |
| W11 | Lose the HTTP response after reserve committed, then retry with identical IDs | The retry discovers the existing charge and must not debit again; client keeps the same IDs until it receives a definitive state |
| W12 | Lose the HTTP response after settlement committed, then retry with identical IDs | The retry recovers the exact saved assistant reply and settled state; no second reply or debit is created |
| W13 | Simulate an exception after wallet balance update but before charge status/event insert | The SQL transaction rolls back the balance and ledger writes together; no partial reservation/refund survives |
| W14 | Inspect direct execution grants for reserve/settle/refund RPCs and the internal trigger functions | `anon`, `authenticated`, and `PUBLIC` cannot execute privileged RPCs; only the trusted server role has the required execute grant |

These are required database integration tests, not assertions that have already passed. Use separate database sessions for concurrency cases and verify charge rows, wallet balances, and wallet_transactions after both sessions complete.
