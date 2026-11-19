-- Additive only: existing AI output and revision rows are not rewritten or deleted.
BEGIN;
ALTER TABLE public.encounter_schedule_generation_outputs
  ADD COLUMN IF NOT EXISTS removed_at timestamptz,
  ADD COLUMN IF NOT EXISTS removed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS encounter_schedule_generation_outputs_visible_actor_idx
  ON public.encounter_schedule_generation_outputs (actor_user_id, created_at DESC)
  WHERE removed_at IS NULL;
REVOKE DELETE ON TABLE public.encounter_schedule_generation_outputs FROM service_role;
REVOKE DELETE ON TABLE public.encounter_schedule_generation_output_revisions FROM service_role;
COMMENT ON COLUMN public.encounter_schedule_generation_outputs.removed_at IS
  'Soft-hide timestamp for the Encounter repair panel; the original AI response and revisions remain stored.';
COMMENT ON COLUMN public.encounter_schedule_generation_outputs.removed_by IS
  'User who hid this output from the Encounter repair panel; this does not delete the original response.';
COMMIT;
