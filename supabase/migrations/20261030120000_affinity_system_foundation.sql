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
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
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
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
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
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  origin_mode text NOT NULL
    CHECK (origin_mode IN ('encounter_snapshot', 'fresh_story')),
  affinity integer NOT NULL DEFAULT 0 CHECK (affinity BETWEEN -100 AND 100),
  relationship_stage text NOT NULL DEFAULT 'first_meeting'
    CHECK (relationship_stage IN (
      'hostile', 'dislike', 'wary',
      'first_meeting', 'acquaintance', 'close', 'intimate', 'special'
    )),
  source_encounter_session_id uuid,
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
    (origin_mode = 'encounter_snapshot'
      AND source_encounter_session_id IS NOT NULL
      AND snapshot_at IS NOT NULL)
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
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
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

ALTER TABLE public.encounter_session_lifecycle ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_session_turns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_relationship_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_relationship_batches ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_session_lifecycle FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_session_turns FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.story_relationship_states FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.story_relationship_batches FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.encounter_session_lifecycle TO authenticated;
GRANT SELECT ON TABLE public.encounter_session_turns TO authenticated;
GRANT SELECT ON TABLE public.story_relationship_states TO authenticated;
GRANT SELECT ON TABLE public.story_relationship_batches TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_session_lifecycle TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_session_turns TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_relationship_states TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_relationship_batches TO service_role;

DROP POLICY IF EXISTS encounter_session_lifecycle_select_own ON public.encounter_session_lifecycle;
CREATE POLICY encounter_session_lifecycle_select_own
  ON public.encounter_session_lifecycle FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS encounter_session_turns_select_own ON public.encounter_session_turns;
CREATE POLICY encounter_session_turns_select_own
  ON public.encounter_session_turns FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS story_relationship_states_select_own ON public.story_relationship_states;
CREATE POLICY story_relationship_states_select_own
  ON public.story_relationship_states FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS story_relationship_batches_select_own ON public.story_relationship_batches;
CREATE POLICY story_relationship_batches_select_own
  ON public.story_relationship_batches FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

COMMENT ON TABLE public.story_relationship_batches IS
  'One idempotent five-player-turn Story batch per chat session. A completed batch contains both the memory summary and affinity evaluation result.';
