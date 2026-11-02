-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Schedules the deployed purge-chat-deletions Edge Function every five minutes,
-- but only when a due chat purge or Storage deletion retry exists.
-- Do not apply until the deployed function version and worker tests are accepted.
--
-- Read-only preflight on 2026-11-02:
--   - pg_cron and pg_net are installed.
--   - Vault contains chat_deletion_worker_service_role_key.
--   - The Vault value is a Supabase Secret API key (sb_secret_...), suitable for
--     the deployed withSupabase({ auth: "secret:default" }) worker.
--   - No chat deletion purge cron currently exists in cron.job.
--
-- The worker is already deployed as purge-chat-deletions with verify_jwt=false;
-- it authenticates the Supabase Secret API key via @supabase/server. The key is
-- sent only in the apikey header and is never stored in this SQL file.
--
-- Idempotency: cron.schedule with this unique job name replaces the same named
-- job rather than creating duplicates. No rows are purged by this schedule SQL;
-- the worker's RPCs enforce purge_after, leases, owner/resource matching and
-- retry limits.

DO $preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE name = 'chat_deletion_worker_service_role_key'
      AND decrypted_secret LIKE 'sb_secret_%'
  ) THEN
    RAISE EXCEPTION 'chat_deletion_worker_secret_missing_or_wrong_type';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_net'
  ) THEN
    RAISE EXCEPTION 'chat_deletion_scheduler_extensions_missing';
  END IF;
END;
$preflight$;

SELECT cron.schedule(
  'poyozz-chat-deletion-purge',
  '*/5 * * * *',
  $job$
    SELECT net.http_post(
      url := 'https://ouyewoagbmtqehbofrje.supabase.co/functions/v1/purge-chat-deletions',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', (
          SELECT decrypted_secret
          FROM vault.decrypted_secrets
          WHERE name = 'chat_deletion_worker_service_role_key'
        )
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 30000
    ) AS request_id
    WHERE EXISTS (
      SELECT 1
      FROM public.chat_deletion_jobs AS j
      WHERE j.purge_after <= clock_timestamp()
        AND j.attempt_count < 8
        AND (
          (j.status IN ('queued', 'retry')
            AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= clock_timestamp()))
          OR
          (j.status = 'processing' AND j.lease_until <= clock_timestamp())
        )
    )
    OR EXISTS (
      SELECT 1
      FROM public.chat_storage_deletion_jobs AS sj
      JOIN public.chat_deletion_jobs AS dj
        ON dj.id = sj.deletion_job_id
      WHERE dj.status = 'completed'
        AND dj.purge_after <= clock_timestamp()
        AND sj.attempt_count < 8
        AND (
          (sj.status IN ('queued', 'retry')
            AND (sj.next_attempt_at IS NULL OR sj.next_attempt_at <= clock_timestamp()))
          OR
          (sj.status = 'processing' AND sj.lease_until <= clock_timestamp())
        )
    );
  $job$
);

-- Rollback (only after confirming the exact job name):
-- SELECT cron.unschedule('poyozz-chat-deletion-purge');
