-- POYOZZ affinity foundation: session-scoped Encounter lifecycle and Story relationships.
-- Additive foundation only. Runtime handlers are intentionally updated in follow-up PRs.
-- Do not apply affinity deltas from the existing per-turn Encounter RPC until that flow is replaced.

-- Encounter affinity is allowed to move below zero.
ALTER TABLE public.encounter_character_state
  DROP CONSTRAINT IF EXISTS encounter_character_state_affinity_check;
ALTER TABLE public.encounter_character_state
  ADD CONSTRAINT encounter_character_state_affinity_check
  CHECK (affinity BETWEEN -100 AND 100);

-- Reserve relationship labels for negative affinity states while preserving legacy values.
ALTER TABLE public.encounter_character_state
  DROP CONSTRAINT IF EXISTS encounter_character_state_relationship_stage_check;
ALTER TABLE public.encounter_character_state
  ADD CONSTRAINT encounter_character_state_relationship_stage_check
  CHECK (relationship_stage IN (
    'hostile', 'dislike', 'wary',
    'first_meeting', 'acquaintance', 'close', 'intimate', 'special'
  ));

ALTER TABLE public.encounter_turn_interaction_receipts
  DROP CONSTRAINT IF EXISTS encounter_turn_receipt_stage_check;
ALTER TABLE public.encounter_turn_interaction_receipts
  ADD CONSTRAINT encounter_turn_receipt_stage_check
  CHECK (
    relationship_stage IS NULL OR relationship_stage IN (
      'hostile', 'dislike', 'wary',
      'first_meeting', 'acquaintance', 'close', 'intimate', 'special'
    )
  );

