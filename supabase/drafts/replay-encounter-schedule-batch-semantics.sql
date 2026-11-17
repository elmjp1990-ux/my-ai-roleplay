-- Disposable local-only assertions for schedule batch cooldown and partial publishing.
-- No queue rows are inserted and no Hosted Supabase project is accessed.

BEGIN;

DO $schedule_batch_semantics$
DECLARE
  v_claim text := pg_catalog.pg_get_functiondef(
    'public.claim_encounter_schedule_batch(integer,boolean,uuid)'::regprocedure
  );
  v_publish text := pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  );
BEGIN
  IF pg_catalog.strpos(v_claim, 'interval ''24 hours''') = 0 THEN
    RAISE EXCEPTION 'schedule queue must trigger when the oldest pending job reaches 24 hours';
  END IF;
  IF pg_catalog.strpos(v_claim, 'MAX(b.completed_at)') = 0
     OR pg_catalog.strpos(v_claim, 'interval ''6 hours''') = 0 THEN
    RAISE EXCEPTION 'global cooldown must be measured from the previous successful completion';
  END IF;
  IF pg_catalog.strpos(v_claim, 'v_daily_count') > 0
     OR pg_catalog.strpos(v_claim, 'daily_limit') > 0
     OR pg_catalog.strpos(v_claim, 'v_last_started') > 0 THEN
    RAISE EXCEPTION 'daily execution cap or start-time cooldown remains in the claim function';
  END IF;
  IF pg_catalog.strpos(v_claim, 'LIMIT v_limit') = 0 THEN
    RAISE EXCEPTION 'claim function must claim the requested full pending queue size';
  END IF;
  IF pg_catalog.strpos(v_publish, 'schedule_batch_character_count_invalid') = 0
     OR pg_catalog.strpos(v_publish, 'remaining_character_count') = 0
     OR pg_catalog.strpos(v_publish, 'status'', CASE WHEN v_remaining_count = 0 THEN ''completed'' ELSE ''partial'' END') = 0 THEN
    RAISE EXCEPTION 'schedule publish function must support per-character partial commits';
  END IF;
END;
$schedule_batch_semantics$;

ROLLBACK;
