BEGIN;

DO $review_contract$
DECLARE
  v_constraint text;
  v_definition text;
  v_review_branch text;
BEGIN
  SELECT pg_catalog.pg_get_constraintdef(c.oid)
  INTO v_constraint
  FROM pg_catalog.pg_constraint c
  WHERE c.conrelid = 'public.encounter_schedule_generation_jobs'::regclass
    AND c.conname = 'encounter_schedule_generation_jobs_status_check';

  IF v_constraint IS NULL OR position('needs_review' IN v_constraint) = 0 THEN
    RAISE EXCEPTION 'worldview_manual_review_status_constraint_missing';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  IF position('worldview_manual_review_required' IN v_definition) = 0
     OR position('needs_review' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'worldview_manual_review_publisher_branch_missing';
  END IF;

  v_review_branch := pg_catalog.substr(
    v_definition,
    pg_catalog.strpos(v_definition, 'IF v_placement = ''needs_review'' THEN'),
    pg_catalog.strpos(v_definition, 'IF v_placement = ''no_matching_location'' THEN')
      - pg_catalog.strpos(v_definition, 'IF v_placement = ''needs_review'' THEN')
  );

  IF v_review_branch = '' OR
     position('character_schedules' IN v_review_branch) > 0 OR
     position('encounter_character_greeting_pools' IN v_review_branch) > 0 THEN
    RAISE EXCEPTION 'worldview_manual_review_must_preserve_existing_schedule_data';
  END IF;

  IF position('status IN (''pending'', ''failed'', ''needs_reconciliation'')' IN
       pg_catalog.pg_get_functiondef('public.claim_encounter_schedule_batch(integer,boolean,uuid)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'needs_review_must_not_be_automatically_reclaimed';
  END IF;
END;
$review_contract$;

ROLLBACK;