-- One authoritative lifecycle row per Encounter chat session.
-- schedule_snapshot preserves the exact schedule that authorized the meeting,
-- even if the creator later edits or removes their schedule.
CREATE TABLE IF NOT EXISTS public.encounter_session_lifecycle (
  session_id uuid PRIMARY KEY REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  location_key text NOT NULL CHECK (char_length(location_key) BETWEEN 1 AND 80),
  schedule_snapshot jsonb NOT NULL CHECK (
    jsonb_typeof(schedule_snapshot) = 'object'
    AND pg_column_size(schedule_snapshot) <= 8000
  ),
  scheduled_start_at timestamptz NOT NULL,
  scheduled_end_at timestamptz NOT NULL,
  timezone text NOT NULL DEFAULT 'Asia/Taipei'
    CHECK (timezone = 'Asia/Taipei'),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'paused', 'ready_to_settle', 'settled', 'cancelled')),
  turn_count integer NOT NULL DEFAULT 0 CHECK (turn_count >= 0),
  settlement_delta integer CHECK (
    settlement_delta IS NULL OR settlement_delta BETWEEN -100 AND 100
  ),
  settlement_result jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
    jsonb_typeof(settlement_result) = 'object'
    AND pg_column_size(settlement_result) <= 8000
  ),
  settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT encounter_session_lifecycle_window_check
    CHECK (scheduled_end_at > scheduled_start_at),
  CONSTRAINT encounter_session_lifecycle_settled_check
    CHECK (
      (status <> 'settled' AND settled_at IS NULL)
      OR (status = 'settled' AND settled_at IS NOT NULL AND settlement_delta IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS encounter_session_lifecycle_due_idx
  ON public.encounter_session_lifecycle (scheduled_end_at, session_id)
  WHERE status IN ('active', 'paused', 'ready_to_settle');

CREATE INDEX IF NOT EXISTS encounter_session_lifecycle_owner_character_idx
  ON public.encounter_session_lifecycle (user_id, character_id, created_at DESC);

COMMENT ON TABLE public.encounter_session_lifecycle IS
  'Server-authoritative Encounter schedule window and settlement lifecycle. A paused session remains pending until its snapshotted schedule end; settlement is idempotent per session.';

-- Per-turn record for an Encounter session. It deliberately does not mutate affinity.
-- A future trusted evaluator will attach a bounded score and structured rationale;
-- the session-level settlement process will aggregate the full encounter.
CREATE TABLE IF NOT EXISTS public.encounter_session_turns (
  turn_id uuid PRIMARY KEY REFERENCES public.chat_turn_charges(turn_id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  user_message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  assistant_message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  turn_number integer NOT NULL CHECK (turn_number > 0),
  evaluation_status text NOT NULL DEFAULT 'pending'
    CHECK (evaluation_status IN ('pending', 'evaluated', 'skipped', 'failed')),
  affinity_delta integer CHECK (
    affinity_delta IS NULL OR affinity_delta BETWEEN -100 AND 100
  ),
  evaluation jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
    jsonb_typeof(evaluation) = 'object'
    AND pg_column_size(evaluation) <= 8000
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  evaluated_at timestamptz,
  CONSTRAINT encounter_session_turns_unique_number UNIQUE (session_id, turn_number),
  CONSTRAINT encounter_session_turns_unique_user_message UNIQUE (user_message_id),
  CONSTRAINT encounter_session_turns_unique_assistant_message UNIQUE (assistant_message_id),
  CONSTRAINT encounter_session_turns_evaluation_check CHECK (
    (evaluation_status = 'evaluated' AND affinity_delta IS NOT NULL AND evaluated_at IS NOT NULL)
    OR (evaluation_status <> 'evaluated')
  )
);

CREATE INDEX IF NOT EXISTS encounter_session_turns_session_order_idx
  ON public.encounter_session_turns (session_id, turn_number);

-- Each Story chat session owns its own mutable relationship state.
-- Imported Encounter affinity and memories are immutable origin snapshots, not live links.
CREATE TABLE IF NOT EXISTS public.story_relationship_states (
  session_id uuid PRIMARY KEY REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  origin_mode text NOT NULL
    CHECK (origin_mode IN ('encounter_snapshot', 'fresh_story')),
  affinity integer NOT NULL DEFAULT 0 CHECK (affinity BETWEEN -100 AND 100),
  relationship_stage text NOT NULL DEFAULT 'first_meeting'
    CHECK (relationship_stage IN (
      'hostile', 'dislike', 'wary',
      'first_meeting', 'acquaintance', 'close', 'intimate', 'special'
    )),
  source_encounter_session_id uuid REFERENCES public.encounter_session_lifecycle(session_id) ON DELETE SET NULL,
  origin_affinity integer NOT NULL DEFAULT 0 CHECK (origin_affinity BETWEEN -100 AND 100),
  origin_relationship_stage text NOT NULL DEFAULT 'first_meeting'
    CHECK (origin_relationship_stage IN (
      'hostile', 'dislike', 'wary',
      'first_meeting', 'acquaintance', 'close', 'intimate', 'special'
    )),
  imported_memories jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
    jsonb_typeof(imported_memories) = 'array'
    AND pg_column_size(imported_memories) <= 20000
  ),
  snapshot_at timestamptz,
  turn_count_since_summary integer NOT NULL DEFAULT 0
    CHECK (turn_count_since_summary BETWEEN 0 AND 4),
  last_processed_batch integer NOT NULL DEFAULT 0 CHECK (last_processed_batch >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT story_relationship_origin_check CHECK (
    (origin_mode = 'encounter_snapshot' AND snapshot_at IS NOT NULL)
    OR
    (origin_mode = 'fresh_story'
      AND source_encounter_session_id IS NULL
      AND snapshot_at IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS story_relationship_states_owner_character_idx
  ON public.story_relationship_states (user_id, character_id, updated_at DESC);

COMMENT ON TABLE public.story_relationship_states IS
  'One isolated relationship per Story chat session. Encounter carry-over is a frozen starting snapshot; subsequent Story changes never write back to Encounter or sibling Story sessions.';

-- Idempotent five-turn Story batch ledger. Summary and affinity evaluation are committed
-- as one logical batch; a retry must reuse the same (session_id, batch_number).
CREATE TABLE IF NOT EXISTS public.story_relationship_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  batch_number integer NOT NULL CHECK (batch_number > 0),
  first_turn_number integer NOT NULL CHECK (first_turn_number > 0),
  last_turn_number integer NOT NULL CHECK (last_turn_number >= first_turn_number),
  source_turn_ids uuid[] NOT NULL CHECK (cardinality(source_turn_ids) BETWEEN 1 AND 5),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  summary text,
  affinity_delta integer CHECK (
    affinity_delta IS NULL OR affinity_delta BETWEEN -10 AND 10
  ),
  evaluation jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
    jsonb_typeof(evaluation) = 'object'
    AND pg_column_size(evaluation) <= 12000
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  CONSTRAINT story_relationship_batches_session_batch_unique UNIQUE (session_id, batch_number),
  CONSTRAINT story_relationship_batches_completion_check CHECK (
    (status = 'completed' AND summary IS NOT NULL AND affinity_delta IS NOT NULL AND processed_at IS NOT NULL)
    OR status <> 'completed'
  )
);

CREATE INDEX IF NOT EXISTS story_relationship_batches_pending_idx
  ON public.story_relationship_batches (status, created_at)
  WHERE status IN ('pending', 'failed');


-- Enforce session ownership and mode consistency inside the database.
-- These checks remain authoritative even when trusted service-role handlers write rows.
CREATE OR REPLACE FUNCTION public.validate_affinity_session_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
DECLARE
  v_user_id uuid;
  v_character_id uuid;
  v_chat_mode text;
BEGIN
  SELECT s.user_id, s.character_id, s.chat_mode
    INTO v_user_id, v_character_id, v_chat_mode
  FROM public.chat_sessions AS s
  WHERE s.id = NEW.session_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Affinity session does not exist' USING ERRCODE = '23503';
  END IF;

  IF v_user_id IS DISTINCT FROM NEW.user_id THEN
    RAISE EXCEPTION 'Affinity session owner mismatch' USING ERRCODE = '23514';
  END IF;

  IF NEW.character_id IS NOT NULL
     AND v_character_id IS DISTINCT FROM NEW.character_id THEN
    RAISE EXCEPTION 'Affinity session character mismatch' USING ERRCODE = '23514';
  END IF;

  IF TG_TABLE_NAME = 'encounter_session_lifecycle'
     AND v_chat_mode <> 'encounter' THEN
    RAISE EXCEPTION 'Encounter lifecycle requires an Encounter session' USING ERRCODE = '23514';
  ELSIF TG_TABLE_NAME = 'story_relationship_states'
     AND v_chat_mode <> 'story' THEN
    RAISE EXCEPTION 'Story relationship requires a Story session' USING ERRCODE = '23514';
  ELSIF TG_TABLE_NAME = 'story_relationship_batches'
     AND v_chat_mode <> 'story' THEN
    RAISE EXCEPTION 'Story batch requires a Story session' USING ERRCODE = '23514';
  ELSIF TG_TABLE_NAME = 'encounter_session_turns'
     AND v_chat_mode <> 'encounter' THEN
    RAISE EXCEPTION 'Encounter turn requires an Encounter session' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$;

REVOKE ALL ON FUNCTION public.validate_affinity_session_link() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS validate_encounter_lifecycle_session_link ON public.encounter_session_lifecycle;
CREATE TRIGGER validate_encounter_lifecycle_session_link
  BEFORE INSERT OR UPDATE OF session_id, user_id, character_id
  ON public.encounter_session_lifecycle
  FOR EACH ROW EXECUTE FUNCTION public.validate_affinity_session_link();

DROP TRIGGER IF EXISTS validate_encounter_turn_session_link ON public.encounter_session_turns;
CREATE TRIGGER validate_encounter_turn_session_link
  BEFORE INSERT OR UPDATE OF session_id, user_id, character_id
  ON public.encounter_session_turns
  FOR EACH ROW EXECUTE FUNCTION public.validate_affinity_session_link();

DROP TRIGGER IF EXISTS validate_story_relationship_session_link ON public.story_relationship_states;
CREATE TRIGGER validate_story_relationship_session_link
  BEFORE INSERT OR UPDATE OF session_id, user_id, character_id
  ON public.story_relationship_states
  FOR EACH ROW EXECUTE FUNCTION public.validate_affinity_session_link();

DROP TRIGGER IF EXISTS validate_story_batch_session_link ON public.story_relationship_batches;
CREATE TRIGGER validate_story_batch_session_link
  BEFORE INSERT OR UPDATE OF session_id, user_id, character_id
  ON public.story_relationship_batches
  FOR EACH ROW EXECUTE FUNCTION public.validate_affinity_session_link();

-- Encounter turn messages and charge must belong to the same session and roles.
CREATE OR REPLACE FUNCTION public.validate_encounter_turn_evidence()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
DECLARE
  v_user_message_session uuid;
  v_user_message_role text;
  v_assistant_message_session uuid;
  v_assistant_message_role text;
  v_charge_session uuid;
  v_charge_user uuid;
BEGIN
  SELECT m.session_id, m.role INTO v_user_message_session, v_user_message_role
  FROM public.chat_messages AS m WHERE m.id = NEW.user_message_id;

  SELECT m.session_id, m.role INTO v_assistant_message_session, v_assistant_message_role
  FROM public.chat_messages AS m WHERE m.id = NEW.assistant_message_id;

  SELECT c.session_id, c.user_id INTO v_charge_session, v_charge_user
  FROM public.chat_turn_charges AS c WHERE c.turn_id = NEW.turn_id;

  IF v_user_message_session IS DISTINCT FROM NEW.session_id OR v_user_message_role <> 'user' THEN
    RAISE EXCEPTION 'Encounter user message does not belong to the session' USING ERRCODE = '23514';
  END IF;
  IF v_assistant_message_session IS DISTINCT FROM NEW.session_id OR v_assistant_message_role <> 'assistant' THEN
    RAISE EXCEPTION 'Encounter assistant message does not belong to the session' USING ERRCODE = '23514';
  END IF;
  IF v_charge_session IS DISTINCT FROM NEW.session_id OR v_charge_user IS DISTINCT FROM NEW.user_id THEN
    RAISE EXCEPTION 'Encounter turn charge does not match session owner' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$;

REVOKE ALL ON FUNCTION public.validate_encounter_turn_evidence() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS validate_encounter_turn_evidence ON public.encounter_session_turns;
CREATE TRIGGER validate_encounter_turn_evidence
  BEFORE INSERT OR UPDATE OF turn_id, session_id, user_id, user_message_id, assistant_message_id
  ON public.encounter_session_turns
  FOR EACH ROW EXECUTE FUNCTION public.validate_encounter_turn_evidence();

-- A carried-over Story must reference a settled Encounter owned by the same player
-- and tied to the same character. The copied affinity/memory remain independent.
CREATE OR REPLACE FUNCTION public.validate_story_relationship_origin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
DECLARE
  v_source_user uuid;
  v_source_character uuid;
  v_source_status text;
BEGIN
  IF NEW.origin_mode = 'encounter_snapshot' AND NEW.source_encounter_session_id IS NOT NULL THEN
    SELECT l.user_id, l.character_id, l.status
      INTO v_source_user, v_source_character, v_source_status
    FROM public.encounter_session_lifecycle AS l
    WHERE l.session_id = NEW.source_encounter_session_id;

    IF NOT FOUND
       OR v_source_user IS DISTINCT FROM NEW.user_id
       OR (NEW.character_id IS NOT NULL AND v_source_character IS DISTINCT FROM NEW.character_id)
       OR v_source_status <> 'settled' THEN
      RAISE EXCEPTION 'Encounter snapshot source is invalid or not settled' USING ERRCODE = '23514';
    END IF;
  ELSIF NEW.origin_mode = 'encounter_snapshot'
        AND (TG_OP = 'INSERT' OR OLD.source_encounter_session_id IS NULL) THEN
    RAISE EXCEPTION 'Encounter snapshot source is required at creation' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$;

REVOKE ALL ON FUNCTION public.validate_story_relationship_origin() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS validate_story_relationship_origin ON public.story_relationship_states;
CREATE TRIGGER validate_story_relationship_origin
  BEFORE INSERT OR UPDATE OF origin_mode, source_encounter_session_id, user_id, character_id
  ON public.story_relationship_states
  FOR EACH ROW EXECUTE FUNCTION public.validate_story_relationship_origin();

ALTER TABLE public.encounter_session_lifecycle ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_session_turns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_relationship_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_relationship_batches ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_session_lifecycle FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_session_turns FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.story_relationship_states FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.story_relationship_batches FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_session_lifecycle TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_session_turns TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_relationship_states TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_relationship_batches TO service_role;

-- No authenticated direct reads: raw affinity values, settlement deltas and evaluator
-- payloads are internal state. A narrowly scoped owner-checked presentation RPC
-- will be added with the runtime/UI integration; service_role remains the only
-- application role allowed to read or mutate these tables.

COMMENT ON TABLE public.story_relationship_batches IS
  'One idempotent five-player-turn Story batch per chat session. A completed batch contains both the memory summary and affinity evaluation result.';
