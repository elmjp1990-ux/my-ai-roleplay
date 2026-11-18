BEGIN;

-- Keep the original model response private and separate from human corrections.
CREATE TABLE IF NOT EXISTS public.encounter_schedule_generation_outputs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.encounter_schedule_batch_runs(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  source_hash text,
  requested_model text NOT NULL,
  provider text NOT NULL DEFAULT 'openrouter',
  response_model text,
  finish_reason text,
  raw_response_text text,
  raw_response_body text,
  response_body_truncated boolean NOT NULL DEFAULT false,
  http_status integer,
  response_content_type text,
  response_parsed boolean NOT NULL DEFAULT true,
  usage jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'received',
  failure_code text,
  validation_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  expires_at timestamptz NOT NULL DEFAULT (pg_catalog.now() + interval '30 days'),
  UNIQUE (batch_id, character_id),
  CHECK (pg_catalog.char_length(COALESCE(raw_response_text, '')) <= 500000),
  CHECK (pg_catalog.char_length(COALESCE(raw_response_body, '')) <= 250000)
);

CREATE INDEX IF NOT EXISTS encounter_schedule_generation_outputs_actor_idx
  ON public.encounter_schedule_generation_outputs (actor_user_id, created_at DESC)
  WHERE actor_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS encounter_schedule_generation_outputs_expiry_idx
  ON public.encounter_schedule_generation_outputs (expires_at);

CREATE TABLE IF NOT EXISTS public.encounter_schedule_generation_output_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  output_id uuid NOT NULL REFERENCES public.encounter_schedule_generation_outputs(id) ON DELETE CASCADE,
  corrected_response_text text NOT NULL,
  validation_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'invalid'
    CHECK (status IN ('invalid', 'validated', 'published', 'publish_failed', 'needs_reconciliation')),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  published_at timestamptz,
  CHECK (pg_catalog.char_length(corrected_response_text) BETWEEN 2 AND 500000)
);

CREATE INDEX IF NOT EXISTS encounter_schedule_output_revisions_output_idx
  ON public.encounter_schedule_generation_output_revisions (output_id, created_at DESC);

ALTER TABLE public.encounter_schedule_generation_outputs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_generation_output_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_schedule_generation_outputs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_generation_output_revisions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_outputs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_output_revisions TO service_role;

COMMENT ON TABLE public.encounter_schedule_generation_outputs IS
  'Private, time-bounded original Encounter schedule AI responses and provider diagnostics. Accessible only to service_role through the test-only organizer endpoint.';
COMMENT ON TABLE public.encounter_schedule_generation_output_revisions IS
  'Append-only human correction submissions for Encounter schedule AI outputs; the original model response is retained separately.';

CREATE OR REPLACE FUNCTION public.claim_encounter_schedule_repair(
  p_original_batch_id uuid,
  p_character_id uuid,
  p_actor_user_id uuid,
  p_expected_source_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_original public.encounter_schedule_batch_runs%ROWTYPE;
  v_job public.encounter_schedule_generation_jobs%ROWTYPE;
  v_source jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_lease uuid := gen_random_uuid();
  v_batch uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_original
  FROM public.encounter_schedule_batch_runs b
  WHERE b.id = p_original_batch_id
    AND b.is_manual IS TRUE
    AND b.actor_user_id = p_actor_user_id
    AND p_character_id = ANY(b.character_ids)
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_repair_original_batch_not_found' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job
  FROM public.encounter_schedule_generation_jobs j
  WHERE j.character_id = p_character_id
    AND j.status = 'failed'
    AND j.source_hash = p_expected_source_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_repair_job_not_failed_or_source_changed' USING ERRCODE = '40001';
  END IF;

  v_source := public.encounter_schedule_source_payload(p_character_id);
  IF v_source IS NULL OR pg_catalog.md5(v_source::text) IS DISTINCT FROM v_job.source_hash THEN
    RAISE EXCEPTION 'schedule_repair_source_changed_or_ineligible' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.encounter_schedule_batch_runs (
    lease_token, status, character_ids, actor_user_id, is_manual, started_at, updated_at
  ) VALUES (
    v_lease, 'processing', ARRAY[p_character_id], p_actor_user_id, true, v_now, v_now
  )
  RETURNING id INTO v_batch;

  UPDATE public.encounter_schedule_generation_jobs
  SET status = 'processing',
      lease_token = v_lease,
      lease_expires_at = v_now + interval '20 minutes',
      lease_generation = lease_generation + 1,
      updated_at = v_now
  WHERE character_id = p_character_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'claimed',
    'batch_id', v_batch,
    'lease_token', v_lease
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_encounter_schedule_repair(uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_schedule_repair(uuid, uuid, uuid, text)
  TO service_role;

COMMIT;
