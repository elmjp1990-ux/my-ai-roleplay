# Account deletion rollout runbook

## Safety gate

Do not deploy or schedule the account-deletion worker until all three migrations have been applied in order, SQL checks pass, and a controlled test proves archive verification and Auth deletion recovery. The worker permanently deletes Auth users; never test it against an account that must be retained.

## Environment-specific grace period

After applying `20261017010841_account_deletion_grace_period_config.sql`, configure exactly one row per Supabase environment using the SQL editor:

Test environment (short test window):
```sql
INSERT INTO public.account_deletion_settings (singleton, grace_period)
VALUES (true, interval '5 minutes')
ON CONFLICT (singleton) DO UPDATE
SET grace_period = EXCLUDED.grace_period,
    updated_at = pg_catalog.statement_timestamp();
```

Production environment (long cancellation window):
```sql
INSERT INTO public.account_deletion_settings (singleton, grace_period)
VALUES (true, interval '30 days')
ON CONFLICT (singleton) DO UPDATE
SET grace_period = EXCLUDED.grace_period,
    updated_at = pg_catalog.statement_timestamp();
```

Never ship the test value into production. The migration intentionally does not seed a duration, and the request function fails closed until an environment-specific row exists.

## Worker activation (not yet enabled)

1. Deploy the migrations in order: group-history snapshot/FK fix, grace-period settings, worker RPCs.
2. Set the Edge Function secret `SUPABASE_SERVICE_ROLE_KEY`; never expose it to browser code.
3. Deploy `account-deletion-worker` and test wrong-method/unauthorized requests before any real deletion.
4. Use a disposable test account and verify archive item payloads/counts before enabling any schedule.
5. Only after explicit release approval, enable pg_cron + pg_net HTTP invocation. No cron job is created by these migrations.
6. Verify retry/idempotency and confirm other users' group history remains unchanged.

## Current known constraints

- Current database has pg_cron but does not have pg_net installed.
- Current project has no account-deletion worker Edge Function and no cron job.
- No deletion requests or archive batches were present at the last inspection.
