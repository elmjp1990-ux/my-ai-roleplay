-- Reflect the schedule window closing immediately in session metadata.
-- AI evaluation/diary settlement remains asynchronous, but history must not
-- display a session as ongoing after its lifecycle has reached ready_to_settle.
CREATE OR REPLACE FUNCTION public.sync_encounter_session_ended_metadata()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ended_at timestamptz;
BEGIN
  IF NEW.status='ready_to_settle'
     AND NEW.scheduled_end_at<=clock_timestamp()
     AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    v_ended_at:=NEW.scheduled_end_at;
    UPDATE public.chat_sessions AS session
    SET session_data=COALESCE(session.session_data,'{}'::jsonb) ||
      jsonb_build_object('archived',true,'archivedAt',extract(epoch from v_ended_at)*1000,
                         'encounterEndedAt',extract(epoch from v_ended_at)*1000),
        updated_at=clock_timestamp()
    WHERE session.id=NEW.session_id
      AND session.chat_mode='encounter'
      AND session.deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_encounter_session_ended_metadata_trigger
  ON public.encounter_session_lifecycle;
CREATE TRIGGER sync_encounter_session_ended_metadata_trigger
AFTER INSERT OR UPDATE OF status ON public.encounter_session_lifecycle
FOR EACH ROW EXECUTE FUNCTION public.sync_encounter_session_ended_metadata();

-- Backfill already-expired sessions at migration time so history does not wait
-- for the next dispatcher tick to stop showing them as ongoing.
UPDATE public.chat_sessions AS session
SET session_data=COALESCE(session.session_data,'{}'::jsonb) ||
    jsonb_build_object('archived',true,'archivedAt',extract(epoch from lifecycle.scheduled_end_at)*1000,
                       'encounterEndedAt',extract(epoch from lifecycle.scheduled_end_at)*1000),
    updated_at=clock_timestamp()
FROM public.encounter_session_lifecycle AS lifecycle
WHERE lifecycle.session_id=session.id
  AND lifecycle.status IN ('active','paused','ready_to_settle')
  AND lifecycle.scheduled_end_at<=clock_timestamp()
  AND session.chat_mode='encounter'
  AND session.deleted_at IS NULL
  AND (COALESCE(session.session_data->>'archived','false')<>'true'
       OR session.session_data->>'encounterEndedAt' IS NULL);
