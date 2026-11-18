BEGIN;

DO $worldview_review_decision_contract$
DECLARE
  v_review text;
  v_enqueue text;
  v_claim text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='encounter_schedule_generation_jobs'
      AND column_name='worldview_review_decision' AND data_type='text'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='encounter_schedule_generation_jobs'
      AND column_name='worldview_reviewed_by' AND data_type='uuid'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='encounter_schedule_generation_jobs'
      AND column_name='worldview_reviewed_at' AND data_type='timestamp with time zone'
  ) THEN
    RAISE EXCEPTION 'worldview_review_decision_columns_missing';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.review_encounter_schedule_worldview(uuid,text)'::regprocedure
  ) INTO v_review;
  SELECT pg_catalog.pg_get_functiondef(
    'public.enqueue_encounter_schedule_generation_internal(uuid)'::regprocedure
  ) INTO v_enqueue;
  SELECT pg_catalog.pg_get_functiondef(
    'public.claim_encounter_schedule_batch(integer,boolean,uuid)'::regprocedure
  ) INTO v_claim;

  IF position('auth.uid()' IN v_review) = 0
     OR position('account_is_active()' IN v_review) = 0
     OR position('author_id = v_user_id' IN v_review) = 0
     OR position('status = ''needs_review''' IN v_review) = 0
     OR position('modern_map_compatible' IN v_review) = 0
     OR position('not_applicable' IN v_review) = 0
     OR position('last_completed_source_hash = v_job.source_hash' IN v_review) = 0
     OR position('existing_schedules_preserved' IN v_review) = 0
     OR position('ai_invoked' IN v_review) = 0 THEN
    RAISE EXCEPTION 'worldview_review_rpc_owner_or_decision_contract_missing';
  END IF;

  IF position('worldview_review_decision = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL' IN v_enqueue) = 0
     OR position('worldview_reviewed_by = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL' IN v_enqueue) = 0
     OR position('worldview_reviewed_at = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL' IN v_enqueue) = 0 THEN
    RAISE EXCEPTION 'worldview_review_override_not_cleared_when_source_changes';
  END IF;

  IF position('p_force IS NOT TRUE OR j.author_id = p_actor_user_id' IN v_claim) = 0
     OR position('worldview_review_decision' IN v_claim) = 0 THEN
    RAISE EXCEPTION 'worldview_review_claim_author_scope_or_override_missing';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.review_encounter_schedule_worldview(uuid,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.review_encounter_schedule_worldview(uuid,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'worldview_review_rpc_grants_invalid';
  END IF;
END;
$worldview_review_decision_contract$;

ROLLBACK;
