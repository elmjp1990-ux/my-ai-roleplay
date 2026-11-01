-- DRAFT ONLY — PR #200 encounter diary lifecycle visibility guard.
-- Reviewed read-only against the connected test project on 2026-11-01.
-- Do not apply to a hosted database until the migration baseline/replay is reconciled.
--
-- Finding:
--   public.encounter_diary is directly SELECT-granted to authenticated and its
--   only current policy is owner-scoped. Every current row has metadata.session_id.
--   The 30-day chat purge deletes encounter_diary rows by metadata.session_id,
--   but there is currently no RLS policy requiring that linked session to remain
--   active. This means a deleted encounter chat's diary can remain readable
--   during the 30-day backend-only retention period.
--
-- Current data impact at audit time:
--   11 diary rows total, all with metadata.session_id; 0 linked to deleted
--   sessions, 11 linked to active sessions. This is a future-path lifecycle gap,
--   not evidence of current deleted-chat diary exposure.
--
-- Preserve standalone diary entries without a session_id. If session_id exists,
-- fail closed unless it identifies an active session owned by the caller.

DROP POLICY IF EXISTS encounter_diary_active_session_lifecycle_guard
  ON public.encounter_diary;

CREATE POLICY encounter_diary_active_session_lifecycle_guard
ON public.encounter_diary
AS RESTRICTIVE
FOR SELECT
TO authenticated
USING (
  NOT (metadata ? 'session_id')
  OR EXISTS (
    SELECT 1
    FROM public.chat_sessions AS s
    WHERE s.id::text = public.encounter_diary.metadata->>'session_id'
      AND s.user_id = (SELECT auth.uid())
      AND s.deleted_at IS NULL
  )
);

-- Required local fixture checks before promotion:
-- 1. Owner can read a diary row linked to an active owned session.
-- 2. After that session is soft-deleted, owner cannot read the diary row.
-- 3. Owner cannot read the row if the referenced session belongs to another user.
-- 4. Rows with no metadata.session_id retain the existing owner-only behavior.
-- 5. At day 30, purge_chat_deletion_job still deletes linked diary rows.
