# Account Deletion Read-only Audit Notes

Date: 2026-10-15
Scope: live Supabase metadata and GitHub `main` frontend source. No database writes were performed.

## Frontend behavior
- `index.html` calls `get_account_deletion_status()` during account initialization and displays a pending-deletion modal when the RPC reports a request.
- A pending account is blocked from most UI actions by a client-side action allowlist. The same file calls `request_account_deletion()` and `cancel_account_deletion()`.
- Client-side gating alone is not a security boundary. Database mutations and any backend endpoints must independently enforce the active-account rule where appropriate.
- The frontend currently presents a 30-day deletion period in its confirmation text. The five-minute schedule appears to be a test configuration, so the production duration and test duration must be explicitly separated rather than silently conflated.

## Current RPC behavior confirmed from live definitions
- `request_account_deletion()`: authenticated user only; inserts a request and uses `ON CONFLICT (user_id) DO NOTHING`, then returns the existing row. It does not refresh an expired row.
- `cancel_account_deletion()`: authenticated user only; deletes the row only when its deadline is still in the future. An expired request cannot be cancelled through this RPC.
- `get_account_deletion_status()`: reports whether the current authenticated user's request row exists; it does not distinguish pending, expired, archived, or failed states.
- `account_is_active()`: returns false whenever a request row exists, even if the deadline has passed. It must be reviewed wherever used by RLS policies or RPCs.
- `archive_account_deletion_data(p_user_id)`: checks that the target has an expired request, archives AI-generation rows and wallet transactions, and marks the batch `archived`. It does not delete source rows or the Auth user. It is not a full deletion processor.

## RLS finding requiring priority review
- Three tables have an `account_must_be_active` permissive policy that checks `account_is_active()`, but the same tables also have a separate permissive `ALL` policy for the owner with no active-account condition: `characters`, `character_stories`, and `conversations`.
- PostgreSQL combines permissive policies with OR. Therefore, the active-account policy can be bypassed by the owner policy on those tables; the frontend block is not enough to guarantee a pending-deletion account cannot mutate data through the Data API.
- This must be corrected by safely consolidating/adjusting policies or adding active-account checks to the owner policies, after reviewing each table's intended public-read and owner-write behavior. Do not blanket-replace policies or change them without a table-by-table check.
- The `messages` table's reported policy was `account_must_be_active`; no parallel owner `ALL` policy appeared in this query. `chat_sessions`, `chat_messages`, `chat_message_versions`, and `ai_generation_records` have active-account checks directly in their relevant policies. Each table must still be checked independently.

## FK inventory relevant to eventual deletion
- `ai_generation_records.user_id -> profiles.id` has the default NO ACTION behavior and is NOT NULL.
- `ai_generation_records.session_id -> chat_sessions.id` and its message references have default NO ACTION behavior. Meanwhile `chat_sessions.user_id -> auth.users.id ON DELETE CASCADE`, and `chat_messages.session_id -> chat_sessions.id ON DELETE CASCADE`. Deleting an Auth user can therefore encounter FK blockers from AI-generation rows unless these relations are deliberately handled first.
- `chat_message_versions.edited_by -> profiles.id` has default NO ACTION behavior; the column is nullable.
- `characters.author_id -> profiles.id ON DELETE CASCADE`; `conversations.user_id -> profiles.id ON DELETE CASCADE`; wallet account/transaction rows cascade from profiles. Cascades can destroy content or transaction history and must be weighed against retention requirements.
- `character_stories.character_id -> characters.id ON DELETE CASCADE`; `conversations.story_id -> character_stories.id ON DELETE CASCADE`.
- This is a focused inventory, not a claim that every user-related table has been accounted for.

## Blockers before coding the deletion worker
1. Inventory all FK constraints, RLS policies, triggers, and every use of `account_is_active()`.
2. Decide product policy for user-created characters and stories: delete, transfer, anonymize, or retain. Existing cascade rules can delete these implicitly.
3. Decide retention and access controls for chat contents, AI-generation logs, wallet transactions, and archived payloads.
4. Define distinct request/processing states and explicit recovery for legacy expired requests.
5. Implement a dry-run-only processor first; do not call Auth Admin delete or remove source rows in the initial repair.
6. Test only with a disposable account after the migration and worker are reviewed.

## No-go conditions
- Do not ask the user to resubmit the five-minute test until the request lifecycle has a safe recovery path and a dry-run verifies what would be changed.
- Do not enable a scheduled deletion worker while retention decisions or FK handling remain unresolved.
