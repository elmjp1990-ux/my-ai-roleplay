-- Persist the latest three AI-generated group reply suggestions on each completed turn.
ALTER TABLE public.chat_group_turns
  ADD COLUMN IF NOT EXISTS suggested_replies jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.chat_group_turns
  ALTER COLUMN suggested_replies SET DEFAULT '[]'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.chat_group_turns'::regclass
      AND conname = 'chat_group_turns_suggested_replies_array_check'
  ) THEN
    ALTER TABLE public.chat_group_turns
      ADD CONSTRAINT chat_group_turns_suggested_replies_array_check
      CHECK (jsonb_typeof(suggested_replies) = 'array' AND jsonb_array_length(suggested_replies) <= 3);
  END IF;
END $$;

COMMENT ON COLUMN public.chat_group_turns.suggested_replies IS
  'Latest AI-generated player reply suggestions for this completed group turn; rendered by the shared single/group chat suggestion UI.';
