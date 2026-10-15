# Account Deletion Read-only Audit Notes

Date: 2026-10-15
Scope: live Supabase metadata and GitHub `main` frontend source. No database writes were performed.

## Frontend and deadline behavior
- `index.html` calls `get_account_deletion_status()` during account initialization and displays a pending-deletion modal when the RPC reports a request.
- The frontend confirmation text says the account can be restored within 30 days.
- The live `account_deletion_requests.scheduled_for` column default is currently `now() + interval '5 minutes'`. This conflicts with the 30-day UI promise. Treat five-minute timing as test-only; production timing must be made explicit and aligned with the intended product rule before enabling any worker.
- A pending account is blocked from most UI actions by a client-side action allowlist. Client-side gating alone is not a security boundary.
- The frontend calls `request_account_deletion()` and `cancel_account_deletion()`.

## Current RPC behavior confirmed from live definitions
- `request_account_deletion()`: requires `auth.uid()`; inserts with `ON CONFLICT (user_id) DO NOTHING`, then returns the existing row. It does not refresh an expired row.
- `cancel_account_deletion()`: deletes only when `scheduled_for > statement_timestamp()`. An expired request cannot be cancelled through this RPC.
- `get_account_deletion_status()`: reports whether the current authenticated user's request row exists; it does not distinguish pending, expired, archived, or failed states.
- `account_is_active()`: returns false whenever a request row exists, even if the deadline has passed. Review all uses when defining recovery and status behavior.
- `archive_account_deletion_data(p_user_id)`: archives AI-generation rows and wallet transactions, marks the batch `archived`, but does not delete source rows or the Auth user. It is not a full deletion processor.
- Archive batch columns include `attempt_count`, `completed_at`, and `last_error`; the existing archive function does not set a completion timestamp or implement a complete processing lifecycle.
- Live privilege checks show `archive_account_deletion_data(uuid)` is executable by `postgres`, but not `authenticated`, `anon`, or `service_role`. The intended worker role and grant model must be designed deliberately; do not broaden grants as a quick fix.

## RLS review — corrected against live metadata
- The live `pg_policies` query shows `account_must_be_active` on `characters`, `character_stories`, and `conversations` is **RESTRICTIVE**, with role `authenticated`; it is not permissive as an earlier draft of this audit claimed.
- Each table also has a permissive owner `ALL` policy. PostgreSQL combines permissive policies with OR, but restrictive policies are additionally ANDed with the applicable permissive result. For authenticated requests, the restrictive active-account policy should still constrain the owner policy. Do **not** assume the owner policy bypasses it and do not apply the earlier DROP/CREATE proposal without further analysis.
- Verify effective behavior table-by-table, including role applicability and each command type. Preserve public approved-content reads and owner access for active accounts.
- The `messages` table has a restrictive `account_must_be_active` policy in the live result; no parallel owner `ALL` policy appeared in that query. `chat_sessions`, `chat_messages`, `chat_message_versions`, and `ai_generation_records` have active-account checks in relevant policies and still require independent review.
- The account-deletion tables have RLS enabled and are not forced. Direct table privileges and policies still need a complete review.

## FK inventory relevant to eventual deletion
- `ai_generation_records.user_id -> profiles.id` uses default NO ACTION behavior and is NOT NULL.
- `ai_generation_records.session_id -> chat_sessions.id` and message references use default NO ACTION behavior. `chat_sessions.user_id -> auth.users.id ON DELETE CASCADE`, and `chat_messages.session_id -> chat_sessions.id ON DELETE CASCADE`. Auth deletion may be blocked by AI-generation rows unless these references are handled intentionally first.
- `chat_message_versions.edited_by -> profiles.id` uses default NO ACTION behavior; the column is nullable.
- `characters.author_id -> profiles.id ON DELETE CASCADE`; `conversations.user_id -> profiles.id ON DELETE CASCADE`; wallet account/transaction rows cascade from profiles. These cascades may remove content or transaction history and must be reconciled with retention requirements.
- `character_stories.character_id -> characters.id ON DELETE CASCADE`; `conversations.story_id -> character_stories.id ON DELETE CASCADE`.
- This remains a focused inventory, not proof that every user-linked table has been accounted for.

## Blockers before coding the deletion worker
1. Complete inventory of all user-linked tables, foreign keys, RLS policies, triggers, and uses of `account_is_active()`.
2. Product decision for creator-owned characters and stories: delete, transfer, anonymize, or retain.
3. Retention/access policy for chat contents, AI-generation logs, wallet transactions, and archive payloads.
4. Explicit lifecycle states and audited recovery for legacy expired requests.
5. Separate production 30-day timing from a controlled five-minute test configuration.
6. Dry-run-only processor first; do not call Auth Admin delete or remove source rows in the initial repair.
7. Test only with a disposable account after the design and migration are reviewed.

## No-go conditions
- Do not ask the user to repeat the five-minute test until there is a safe recovery path and a dry-run proves what would change.
- Do not enable a scheduled deletion worker while retention decisions, complete FK handling, and failure recovery remain unresolved.
