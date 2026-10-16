-- Preserve cross-user group history when a character author account is deleted.
-- Add durable speaker identity before loosening character foreign keys.
ALTER TABLE public.chat_group_messages
  ADD COLUMN IF NOT EXISTS speaker_snapshot jsonb;

UPDATE public.chat_group_messages AS msg
SET speaker_snapshot = jsonb_build_object(
  'id', member.character_snapshot->>'id',
  'name', member.character_snapshot->>'name'
)
FROM public.chat_group_members AS member
WHERE msg.speaker_type = 'character'
  AND msg.group_id = member.group_id
  AND msg.character_id = member.character_id
  AND msg.speaker_snapshot IS NULL;

ALTER TABLE public.chat_group_members
  ALTER COLUMN character_id DROP NOT NULL;

DO $migration$
DECLARE
  v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT c.conname
    FROM pg_catalog.pg_constraint AS c
    JOIN pg_catalog.pg_attribute AS a
      ON a.attrelid = c.conrelid
     AND a.attnum = ANY(c.conkey)
    WHERE c.contype = 'f'
      AND c.conrelid = 'public.chat_group_members'::regclass
      AND a.attname = 'character_id'
      AND c.confrelid = 'public.characters'::regclass
  LOOP
    EXECUTE format('ALTER TABLE public.chat_group_members DROP CONSTRAINT %I', v_constraint);
  END LOOP;
  ALTER TABLE public.chat_group_members
    ADD CONSTRAINT chat_group_members_character_id_fkey
    FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE SET NULL;
END
$migration$;

DO $migration$
DECLARE
  v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT c.conname
    FROM pg_catalog.pg_constraint AS c
    JOIN pg_catalog.pg_attribute AS a
      ON a.attrelid = c.conrelid
     AND a.attnum = ANY(c.conkey)
    WHERE c.contype = 'f'
      AND c.conrelid = 'public.chat_group_messages'::regclass
      AND a.attname = 'character_id'
      AND c.confrelid = 'public.characters'::regclass
  LOOP
    EXECUTE format('ALTER TABLE public.chat_group_messages DROP CONSTRAINT %I', v_constraint);
  END LOOP;
  ALTER TABLE public.chat_group_messages
    ADD CONSTRAINT chat_group_messages_character_id_fkey
    FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE SET NULL;
END
$migration$;
