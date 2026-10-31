-- Cover the author ownership foreign key used by schedule-description RLS.
CREATE INDEX IF NOT EXISTS character_schedule_descriptions_author_id_idx
  ON public.character_schedule_descriptions (author_id);