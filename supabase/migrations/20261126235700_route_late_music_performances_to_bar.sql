-- Route active music performances by their Taiwan-local schedule start time.
-- This is a system data correction, not an author edit: pause user triggers so
-- legacy manual rows do not enqueue a fresh AI generation job during migration.
ALTER TABLE public.character_schedules DISABLE TRIGGER USER;

UPDATE public.character_schedules
SET
  location_key = CASE
    WHEN start_time >= TIME '21:00' THEN 'night-bar'
    ELSE 'live-house'
  END,
  location_description = CASE
    WHEN start_time >= TIME '21:00' THEN '夜間酒吧'
    ELSE '展演空間'
  END,
  updated_at = now()
WHERE is_active = true
  AND location_key IN ('live-house', 'night-bar')
  AND activity ~ '(正式演出|正在演出|演出中|演出進入高潮|演出接近尾聲|登台演出|上台演出|現場演出|表演中|現場表演|演唱會演出|舞台上演出|彈奏.{0,12}(帶動|炒熱|感染).{0,8}(觀眾|全場|氣氛)|performing live|live performance|on.?stage)'
  AND (
    (start_time >= TIME '21:00' AND location_key = 'live-house')
    OR (start_time < TIME '21:00' AND location_key = 'night-bar')
  );

ALTER TABLE public.character_schedules ENABLE TRIGGER USER;
