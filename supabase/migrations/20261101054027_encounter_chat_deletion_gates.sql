-- PR #200: close encounter/story write paths that could race with chat deletion.

CREATE OR REPLACE FUNCTION public.reserve_encounter_chat_turn(
  p_user_id uuid,p_turn_id uuid,p_session_id uuid,p_user_message_id uuid,p_assistant_message_id uuid
)
RETURNS TABLE(turn_id uuid,status text,silver_reserved integer,diamonds_reserved integer,balance_silver integer,balance_diamonds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE l public.encounter_session_lifecycle%ROWTYPE; c public.chat_turn_charges%ROWTYPE; v_existing boolean:=false;
BEGIN
  IF p_user_id IS NULL OR p_turn_id IS NULL OR p_session_id IS NULL OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL THEN
    RAISE EXCEPTION 'invalid_turn_request';
  END IF;
  -- Global lock order: chat parent, encounter lifecycle, charge, wallet, messages.
  PERFORM 1 FROM public.chat_sessions s
  WHERE s.id=p_session_id AND s.user_id=p_user_id AND s.chat_mode='encounter' AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'encounter_chat_not_found_or_deleted' USING ERRCODE='23514'; END IF;

  SELECT * INTO l FROM public.encounter_session_lifecycle WHERE session_id=p_session_id FOR UPDATE;
  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id OR l.status NOT IN ('active','paused','ready_to_settle') THEN
    RAISE EXCEPTION 'encounter_scene_expired_or_inactive' USING ERRCODE='23514';
  END IF;

  SELECT charge.* INTO c FROM public.chat_turn_charges AS charge WHERE charge.turn_id=p_turn_id FOR UPDATE;
  v_existing:=FOUND;
  IF v_existing THEN
    IF c.user_id IS DISTINCT FROM p_user_id OR c.session_id IS DISTINCT FROM p_session_id
       OR c.user_message_id IS DISTINCT FROM p_user_message_id
       OR c.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN
      RAISE EXCEPTION 'turn_id_reuse_conflict' USING ERRCODE='23505';
    END IF;
    IF c.status='insufficient_funds' THEN
      RETURN QUERY SELECT r.turn_id,r.status,r.silver_reserved,r.diamonds_reserved,r.balance_silver,r.balance_diamonds
      FROM public.reserve_chat_turn(p_user_id,p_turn_id,p_session_id,p_user_message_id,p_assistant_message_id) AS r;
      RETURN;
    END IF;
    IF c.status IN ('reserved','needs_reconciliation','settled','refunded')
       AND c.reserved_at IS NOT NULL AND c.reserved_at<=l.scheduled_end_at THEN
      RETURN QUERY SELECT r.turn_id,r.status,r.silver_reserved,r.diamonds_reserved,r.balance_silver,r.balance_diamonds
      FROM public.reserve_chat_turn(p_user_id,p_turn_id,p_session_id,p_user_message_id,p_assistant_message_id) AS r;
      RETURN;
    END IF;
  END IF;
  IF l.status<>'active' OR l.scheduled_end_at<=clock_timestamp() THEN
    RAISE EXCEPTION 'encounter_scene_expired_or_inactive' USING ERRCODE='23514';
  END IF;
  RETURN QUERY SELECT r.turn_id,r.status,r.silver_reserved,r.diamonds_reserved,r.balance_silver,r.balance_diamonds
  FROM public.reserve_chat_turn(p_user_id,p_turn_id,p_session_id,p_user_message_id,p_assistant_message_id) AS r;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_encounter_session_turn_evidence(
  p_turn_id uuid,p_session_id uuid,p_user_id uuid,p_character_id uuid,
  p_user_message_id uuid,p_assistant_message_id uuid,p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE; c public.chat_turn_charges%ROWTYPE;
  um public.chat_messages%ROWTYPE; am public.chat_messages%ROWTYPE;
  oldrow public.encounter_session_turns%ROWTYPE; n integer;
BEGIN
  IF p_turn_id IS NULL OR p_session_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL
     OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb))<>'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb))>8000 THEN
    RAISE EXCEPTION 'Invalid evidence input' USING ERRCODE='22023';
  END IF;

  PERFORM 1 FROM public.chat_sessions s
  WHERE s.id=p_session_id AND s.user_id=p_user_id AND s.character_id=p_character_id
    AND s.chat_mode='encounter' AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Encounter chat is deleted or not owned' USING ERRCODE='23514'; END IF;

  SELECT * INTO l FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id FOR UPDATE;
  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id OR l.character_id IS DISTINCT FROM p_character_id
     OR l.status NOT IN ('active','paused','ready_to_settle') THEN
    RAISE EXCEPTION 'Invalid Encounter lifecycle' USING ERRCODE='23514';
  END IF;

  SELECT * INTO c FROM public.chat_turn_charges WHERE turn_id=p_turn_id FOR SHARE;
  IF NOT FOUND OR c.session_id IS DISTINCT FROM p_session_id OR c.user_id IS DISTINCT FROM p_user_id
     OR c.status<>'settled' OR c.user_message_id IS DISTINCT FROM p_user_message_id
     OR c.assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR c.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR c.reserved_at IS NULL OR c.reserved_at>l.scheduled_end_at THEN
    RAISE EXCEPTION 'Charge evidence mismatch, unsettled, or reserved after scene end' USING ERRCODE='23514';
  END IF;

  SELECT * INTO um FROM public.chat_messages WHERE id=p_user_message_id FOR SHARE;
  IF NOT FOUND OR um.session_id IS DISTINCT FROM p_session_id OR um.role<>'user'
     OR um.deleted_at IS NOT NULL OR length(btrim(um.content))=0 THEN
    RAISE EXCEPTION 'Invalid user message evidence' USING ERRCODE='23514';
  END IF;
  SELECT * INTO am FROM public.chat_messages WHERE id=p_assistant_message_id FOR SHARE;
  IF NOT FOUND OR am.session_id IS DISTINCT FROM p_session_id OR am.role<>'assistant'
     OR am.deleted_at IS NOT NULL OR length(btrim(am.content))=0 THEN
    RAISE EXCEPTION 'Invalid assistant message evidence' USING ERRCODE='23514';
  END IF;

  SELECT * INTO oldrow FROM public.encounter_session_turns WHERE turn_id=p_turn_id;
  IF FOUND THEN
    IF oldrow.session_id IS DISTINCT FROM p_session_id OR oldrow.user_id IS DISTINCT FROM p_user_id
       OR oldrow.character_id IS DISTINCT FROM p_character_id
       OR oldrow.user_message_id IS DISTINCT FROM p_user_message_id
       OR oldrow.assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN
      RAISE EXCEPTION 'Evidence idempotency collision' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('turn_id',oldrow.turn_id,'turn_number',oldrow.turn_number,
      'status',oldrow.evaluation_status,'idempotent',true);
  END IF;

  n:=l.turn_count+1;
  INSERT INTO public.encounter_session_turns(
    turn_id,session_id,user_id,character_id,user_message_id,assistant_message_id,
    turn_number,evaluation_status,evaluation
  ) VALUES(p_turn_id,p_session_id,p_user_id,p_character_id,p_user_message_id,p_assistant_message_id,
    n,'pending',COALESCE(p_evaluation,'{}'::jsonb));
  UPDATE public.encounter_session_lifecycle SET turn_count=n,updated_at=clock_timestamp()
  WHERE session_id=p_session_id;
  RETURN jsonb_build_object('turn_id',p_turn_id,'turn_number',n,'status','pending','idempotent',false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_encounter_turn_interaction(
  p_turn_id uuid,p_user_id uuid,p_character_id uuid,p_affinity_delta integer,p_event_type text,
  p_summary text,p_metadata jsonb DEFAULT '{}'::jsonb,p_occurred_at timestamptz DEFAULT now()
)
RETURNS TABLE(affinity integer,relationship_stage text,diary_id uuid,idempotent boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_inserted integer; v_affinity integer; v_stage text; v_diary_id uuid;
  v_receipt public.encounter_turn_interaction_receipts%ROWTYPE;
  v_charge public.chat_turn_charges%ROWTYPE; v_session public.chat_sessions%ROWTYPE;
  v_session_id uuid; v_occurred_at timestamptz:=COALESCE(p_occurred_at,now());
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'Trusted backend required' USING ERRCODE='42501'; END IF;
  IF p_turn_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL THEN RAISE EXCEPTION 'Turn, user and character are required' USING ERRCODE='22023'; END IF;
  IF p_affinity_delta IS NULL OR p_affinity_delta < -10 OR p_affinity_delta > 10 THEN RAISE EXCEPTION 'Affinity delta must be between -10 and 10' USING ERRCODE='22023'; END IF;
  IF COALESCE(char_length(btrim(p_event_type)),0) NOT BETWEEN 1 AND 60
     OR COALESCE(char_length(btrim(p_summary)),0) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Invalid event type or diary summary' USING ERRCODE='22023'; END IF;
  IF p_metadata IS NULL OR jsonb_typeof(p_metadata)<>'object' OR pg_column_size(p_metadata)>4000 THEN RAISE EXCEPTION 'Invalid diary metadata' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p_user_id) THEN RAISE EXCEPTION 'User not found' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.characters c WHERE c.id=p_character_id AND c.deleted_at IS NULL) THEN RAISE EXCEPTION 'Character not found or deleted' USING ERRCODE='22023'; END IF;

  -- Read the session reference without locking, then lock parent before charge.
  SELECT c.session_id INTO v_session_id FROM public.chat_turn_charges c
  WHERE c.turn_id=p_turn_id AND c.user_id=p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Encounter interaction requires matching settled chat turn' USING ERRCODE='23514'; END IF;

  SELECT s.* INTO v_session FROM public.chat_sessions s
  WHERE s.id=v_session_id AND s.user_id=p_user_id AND s.character_id=p_character_id
    AND s.chat_mode='encounter' AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Encounter session ownership or lifecycle mismatch' USING ERRCODE='23514'; END IF;

  SELECT c.* INTO v_charge FROM public.chat_turn_charges c WHERE c.turn_id=p_turn_id FOR UPDATE;
  IF NOT FOUND OR v_charge.session_id IS DISTINCT FROM v_session.id
     OR v_charge.user_id IS DISTINCT FROM p_user_id OR v_charge.status IS DISTINCT FROM 'settled'
     OR v_charge.assistant_message_id IS DISTINCT FROM v_charge.expected_assistant_message_id
     OR p_metadata->>'session_id' IS DISTINCT FROM v_charge.session_id::text
     OR p_metadata->>'user_message_id' IS DISTINCT FROM v_charge.user_message_id::text
     OR p_metadata->>'assistant_message_id' IS DISTINCT FROM v_charge.expected_assistant_message_id::text THEN
    RAISE EXCEPTION 'Encounter interaction requires matching settled chat turn' USING ERRCODE='23514';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.chat_messages m WHERE m.id=v_charge.user_message_id
      AND m.session_id=v_charge.session_id AND m.role='user' AND m.deleted_at IS NULL AND length(btrim(m.content))>0
  ) OR NOT EXISTS(
    SELECT 1 FROM public.chat_messages m WHERE m.id=v_charge.expected_assistant_message_id
      AND m.session_id=v_charge.session_id AND m.role='assistant' AND m.deleted_at IS NULL AND length(btrim(m.content))>0
  ) THEN RAISE EXCEPTION 'Encounter interaction requires durable user and assistant messages' USING ERRCODE='23514'; END IF;

  INSERT INTO public.encounter_turn_interaction_receipts(turn_id,user_id,character_id)
  VALUES(p_turn_id,p_user_id,p_character_id) ON CONFLICT(turn_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  IF v_inserted=0 THEN
    SELECT * INTO v_receipt FROM public.encounter_turn_interaction_receipts r WHERE r.turn_id=p_turn_id FOR UPDATE;
    IF v_receipt.user_id<>p_user_id OR v_receipt.character_id<>p_character_id THEN RAISE EXCEPTION 'Turn ID reused with different owner or character' USING ERRCODE='23505'; END IF;
    IF v_receipt.diary_id IS NULL OR v_receipt.affinity IS NULL OR v_receipt.relationship_stage IS NULL THEN RAISE EXCEPTION 'Interaction receipt incomplete' USING ERRCODE='55000'; END IF;
    RETURN QUERY SELECT v_receipt.affinity,v_receipt.relationship_stage,v_receipt.diary_id,true; RETURN;
  END IF;

  INSERT INTO public.encounter_character_state AS current_state(
    user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at,updated_at
  ) VALUES(p_user_id,p_character_id,GREATEST(0,LEAST(100,p_affinity_delta)),
    'first_meeting',v_occurred_at,v_occurred_at,now())
  ON CONFLICT(user_id,character_id) DO UPDATE
  SET affinity=GREATEST(0,LEAST(100,current_state.affinity+p_affinity_delta)),
      last_interaction_at=GREATEST(current_state.last_interaction_at,EXCLUDED.last_interaction_at),
      updated_at=now()
  RETURNING current_state.affinity INTO v_affinity;

  v_stage:=CASE WHEN v_affinity>=80 THEN 'special' WHEN v_affinity>=50 THEN 'intimate'
    WHEN v_affinity>=20 THEN 'close' WHEN v_affinity>=1 THEN 'acquaintance' ELSE 'first_meeting' END;
  UPDATE public.encounter_character_state s SET relationship_stage=v_stage,
    first_met_at=COALESCE(s.first_met_at,v_occurred_at),updated_at=now()
  WHERE s.user_id=p_user_id AND s.character_id=p_character_id;

  INSERT INTO public.encounter_diary(user_id,character_id,event_type,summary,occurred_at,metadata)
  VALUES(p_user_id,p_character_id,btrim(p_event_type),btrim(p_summary),v_occurred_at,p_metadata)
  RETURNING id INTO v_diary_id;
  UPDATE public.encounter_turn_interaction_receipts r
  SET affinity=v_affinity,relationship_stage=v_stage,diary_id=v_diary_id
  WHERE r.turn_id=p_turn_id;
  RETURN QUERY SELECT v_affinity,v_stage,v_diary_id,false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_encounter_turn_evidence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_user_message_session uuid; v_user_message_role text;
  v_assistant_message_session uuid; v_assistant_message_role text;
  v_charge_session uuid; v_charge_user uuid;
BEGIN
  PERFORM 1 FROM public.chat_sessions s
  WHERE s.id=NEW.session_id AND s.user_id=NEW.user_id AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Encounter evidence parent session is deleted or inaccessible' USING ERRCODE='23514'; END IF;

  SELECT m.session_id,m.role INTO v_user_message_session,v_user_message_role FROM public.chat_messages m WHERE m.id=NEW.user_message_id;
  SELECT m.session_id,m.role INTO v_assistant_message_session,v_assistant_message_role FROM public.chat_messages m WHERE m.id=NEW.assistant_message_id;
  SELECT c.session_id,c.user_id INTO v_charge_session,v_charge_user FROM public.chat_turn_charges c WHERE c.turn_id=NEW.turn_id;
  IF v_user_message_session IS DISTINCT FROM NEW.session_id OR v_user_message_role<>'user' THEN
    RAISE EXCEPTION 'Encounter user message does not belong to the session' USING ERRCODE='23514';
  END IF;
  IF v_assistant_message_session IS DISTINCT FROM NEW.session_id OR v_assistant_message_role<>'assistant' THEN
    RAISE EXCEPTION 'Encounter assistant message does not belong to the session' USING ERRCODE='23514';
  END IF;
  IF v_charge_session IS DISTINCT FROM NEW.session_id OR v_charge_user IS DISTINCT FROM NEW.user_id THEN
    RAISE EXCEPTION 'Encounter turn charge does not match session owner' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_story_relationship_batch_sources()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_expected_count integer; v_distinct_count integer; v_valid_count integer;
BEGIN
  PERFORM 1 FROM public.chat_sessions s
  WHERE s.id=NEW.session_id AND s.user_id=NEW.user_id AND s.chat_mode='story' AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Story session is deleted or inaccessible' USING ERRCODE='23514'; END IF;

  v_expected_count:=NEW.last_turn_number-NEW.first_turn_number+1;
  IF NEW.first_turn_number<1 OR NEW.last_turn_number<NEW.first_turn_number
     OR v_expected_count NOT BETWEEN 1 AND 5 OR cardinality(NEW.source_turn_ids)<>v_expected_count THEN
    RAISE EXCEPTION 'Story batch turn range does not match source turn count' USING ERRCODE='23514';
  END IF;
  SELECT count(DISTINCT source_id) INTO v_distinct_count FROM unnest(NEW.source_turn_ids) AS source(source_id);
  IF v_distinct_count<>cardinality(NEW.source_turn_ids) THEN RAISE EXCEPTION 'Story batch source turn IDs must be unique' USING ERRCODE='23514'; END IF;
  SELECT count(*) INTO v_valid_count
  FROM unnest(NEW.source_turn_ids) AS source(source_id)
  JOIN public.chat_turn_charges charge ON charge.turn_id=source.source_id
  WHERE charge.session_id=NEW.session_id AND charge.user_id=NEW.user_id AND charge.status='settled';
  IF v_valid_count<>cardinality(NEW.source_turn_ids) THEN
    RAISE EXCEPTION 'Story batch sources must be settled turns from the same session and owner' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_story_relationship_origin()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_source_user uuid; v_source_character uuid; v_source_status text;
BEGIN
  PERFORM 1 FROM public.chat_sessions s
  WHERE s.id=NEW.session_id AND s.user_id=NEW.user_id AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Story session is deleted or inaccessible' USING ERRCODE='23514'; END IF;

  IF NEW.origin_mode='encounter_snapshot' AND NEW.source_encounter_session_id IS NOT NULL THEN
    PERFORM 1 FROM public.chat_sessions s
    WHERE s.id=NEW.source_encounter_session_id AND s.user_id=NEW.user_id AND s.deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Encounter snapshot source session is deleted' USING ERRCODE='23514'; END IF;

    SELECT l.user_id,l.character_id,l.status INTO v_source_user,v_source_character,v_source_status
    FROM public.encounter_session_lifecycle l WHERE l.session_id=NEW.source_encounter_session_id;
    IF NOT FOUND OR v_source_user IS DISTINCT FROM NEW.user_id
       OR (NEW.character_id IS NOT NULL AND v_source_character IS DISTINCT FROM NEW.character_id)
       OR v_source_status<>'settled' THEN
      RAISE EXCEPTION 'Encounter snapshot source is invalid or not settled' USING ERRCODE='23514';
    END IF;
  ELSIF NEW.origin_mode='encounter_snapshot' AND (TG_OP='INSERT' OR OLD.source_encounter_session_id IS NULL) THEN
    RAISE EXCEPTION 'Encounter snapshot source is required at creation' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enqueue_due_encounter_evaluations(p_limit integer DEFAULT 50)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_enqueued integer:=0; v_rows integer:=0;
  v_limit integer:=LEAST(GREATEST(COALESCE(p_limit,50),1),100);
  v_session_id uuid;
BEGIN
  -- Lock chat parent before lifecycle state so deletion and settlement share one order.
  FOR v_session_id IN
    SELECT s.id
    FROM public.chat_sessions s
    JOIN public.encounter_session_lifecycle lifecycle ON lifecycle.session_id=s.id
    WHERE s.deleted_at IS NULL
      AND lifecycle.status IN ('active','paused','ready_to_settle')
      AND lifecycle.character_id IS NOT NULL
      AND lifecycle.scheduled_end_at<=clock_timestamp()
    ORDER BY lifecycle.scheduled_end_at,lifecycle.session_id
    FOR UPDATE OF s SKIP LOCKED
    LIMIT v_limit
  LOOP
    SELECT lifecycle.* INTO l
    FROM public.encounter_session_lifecycle lifecycle
    WHERE lifecycle.session_id=v_session_id
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    IF EXISTS(SELECT 1 FROM public.chat_turn_charges charge
      WHERE charge.session_id=l.session_id AND charge.status IN ('created','reserved','needs_reconciliation')) THEN
      CONTINUE;
    END IF;
    IF (SELECT count(*) FROM public.encounter_session_turns turn WHERE turn.session_id=l.session_id)<>l.turn_count THEN
      CONTINUE;
    END IF;

    UPDATE public.encounter_session_lifecycle SET status='ready_to_settle',updated_at=clock_timestamp()
    WHERE session_id=l.session_id AND status IN ('active','paused','ready_to_settle');
    INSERT INTO public.encounter_session_evaluation_jobs(session_id,user_id,character_id,status)
    VALUES(l.session_id,l.user_id,l.character_id,'pending')
    ON CONFLICT(session_id) DO UPDATE
      SET status='pending',claimed_at=NULL,completed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
      WHERE public.encounter_session_evaluation_jobs.status='failed'
        AND public.encounter_session_evaluation_jobs.attempt_count<5
        AND public.encounter_session_evaluation_jobs.updated_at<=clock_timestamp()-interval '5 minutes';
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    v_enqueued:=v_enqueued+v_rows;
  END LOOP;
  RETURN v_enqueued;
END;
$function$;

CREATE OR REPLACE FUNCTION public.claim_encounter_evaluation_jobs(p_limit integer DEFAULT 10)
RETURNS TABLE(session_id uuid,user_id uuid,character_id uuid,turn_count integer,attempt_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_limit integer:=LEAST(GREATEST(COALESCE(p_limit,10),1),25);
BEGIN
  RETURN QUERY
  WITH candidate_sessions AS MATERIALIZED (
    SELECT s.id
    FROM public.chat_sessions s
    JOIN public.encounter_session_lifecycle lifecycle ON lifecycle.session_id=s.id
    JOIN public.encounter_session_evaluation_jobs job ON job.session_id=s.id
    WHERE s.deleted_at IS NULL
      AND lifecycle.status='ready_to_settle'
      AND lifecycle.scheduled_end_at<=clock_timestamp()
      AND job.attempt_count<5
      AND (
        job.status='pending'
        OR (job.status='failed' AND job.updated_at<=clock_timestamp()-interval '5 minutes')
        OR (job.status='processing' AND job.claimed_at<clock_timestamp()-interval '10 minutes')
      )
      AND NOT EXISTS(SELECT 1 FROM public.chat_turn_charges charge
        WHERE charge.session_id=job.session_id AND charge.status IN ('created','reserved','needs_reconciliation'))
      AND (SELECT count(*) FROM public.encounter_session_turns turn WHERE turn.session_id=job.session_id)=lifecycle.turn_count
    ORDER BY lifecycle.scheduled_end_at,job.session_id
    FOR UPDATE OF s SKIP LOCKED
    LIMIT v_limit
  ),
  candidates AS MATERIALIZED (
    SELECT job.session_id
    FROM public.encounter_session_evaluation_jobs job
    JOIN candidate_sessions cs ON cs.id=job.session_id
    ORDER BY job.session_id
    FOR UPDATE OF job SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.encounter_session_evaluation_jobs job
  SET status='processing',attempt_count=job.attempt_count+1,
      claimed_at=clock_timestamp(),completed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
  FROM candidates
  JOIN public.encounter_session_lifecycle lifecycle ON lifecycle.session_id=candidates.session_id
  WHERE job.session_id=candidates.session_id
  RETURNING job.session_id,job.user_id,job.character_id,lifecycle.turn_count,job.attempt_count;
END;
$function$;
