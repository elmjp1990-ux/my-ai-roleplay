-- Permit character messages to retain their immutable speaker snapshot after
-- ON DELETE SET NULL clears the live character foreign key.
ALTER TABLE public.chat_group_messages
  DROP CONSTRAINT IF EXISTS chat_group_messages_check;

ALTER TABLE public.chat_group_messages
  ADD CONSTRAINT chat_group_messages_check
  CHECK (
    (
      speaker_type = 'character'
      AND (
        character_id IS NOT NULL
        OR (
          speaker_snapshot IS NOT NULL
          AND jsonb_typeof(speaker_snapshot) = 'object'
          AND NULLIF(btrim(speaker_snapshot->>'name'), '') IS NOT NULL
        )
      )
    )
    OR (
      speaker_type <> 'character'
      AND character_id IS NULL
    )
  );
