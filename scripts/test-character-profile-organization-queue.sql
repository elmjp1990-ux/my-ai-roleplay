\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS extensions;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.role', true), '')
$$;

CREATE TABLE auth.users (id uuid PRIMARY KEY);

CREATE TABLE public.characters (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL,
  intro text,
  race text,
  style text,
  deleted_at timestamptz
);
CREATE TABLE public.character_private_info (
  character_id uuid NOT NULL,
  author_id uuid NOT NULL,
  private_info text,
  personality_profile jsonb
);

INSERT INTO auth.users (id)
VALUES ('22222222-2222-4222-8222-222222222222');

\i supabase/migrations/20261107120000_character_ai_profile_organization_queue.sql
\i supabase/migrations/20261107123000_schedule_character_profile_organization_worker.sql
-- Replaying both migrations must be idempotent.
\i supabase/migrations/20261107120000_character_ai_profile_organization_queue.sql
\i supabase/migrations/20261107123000_schedule_character_profile_organization_worker.sql

INSERT INTO public.characters (id, author_id, intro, race, style)
VALUES (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '在台北工作的咖啡師。',
  '人類',
  '慢熟、謹慎'
);
INSERT INTO public.character_private_info (character_id, author_id, private_info, personality_profile)
VALUES (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '不願提起過去的失敗。',
  '{"coreTraits":"慢熟、謹慎","values":"重視承諾","speechStyle":"簡短直接","behaviorRules":"不輕易信任陌生人","likes":"手沖咖啡","dislikes":"失約","boundaries":"不接受欺騙","relationshipPacing":"需要時間建立信任"}'::jsonb
);

SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SET ROLE authenticated;
SELECT public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
SELECT public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
RESET ROLE;

-- A different authenticated user cannot enqueue another author's character.
SELECT set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
    RAISE EXCEPTION 'non-owner unexpectedly enqueued a character profile';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM * FROM public.claim_character_profile_organization_jobs(1);
    RAISE EXCEPTION 'authenticated unexpectedly claimed a profile job';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;

SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.character_profile_organization_jobs) <> 1 THEN
    RAISE EXCEPTION 'enqueue did not coalesce to one job per character';
  END IF;
  IF has_table_privilege('authenticated', 'public.character_profile_organization_jobs', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated can read private job queue';
  END IF;
  IF has_table_privilege('authenticated', 'public.character_profile_organization', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated can read private derived profile';
  END IF;
  IF has_table_privilege('authenticated', 'public.character_profile_organization_usage', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated can read private Profile usage ledger';
  END IF;
END $$;

CREATE TEMP TABLE claimed_data (
  character_id uuid, author_id uuid, source_hash text, lease_token uuid,
  lease_generation bigint, lease_expires_at timestamptz, source_payload jsonb
);
GRANT ALL ON claimed_data TO service_role;

SELECT set_config('request.jwt.claim.role', 'service_role', false);
SET ROLE service_role;
INSERT INTO claimed_data SELECT * FROM public.claim_character_profile_organization_jobs(1);
CREATE TEMP TABLE competing_claim AS
  SELECT * FROM public.claim_character_profile_organization_jobs(1);
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM competing_claim) THEN
    RAISE EXCEPTION 'a concurrent worker claimed a second profile job';
  END IF;
END $$;

-- Re-saving the exact same source while a Worker owns a lease must preserve
-- the lease token/generation and must not enqueue another model generation.
SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SET ROLE authenticated;
SELECT public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
RESET ROLE;
DO $$
DECLARE
  v_claim record;
  v_job public.character_profile_organization_jobs%ROWTYPE;
BEGIN
  SELECT * INTO v_claim FROM claimed_data LIMIT 1;
  SELECT * INTO v_job FROM public.character_profile_organization_jobs
  WHERE character_id = v_claim.character_id;
  IF v_job.status <> 'processing'
     OR v_job.lease_token IS DISTINCT FROM v_claim.lease_token
     OR v_job.lease_generation IS DISTINCT FROM v_claim.lease_generation THEN
    RAISE EXCEPTION 'same-source enqueue invalidated an active Worker lease';
  END IF;
END $$;

-- Change an AI source after claim. Completion must refuse the stale generation.
UPDATE public.characters
SET intro = '更新後的角色介紹。'
WHERE id = '11111111-1111-4111-8111-111111111111';

-- A changed source saved during processing is coalesced behind the current
-- Worker lease; it must not start a concurrent generation.
SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SET ROLE authenticated;
SELECT public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
RESET ROLE;
DO $$
DECLARE
  v_claim record;
  v_job public.character_profile_organization_jobs%ROWTYPE;
BEGIN
  SELECT * INTO v_claim FROM claimed_data LIMIT 1;
  SELECT * INTO v_job FROM public.character_profile_organization_jobs
  WHERE character_id = v_claim.character_id;
  IF v_job.status <> 'processing'
     OR v_job.lease_token IS DISTINCT FROM v_claim.lease_token
     OR v_job.lease_generation IS DISTINCT FROM v_claim.lease_generation
     OR v_job.source_hash = v_claim.source_hash THEN
    RAISE EXCEPTION 'changed-source enqueue did not preserve lease and coalesce latest source';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.role', 'service_role', false);
DO $$
DECLARE
  v_claim record;
  v_status text;
BEGIN
  SELECT * INTO v_claim FROM claimed_data LIMIT 1;
  IF v_claim.character_id IS NULL THEN RAISE EXCEPTION 'worker failed to claim a job'; END IF;
  v_status := public.complete_character_profile_organization_job(
    v_claim.character_id, v_claim.lease_token, v_claim.lease_generation,
    v_claim.source_hash, '{"schema_version":"1.0"}'::jsonb
  );
  IF v_status <> 'stale_source' THEN
    RAISE EXCEPTION 'stale source was not rejected: %', v_status;
  END IF;
END $$;

-- The stale completion re-queues the latest source; the next claim can complete.
INSERT INTO claimed_data SELECT * FROM public.claim_character_profile_organization_jobs(1);
DO $$
DECLARE
  v_claim record;
  v_status text;
BEGIN
  SELECT * INTO v_claim FROM claimed_data ORDER BY lease_generation DESC LIMIT 1;
  v_status := public.complete_character_profile_organization_job(
    v_claim.character_id, v_claim.lease_token, v_claim.lease_generation,
    v_claim.source_hash, '{"schema_version":"1.0"}'::jsonb
  );
  IF v_status <> 'completed' THEN
    RAISE EXCEPTION 'fresh profile completion failed: %', v_status;
  END IF;
END $$;
RESET ROLE;

-- Unknown provider outcomes must stop automatic retries to avoid a possible
-- second bill when a timed-out request actually completed upstream.
DO $$
DECLARE
  v_job public.character_profile_organization_jobs%ROWTYPE;
  v_status text;
  v_claim_count integer;
BEGIN
  UPDATE public.character_profile_organization_jobs
  SET status = 'processing',
      lease_token = gen_random_uuid(),
      lease_generation = lease_generation + 1,
      lease_expires_at = now() + interval '3 minutes',
      lease_source_hash = source_hash
  WHERE character_id = '11111111-1111-4111-8111-111111111111'
  RETURNING * INTO v_job;

  v_status := public.fail_character_profile_organization_job(
    v_job.character_id, v_job.lease_token, v_job.lease_generation,
    'provider_outcome_unknown'
  );
  IF v_status <> 'failed' THEN
    RAISE EXCEPTION 'ambiguous provider outcome was automatically retried: %', v_status;
  END IF;

  SELECT count(*) INTO v_claim_count
  FROM public.claim_character_profile_organization_jobs(1);
  IF v_claim_count <> 0 THEN
    RAISE EXCEPTION 'terminal provider outcome remained automatically claimable';
  END IF;
END $$;

-- An explicit owner save is the supported manual retry path after a terminal
-- unknown provider outcome.
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SET ROLE authenticated;
SELECT public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
RESET ROLE;
DO $$
BEGIN
  IF (SELECT status FROM public.character_profile_organization_jobs
      WHERE character_id = '11111111-1111-4111-8111-111111111111') <> 'pending' THEN
    RAISE EXCEPTION 'explicit owner save did not requeue terminal failed job';
  END IF;
END $$;

-- A database persistence failure after a successful provider response is
-- terminal: the same paid generation must not be automatically requested again.
SELECT set_config('request.jwt.claim.role', 'service_role', false);
DO $$
DECLARE
  v_job public.character_profile_organization_jobs%ROWTYPE;
  v_status text;
  v_claim_count integer;
BEGIN
  UPDATE public.character_profile_organization_jobs
  SET status = 'processing',
      lease_token = gen_random_uuid(),
      lease_generation = lease_generation + 1,
      lease_expires_at = now() + interval '3 minutes',
      lease_source_hash = source_hash
  WHERE character_id = '11111111-1111-4111-8111-111111111111'
  RETURNING * INTO v_job;

  v_status := public.fail_character_profile_organization_job(
    v_job.character_id, v_job.lease_token, v_job.lease_generation,
    'profile_persistence_failed_after_generation'
  );
  IF v_status <> 'failed' THEN
    RAISE EXCEPTION 'post-generation persistence failure was not terminal: %', v_status;
  END IF;

  SELECT count(*) INTO v_claim_count
  FROM public.claim_character_profile_organization_jobs(1);
  IF v_claim_count <> 0 THEN
    RAISE EXCEPTION 'post-generation persistence failure was automatically regenerated';
  END IF;

  UPDATE public.character_profile_organization_jobs
  SET status = 'processing',
      lease_token = gen_random_uuid(),
      lease_generation = lease_generation + 1,
      lease_expires_at = now() + interval '3 minutes',
      lease_source_hash = source_hash
  WHERE character_id = '11111111-1111-4111-8111-111111111111'
  RETURNING * INTO v_job;

  v_status := public.fail_character_profile_organization_job(
    v_job.character_id, v_job.lease_token, v_job.lease_generation,
    'profile_schema_invalid_profile_output_too_large'
  );
  IF v_status <> 'failed' THEN
    RAISE EXCEPTION 'invalid paid model output was automatically retried: %', v_status;
  END IF;
END $;

-- An expired Worker lease is also ambiguous and must become terminal rather
-- than being reclaimed by the next cron invocation.
DO $$
DECLARE
  v_claim_count integer;
  v_status text;
  v_error text;
BEGIN
  UPDATE public.character_profile_organization_jobs
  SET status = 'processing',
      lease_token = gen_random_uuid(),
      lease_generation = lease_generation + 1,
      lease_expires_at = now() - interval '1 second',
      lease_source_hash = source_hash
  WHERE character_id = '11111111-1111-4111-8111-111111111111';

  SELECT count(*) INTO v_claim_count
  FROM public.claim_character_profile_organization_jobs(1);
  SELECT status, last_error_code INTO v_status, v_error
  FROM public.character_profile_organization_jobs
  WHERE character_id = '11111111-1111-4111-8111-111111111111';
  IF v_claim_count <> 0 OR v_status <> 'failed'
     OR v_error <> 'worker_lease_expired_manual_retry' THEN
    RAISE EXCEPTION 'expired lease was automatically reclaimed: %, %, %', v_claim_count, v_status, v_error;
  END IF;
END $$;

-- Explicit owner save is still the recovery path for terminal jobs.
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SET ROLE authenticated;
SELECT public.enqueue_character_profile_organization('11111111-1111-4111-8111-111111111111');
RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', false);

INSERT INTO public.character_profile_organization_usage (
  character_id, author_id, source_hash, model, provider,
  prompt_tokens, completion_tokens, total_tokens, cost_usd, status
)
SELECT character_id, author_id, source_hash,
  'deepseek/deepseek-v4-flash-20260423', 'deepinfra',
  123, 45, 168, 0.000123, 'generated'
FROM claimed_data
ORDER BY lease_generation DESC
LIMIT 1;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.character_profile_organization_usage) <> 1 THEN
    RAISE EXCEPTION 'Profile generation usage was not recorded';
  END IF;
  IF (SELECT cost_usd FROM public.character_profile_organization_usage LIMIT 1) <> 0.000123 THEN
    RAISE EXCEPTION 'Profile generation cost was not preserved';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.role', 'service_role', false);
DO $$
DECLARE
  v_profile jsonb;
BEGIN
  v_profile := public.get_character_ai_profile_for_chat(
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
  );
  IF v_profile IS NULL OR v_profile ->> 'schema_version' <> '1.0' THEN
    RAISE EXCEPTION 'current source-matched profile was not returned';
  END IF;
END $$;
RESET ROLE;

-- Oversized creator source must be replaced with a small sentinel inside
-- Postgres, so the full private text is never returned to the Worker.
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  UPDATE public.characters
  SET intro = repeat('字', 70000)
  WHERE id = '11111111-1111-4111-8111-111111111111';
  v_payload := public.character_profile_source_payload(
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
  );
  IF v_payload <> '{"__profile_source_error":"source_payload_too_large"}'::jsonb THEN
    RAISE EXCEPTION 'oversized source payload was returned instead of a safe sentinel';
  END IF;
END $$;

-- Soft delete must remove both queued work and private derived profile data.
UPDATE public.characters
SET deleted_at = now()
WHERE id = '11111111-1111-4111-8111-111111111111';
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.character_profile_organization_jobs
    WHERE character_id = '11111111-1111-4111-8111-111111111111'
  ) THEN
    RAISE EXCEPTION 'soft-deleted character retained a profile queue job';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.character_profile_organization
    WHERE character_id = '11111111-1111-4111-8111-111111111111'
  ) THEN
    RAISE EXCEPTION 'soft-deleted character retained a derived profile';
  END IF;
END $$;

\echo 'Character AI Profile queue migration tests passed.'
