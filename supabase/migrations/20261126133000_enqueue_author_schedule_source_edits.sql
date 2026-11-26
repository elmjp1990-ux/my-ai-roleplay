-- Treat author edits to schedule descriptions, private context, and manual schedule rows
-- as source changes; batch scans remain read-only for characters with active schedules.
BEGIN;

CREATE OR REPLACE FUNCTION public.on_encounter_character_private_info_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id, true);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.on_encounter_schedule_description_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id, true);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.on_encounter_manual_schedule_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_character_id uuid;
  v_was_manual boolean := false;
  v_is_manual boolean := false;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    v_was_manual := OLD.source_type = 'manual';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_is_manual := NEW.source_type = 'manual';
  END IF;

  IF NOT v_was_manual AND NOT v_is_manual THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id, true);

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS character_schedules_enqueue_encounter_schedule_ai
  ON public.character_schedules;
CREATE TRIGGER character_schedules_enqueue_encounter_schedule_ai
AFTER INSERT OR UPDATE OR DELETE ON public.character_schedules
FOR EACH ROW
EXECUTE FUNCTION public.on_encounter_manual_schedule_changed();

COMMIT;
