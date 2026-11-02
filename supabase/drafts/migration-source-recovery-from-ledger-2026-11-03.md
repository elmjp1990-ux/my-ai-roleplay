# Migration source recovery from the live test ledger — 2026-11-03

## Method

The connected test project exposes `supabase_migrations.schema_migrations.statements` as a text array. A read-only catalog query confirmed the columns `version`, `name`, `statements`, `created_by`, `idempotency_key`, and `rollback`.

For each migration below, `array_length(statements, 1) = 1`. The SQL statement body was read from the already-applied ledger row and restored into the repository under its recorded 14-digit version and migration name. No migration was applied, repaired, or re-run.

Important provenance limitation: the ledger stores executable statements, not necessarily the original source file's comments/formatting. These restored files are therefore exact recorded SQL statement bodies (with source comments/formatting not guaranteed), not byte-for-byte Git source recovery. The migration version/name and SQL behavior are grounded in the connected test project's ledger.

## Restored from the ledger

| Migration | Restored file | Purpose |
|---|---|---|
| `20261015083242 make_account_deletion_archive_idempotent` | `supabase/migrations/20261015083242_make_account_deletion_archive_idempotent.sql` | Idempotent archive of AI generation and wallet transaction evidence |
| `20261015084226 allow_safe_recovery_before_deletion_processing` | `supabase/migrations/20261015084226_allow_safe_recovery_before_deletion_processing.sql` | Cancel account deletion safely before archive/deletion processing starts |
| `20261018015631 guard_character_rpcs_during_deletion` | `supabase/migrations/20261018015631_guard_character_rpcs_during_deletion.sql` | Account-active and author checks for character delete/snapshot RPCs |
| `20261022094147 delete_chat_group_with_related_data` | `supabase/migrations/20261022094147_delete_chat_group_with_related_data.sql` | Historical group-chat deletion RPC (immediate relational deletion) |
| `20261022094349 delete_chat_session_content` | `supabase/migrations/20261022094349_delete_chat_session_content.sql` | Historical single-chat deletion RPC (immediate content redaction) |
| `20261024002459 guard_memory_photo_delete_during_pending_account_deletion` | `supabase/migrations/20261024002459_guard_memory_photo_delete_during_pending_account_deletion.sql` | Prevent chat-memory photo deletion while account deletion is pending |
| `20261101110211 account_deletion_character_video_storage_gates` | `supabase/migrations/20261101110211_account_deletion_character_video_storage_gates.sql` | Character-avatar-video Storage insert/update policies require owner path and active account |

## Safety / ordering notes

- The two 2026-10-22 chat deletion migrations are historical function definitions. The later 2026-11-01 chat soft-delete lifecycle migrations replace their immediate-delete behavior with the approved shared 30-day queue. Restoring the historical source does not mean the old functions should be reintroduced or called as the current product behavior.
- The 2026-10-18 character RPC guard is the earlier soft-delete implementation; PR #200's history-aware deletion draft is a later proposed replacement and is not yet an active migration.
- The 2026-11-01 account video Storage policy migration was present in the remote ledger but absent from the repository; its recorded SQL is now restored.
- These seven files use versions already recorded in the connected test project's ledger. Do not re-apply them to that project.
- The repository still has five timestamp collision values and five legacy files without 14-digit versions. The original `profiles` / `characters` pre-ledger foundation remains unavailable. Full historical clean replay remains blocked; do not use a hosted `db push`, `db reset`, or migration repair to paper over it.
- Use the synthetic current-state fixture only for disposable schema/DML/rollback tests; it is not a historical migration chain.

## Verification

- Source of truth: read-only `supabase_migrations.schema_migrations.statements` queries on project `ouyewoagbmtqehbofrje`.
- All seven versions/names were present in the 152-row live migration ledger at time of inspection.
- The restored SQL files were committed to PR #200. GitHub CI and disposable schema replay are being re-run after the restorations.
- No hosted database, Auth, Storage, Edge Function, or Cron state was modified.


## Additional chat access / billing source recovery

A second read-only pass recovered five more migration statement bodies relevant to the old-chat continuation and billing path:

| Migration | Restored file | Why it matters |
|---|---|---|
| `20261015130752 chat_session_character_access` | `supabase/migrations/20261015130752_chat_session_character_access.sql` | New chat INSERT is restricted to eligible characters; existing chat sessions are explicitly unaffected |
| `20261015133300 chat_turn_transaction_functions` | `supabase/migrations/20261015133300_chat_turn_transaction_functions.sql` | Original reserve/settle/refund transaction RPCs and assistant insert guard |
| `20261015134109 chat_turn_ledger_idempotency` | `supabase/migrations/20261015134109_chat_turn_ledger_idempotency.sql` | Wallet transaction idempotency unique index for chat turn charge/refund |
| `20261015145637 fix_reserve_chat_turn_conflict_target` | `supabase/migrations/20261015145637_fix_reserve_chat_turn_conflict_target.sql` | Correct primary-key conflict target in reserve RPC |
| `20261017100648 chat_turn_existing_retry_recovery_order` | `supabase/migrations/20261017100648_chat_turn_existing_retry_recovery_order.sql` | Lock/recover stable existing turn before validating user message visibility; supports idempotent retry |

All five versions/names exist in the connected test project's ledger and each has one stored SQL statement. These are historical sources only; later migrations may replace their function bodies. They are not being applied to the hosted test project.

Total migration SQL statement bodies recovered in this note: **12** (seven deletion/account/storage items plus five chat-access/billing items). The remaining timestamp collisions, legacy filenames, and pre-ledger foundation gap remain unchanged.
