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
| U1 | Change content on a charged assistant reply | Rejected; no message-version row remains |
| U2 | Change role on a charged assistant reply | Rejected |
| U3 | Change ID or session on a charged assistant reply | Rejected |
| U4 | Client upsert uses an existing charged assistant ID but supplies role=user | Rejected by UPDATE guard |
| U5 | Change ordinary user-message content | Allowed; existing version-history behavior preserved |
| U6 | Convert ordinary user message to assistant | Rejected |
| U7 | Convert uncharged assistant row to user | Rejected |
| U8 | Soft-delete a charged assistant reply after its charge is `settled`, changing only `deleted_at` | Allowed; protected fields remain unchanged |
| U9 | Attempt to target another turn's expected assistant ID | Rejected; neither turn/message changes |
| U10 | Two concurrent transactions attempt content edit and soft-delete on a settled reply | Protected content/identity cannot change; soft-delete may succeed |
| U14 | Soft-delete a reply while its charge is `reserved` after the assistant row was inserted | Rejected; row remains visible so refund logic cannot mistake a persisted reply for no reply |
| U15 | Soft-delete a reply while its charge is `needs_reconciliation` or `refunded` | Rejected; only `settled` permits soft-delete |
| U16 | Attempt refund after a reply row exists but was hidden by legacy `deleted_at` before hardening | Refund must still be rejected after the refund RPC is hardened to detect any persisted expected assistant row, including soft-deleted rows |
| U17 | Change an ordinary user message role to `system`, or change a legacy system row to `user` | Rejected by the immutable-role guard; role changes cannot alter prompt semantics |
| U11 | Failed protected content edit with version trigger enabled | Transaction rollback leaves no new `chat_message_versions` row |
| U12 | Change message A's ID to the expected assistant ID of charged turn B while A belongs to charged turn A | Rejected as cross-turn conflict; both charge rows and messages remain unchanged |
| U13 | Run simultaneous opposite-direction ID swaps between two charged assistant messages | Both swaps rejected; charge rows are locked in deterministic expected-message-ID order, and neither transaction changes message/charge data |

The existing `chat_messages_save_version_before_update` trigger runs on `UPDATE OF content`. Verify PostgreSQL trigger order and confirm that if it fires before the guard, the guard exception rolls back the version insert as part of the same statement.

Message roles are immutable for every row, including user -> system changes, so an authenticated UPDATE cannot promote player-controlled text into a privileged prompt role. The UPDATE guard must lock all matching old/new charge rows in deterministic `expected_assistant_message_id` order. This both detects cross-turn ID swaps and avoids opposite-order locks for concurrent swaps. The guard trigger must include `deleted_at`; only a `settled` turn may soft-delete its charged assistant reply. The refund RPC must also be hardened to detect an expected assistant row regardless of `deleted_at`, so legacy hidden replies cannot be refunded as if absent.

## Frontend sync regression tests

- F1: Before the first billable turn, cloud sync saves the user message, and no assistant-role row is written by the browser.
- F2: The server inserts the fixed demo assistant reply and settles exactly one charge.
- F3: After the reply, metadata sync does not attempt to upsert the assistant row again.
- F4: Reloading the session displays the saved assistant reply from `chat_messages`.
- F5: When no opening assistant row exists before the first user message, the UI reconstructs the opening text from `character_snapshot.opening` without inserting a database assistant row.
- F6: When an opening assistant row already exists, reload does not duplicate it.
- F7: Editing a user message remains free and persists normally.
- F8: A failed user-message sync aborts before invoking `chat-turn`, so no wallet reservation occurs.
- F9: The Edge Function returns `status='settled'` but an assistant message ID different from the pending turn's expected ID; the UI does not render it or clear the pending turn.
- F10: The Edge Function returns a non-assistant role or empty content; the UI does not render it or clear the pending turn.

## Acceptance criteria

- All tests pass in isolation, including an authenticated client and service-role request.
- User-message insert/edit and chat reload still work.
- Client cannot create arbitrary assistant messages or mutate a charged assistant reply.
- Failed UPDATE does not leave a message-version side effect.
- No production policy/function/trigger changes until isolated results and rollback SQL are reviewed and explicitly approved.
