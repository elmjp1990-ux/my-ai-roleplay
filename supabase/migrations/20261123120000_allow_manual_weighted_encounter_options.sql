BEGIN;
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_special_event_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_special_event_check
  CHECK (
    (
      variant_key = 'special'
      AND special_event_key = ANY (ARRAY['taiwan_public_holiday','lunar_new_year','valentines_day','christmas'])
      AND day_type = 'any'
      AND variant_weight = 100
    )
    OR (
      variant_key IN ('primary','alternative')
      AND special_event_key IS NULL
    )
    OR (
      variant_key IN ('option_1','option_2','option_3')
      AND source_type IN ('ai','manual')
      AND special_event_key IS NULL
      AND day_type IN ('weekday','holiday')
    )
  );
COMMIT;