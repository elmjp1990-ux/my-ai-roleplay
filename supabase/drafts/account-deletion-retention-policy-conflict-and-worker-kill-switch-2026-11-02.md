# Account deletion — retention-policy conflict and fail-closed worker guard — Round 46 — 2026-11-02

PR #200: Draft / unmerged
Branch: `security/chat-deletion-lifecycle-reconciliation`

## 1. Policy conflict found — do not execute either interpretation yet

The repository draft `account-deletion-never-published-character-policy-2026-11-02.md` says never-published characters should be permanently deleted during account deletion.

However, the previously recorded user-approved account-deletion requirement in the project history says account deletion must preserve all character rows/content/settings, including never-published characters, and preserve illustration/video assets. This differs from manual character deletion, where an unused never-published character may be hard-deleted.

These are materially different retention policies. The repository draft's heading "User-confirmed policy refinement" is not sufficient evidence by itself to override the earlier explicit requirement. Therefore this round does NOT implement either destructive disposition. Until the user explicitly resolves the conflict, use the safer non-destructive behavior: preserve all characters, including never-published ones, and do not delete their Storage objects during account deletion. A future policy change must be explicit and separately documented.

## 2. Worker fail-closed code guard added

Updated `supabase/functions/account-deletion-worker/index.ts`:
- Added a compile-time constant `ACCOUNT_DELETION_EXECUTION_ENABLED = false`.
- The HTTP handler returns 503 `account_deletion_worker_disabled` before calling `get_account_deletion_work_items()`, archive/prepare/finalize/failure RPCs, or Auth Admin `deleteUser()`.
- The guard is intentionally not an environment variable; an accidental deployment or configuration value cannot enable destructive execution.
- Do not flip this constant in isolation. Remove it only in a separately approved release change after durable character preservation, active-owner detachment, RLS/Storage/session authorization, concurrency fencing, and local acceptance tests pass.

Commit: `8e287d03aacf78b5ba149d9a30fe5609ddc1f625`.

## 3. CI coverage

The existing workflow `.github/workflows/account-deletion-worker-tests.yml` already runs:
- `deno check supabase/functions/account-deletion-worker/index.ts`
- `deno test supabase/functions/_shared/account-deletion-worker.test.ts`

The handler change matches the workflow path filters, so a branch push should trigger the workflow. This is not yet a passing test claim; inspect the new run before acceptance. Existing unit tests exercise the orchestration helper, not an HTTP integration test for the 503 guard. Add a handler-level test if the project has a suitable import/mock pattern; otherwise retain the static guard and type-check result as separate evidence.

## 4. Current hard blockers remain

- Current archive/prepare RPCs do not preserve/detach character rows/settings/media metadata before Auth deletion.
- Profile FK CASCADE can still destroy characters, illustrations, and private info.
- Existing-session private media reads after author deletion are not implemented.
- Atomic lease/fencing remains unimplemented.
- NO ACTION and financial/audit retention dispositions remain to be resolved.
- Worker is now additionally guarded in code and must remain un-deployed.
- PR #200 remains Draft/unmerged.

## 5. Safety

No hosted RPC was invoked, no DDL/DML or settings changed, no Auth/Storage mutation, no Edge Function deployment, and no Cron change occurred.
