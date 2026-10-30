-- Encounter mode MVP foundation: character profile, private affinity/diary, author-managed schedules.
-- Deliberately does not expose schedule rows to players yet; a safe public resolver must
-- apply the same character visibility and age-gate rules as the existing character reads.

ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS personality_profile jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.characters
  DROP CONSTRAINT IF EXISTS characters_personality_profile_object_check;
ALTER TABLE public.characters
  ADD CONSTRAINT characters_personality_profile_object_check
  CHECK (
    jsonb_typeof(personality_profile) = 'object'
    AND pg_column_size(personality_profile) <= 12000
  );

COMMENT ON COLUMN public.characters.personality_profile IS
  'Creator-authored structured public character personality. Private author-only details remain in character_private_info.';

CREATE TABLE IF NOT EXISTS public.encounter_character_state (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  affinity integer NOT NULL DEFAULT 0 CHECK (affinity BETWEEN 0 AND 100),
  relationship_stage text NOT NULL DEFAULT 'first_meeting'
    CHECK (relationship_stage IN ('first_meeting', 'acquaintance', 'close', 'intimate', 'special')),
  first_met_at timestamptz,
  last_interaction_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, character_id)
);

COMMENT ON TABLE public.encounter_character_state IS
  'Authoritative per-player/per-character Encounter affinity. Client roles may read own rows only; writes are reserved for trusted backend functions.';

CREATE TABLE IF NOT EXISTS public.encounter_diary (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  event_type text NOT NULL DEFAULT 'interaction'
    CHECK (char_length(event_type) BETWEEN 1 AND 60),
  summary text NOT NULL
    CHECK (char_length(summary) BETWEEN 1 AND 2000),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 4000),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.encounter_diary IS
  'Private Encounter event summaries scoped to one user and one character. Direct client writes are disabled; trusted backend owns diary creation.';

CREATE INDEX IF NOT EXISTS encounter_diary_user_character_time_idx
  ON public.encounter_diary (user_id, character_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS encounter_state_character_idx
  ON public.encounter_character_state (character_id);

CREATE TABLE IF NOT EXISTS public.character_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  weekday smallint CHECK (weekday BETWEEN 0 AND 6),
  day_type text NOT NULL DEFAULT 'any'
    CHECK (day_type IN ('any', 'weekday', 'weekend')),
  start_time time NOT NULL,
  end_time time NOT NULL,
  location_key text NOT NULL CHECK (char_length(location_key) BETWEEN 1 AND 80),
  activity text NOT NULL CHECK (char_length(activity) BETWEEN 1 AND 300),
  priority smallint NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 100),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (start_time <> end_time)
);

COMMENT ON TABLE public.character_schedules IS
  'Creator-managed schedule for Encounter mode. Intentionally author-only until a public resolver can enforce all character visibility and age-gate rules.';

CREATE INDEX IF NOT EXISTS character_schedules_character_active_idx
  ON public.character_schedules (character_id, is_active, priority DESC);

ALTER TABLE public.encounter_character_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_diary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.character_schedules ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_character_state FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_diary FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.character_schedules FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.encounter_character_state TO authenticated;
GRANT SELECT ON TABLE public.encounter_diary TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.character_schedules TO authenticated;

DROP POLICY IF EXISTS encounter_state_select_own ON public.encounter_character_state;
CREATE POLICY encounter_state_select_own
  ON public.encounter_character_state
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS encounter_diary_select_own ON public.encounter_diary;
CREATE POLICY encounter_diary_select_own
  ON public.encounter_diary
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS character_schedules_select_author ON public.character_schedules;
CREATE POLICY character_schedules_select_author
  ON public.character_schedules
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
  );

DROP POLICY IF EXISTS character_schedules_insert_author ON public.character_schedules;
CREATE POLICY character_schedules_insert_author
  ON public.character_schedules
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
  );

DROP POLICY IF EXISTS character_schedules_update_author ON public.character_schedules;
CREATE POLICY character_schedules_update_author
  ON public.character_schedules
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
  );

DROP POLICY IF EXISTS character_schedules_delete_author ON public.character_schedules;
CREATE POLICY character_schedules_delete_author
  ON public.character_schedules
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
  );