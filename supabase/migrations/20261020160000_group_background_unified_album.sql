-- GROUP-BACKGROUND: keep chat background selection on the unified memory-photo model.
ALTER TABLE public.chat_groups
  ADD COLUMN IF NOT EXISTS background_mode text NOT NULL DEFAULT 'avatar',
  ADD COLUMN IF NOT EXISTS background_memory_photo_id uuid NULL;

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.chat_groups'::regclass
      AND conname = 'chat_groups_background_mode_check'
  ) THEN
    ALTER TABLE public.chat_groups
      ADD CONSTRAINT chat_groups_background_mode_check
      CHECK (background_mode IN ('avatar','none','memory'));
  END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION public.validate_chat_group_background_photo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
BEGIN
  -- Do not block unrelated group edits because of a stale legacy background reference.
  IF TG_OP = 'UPDATE'
     AND NEW.background_mode IS NOT DISTINCT FROM OLD.background_mode
     AND NEW.background_memory_photo_id IS NOT DISTINCT FROM OLD.background_memory_photo_id
     AND NEW.owner_id IS NOT DISTINCT FROM OLD.owner_id THEN
    RETURN NEW;
  END IF;

  IF NEW.background_mode NOT IN ('avatar','none','memory') THEN
    RAISE EXCEPTION 'invalid_group_background_mode';
  END IF;

  IF NEW.background_mode = 'memory' THEN
    IF NEW.background_memory_photo_id IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.chat_memory_photos AS photo
      WHERE photo.id = NEW.background_memory_photo_id
        AND photo.chat_type = 'group'
        AND photo.group_id = NEW.id
        AND photo.owner_id = NEW.owner_id
        AND photo.status = 'active'
        AND photo.deleted_at IS NULL
        AND photo.expires_at > pg_catalog.now()
    ) THEN
      RAISE EXCEPTION 'group_background_photo_not_owned_or_active';
    END IF;
  ELSE
    NEW.background_memory_photo_id := NULL;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.validate_chat_group_background_photo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS validate_chat_group_background_photo ON public.chat_groups;
CREATE TRIGGER validate_chat_group_background_photo
BEFORE INSERT OR UPDATE ON public.chat_groups
FOR EACH ROW
EXECUTE FUNCTION public.validate_chat_group_background_photo();

COMMENT ON COLUMN public.chat_groups.background_mode IS
  'Group background: avatar carousel, no background, or a group-owned active unified memory photo.';
COMMENT ON COLUMN public.chat_groups.background_memory_photo_id IS
  'References chat_memory_photos.id; trigger enforces same-group ownership and active retention status.';
