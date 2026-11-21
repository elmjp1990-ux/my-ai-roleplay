BEGIN;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='encounter_schedule_generation_outputs' AND column_name='removed_at')
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='encounter_schedule_generation_outputs' AND column_name='removed_by') THEN
    RAISE EXCEPTION 'encounter_schedule_output_soft_hide_columns_missing';
  END IF;
  IF has_table_privilege('service_role','public.encounter_schedule_generation_outputs','DELETE')
     OR has_table_privilege('service_role','public.encounter_schedule_generation_output_revisions','DELETE') THEN
    RAISE EXCEPTION 'encounter_schedule_output_physical_delete_still_granted';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname='public' AND indexname='encounter_schedule_generation_outputs_visible_actor_idx') THEN
    RAISE EXCEPTION 'encounter_schedule_output_visible_index_missing';
  END IF;
END;
$$;
ROLLBACK;
