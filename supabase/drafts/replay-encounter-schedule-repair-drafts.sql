-- Idempotent local synthetic replay for saved Encounter schedule correction drafts.
ALTER TABLE public.encounter_schedule_generation_output_revisions
  DROP CONSTRAINT IF EXISTS encounter_schedule_generation_output_revisions_status_check;

ALTER TABLE public.encounter_schedule_generation_output_revisions
  ADD CONSTRAINT encounter_schedule_generation_output_revisions_status_check
  CHECK (status IN (
    'draft',
    'invalid',
    'validated',
    'published',
    'publish_failed',
    'needs_reconciliation'
  ));
