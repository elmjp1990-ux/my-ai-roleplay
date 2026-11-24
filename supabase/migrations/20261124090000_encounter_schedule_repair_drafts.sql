-- Persist user-edited Encounter schedule repair drafts without validating or publishing them.
-- Draft content remains append-only in the existing revision audit table.
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

COMMENT ON TABLE public.encounter_schedule_generation_output_revisions IS
  'Append-only human correction drafts and submissions for Encounter schedule AI outputs; corrected content and validation evidence are immutable while workflow status may advance.';
