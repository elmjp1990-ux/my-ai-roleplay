# Account deletion repair — review gates before implementation

Status: planning / proposal only. No production database changes.

## Confirmed defects
- Frontend promises a 30-day cancellation window; the live column default was observed as now() + 5 minutes.
- `request_account_deletion()` uses `ON CONFLICT (user_id) DO NOTHING`, so an old request is not reset into a new lifecycle.
- `cancel_account_deletion()` deletes only when the deadline is in the future, so an expired request blocks the existing recovery button.
- `get_account_deletion_status()` reports request existence/timestamps only, not whether processing started, archival reconciled, or recovery is safe.
- The archive RPC archives only AI generation records and wallet transactions. It leaves source rows and the Auth user intact, sets batch status `archived`, and does not set `completed_at`. That status must not be treated as deletion completion.
- No deployed Edge Function or scheduled deletion worker was found in the reviewed project. Do not enable a worker until lifecycle and retention are settled.
- FK dependencies include NO ACTION references from AI generation records and chat message versions; direct Auth user deletion can be blocked unless dependent data is retained/deleted in a carefully reviewed order.

## Staged implementation
1. Keep production read-only; finish schema, ACL, RLS, FK and frontend call-site audit.
2. Build an isolated Supabase test project with representative disposable records; never use a real user account for destructive testing.
3. Apply reviewed migrations only to the isolated project:
   - 30-day default for new requests.
   - Explicit request lifecycle/state transitions.
   - Expired recovery RPC with auth.uid-only ownership, fail-closed states, lock coordination, append-only audit and archive/source reconciliation.
   - Updated status RPC with explicit server-derived lifecycle and recovery eligibility.
4. Add frontend integration only after RPC contract is fixed:
   - Show expired-recovery option based on server status.
   - Keep pending state on any error/refusal.
   - Clear local pending state only after explicit server success.
   - Refresh profile and wallet from the database; never infer balances from local state.
5. Test concurrent recovery/request processing, null deadline, future deadline, expired deadline, no request, ambiguous/multiple archive batches, archive mismatch, repeated requests, RPC permission boundaries, and FK deletion ordering.
6. Only after test pass, review the final diff and migration plan, then ask for explicit production-change approval. Do not merge/deploy or apply production SQL automatically.

## Release blockers
- No confirmed deletion worker / schedule.
- No approved retention policy for characters, chats, message versions, AI records, wallets and archive copies.
- Existing batch state `archived` is not equivalent to completed account deletion.
- Recovery draft is proposal-only and must be tested and reviewed before use.
- Branch `fix/account-deletion-repair` is not merged; branch divergence requires a fresh diff review before any PR merge.
