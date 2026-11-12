# Chat message write guard verification

Status: migration activates the UPDATE guard function already versioned on current main and restricts browser INSERTs to user messages. This is code-only; no hosted Supabase migration has been applied.

## Current-main protections reused

- `guard_chat_turn_assistant_update()` is already defined in `20261101055617_chat_deletion_purge_worker_rpc.sql`. Preserve it unchanged: it locks the parent session, makes role/identity immutable, serializes updates against charge rows, blocks editing/hiding unresolved assistant replies, and allows the narrowly scoped `service_role` purge-worker path.
- `guard_chat_turn_assistant_insert()` is already present and rejects assistant rows without a matching expected assistant ID and unresolved charge. It also locks the active parent session.
- `refund_chat_turn()` already fails closed when ANY row occupies the expected assistant ID, including soft-deleted/malformed rows.
- Reserve/settle/refund RPCs are service-role-only.
- This migration attaches the existing UPDATE function as a trigger and replaces the known browser INSERT policy with a user-role-only policy. It does not replace the AI Edge Function or wallet RPC bodies.

## Automated disposable integration coverage

Added `supabase/drafts/test-chat-message-write-guards.sql` and
`.github/workflows/chat-message-write-guard-tests.yml`.

The workflow starts a fresh local Supabase database with no hosted credentials,
loads only the synthetic schema-only fixture, applies this PR's migration, runs
the assertions, and stops/discards the local database. It does not link to or
mutate the connected Supabase project.

The executable cases now cover:
- Exactly one permissive browser INSERT policy remains on `chat_messages`.
- Own active-session user message insert is allowed; forged assistant insert,
  foreign-session insert, deleted-session insert, and pending-account-deletion
  insert are denied.
- Assistant insert without a charge, for the wrong session, with empty content,
  or against a settled charge is denied; the expected reserved assistant reply
  is accepted.
- User message content edits remain compatible, while message identity is
  immutable; unresolved assistant edits/deletes are denied.
- Settled assistant edit/version history and soft-delete behavior are preserved.
- A second active account cannot edit another user's message.
- Rejected assistant edits leave no message-version side effect.
- The purge-worker marker permits only the existing trusted purge path after
  parent deletion; service-role writes without the marker remain guarded.
- The two assistant guards remain SECURITY DEFINER with an empty search_path;
  the timestamp-only guard is SECURITY INVOKER because it performs no privileged
  reads or writes. All three use an empty search_path, browser roles cannot
  execute them directly, and service_role retains the required ACL.
- The parent-session primary key, expected-assistant unique index, and existing
  `(session_id, created_at)` message index are present.

## Performance review

No additional index is proposed for this change:
- The active parent-session check resolves through `chat_sessions_pkey`.
- The assistant charge lookup resolves through the unique
  `expected_assistant_message_id` index.
- The existing `idx_chat_messages_session_created` supports session history
  reads and session-scoped scans.
- The timestamp immutability trigger runs only when an UPDATE explicitly targets
  `created_at`; normal message inserts and content edits do not invoke it. Its
  invoker-only function rejects the change without a database lookup or parent
  lock, avoiding an unnecessary lock on a request that can never succeed.
- The policy wraps `auth.uid()` and `account_is_active()` as scalar SELECT
  expressions so PostgreSQL can evaluate request-scoped values once rather
  than repeatedly per candidate row.

The UPDATE guard intentionally locks the parent session before charge rows.
This serializes edits/purge against chat deletion and is retained for correctness;
do not remove the lock as a speculative micro-optimization.

The workflow also runs `scripts/test-chat-write-guard-concurrency.sh` using two
independent `psql` connections:
- Delete-first: a writer waits on the parent row, then rejects the assistant insert
  after the deletion commits; no reply is persisted and the charge remains reserved.
- Writer-first: the assistant insert commits while holding the parent lock; deletion
  waits, then completes. The durable reply is not lost.
Both races use synthetic local-only identities and the local database is discarded.

## Disposable-project test plan

Run only against a disposable Supabase branch/project with disposable users, sessions, messages and wallet rows.

| Case | Operation | Expected |
|---|---|---|
| I1 | Authenticated user inserts role=user into own active session | Allowed |
| I2 | Authenticated user inserts role=assistant or role=system | Rejected by INSERT RLS |
| I3 | Authenticated user inserts role=user into another user's session | Rejected by INSERT RLS |
| I4 | Authenticated user inserts role=user into deleted session or inactive account | Rejected by INSERT RLS |
| I5 | Service role inserts assistant row without matching charge | Rejected by assistant INSERT trigger |
| I6 | Service role inserts non-empty expected assistant row for reserved turn in matching active session | Allowed |
| I7 | Service role inserts assistant row for wrong session, empty content, settled/refunded turn | Rejected by assistant INSERT trigger |
| U1 | Owner changes role, ID or session_id of any message | Rejected by UPDATE guard |
| U2 | Owner edits user message content | Allowed; existing behavior preserved |
| U3 | Owner edits assistant content for reserved/needs_reconciliation charge | Rejected |
| U4 | Owner edits assistant content for settled charge | Allowed; prior content version is recorded |
| U5 | Owner soft-deletes assistant for reserved/needs_reconciliation charge | Rejected |
| U6 | Owner soft-deletes assistant for settled charge | Allowed |
| U7 | Other user attempts update | Rejected by existing owner RLS |
| P1 | Service-role purge worker performs the existing authorized content purge with `app.chat_purge_worker=on` | Allowed by existing narrowly scoped guard bypass |
| P2 | Service role without purge-worker marker attempts to change message identity/role | Rejected |

For rejected updates, assert no wallet balance/transaction/charge changes and no residual `chat_message_versions` row. Confirm trigger enabled, function remains SECURITY DEFINER with empty search_path, and browser roles cannot execute the guard function directly.

## Safety boundary

- No migration push to hosted test or production Supabase in this PR.
- No wallet, message, session, or Storage data is modified.
- Do not copy the old #29 demo-era `chat-turn` Edge Function changes; current main uses the real provider-backed handler.
- Do not add #29's assistant-reply editing UI; this PR ports database write protections only.
- Keep PR #29 open until this replacement PR has been reviewed, tested and merged. Then close #29 without merging it.
