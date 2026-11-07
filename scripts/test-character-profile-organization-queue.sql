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
END $$;

CREATE TEMP TABLE claimed_data (
  character_id uuid, author_id uuid, source_hash text, lease_token uuid,
  lease_generation bigint, lease_expires_at timestamptz, source_payload jsonb
);
GRANT ALL ON claimed_data TO service_role;

SELECT set_config('request.jwt.claim.role', 'service_role', false);
SET ROLE service_role;
INSERT INTO claimed_data SELECT * FROM public.claim_character_profile_organization_jobs(1);
RESET ROLE;

-- Change an AI source after claim. Completion must refuse the stale generation.
UPDATE public.characters
SET intro = '更新後的角色介紹。'
WHERE id = '11111111-1111-4111-8111-111111111111';

SET ROLE service_role;
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

SELECT set_config('request.jwt.claim.role', 'service_role', false);
SET ROLE service_role;
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

-- Soft delete must remove both queued work and private derived profile data.
UPDATE public.characters
SET deleted_at = now()
WHERE id = '11111111-1111-4111-8111-111111111111';
DO $
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
END $;

\echo 'Character AI Profile queue migration tests passed.'
