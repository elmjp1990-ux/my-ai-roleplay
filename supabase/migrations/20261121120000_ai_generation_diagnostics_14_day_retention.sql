-- Store every model response for short-lived, service-role-only diagnostics.
-- Raw generated text is retained for 14 days; prompts and player context are never stored.

BEGIN;

CREATE TABLE IF NOT EXISTS public.ai_generation_diagnostics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  generation_type text NOT NULL CHECK (generation_type IN (
    'story_chat', 'group_chat', 'encounter_chat', 'memory_summary',
    'character_profile', 'encounter_schedule', 'encounter_evaluation'
  )),
  status text NOT NULL DEFAULT 'received'
    CHECK (status IN ('received', 'completed', 'failed', 'partial')),
  user_id uuid,
  character_id uuid,
  session_id uuid,
  turn_id uuid,
  batch_number integer,
  source_ref text,
  model text,
  provider text,
  gateway_request_id text,
  http_status integer,
  finish_reason text,
  response_content_type text,
  response_body_length integer,
  response_parsed boolean,
  raw_output_text text,
  refusal_text text,
  failure_stage text,
  failure_code text,
  validation_errors jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(validation_errors) = 'array'),
  usage jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(usage) = 'object'),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '14 days')
);

CREATE INDEX IF NOT EXISTS ai_generation_diagnostics_created_idx
  ON public.ai_generation_diagnostics (created_at DESC);
CREATE INDEX IF NOT EXISTS ai_generation_diagnostics_type_created_idx
  ON public.ai_generation_diagnostics (generation_type, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_generation_diagnostics_session_idx
  ON public.ai_generation_diagnostics (session_id, created_at DESC)
  WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ai_generation_diagnostics_turn_idx
  ON public.ai_generation_diagnostics (turn_id)
  WHERE turn_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ai_generation_diagnostics_expiry_idx
  ON public.ai_generation_diagnostics (expires_at);

ALTER TABLE public.ai_generation_diagnostics ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_generation_diagnostics FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ai_generation_diagnostics TO service_role;

COMMENT ON TABLE public.ai_generation_diagnostics IS
  'Service-role-only short-lived audit of raw AI outputs and validation outcomes. Expires after 14 days; never stores prompts or player transcripts.';

CREATE OR REPLACE FUNCTION public.purge_expired_ai_generation_diagnostics()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_diagnostics_deleted integer := 0;
  v_schedule_revisions_deleted integer := 0;
  v_schedule_outputs_deleted integer := 0;
BEGIN
  DELETE FROM public.ai_generation_diagnostics
  WHERE expires_at <= pg_catalog.clock_timestamp();
  GET DIAGNOSTICS v_diagnostics_deleted = ROW_COUNT;

  -- Existing schedule-repair storage also contains raw model output. Keep its
  -- original/revision workflow available for the same 14-day diagnostic window.
  DELETE FROM public.encounter_schedule_generation_output_revisions r
  USING public.encounter_schedule_generation_outputs o
  WHERE r.output_id = o.id
    AND o.created_at < pg_catalog.clock_timestamp() - interval '14 days';
  GET DIAGNOSTICS v_schedule_revisions_deleted = ROW_COUNT;

  DELETE FROM public.encounter_schedule_generation_outputs
  WHERE created_at < pg_catalog.clock_timestamp() - interval '14 days';
  GET DIAGNOSTICS v_schedule_outputs_deleted = ROW_COUNT;

  RETURN pg_catalog.jsonb_build_object(
    'diagnostics_deleted', v_diagnostics_deleted,
    'schedule_revisions_deleted', v_schedule_revisions_deleted,
    'schedule_outputs_deleted', v_schedule_outputs_deleted
  );
END;
$$;

REVOKE ALL ON FUNCTION public.purge_expired_ai_generation_diagnostics()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_ai_generation_diagnostics()
  TO service_role;

DO $migration$
DECLARE
  v_job_id bigint;
BEGIN
  IF pg_catalog.to_regclass('cron.job') IS NULL
     OR pg_catalog.to_regprocedure('cron.schedule(text,text,text)') IS NULL
     OR pg_catalog.to_regprocedure('cron.unschedule(bigint)') IS NULL THEN
    RAISE EXCEPTION 'pg_cron_retention_prerequisites_missing';
  END IF;

  FOR v_job_id IN
    SELECT jobid FROM cron.job
    WHERE jobname = 'poyozz-ai-generation-diagnostics-purge'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'poyozz-ai-generation-diagnostics-purge',
    '23 3 * * *',
    'SELECT public.purge_expired_ai_generation_diagnostics();'
  );
END;
$migration$;

COMMIT;
