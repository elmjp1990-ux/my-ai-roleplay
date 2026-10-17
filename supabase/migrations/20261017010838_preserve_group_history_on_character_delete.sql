-- Preserve cross-user group history when a character author account is deleted.
-- Add durable speaker identity before loosening character foreign keys.
ALTER TABLE public.chat_group_messages
  ADD COLUMN IF NOT EXISTS speaker_snapshot jsonb;

-- Prefer the immutable member snapshot, but fall back to the live character row
-- so a message is not left without a display name if its member row is missing.
UPDATE public.chat_group_messages AS msg
SET speaker_snapshot = jsonb_build_object(
  'id', COALESCE(
    (
      SELECT member.character_snapshot->>'id'
      FROM public.chat_group_members AS member
      WHERE member.group_id = msg.group_id
        AND member.character_id = msg.character_id
      ORDER BY member.position
      LIMIT 1
    ),
    msg.character_id::text
  ),
  'name', COALESCE(
    (
      SELECT member.character_snapshot->>'name'
      FROM public.chat_group_members AS member
      WHERE member.group_id = msg.group_id
        AND member.character_id = msg.character_id
      ORDER BY member.position
      LIMIT 1
    ),
    character_row.name,
    '角色'
  )
)
FROM public.characters AS character_row
WHERE msg.speaker_type = 'character'
  AND msg.character_id = character_row.id
  AND msg.speaker_snapshot IS NULL;

ALTER TABLE public.chat_group_members
  ALTER COLUMN character_id DROP NOT NULL;

DO $migration$
DECLARE
  v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT DISTINCT c.conname
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
    SELECT DISTINCT c.conname
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
