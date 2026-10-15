# Frontend contract for expired account recovery

Status: implementation contract only. No production code or Supabase schema has been changed by this document.

## Current frontend behavior
- Startup calls `get_account_deletion_status()`.
- The account-deletion dialog uses `cancel_account_deletion()` as its recovery/cancellation action.
- The current UI does not call `recover_expired_account_deletion()` and cannot distinguish an expired request from a cancellable request based on the current status RPC.
- The existing persistent error dialog is a presentation fix only; it does not recover an expired request.

## Required backend contract before frontend wiring
The recovery RPC proposal returns one row with `recovered boolean` and a stable `result_code`. Frontend code must treat the code as an allowlisted enum, not render arbitrary database error text.

| result_code | UI behavior | Clear local pending state? |
|---|---|---|
| `recovered` with `recovered=true` | Clear deletion-pending UI, refresh auth/profile/wallet state, then show success | Only after confirmed success and refresh |
| `no_request` | Refresh server status and reconcile local UI; do not claim recovery | Only if refreshed status confirms no request |
| `use_cancel_before_deadline` | Offer the normal cancellation action | No |
| `manual_review_required` | Keep account state blocked and show a persistent support/manual-review message | No |
| `archive_count_mismatch` | Keep blocked; show a generic safe error; log diagnostic details only to restricted operations logs | No |
| `archive_payload_mismatch` | Keep blocked; show a generic safe error; log diagnostic details only to restricted operations logs | No |
| RPC/network/auth failure or unknown code | Keep current pending state; show persistent retry/support message | No |

## Wiring rules
1. The recovery action must verify the currently authenticated Supabase user matches the app's active user before invoking the RPC.
2. The RPC takes no user ID or request ID argument; it must derive identity from `auth.uid()`.
3. Do not call recovery automatically during startup. Only invoke after an explicit user action.
4. Do not clear local flags before the RPC returns `recovered=true`.
5. After success, re-read server deletion status and reload profile/wallet data before showing success. If refresh fails, state that recovery succeeded but refresh failed; do not silently pretend the refresh completed.
6. Do not use client time as the authority for whether a request is expired. The backend response is authoritative.
7. Preserve the persistent error dialog for refusals and unknown responses; do not dismiss it immediately behind another modal.
8. Never call Auth Admin deletion from browser code, and never expose service-role credentials in frontend assets.
9. Test both desktop and mobile modal stacking only after backend behavior is validated in a disposable project.

## Release blockers
- The recovery SQL is still a proposal and has not been applied or tested in an isolated project.
- Status RPC still lacks an explicit lifecycle state and does not distinguish expired, archiving, archived, failed, or completed.
- Idempotent behavior for repeated successful calls needs a product/API decision.
- The branch `fix/account-deletion-repair` is diverged from `main`; do not merge it wholesale without reconciling the two commits missing from the branch and reviewing the frontend diff.
- Production deadline remains five minutes while the UI promises 30 days. The 30-day default SQL is a proposal only.

## User test notification gate
Do not ask the user to test until:
- the recovery RPC and lifecycle design have been reviewed,
- a disposable Supabase project is available and test cases pass,
- the frontend is wired to the authoritative RPC response,
- production and test deadlines are clearly separated,
- and the exact test action is safe and does not permanently delete an account.
