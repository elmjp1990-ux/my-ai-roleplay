CREATE OR REPLACE FUNCTION public.record_encounter_session_turn_evidence(
  p_turn_id uuid,
  p_session_id uuid,
  p_user_id uuid,
  p_character_id uuid,
  p_user_message_id uuid,
  p_assistant_message_id uuid,
  p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  c public.chat_turn_charges%ROWTYPE;
  um public.chat_messages%ROWTYPE;
  am public.chat_messages%ROWTYPE;
  oldrow public.encounter_session_turns%ROWTYPE;
  n integer;
BEGIN
  IF p_turn_id IS NULL OR p_session_id IS NULL OR p_user_id IS NULL
     OR p_character_id IS NULL OR p_user_message_id IS NULL
     OR p_assistant_message_id IS NULL
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 8000 THEN
    RAISE EXCEPTION 'Invalid evidence input' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id
     OR l.character_id IS DISTINCT FROM p_character_id
     OR l.status NOT IN ('active','paused','ready_to_settle') THEN
    RAISE EXCEPTION 'Invalid Encounter lifecycle' USING ERRCODE='23514';
  END IF;

  SELECT * INTO c
  FROM public.chat_turn_charges
  WHERE turn_id=p_turn_id
  FOR SHARE;

  IF NOT FOUND OR c.session_id IS DISTINCT FROM p_session_id
     OR c.user_id IS DISTINCT FROM p_user_id
     OR c.status <> 'settled'
     OR c.user_message_id IS DISTINCT FROM p_user_message_id
     OR c.assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR c.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR (
       l.status='ready_to_settle'
       AND (c.reserved_at IS NULL OR c.reserved_at > l.scheduled_end_at)
     ) THEN
    RAISE EXCEPTION 'Charge evidence mismatch, post-end reservation, or unsettled charge'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO um FROM public.chat_messages WHERE id=p_user_message_id FOR SHARE;
  IF NOT FOUND OR um.session_id IS DISTINCT FROM p_session_id
     OR um.role <> 'user' OR um.deleted_at IS NOT NULL
     OR length(btrim(um.content))=0 THEN
    RAISE EXCEPTION 'Invalid user message evidence' USING ERRCODE='23514';
  END IF;

  SELECT * INTO am FROM public.chat_messages WHERE id=p_assistant_message_id FOR SHARE;
  IF NOT FOUND OR am.session_id IS DISTINCT FROM p_session_id
     OR am.role <> 'assistant' OR am.deleted_at IS NOT NULL
     OR length(btrim(am.content))=0 THEN
    RAISE EXCEPTION 'Invalid assistant message evidence' USING ERRCODE='23514';
  END IF;

  SELECT * INTO oldrow FROM public.encounter_session_turns WHERE turn_id=p_turn_id;
  IF FOUND THEN
    IF oldrow.session_id IS DISTINCT FROM p_session_id
       OR oldrow.user_id IS DISTINCT FROM p_user_id
       OR oldrow.character_id IS DISTINCT FROM p_character_id
       OR oldrow.user_message_id IS DISTINCT FROM p_user_message_id
       OR oldrow.assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN
      RAISE EXCEPTION 'Evidence idempotency collision' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object(
      'turn_id',oldrow.turn_id,'turn_number',oldrow.turn_number,
      'status',oldrow.evaluation_status,'idempotent',true
    );
  END IF;

  n := l.turn_count+1;
  INSERT INTO public.encounter_session_turns(
    turn_id,session_id,user_id,character_id,user_message_id,assistant_message_id,
    turn_number,evaluation_status,evaluation
  ) VALUES (
    p_turn_id,p_session_id,p_user_id,p_character_id,p_user_message_id,p_assistant_message_id,
    n,'pending',COALESCE(p_evaluation,'{}'::jsonb)
  );
  UPDATE public.encounter_session_lifecycle
  SET turn_count=n,updated_at=pg_catalog.clock_timestamp()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('turn_id',p_turn_id,'turn_number',n,'status','pending','idempotent',false);
END;
$$;

REVOKE ALL ON FUNCTION public.record_encounter_session_turn_evidence(uuid,uuid,uuid,uuid,uuid,uuid,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_encounter_session_turn_evidence(uuid,uuid,uuid,uuid,uuid,uuid,jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_due_encounter_evaluations(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_enqueued integer := 0;
  v_rows integer := 0;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit,50),1),100);
BEGIN
  FOR l IN
    SELECT lifecycle.*
    FROM public.encounter_session_lifecycle AS lifecycle
    WHERE lifecycle.status IN ('active','paused','ready_to_settle')
      AND lifecycle.character_id IS NOT NULL
      AND lifecycle.scheduled_end_at <= pg_catalog.clock_timestamp()
    ORDER BY lifecycle.scheduled_end_at,lifecycle.session_id
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.chat_turn_charges AS charge
      WHERE charge.session_id=l.session_id
        AND charge.status IN ('created','reserved','needs_reconciliation')
    ) OR EXISTS (
      SELECT 1
      FROM public.chat_turn_charges AS charge
      WHERE charge.session_id=l.session_id
        AND charge.status='settled'
        AND NOT EXISTS (
          SELECT 1 FROM public.encounter_session_turns AS turn
          WHERE turn.turn_id=charge.turn_id
        )
    ) THEN
      CONTINUE;
    END IF;

    IF (
      SELECT count(*) FROM public.encounter_session_turns AS turn
      WHERE turn.session_id=l.session_id
    ) <> l.turn_count THEN
      CONTINUE;
    END IF;

    UPDATE public.encounter_session_lifecycle
    SET status='ready_to_settle',updated_at=pg_catalog.clock_timestamp()
    WHERE session_id=l.session_id
      AND status IN ('active','paused','ready_to_settle');

    INSERT INTO public.encounter_session_evaluation_jobs(session_id,user_id,character_id,status)
    VALUES(l.session_id,l.user_id,l.character_id,'pending')
    ON CONFLICT (session_id) DO UPDATE
      SET status='pending',claimed_at=NULL,completed_at=NULL,last_error=NULL,
          updated_at=pg_catalog.clock_timestamp()
      WHERE public.encounter_session_evaluation_jobs.status='failed'
        AND public.encounter_session_evaluation_jobs.attempt_count < 5
        AND public.encounter_session_evaluation_jobs.updated_at
          <= pg_catalog.clock_timestamp()-interval '5 minutes';

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_enqueued := v_enqueued + v_rows;
  END LOOP;

  RETURN v_enqueued;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_due_encounter_evaluations(integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_due_encounter_evaluations(integer)
  TO service_role;

CREATE OR REPLACE FUNCTION public.claim_encounter_evaluation_jobs(p_limit integer DEFAULT 10)
RETURNS TABLE(
  session_id uuid,
  user_id uuid,
  character_id uuid,
  turn_count integer,
  attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit,10),1),25);
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT job.session_id
    FROM public.encounter_session_evaluation_jobs AS job
    JOIN public.encounter_session_lifecycle AS lifecycle
      ON lifecycle.session_id=job.session_id
    WHERE lifecycle.status='ready_to_settle'
      AND lifecycle.scheduled_end_at <= pg_catalog.clock_timestamp()
      AND job.attempt_count < 5
      AND (
        job.status='pending'
        OR (
          job.status='failed'
          AND job.updated_at <= pg_catalog.clock_timestamp()-interval '5 minutes'
        )
        OR (
          job.status='processing'
          AND job.claimed_at < pg_catalog.clock_timestamp()-interval '10 minutes'
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.chat_turn_charges AS charge
        WHERE charge.session_id=job.session_id
          AND charge.status IN ('created','reserved','needs_reconciliation')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.chat_turn_charges AS charge
        WHERE charge.session_id=job.session_id
          AND charge.status='settled'
          AND NOT EXISTS (
            SELECT 1 FROM public.encounter_session_turns AS turn
            WHERE turn.turn_id=charge.turn_id
          )
      )
      AND (
        SELECT count(*) FROM public.encounter_session_turns AS turn
        WHERE turn.session_id=job.session_id
      ) = lifecycle.turn_count
    ORDER BY lifecycle.scheduled_end_at,job.session_id
    FOR UPDATE OF job SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.encounter_session_evaluation_jobs AS job
  SET status='processing',attempt_count=job.attempt_count+1,
      claimed_at=pg_catalog.clock_timestamp(),completed_at=NULL,last_error=NULL,
      updated_at=pg_catalog.clock_timestamp()
  FROM candidates
  JOIN public.encounter_session_lifecycle AS lifecycle
    ON lifecycle.session_id=candidates.session_id
  WHERE job.session_id=candidates.session_id
  RETURNING job.session_id,job.user_id,job.character_id,lifecycle.turn_count,job.attempt_count;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_encounter_evaluation_jobs(integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_evaluation_jobs(integer)
  TO service_role;

COMMENT ON FUNCTION public.enqueue_due_encounter_evaluations(integer) IS
  'Queues only due Encounter sessions after all settled charges have corresponding turn evidence; never evaluates a transient zero-turn snapshot.';
COMMENT ON FUNCTION public.claim_encounter_evaluation_jobs(integer) IS
  'Claims due Encounter jobs only when no in-flight charges or settled-but-unrecorded turn evidence remain.';

CREATE OR REPLACE FUNCTION public.settle_encounter_session(
  p_session_id uuid,
  p_affinity_delta integer,
  p_relationship_stage text,
  p_memories jsonb DEFAULT '[]'::jsonb,
  p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_current integer := 0;
  v_final integer := 0;
  v_state_id uuid;
  v_result jsonb;
BEGIN
  IF p_session_id IS NULL
     OR p_affinity_delta IS NULL OR p_affinity_delta NOT BETWEEN -100 AND 100
     OR p_relationship_stage NOT IN ('hostile','dislike','wary','first_meeting','acquaintance','close','intimate','special')
     OR jsonb_typeof(COALESCE(p_memories,'[]'::jsonb)) <> 'array'
     OR pg_column_size(COALESCE(p_memories,'[]'::jsonb)) > 20000
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 12000 THEN
    RAISE EXCEPTION 'Invalid Encounter settlement payload' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter lifecycle not found' USING ERRCODE='P0002';
  END IF;

  IF l.status='settled' THEN
    RETURN jsonb_build_object('settled',true,'idempotent',true,'result',l.settlement_result);
  END IF;

  IF l.character_id IS NULL THEN
    RAISE EXCEPTION 'Encounter character is no longer available for relationship settlement' USING ERRCODE='23514';
  END IF;

  IF l.status NOT IN ('active','paused','ready_to_settle') THEN
    RAISE EXCEPTION 'Encounter lifecycle is not settleable' USING ERRCODE='23514';
  END IF;
  IF l.scheduled_end_at > pg_catalog.clock_timestamp() THEN
    RAISE EXCEPTION 'Encounter scene has not reached scheduled end' USING ERRCODE='23514';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.chat_turn_charges AS charge
    WHERE charge.session_id=p_session_id
      AND charge.status='settled'
      AND NOT EXISTS (
        SELECT 1 FROM public.encounter_session_turns AS turn
        WHERE turn.turn_id=charge.turn_id
      )
  ) THEN
    RAISE EXCEPTION 'Encounter settled charge evidence is still pending' USING ERRCODE='23514';
  END IF;

  IF (
    SELECT count(*) FROM public.encounter_session_turns AS turn
    WHERE turn.session_id=p_session_id
  ) <> l.turn_count THEN
    RAISE EXCEPTION 'Encounter turn evidence is incomplete' USING ERRCODE='23514';
  END IF;

  INSERT INTO public.encounter_character_state(
    user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at
  ) VALUES (
    l.user_id,l.character_id,0,'first_meeting',pg_catalog.now(),pg_catalog.now()
  )
  ON CONFLICT (user_id,character_id) DO NOTHING;

  SELECT state.id,state.affinity
  INTO v_state_id,v_current
  FROM public.encounter_character_state AS state
  WHERE state.user_id=l.user_id AND state.character_id=l.character_id
  FOR UPDATE;

  v_final := greatest(-100,least(100,v_current+p_affinity_delta));

  UPDATE public.encounter_character_state
  SET affinity=v_final,
      relationship_stage=p_relationship_stage,
      last_interaction_at=pg_catalog.now(),
      updated_at=pg_catalog.now()
  WHERE id=v_state_id;

  v_result := jsonb_build_object(
    'final_affinity',v_final,
    'affinity_delta',v_final-v_current,
    'relationship_stage',p_relationship_stage,
    'memories',COALESCE(p_memories,'[]'::jsonb),
    'evaluation',COALESCE(p_evaluation,'{}'::jsonb),
    'turn_count',l.turn_count,
    'source_session_id',p_session_id
  );

  UPDATE public.encounter_session_lifecycle
  SET status='settled',
      settlement_delta=v_final-v_current,
      settlement_result=v_result,
      settled_at=pg_catalog.clock_timestamp(),
      updated_at=pg_catalog.clock_timestamp()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('settled',true,'idempotent',false,'result',v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb)
  TO service_role;

COMMENT ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb) IS
  'Commits an externally evaluated Encounter result once and refuses settlement while any settled wallet charge is missing its turn-evidence row.';
