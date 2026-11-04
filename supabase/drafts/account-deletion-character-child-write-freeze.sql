-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Consistent pending-account-deletion RLS freeze for author-managed character data.
-- Do not execute against the hosted Supabase project.
--
-- Existing owner policies remain the permissive ownership/visibility checks.
-- These additional RESTRICTIVE policies are AND gates for authenticated users:
-- a pending-deletion account cannot read or mutate these owner-managed rows.
-- Public/anon reads are not changed because these policies target authenticated.
--
-- Pair with account-is-active-auth-user-existence-guard.sql so stale JWTs for
-- deleted Auth users also fail account_is_active().

DO $policy$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'character_private_info'
      AND c.relkind = 'r'
  ) THEN
    RAISE EXCEPTION 'required table public.character_private_info is missing';
  END IF;
END;
$policy$;

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_private_info;
CREATE POLICY account_must_be_active
  ON public.character_private_info
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_schedules;
CREATE POLICY account_must_be_active
  ON public.character_schedules
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_schedule_descriptions;
CREATE POLICY account_must_be_active
  ON public.character_schedule_descriptions
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_illustrations;
CREATE POLICY account_must_be_active
  ON public.character_illustrations
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

-- No policy is added to character_comments or character_comment_likes here:
-- those are player-authored social records, not author-owned character settings.
-- Their deletion/anonymization policy is separate from character retention.
