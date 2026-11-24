-- Finish mapping Jiang Chenyuan's already-published schedules to existing city scenes.
-- This is a no-AI data-only correction; keep authored labels and activity text.
BEGIN;

UPDATE public.character_schedules
SET location_key = 'commercial',
    updated_at = pg_catalog.now()
WHERE character_id = '19000b3d-6a0a-4266-8248-4acafab82305'
  AND source_type = 'ai'
  AND is_active IS TRUE
  AND location_key IS NULL
  AND location_description IN ('事務所', '工作室');

UPDATE public.character_schedules
SET location_key = 'apartment',
    updated_at = pg_catalog.now()
WHERE character_id = '19000b3d-6a0a-4266-8248-4acafab82305'
  AND source_type = 'ai'
  AND is_active IS TRUE
  AND location_key IS NULL
  AND location_description = '你家';

COMMIT;
