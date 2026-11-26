-- Enforce the POYOZZ music-performance venue rule for future manual and AI writes.
-- 20:00 and earlier: exhibition space; 21:00 and later: night bar.
CREATE OR REPLACE FUNCTION public.enforce_music_performance_venue_by_time()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.start_time IS NOT NULL
    AND NEW.activity ~ '(正式演出|正在演出|演出中|演出進入高潮|演出接近尾聲|登台演出|上台演出|現場演出|表演中|現場表演|演唱會演出|舞台上演出|彈奏.{0,12}(帶動|炒熱|感染).{0,8}(觀眾|全場|氣氛)|performing live|live performance|on.?stage)'
  THEN
    IF NEW.start_time >= TIME '21:00' THEN
      NEW.location_key := 'night-bar';
      NEW.location_description := '夜間酒吧';
    ELSE
      NEW.location_key := 'live-house';
      NEW.location_description := '展演空間';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_music_performance_venue_by_time
  ON public.character_schedules;

CREATE TRIGGER enforce_music_performance_venue_by_time
BEFORE INSERT OR UPDATE OF start_time, location_key, location_description, activity
ON public.character_schedules
FOR EACH ROW
EXECUTE FUNCTION public.enforce_music_performance_venue_by_time();
