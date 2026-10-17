# WALLET-02 — Atomic reply persistence acceptance matrix

Status: design checklist only. No database writes, migrations, deployment, or live HTTP tests have been run.

Target implementation:
- SQL draft: `supabase/drafts/chat-turn-atomic-reply-persistence.sql`
- Handler: `supabase/functions/chat-turn/index.ts`
- Branch: `fix/wallet-reply-identity-reconciliation`

## Preconditions to test in an isolated Supabase project

1. Apply the schema/trigger fixtures that match the target project's current schema.
2. Confirm the RPC is executable by `service_role`, and not by `PUBLIC`, `anon`, or `authenticated`.
3. Confirm the `chat_messages` assistant INSERT guard and the foreign key from `ai_generation_records.assistant_message_id` are enabled.
4. Use synthetic users, sessions, user messages, and charges only.

## Required cases

| Case | Setup / action | Expected result |
| --- | --- | --- |
| Happy path | reserved charge; valid owned active session; valid user message; new assistant ID; non-empty content | one assistant row and one exact generation identity row; RPC returns persisted/idempotent=false |
| Exact retry | repeat same RPC call after successful persistence while charge remains unresolved | no duplicate rows; same stored reply; idempotent=true |
| Same ID, different session | supply a session ID not matching the charge | RPC raises identity conflict; no new rows |
| Same ID, different user message | supply another user message ID | RPC raises identity conflict; no new rows |
| Empty content | blank/whitespace-only content | rejected before inserts; no rows |
| Assistant ID collision | assistant ID already belongs to a different message/turn | error; existing data unchanged |
| Partial legacy state | only assistant row exists, no generation identity | fail closed with partial identity error; do not adopt the row |
| Generation insert constraint failure | force a unique-key/FK/constraint failure after assistant insert in an isolated test fixture | entire RPC transaction rolls back; neither newly inserted row remains |
| Charge settled/refunded | call persistence RPC against a non-unresolved charge | rejected; no changes |
| Session deleted/not owned | mark session deleted or mismatch owner | rejected; no inserts |
| Concurrent identical calls | issue same request concurrently | at most one pair of rows; second call either returns exact idempotent match or a safe retryable transaction error; never duplicate identity |
| Concurrent conflicting calls | same charge with different reply IDs or identity args | one request rejected; charge/message identity remains consistent |
| Privilege boundary | invoke RPC as anon/authenticated | permission denied |
| Settlement after persistence | call settle RPC after successful atomic write | charge settles once; retry does not double charge |
| Settlement failure | simulate settlement RPC failure after persistence | reply and generation identity remain durable; charge becomes/retains needs_reconciliation; no refund |
| Response lost after commit | simulate client losing RPC response after commit, then handler reads rows | only exact matching durable identity is accepted for settlement |
| Mismatched stored identity | alter fixture to have mismatched generation identity and invoke recovery | no settlement; needs_reconciliation/error logged |

## Exit criteria

- SQL compiles against a clean isolated schema with matching migrations.
- All cases pass, including rollback and concurrent execution.
- Run database security advisors; confirm no unintended PUBLIC/anon/authenticated EXECUTE grant.
- Run Deno/TypeScript check and handler-level tests.
- Only after those checks pass, prepare a migration and review the deployment diff. Do not apply to the connected test DB or deploy as part of this checklist.
