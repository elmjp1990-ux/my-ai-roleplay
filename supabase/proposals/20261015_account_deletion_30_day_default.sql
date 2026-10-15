-- PROPOSAL ONLY — do not apply to production without explicit approval.
-- Align new account-deletion requests with the 30-day promise shown in index.html.
-- This changes only the column default for future inserts; existing requests are untouched.
-- Do not use a 5-minute deadline in production.

begin;

alter table public.account_deletion_requests
  alter column scheduled_for
  set default (pg_catalog.statement_timestamp() + interval '30 days');

-- Verification after applying in a disposable project:
-- select column_default
-- from information_schema.columns
-- where table_schema = 'public'
--   and table_name = 'account_deletion_requests'
--   and column_name = 'scheduled_for';
--
-- Verify request_account_deletion() inserts only user_id and relies on this default.
-- Verify a new test request's scheduled_for is approximately 30 days after requested_at.
-- Existing scheduled_for values are intentionally not updated by this migration.

commit;
